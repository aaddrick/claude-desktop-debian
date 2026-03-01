#!/usr/bin/env node

/**
 * Linux Cowork VM Service Daemon
 *
 * Replaces the Windows cowork-vm-service for Linux. Listens on a Unix domain
 * socket using the same length-prefixed JSON protocol as the Windows named pipe.
 *
 * Architecture: VMManager (dispatcher) + pluggable backends
 *   - HostBackend:  Run processes directly on host (no isolation)
 *   - BwrapBackend: Bubblewrap namespace sandbox
 *   - KvmBackend:   QEMU/KVM virtual machine with vsock communication
 *
 * Backend selection (auto-detected or overridden via COWORK_VM_BACKEND env):
 *   1. kvm   — if /dev/kvm, qemu-system-x86_64, /dev/vhost-vsock, and
 *              rootfs.qcow2 are all available
 *   2. bwrap — if bwrap is installed and functional
 *   3. host  — fallback, no isolation
 *
 * Protocol:
 *   Transport: Unix domain socket at $XDG_RUNTIME_DIR/cowork-vm-service.sock
 *   Framing:   4-byte big-endian length prefix + JSON payload
 *   Request:   { method: "methodName", params: {...} }
 *   Response:  { success: true, result: {...} } or { success: false, error: "..." }
 *   Events:    { type: "stdout"|"stderr"|"exit"|"error"|"networkStatus"|"apiReachability", ... }
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { spawn: spawnProcess, execSync, execFileSync } = require('child_process');

// ============================================================
// Configuration
// ============================================================

const SOCKET_PATH = (process.env.XDG_RUNTIME_DIR || '/tmp') +
    '/cowork-vm-service.sock';
const DEBUG = process.env.COWORK_VM_DEBUG === '1' ||
    process.env.CLAUDE_LINUX_DEBUG === '1';
const LOG_PREFIX = '[cowork-vm-service]';

// Backend override: set COWORK_VM_BACKEND to "host", "bwrap", or "kvm"
// to force a specific backend instead of auto-detection.
const BACKEND_OVERRIDE = process.env.COWORK_VM_BACKEND || null;

// The daemon is forked with stdio:'ignore', so console output goes nowhere.
// Write logs to a file so they're accessible for debugging.
const LOG_FILE = path.join(
    process.env.HOME || '/tmp',
    '.config', 'Claude', 'logs', 'cowork_vm_daemon.log'
);
function formatArgs(args) {
    return args.map(a => typeof a === 'string' ? a : JSON.stringify(a))
        .join(' ');
}

function writeLog(level, args) {
    const ts = new Date().toISOString();
    const msg = `${ts} [${level}] ${LOG_PREFIX} ${formatArgs(args)}\n`;
    try {
        fs.appendFileSync(LOG_FILE, msg);
    } catch (_) {
        // Ignore write errors (dir may not exist yet)
    }
}

function log(...args) {
    if (!DEBUG) return;
    writeLog('debug', args);
    console.log(LOG_PREFIX, ...args);
}

function logError(...args) {
    writeLog('error', args);
    console.error(LOG_PREFIX, ...args);
}

// ============================================================
// Length-Prefixed JSON Protocol (matches Windows pipe protocol)
// ============================================================

/**
 * Write a length-prefixed JSON message to a socket.
 * Format: 4 bytes big-endian length + JSON bytes
 */
function writeMessage(socket, message) {
    const json = JSON.stringify(message);
    const jsonBuf = Buffer.from(json, 'utf8');
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(jsonBuf.length, 0);
    socket.write(Buffer.concat([lenBuf, jsonBuf]));
}

/**
 * Parse a length-prefixed JSON message from a buffer.
 * Returns { message, remaining } or null if incomplete.
 */
function parseMessage(buffer) {
    if (buffer.length < 4) return null;
    const len = buffer.readUInt32BE(0);
    if (buffer.length < 4 + len) return null;
    const json = buffer.subarray(4, 4 + len).toString('utf8');
    const remaining = Buffer.from(buffer.subarray(4 + len));
    return { message: JSON.parse(json), remaining };
}

// ============================================================
// Shared Helpers (used by multiple backends)
// ============================================================

/**
 * Keys to strip from spawned process environments.
 * CLAUDECODE triggers "cannot be launched inside another session".
 * ELECTRON_* are Electron internals that break child processes.
 */
const BLOCKED_ENV_KEYS = new Set([
    'CLAUDECODE', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ASAR',
]);

/**
 * Filter environment variables, removing blocked keys and optional prefixes.
 */
function filterEnv(source, stripPrefixes = []) {
    const result = {};
    for (const [k, v] of Object.entries(source)) {
        if (BLOCKED_ENV_KEYS.has(k)) continue;
        if (stripPrefixes.some(p => k.startsWith(p))) continue;
        result[k] = v;
    }
    return result;
}

/**
 * Build a merged environment for a spawned process.
 * Combines filtered daemon env with filtered app-provided env.
 */
function buildSpawnEnv(appEnv) {
    const mergedEnv = {
        ...filterEnv(process.env, ['CLAUDE_CODE_']),
        ...filterEnv(appEnv || {}),
        TERM: 'xterm-256color',
    };

    // CLAUDE_CONFIG_DIR from the app points to a VM guest path
    // (/sessions/<name>/mnt/.claude) that doesn't exist on the host.
    // Remove it so Claude Code uses its default (~/.claude/).
    if (mergedEnv.CLAUDE_CONFIG_DIR &&
        mergedEnv.CLAUDE_CONFIG_DIR.startsWith('/sessions/')) {
        log(`buildSpawnEnv: removing VM guest CLAUDE_CONFIG_DIR: ${mergedEnv.CLAUDE_CONFIG_DIR}`);
        delete mergedEnv.CLAUDE_CONFIG_DIR;
    }

    return mergedEnv;
}

/**
 * Filter out args that reference VM guest paths (/sessions/...).
 * Flags like --add-dir and --plugin-dir point to paths inside the VM
 * that don't exist on the host.
 */
function cleanSpawnArgs(rawArgs) {
    const cleanArgs = [];
    const guestPathFlags = new Set(['--add-dir', '--plugin-dir']);
    for (let i = 0; i < rawArgs.length; i++) {
        if (guestPathFlags.has(rawArgs[i]) &&
            i + 1 < rawArgs.length &&
            rawArgs[i + 1].startsWith('/sessions/')) {
            log(`cleanSpawnArgs: removing ${rawArgs[i]} ${rawArgs[i + 1]} (VM guest path)`);
            i++; // skip the value too
            continue;
        }
        cleanArgs.push(rawArgs[i]);
    }
    return cleanArgs;
}

/**
 * Resolve the working directory from spawn params.
 * Handles sharedCwdPath, guest paths, and non-existent directories.
 */
function resolveWorkDir(cwd, sharedCwdPath) {
    let workDir = cwd || os.homedir();
    if (sharedCwdPath) {
        workDir = path.join(os.homedir(), sharedCwdPath);
    } else if (cwd && cwd.startsWith('/sessions/')) {
        log(`resolveWorkDir: cwd is VM guest path "${cwd}", using home dir`);
        workDir = os.homedir();
    }

    if (!fs.existsSync(workDir)) {
        log(`resolveWorkDir: cwd "${workDir}" does not exist, using home dir`);
        workDir = os.homedir();
    }

    return workDir;
}

/**
 * Resolve the SDK binary path from subpath and version.
 * Returns the path if found and executable, null otherwise.
 */
function resolveSdkBinary(sdkSubpath, version, label) {
    if (!sdkSubpath || !version) return null;
    const candidatePath = path.join(
        os.homedir(), sdkSubpath, version, 'claude'
    );
    try {
        fs.accessSync(candidatePath, fs.constants.X_OK);
        log(`${label}: SDK binary found: ${candidatePath}`);
        return candidatePath;
    } catch (e) {
        log(`${label}: SDK binary not found: ${candidatePath}`);
        return null;
    }
}

/**
 * Resolve the actual command binary to execute.
 * Priority: 1) SDK binary from installSdk, 2) command path, 3) which
 * Returns { command, error } — error is set if command not found.
 */
function resolveCommand(command, sdkBinaryPath) {
    if (sdkBinaryPath && fs.existsSync(sdkBinaryPath)) {
        log(`resolveCommand: using SDK binary: ${sdkBinaryPath}`);
        return { command: sdkBinaryPath, error: null };
    }

    if (fs.existsSync(command)) {
        return { command, error: null };
    }

    const basename = path.basename(command);
    try {
        const resolved = execFileSync('which', [basename],
            { encoding: 'utf-8' }).trim();
        log(`resolveCommand: resolved via which: ${resolved}`);
        return { command: resolved, error: null };
    } catch (e) {
        return { command: null, error: `${command} not found` };
    }
}

// ============================================================
// Backend Base Class
// ============================================================

/**
 * Base class documenting the interface all backends must implement.
 * Each backend receives an emitEvent callback for broadcasting events
 * (stdout, stderr, exit, error, networkStatus, etc.) to subscribers.
 */
class BackendBase {
    constructor(emitEvent) {
        /** @type {function} Callback to broadcast events to subscribers */
        this.emitEvent = emitEvent;
    }

    /** One-time initialization with VM config */
    async init(config) {
        throw new Error('Not implemented: init');
    }

    /** Start the VM/sandbox/nothing */
    async startVM(params) {
        throw new Error('Not implemented: startVM');
    }

    /** Stop everything */
    async stopVM() {
        throw new Error('Not implemented: stopVM');
    }

    /** Return { running: bool } */
    isRunning() {
        throw new Error('Not implemented: isRunning');
    }

    /** Return { connected: bool } */
    isGuestConnected() {
        throw new Error('Not implemented: isGuestConnected');
    }

    /** Spawn a process */
    async spawn(params) {
        throw new Error('Not implemented: spawn');
    }

    /** Kill a process */
    async kill(params) {
        throw new Error('Not implemented: kill');
    }

    /** Write to process stdin */
    async writeStdin(params) {
        throw new Error('Not implemented: writeStdin');
    }

    /** Check if process is running, return { running: bool } */
    isProcessRunning(params) {
        throw new Error('Not implemented: isProcessRunning');
    }

    /** Handle mount requests */
    async mountPath(params) {
        throw new Error('Not implemented: mountPath');
    }

    /** Read a file */
    async readFile(params) {
        throw new Error('Not implemented: readFile');
    }

    /** Handle SDK installation */
    async installSdk(params) {
        throw new Error('Not implemented: installSdk');
    }

    /** Handle OAuth */
    async addApprovedOauthToken(params) {
        throw new Error('Not implemented: addApprovedOauthToken');
    }
}

// ============================================================
// LocalBackend — Shared logic for host-local backends
// ============================================================

/**
 * Common base for backends that run processes locally (Host and Bwrap).
 * Provides shared implementations of process management, file I/O,
 * SDK installation, and lifecycle methods. Subclasses override
 * startVM(), stopVM(), spawn(), and mountPath() as needed.
 */
class LocalBackend extends BackendBase {
    constructor(emitEvent, backendName) {
        super(emitEvent);
        this.backendName = backendName;
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.running = false;
        this.guestConnected = false;
        this.sdkBinaryPath = null;
        this.processes = new Map();
    }

    async init(config) {
        if (config.memoryMB !== undefined) {
            this.config.memoryMB = config.memoryMB;
        }
        if (config.cpuCount !== undefined) {
            this.config.cpuCount = config.cpuCount;
        }
        log(`${this.backendName} configured:`, this.config);
    }

    isRunning() {
        return { running: this.running };
    }

    isGuestConnected() {
        return { connected: this.guestConnected };
    }

    /**
     * Spawn a local process. Subclasses call this with the resolved
     * command and args to get consistent event wiring.
     * @param {string} id - Process identifier
     * @param {string} spawnCmd - Command to execute
     * @param {string[]} spawnArgs - Arguments array
     * @param {string} workDir - Working directory
     * @param {object} env - Environment variables
     */
    _spawnLocal(id, spawnCmd, spawnArgs, workDir, env) {
        const proc = spawnProcess(spawnCmd, spawnArgs, {
            cwd: workDir,
            env,
            stdio: ['pipe', 'pipe', 'pipe'],
        });

        log(`${this.backendName} spawn: pid=${proc.pid}`);
        this.processes.set(id, proc);

        proc.stdout.on('data', (data) => {
            this.emitEvent({ type: 'stdout', id, data: data.toString() });
        });

        proc.stderr.on('data', (data) => {
            this.emitEvent({ type: 'stderr', id, data: data.toString() });
        });

        proc.on('exit', (exitCode, signal) => {
            log(`${this.backendName}: process ${id} exited: code=${exitCode}, signal=${signal}`);
            this.processes.delete(id);
            this.emitEvent({ type: 'exit', id, exitCode, signal });
        });

        proc.on('error', (err) => {
            this.emitEvent({ type: 'error', id, message: err.message });
        });

        return proc;
    }

    /**
     * Resolve command and prepare environment/args for spawning.
     * Returns null and emits error events if command not found.
     */
    _prepareSpawn(params) {
        const { id, name, command, args, cwd, env,
            sharedCwdPath } = params;

        log(`${this.backendName} spawn: id=${id}, name=${name}, command=${command}`);

        const workDir = resolveWorkDir(cwd, sharedCwdPath);
        const resolved = resolveCommand(command, this.sdkBinaryPath);

        if (resolved.error) {
            this.emitEvent({
                type: 'stderr', id,
                data: `Error: ${resolved.error}\n`,
            });
            this.emitEvent({
                type: 'exit', id, exitCode: 127, signal: null,
            });
            return null;
        }

        return {
            id,
            actualCommand: resolved.command,
            cleanArgs: cleanSpawnArgs(args || []),
            mergedEnv: buildSpawnEnv(env),
            workDir,
        };
    }

    _killAllProcesses(killSignal) {
        for (const [id, proc] of this.processes) {
            try {
                if (proc.kill) proc.kill(killSignal);
            } catch (e) {
                log(`${this.backendName}: error killing process ${id}:`, e.message);
            }
        }
        this.processes.clear();
    }

    _setDisconnected() {
        this.running = false;
        this.guestConnected = false;
        this.emitEvent({ type: 'networkStatus', status: 'disconnected' });
    }

    async kill(params) {
        const { id, signal } = params;
        const proc = this.processes.get(id);
        if (proc) {
            try {
                proc.kill(signal || 'SIGTERM');
            } catch (e) {
                log(`${this.backendName}: kill failed for ${id}:`, e.message);
            }
        }
        return {};
    }

    async writeStdin(params) {
        const { id, data } = params;
        const proc = this.processes.get(id);
        if (proc && proc.stdin && !proc.stdin.destroyed) {
            proc.stdin.write(data);
        }
        return {};
    }

    isProcessRunning(params) {
        return { running: !!this.processes.get(params.id) };
    }

    async readFile(params) {
        const { filePath } = params;
        log(`${this.backendName} readFile: ${filePath}`);
        const resolved = path.resolve(filePath);
        const home = os.homedir();
        if (!resolved.startsWith(home + path.sep) && resolved !== home) {
            return { error: 'Access denied: path outside home directory' };
        }
        try {
            const content = fs.readFileSync(resolved, 'utf8');
            return { content };
        } catch (e) {
            return { error: e.message };
        }
    }

    async installSdk(params) {
        const { sdkSubpath, version } = params;
        log(`${this.backendName} installSdk: ${sdkSubpath}@${version}`);
        const resolved = resolveSdkBinary(
            sdkSubpath, version, this.backendName
        );
        if (resolved) this.sdkBinaryPath = resolved;
        return {};
    }

    async addApprovedOauthToken(params) {
        log(`${this.backendName}: addApprovedOauthToken`);
        return {};
    }
}

// ============================================================
// HostBackend — Run processes directly on host (no isolation)
// ============================================================

class HostBackend extends LocalBackend {
    constructor(emitEvent) {
        super(emitEvent, 'HostBackend');
    }

    async startVM(params) {
        if (this.running) {
            log('HostBackend: already running');
            return {};
        }

        this.running = true;

        // Simulate async guest connection
        setTimeout(() => {
            this.guestConnected = true;
            this.emitEvent({
                type: 'networkStatus',
                status: 'connected',
            });
            log('HostBackend: guest connected');
        }, 500);

        return {};
    }

    async stopVM() {
        log('HostBackend: stopVM');
        this._killAllProcesses('SIGTERM');
        this._setDisconnected();
        return {};
    }

    async spawn(params) {
        const prepared = this._prepareSpawn(params);
        if (!prepared) return {};

        const { id, actualCommand, cleanArgs, mergedEnv, workDir } = prepared;

        log(`HostBackend spawn: command=${actualCommand}, args=${JSON.stringify(cleanArgs)}`);
        log(`HostBackend spawn: cwd=${workDir}`);

        this._spawnLocal(id, actualCommand, cleanArgs, workDir, mergedEnv);
        return {};
    }

    async mountPath(params) {
        const { subpath } = params;
        log(`HostBackend mountPath: ${subpath}`);
        const guestPath = path.join(os.homedir(), subpath || '');
        return { guestPath };
    }
}

// ============================================================
// BwrapBackend — Bubblewrap namespace sandbox
// ============================================================

class BwrapBackend extends LocalBackend {
    constructor(emitEvent) {
        super(emitEvent, 'BwrapBackend');
        this.mountBinds = new Map(); // mountName -> hostPath
    }

    async startVM(params) {
        if (this.running) {
            log('BwrapBackend: already running');
            return {};
        }

        // bwrap is process-level sandboxing; no VM to start
        this.running = true;
        this.guestConnected = true;
        this.emitEvent({
            type: 'networkStatus',
            status: 'connected',
        });
        log('BwrapBackend: started (sandbox ready)');
        return {};
    }

    async stopVM() {
        log('BwrapBackend: stopVM');
        this._killAllProcesses('SIGKILL');
        this.mountBinds.clear();
        this._setDisconnected();
        return {};
    }

    async spawn(params) {
        const prepared = this._prepareSpawn(params);
        if (!prepared) return {};

        const { id, actualCommand, cleanArgs, mergedEnv, workDir } = prepared;

        // Build bwrap arguments
        const bwrapArgs = [
            '--ro-bind', '/', '/',
            '--dev', '/dev',
            '--proc', '/proc',
            '--tmpfs', '/tmp',
            '--tmpfs', '/run',
        ];

        // Preserve DNS resolution: /etc/resolv.conf is often a symlink
        // to /run/systemd/resolve/stub-resolv.conf which --tmpfs /run
        // wipes out. Bind-mount the resolved target back in.
        try {
            const resolvedConf = fs.realpathSync('/etc/resolv.conf');
            if (resolvedConf.startsWith('/run/')) {
                const resolvedDir = path.dirname(resolvedConf);
                bwrapArgs.push('--ro-bind', resolvedDir, resolvedDir);
            }
        } catch (e) {
            // resolv.conf missing or unresolvable — DNS may not work
            log('BwrapBackend: could not resolve /etc/resolv.conf:', e.message);
        }

        // Home is read-only; only workDir and explicit mounts are writable.
        // This prevents the sandbox from writing to ~/.ssh, ~/.gnupg, etc.
        const homeDir = os.homedir();
        bwrapArgs.push('--ro-bind', homeDir, homeDir);
        bwrapArgs.push('--bind', workDir, workDir);

        // Apply stored mount binds as writable
        for (const [, hostPath] of this.mountBinds) {
            if (fs.existsSync(hostPath)) {
                bwrapArgs.push('--bind', hostPath, hostPath);
            }
        }

        // Namespace isolation + actual command
        bwrapArgs.push(
            '--unshare-pid',
            '--die-with-parent',
            '--new-session',
            '--',
            actualCommand,
            ...cleanArgs,
        );

        log(`BwrapBackend spawn: bwrap args=${JSON.stringify(bwrapArgs)}`);
        log(`BwrapBackend spawn: cwd=${workDir}`);

        this._spawnLocal(id, 'bwrap', bwrapArgs, workDir, mergedEnv);
        return {};
    }

    async mountPath(params) {
        const { subpath, mountName } = params;
        log(`BwrapBackend mountPath: ${mountName} -> ${subpath}`);
        const hostPath = path.join(os.homedir(), subpath || '');
        // Store for --bind on next spawn
        this.mountBinds.set(mountName || subpath, hostPath);
        return { guestPath: hostPath };
    }
}

// ============================================================
// KvmBackend — QEMU/KVM virtual machine
// ============================================================

const VM_BASE_DIR = path.join(os.homedir(), '.local/share/claude-desktop/vm');
const VM_SESSION_DIR = path.join(VM_BASE_DIR, 'sessions');
const VSOCK_GUEST_PORT = 51234;  // 0xC822 — matches guest sdk-daemon
const QMP_CAPABILITIES = JSON.stringify({ execute: 'qmp_capabilities' });

/** Event types forwarded from the guest sdk-daemon to subscribers. */
const FORWARDED_EVENTS = new Set([
    'stdout', 'stderr', 'exit', 'networkStatus', 'apiReachability',
]);

class KvmBackend extends BackendBase {
    constructor(emitEvent) {
        super(emitEvent);
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.running = false;
        this.guestConnected = false;
        this.qemuProcess = null;
        this.virtiofsdProcess = null;
        this.socatProcess = null;
        this.sessionDir = null;
        this.monitorSock = null;
        this.bridgeSock = null;
        this.guestCid = null;
        this.sdkBinaryPath = null;
        this._qmpAvailable = true;
        this.processes = new Map(); // id -> bridge connection state
    }

    async init(config) {
        if (config.memoryMB !== undefined) {
            this.config.memoryMB = config.memoryMB;
        }
        if (config.cpuCount !== undefined) {
            this.config.cpuCount = config.cpuCount;
        }

        // Ensure VM directory exists
        fs.mkdirSync(VM_BASE_DIR, { recursive: true });

        // Convert VHDX to qcow2 if needed
        const vhdxPath = path.join(VM_BASE_DIR, 'rootfs.vhdx');
        const qcow2Path = path.join(VM_BASE_DIR, 'rootfs.qcow2');
        if (fs.existsSync(vhdxPath) && !fs.existsSync(qcow2Path)) {
            log('KvmBackend: converting VHDX to qcow2...');
            try {
                execFileSync('qemu-img', [
                    'convert', '-f', 'vhdx', '-O', 'qcow2',
                    vhdxPath, qcow2Path
                ], { stdio: 'pipe', timeout: 300000 });
                log('KvmBackend: VHDX conversion complete');
            } catch (e) {
                logError('KvmBackend: VHDX conversion failed:', e.message);
                throw new Error(`VHDX conversion failed: ${e.message}`);
            }
        }

        log('KvmBackend configured:', this.config);
    }

    _allocateCid() {
        // Allocate a unique guest CID starting at 3 (0-2 are reserved)
        // Check /dev/vhost-vsock is available and pick next free CID
        let cid = 3;
        const cidFile = path.join(VM_BASE_DIR, '.next_cid');
        try {
            cid = parseInt(fs.readFileSync(cidFile, 'utf8').trim(), 10);
            if (isNaN(cid) || cid < 3) cid = 3;
        } catch (_) {
            // First run, start at 3
        }
        const next = cid >= 65535 ? 3 : cid + 1;
        fs.writeFileSync(cidFile, String(next));
        return cid;
    }

    async startVM(params) {
        if (this.running) {
            log('KvmBackend: already running');
            return {};
        }

        this.bundlePath = params.bundlePath;
        const memoryGB = params.memoryGB ||
            Math.ceil(this.config.memoryMB / 1024);
        const cpuCount = this.config.cpuCount;

        // Create session directory
        const sessionId = crypto.randomUUID();
        this.sessionDir = path.join(VM_SESSION_DIR, sessionId);
        fs.mkdirSync(this.sessionDir, { recursive: true });

        // Create overlay disk
        const overlayPath = path.join(this.sessionDir, 'overlay.qcow2');
        const basePath = path.join(VM_BASE_DIR, 'rootfs.qcow2');
        try {
            execFileSync('qemu-img', [
                'create', '-f', 'qcow2', '-b', basePath,
                '-F', 'qcow2', overlayPath
            ], { stdio: 'pipe' });
        } catch (e) {
            logError('KvmBackend: overlay creation failed:', e.message);
            throw new Error(`Overlay creation failed: ${e.message}`);
        }

        // Allocate guest CID
        this.guestCid = this._allocateCid();
        this.monitorSock = path.join(this.sessionDir, 'qmp.sock');
        this.bridgeSock = path.join(this.sessionDir, 'bridge.sock');

        const vmlinuzPath = path.join(VM_BASE_DIR, 'vmlinuz');
        const initrdPath = path.join(VM_BASE_DIR, 'initrd');

        // Start virtiofsd for home directory share (if available)
        try {
            const virtiofsSock = path.join(this.sessionDir, 'virtiofs.sock');
            this.virtiofsdProcess = spawnProcess('virtiofsd', [
                `--socket-path=${virtiofsSock}`,
                '-o', `source=${os.homedir()}`,
                '-o', 'cache=auto',
            ], {
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            this.virtiofsdProcess.on('error', (err) => {
                log('KvmBackend: virtiofsd error:', err.message);
                this.virtiofsdProcess = null;
            });
            log(`KvmBackend: virtiofsd started, socket=${virtiofsSock}`);
        } catch (e) {
            log(`KvmBackend: virtiofsd not available: ${e.message}`);
            this.virtiofsdProcess = null;
        }

        // Build QEMU arguments
        const qemuArgs = [
            '-enable-kvm',
            '-m', `${memoryGB}G`,
            '-cpu', 'host',
            '-smp', String(cpuCount),
            '-nographic',
        ];

        // Kernel and initrd (if available)
        if (fs.existsSync(vmlinuzPath)) {
            qemuArgs.push('-kernel', vmlinuzPath);
            if (fs.existsSync(initrdPath)) {
                qemuArgs.push('-initrd', initrdPath);
            }
            qemuArgs.push(
                '-append', 'root=LABEL=cloudimg-rootfs console=ttyS0 quiet'
            );
        }

        // Disk
        qemuArgs.push(
            '-drive', `file=${overlayPath},format=qcow2,if=virtio`
        );

        // vsock
        qemuArgs.push(
            '-device', `vhost-vsock-pci,guest-cid=${this.guestCid}`
        );

        // QMP monitor
        qemuArgs.push(
            '-qmp', `unix:${this.monitorSock},server,nowait`
        );

        // Network
        qemuArgs.push(
            '-netdev', 'user,id=net0',
            '-device', 'virtio-net-pci,netdev=net0'
        );

        // virtiofs char device (if virtiofsd is running)
        if (this.virtiofsdProcess) {
            const virtiofsSock = path.join(this.sessionDir, 'virtiofs.sock');
            qemuArgs.push(
                '-chardev', `socket,id=virtiofs,path=${virtiofsSock}`,
                '-device', 'vhost-user-fs-pci,chardev=virtiofs,tag=hostshare',
            );
        }

        // Start QEMU
        log(`KvmBackend: starting QEMU with CID ${this.guestCid}`);
        this.qemuProcess = spawnProcess('qemu-system-x86_64', qemuArgs, {
            stdio: ['pipe', 'pipe', 'pipe'],
        });

        this.qemuProcess.on('error', (err) => {
            logError('KvmBackend: QEMU error:', err.message);
            this.running = false;
            this.guestConnected = false;
            this.emitEvent({ type: 'networkStatus', status: 'disconnected' });
        });

        this.qemuProcess.on('exit', (code, signal) => {
            log(`KvmBackend: QEMU exited: code=${code}, signal=${signal}`);
            this.running = false;
            this.guestConnected = false;
            this.emitEvent({ type: 'networkStatus', status: 'disconnected' });
        });

        this.qemuProcess.stderr.on('data', (data) => {
            log(`KvmBackend QEMU stderr: ${data.toString().trim()}`);
        });

        this.running = true;

        // Connect to QMP monitor and send capabilities
        await this._connectQmp();

        // Wait for guest sdk-daemon to connect via vsock bridge
        // (_waitForGuest starts both the bridge server and socat listener)
        await this._waitForGuest();

        return {};
    }

    async _connectQmp() {
        const timeout = 30000;
        const start = Date.now();

        return new Promise((resolve) => {
            const tryConnect = () => {
                if (Date.now() - start > timeout) {
                    logError('KvmBackend: QMP connection timeout — VM control limited');
                    this._qmpAvailable = false;
                    resolve();
                    return;
                }

                if (!fs.existsSync(this.monitorSock)) {
                    setTimeout(tryConnect, 200);
                    return;
                }

                const qmpClient = net.createConnection(
                    this.monitorSock, () => {
                        log('KvmBackend: QMP connected');
                    }
                );

                let qmpBuffer = '';
                qmpClient.on('data', (data) => {
                    qmpBuffer += data.toString();
                    // Wait for QMP greeting, then send capabilities
                    if (qmpBuffer.includes('"QMP"')) {
                        qmpClient.write(QMP_CAPABILITIES + '\n');
                        qmpBuffer = '';
                    }
                    if (qmpBuffer.includes('"return"')) {
                        log('KvmBackend: QMP capabilities negotiated');
                        this._qmpClient = qmpClient;
                        resolve();
                    }
                });

                qmpClient.on('error', (err) => {
                    log('KvmBackend: QMP connect error:', err.message);
                    setTimeout(tryConnect, 500);
                });
            };

            // Give QEMU a moment to create the socket
            setTimeout(tryConnect, 500);
        });
    }

    _startVsockBridge() {
        // The guest sdk-daemon connects TO the host (CID=2) on the vsock port.
        // We listen on vsock and forward to a local Unix bridge socket so that
        // _forwardToGuest can connect to the bridge to reach the guest daemon.
        //
        // Direction: guest → vsock:51234 → socat → bridge.sock
        //            _forwardToGuest → bridge.sock → socat → vsock → guest
        //
        // socat listens on the vsock port for the guest's outbound connection
        // and bridges it to a Unix socket that we can use for bidirectional RPC.
        try {
            this.socatProcess = spawnProcess('socat', [
                `VSOCK-LISTEN:${VSOCK_GUEST_PORT},reuseaddr,fork`,
                `UNIX-CONNECT:${this.bridgeSock}`,
            ], {
                stdio: ['ignore', 'pipe', 'pipe'],
            });

            this.socatProcess.on('error', (err) => {
                log('KvmBackend: socat error:', err.message);
            });

            log(`KvmBackend: socat vsock listener started on port ${VSOCK_GUEST_PORT}`);
        } catch (e) {
            logError('KvmBackend: failed to start socat:', e.message);
        }
    }

    _startBridgeServer() {
        // Create a Unix socket server that accepts connections from socat
        // (guest→vsock→socat→bridge.sock) and from _forwardToGuest.
        // The first inbound connection from socat is the guest sdk-daemon.
        return new Promise((resolve) => {
            this._bridgeServer = net.createServer((conn) => {
                if (!this.guestConnected) {
                    log('KvmBackend: guest connected via vsock bridge');
                    this.guestConnected = true;
                    this._guestConn = conn;
                    this._guestBuffer = Buffer.alloc(0);

                    conn.on('data', (data) => {
                        this._handleGuestData(data);
                    });

                    conn.on('error', (err) => {
                        logError('KvmBackend: guest connection error:', err.message);
                        this.guestConnected = false;
                        this._guestConn = null;
                    });

                    conn.on('close', () => {
                        log('KvmBackend: guest connection closed');
                        this.guestConnected = false;
                        this._guestConn = null;
                    });

                    this.emitEvent({
                        type: 'networkStatus',
                        status: 'connected',
                    });
                    resolve();
                }
            });

            this._bridgeServer.listen(this.bridgeSock, () => {
                log(`KvmBackend: bridge server listening on ${this.bridgeSock}`);
            });

            this._bridgeServer.on('error', (err) => {
                logError('KvmBackend: bridge server error:', err.message);
            });
        });
    }

    _handleGuestData(data) {
        // Parse and route incoming messages from guest sdk-daemon
        this._guestBuffer = Buffer.concat([this._guestBuffer, data]);
        while (true) {
            const parsed = parseMessage(this._guestBuffer);
            if (!parsed) break;
            this._guestBuffer = parsed.remaining;
            const msg = parsed.message;

            if (FORWARDED_EVENTS.has(msg.type)) {
                this.emitEvent(msg);
            } else if (msg.success !== undefined) {
                // Response to a request we sent — route to pending callback
                if (this._pendingCallbacks && msg.id !== undefined) {
                    const cb = this._pendingCallbacks.get(String(msg.id));
                    if (cb) {
                        this._pendingCallbacks.delete(String(msg.id));
                        cb(msg);
                    }
                }
            } else {
                log('KvmBackend: unhandled guest message:', JSON.stringify(msg));
            }
        }
    }

    async _waitForGuest() {
        const timeout = 90000;
        const start = Date.now();

        // Start the bridge Unix socket server, then start socat to listen on
        // vsock. The guest sdk-daemon will connect after boot.
        const bridgeReady = this._startBridgeServer();
        this._startVsockBridge();

        // Wait for guest to connect (or timeout)
        return Promise.race([
            bridgeReady,
            new Promise((resolve) => {
                const checkTimeout = () => {
                    if (Date.now() - start > timeout) {
                        logError('KvmBackend: guest readiness timeout');
                        resolve();
                        return;
                    }
                    if (this.guestConnected) {
                        resolve();
                        return;
                    }
                    setTimeout(checkTimeout, 1000);
                };
                setTimeout(checkTimeout, 2000);
            }),
        ]);
    }

    _sendQmpCommand(command) {
        return new Promise((resolve, reject) => {
            if (!this._qmpClient || this._qmpClient.destroyed) {
                reject(new Error('QMP not connected'));
                return;
            }

            let responseBuffer = '';
            let timer;
            const onData = (data) => {
                responseBuffer += data.toString();
                try {
                    const parsed = JSON.parse(responseBuffer);
                    clearTimeout(timer);
                    this._qmpClient.removeListener('data', onData);
                    resolve(parsed);
                } catch (_) {
                    // Incomplete JSON, keep buffering
                }
            };

            this._qmpClient.on('data', onData);
            this._qmpClient.write(
                JSON.stringify({ execute: command }) + '\n'
            );

            timer = setTimeout(() => {
                this._qmpClient.removeListener('data', onData);
                reject(new Error('QMP command timeout'));
            }, 10000);
        });
    }

    _forwardToGuest(request) {
        return new Promise((resolve, reject) => {
            if (!this._guestConn || !this.guestConnected) {
                reject(new Error('Guest not connected'));
                return;
            }

            // Assign a unique ID if not present, so we can match responses
            if (request.id === undefined) {
                if (!this._nextRequestId) this._nextRequestId = 1;
                request.id = String(this._nextRequestId++);
            }

            if (!this._pendingCallbacks) {
                this._pendingCallbacks = new Map();
            }

            const timer = setTimeout(() => {
                this._pendingCallbacks.delete(request.id);
                reject(new Error('Guest communication timeout'));
            }, 30000);

            this._pendingCallbacks.set(request.id, (response) => {
                clearTimeout(timer);
                resolve(response);
            });

            try {
                writeMessage(this._guestConn, request);
            } catch (err) {
                clearTimeout(timer);
                this._pendingCallbacks.delete(request.id);
                reject(err);
            }
        });
    }

    async stopVM() {
        log('KvmBackend: stopVM');

        // 1. ACPI shutdown via QMP
        try {
            await this._sendQmpCommand('system_powerdown');
            log('KvmBackend: ACPI shutdown sent');
        } catch (e) {
            log('KvmBackend: ACPI shutdown failed:', e.message);
        }

        // 2. Wait 10s, then force quit via QMP
        await new Promise((resolve) => {
            const checkExit = () => {
                if (!this.qemuProcess || this.qemuProcess.exitCode !== null) {
                    resolve();
                    return;
                }
                // Force quit after waiting
                this._sendQmpCommand('quit').catch(() => {});
                setTimeout(() => {
                    resolve();
                }, 3000);
            };
            setTimeout(checkExit, 10000);
        });

        // 3. SIGKILL if still running
        if (this.qemuProcess && this.qemuProcess.exitCode === null) {
            try {
                this.qemuProcess.kill('SIGKILL');
                log('KvmBackend: QEMU force killed');
            } catch (e) {
                log('KvmBackend: QEMU kill error:', e.message);
            }
        }

        // 4. Kill helper processes and close connections
        const cleanup = (obj, method) => {
            if (!obj) return;
            try { obj[method](); } catch (_) {}
        };
        cleanup(this.virtiofsdProcess, 'kill');
        cleanup(this.socatProcess, 'kill');
        cleanup(this._qmpClient, 'destroy');
        cleanup(this._guestConn, 'destroy');
        cleanup(this._bridgeServer, 'close');
        this.virtiofsdProcess = null;
        this.socatProcess = null;
        this._qmpClient = null;
        this._guestConn = null;
        this._bridgeServer = null;

        // 5. Clean up session directory
        if (this.sessionDir) {
            try {
                fs.rmSync(this.sessionDir, { recursive: true, force: true });
                log(`KvmBackend: cleaned up session dir: ${this.sessionDir}`);
            } catch (e) {
                log('KvmBackend: session cleanup error:', e.message);
            }
            this.sessionDir = null;
        }

        this.running = false;
        this.guestConnected = false;
        this.qemuProcess = null;
        this.emitEvent({ type: 'networkStatus', status: 'disconnected' });
        return {};
    }

    isRunning() {
        return { running: this.running };
    }

    isGuestConnected() {
        return { connected: this.guestConnected };
    }

    async spawn(params) {
        const { id } = params;
        log(`KvmBackend spawn: id=${id}, forwarding to guest`);

        try {
            const result = await this._forwardToGuest({
                method: 'spawn', params
            });
            // Track that this process exists in the guest.
            // Events (stdout/stderr/exit) flow back through the
            // single guest connection → _handleGuestData → emitEvent.
            this.processes.set(id, { remote: true });

            return result.result || {};
        } catch (e) {
            logError(`KvmBackend: spawn forward failed: ${e.message}`);
            this.emitEvent({
                type: 'stderr', id,
                data: `Error: Failed to spawn in VM: ${e.message}\n`,
            });
            this.emitEvent({
                type: 'exit', id, exitCode: 1,
                signal: null,
            });
            return {};
        }
    }

    async kill(params) {
        log(`KvmBackend kill: id=${params.id}`);
        try {
            await this._forwardToGuest({ method: 'kill', params });
        } catch (e) {
            log(`KvmBackend: kill forward failed: ${e.message}`);
        }
        return {};
    }

    async writeStdin(params) {
        try {
            await this._forwardToGuest({ method: 'writeStdin', params });
        } catch (e) {
            log(`KvmBackend: writeStdin forward failed: ${e.message}`);
        }
        return {};
    }

    isProcessRunning(params) {
        const { id } = params;
        return { running: this.processes.has(id) };
    }

    async mountPath(params) {
        const { subpath, mountName } = params;
        log(`KvmBackend mountPath: ${mountName} -> ${subpath}`);

        if (this.virtiofsdProcess) {
            // virtiofs is active — guest can access host files via mount
            const guestPath = path.join('/mnt/host', subpath || '');
            return { guestPath };
        }

        // Fallback: return host path with a warning
        const hostPath = path.join(os.homedir(), subpath || '');
        log('KvmBackend: virtiofs not available, returning host path');
        return { guestPath: hostPath };
    }

    async readFile(params) {
        const { filePath } = params;
        log(`KvmBackend readFile: ${filePath}`);

        // Try forwarding to guest first
        if (this.guestConnected) {
            try {
                const result = await this._forwardToGuest({
                    method: 'readFile', params
                });
                if (result.result) return result.result;
            } catch (e) {
                log(`KvmBackend: guest readFile failed, trying host: ${e.message}`);
            }
        }

        // Fallback: read from host
        const resolved = path.resolve(filePath);
        const home = os.homedir();
        if (!resolved.startsWith(home + path.sep) && resolved !== home) {
            return { error: 'Access denied: path outside home directory' };
        }
        try {
            const content = fs.readFileSync(resolved, 'utf8');
            return { content };
        } catch (e) {
            return { error: e.message };
        }
    }

    async installSdk(params) {
        const { sdkSubpath, version } = params;
        log(`KvmBackend installSdk: ${sdkSubpath}@${version}`);
        const resolved = resolveSdkBinary(
            sdkSubpath, version, 'KvmBackend'
        );
        if (resolved) this.sdkBinaryPath = resolved;
        return {};
    }

    async addApprovedOauthToken(params) {
        log('KvmBackend: addApprovedOauthToken');
        // Forward to guest if connected
        if (this.guestConnected) {
            try {
                await this._forwardToGuest({
                    method: 'addApprovedOauthToken', params
                });
            } catch (e) {
                log('KvmBackend: OAuth forward failed:', e.message);
            }
        }
        return {};
    }
}

// ============================================================
// Backend Detection
// ============================================================

function detectBackend(emitEvent) {
    const override = BACKEND_OVERRIDE;
    if (override) {
        log(`Backend override: ${override}`);
        switch (override.toLowerCase()) {
        case 'kvm':
            return new KvmBackend(emitEvent);
        case 'bwrap':
            return new BwrapBackend(emitEvent);
        case 'host':
            return new HostBackend(emitEvent);
        default:
            logError(`Unknown backend override "${override}", falling back to auto-detect`);
        }
    }

    // Auto-detect: try KVM first, then bwrap, then host
    try {
        fs.accessSync('/dev/kvm', fs.constants.R_OK | fs.constants.W_OK);
        execFileSync('which', ['qemu-system-x86_64'], { stdio: 'pipe' });
        fs.accessSync('/dev/vhost-vsock', fs.constants.R_OK);
        fs.accessSync(
            path.join(VM_BASE_DIR, 'rootfs.qcow2'), fs.constants.R_OK
        );
        log('Backend: kvm (all requirements met)');
        return new KvmBackend(emitEvent);
    } catch (e) {
        log(`KVM not available: ${e.message}`);
    }

    try {
        execFileSync('which', ['bwrap'], { stdio: 'pipe' });
        execFileSync('bwrap', ['--ro-bind', '/', '/', 'true'], {
            stdio: 'pipe', timeout: 5000
        });
        log('Backend: bwrap');
        return new BwrapBackend(emitEvent);
    } catch (e) {
        log(`bwrap not available: ${e.message}`);
    }

    log('Backend: host (no isolation)');
    return new HostBackend(emitEvent);
}

// ============================================================
// VMManager — Thin Dispatcher
// ============================================================

class VMManager {
    constructor() {
        this.eventSubscribers = new Set();
        this.backend = detectBackend((event) => this.broadcastEvent(event));
    }

    // --- Configuration ---

    configure(params) {
        const config = {};
        if (params.memoryMB !== undefined) config.memoryMB = params.memoryMB;
        if (params.cpuCount !== undefined) config.cpuCount = params.cpuCount;
        // init is async but configure is sync in the protocol —
        // fire-and-forget is fine for config
        this.backend.init(config).catch((e) => {
            logError('Backend init error:', e.message);
        });
        log('Configured:', params);
        return {};
    }

    // --- VM Lifecycle (delegate to backend) ---

    async createVM(params) {
        log(`createVM: bundle=${params.bundlePath}`);
        return {};
    }

    async startVM(params) {
        return this.backend.startVM(params);
    }

    async stopVM() {
        return this.backend.stopVM();
    }

    isRunning() {
        return this.backend.isRunning();
    }

    isGuestConnected() {
        return this.backend.isGuestConnected();
    }

    // --- Process Management (delegate to backend) ---

    async spawn(params) {
        return this.backend.spawn(params);
    }

    async kill(params) {
        return this.backend.kill(params);
    }

    async writeStdin(params) {
        return this.backend.writeStdin(params);
    }

    isProcessRunning(params) {
        return this.backend.isProcessRunning(params);
    }

    // --- File System (delegate to backend) ---

    async mountPath(params) {
        return this.backend.mountPath(params);
    }

    async readFile(params) {
        return this.backend.readFile(params);
    }

    // --- SDK Management (delegate to backend) ---

    async installSdk(params) {
        return this.backend.installSdk(params);
    }

    // --- OAuth (delegate to backend) ---

    async addApprovedOauthToken(params) {
        return this.backend.addApprovedOauthToken(params);
    }

    // --- Events (managed by VMManager, not backend) ---

    subscribeEvents(socket) {
        this.eventSubscribers.add(socket);
        socket.on('close', () => {
            this.eventSubscribers.delete(socket);
        });
        return {};
    }

    broadcastEvent(event) {
        for (const socket of this.eventSubscribers) {
            try {
                writeMessage(socket, event);
            } catch (e) {
                log('Failed to send event:', e.message);
                this.eventSubscribers.delete(socket);
            }
        }
    }
}

// ============================================================
// Method Dispatch
// ============================================================

const vm = new VMManager();

const METHODS = {
    configure: (params) => vm.configure(params),
    createVM: (params) => vm.createVM(params),
    startVM: (params) => vm.startVM(params),
    stopVM: () => vm.stopVM(),
    isRunning: () => vm.isRunning(),
    isGuestConnected: () => vm.isGuestConnected(),
    spawn: (params) => vm.spawn(params),
    kill: (params) => vm.kill(params),
    writeStdin: (params) => vm.writeStdin(params),
    isProcessRunning: (params) => vm.isProcessRunning(params),
    mountPath: (params) => vm.mountPath(params),
    readFile: (params) => vm.readFile(params),
    installSdk: (params) => vm.installSdk(params),
    addApprovedOauthToken: (params) => vm.addApprovedOauthToken(params),
    subscribeEvents: (params, socket) => vm.subscribeEvents(socket),
};

async function handleRequest(request, socket) {
    const { method, params } = request;
    log(`Request: ${method}`, params ? JSON.stringify(params).substring(0, 200) : '');

    const handler = METHODS[method];
    if (!handler) {
        return { success: false, error: `Unknown method: ${method}` };
    }

    try {
        const result = await handler(params || {}, socket);
        return { success: true, result: result || {} };
    } catch (e) {
        logError(`Method ${method} failed:`, e.message);
        return { success: false, error: e.message };
    }
}

// ============================================================
// Socket Server
// ============================================================

function cleanupSocket() {
    try {
        if (fs.existsSync(SOCKET_PATH)) {
            fs.unlinkSync(SOCKET_PATH);
        }
    } catch (e) {
        // Ignore cleanup errors
    }
}

function startServer() {
    // Clean up stale socket
    cleanupSocket();

    const server = net.createServer((socket) => {
        log('Client connected');
        let buffer = Buffer.alloc(0);

        socket.on('data', async (data) => {
            buffer = Buffer.concat([buffer, data]);

            // Process all complete messages in buffer
            let parsed;
            try {
                parsed = parseMessage(buffer);
            } catch (e) {
                logError('Parse error:', e.message);
                buffer = Buffer.alloc(0);
                return;
            }

            while (parsed) {
                buffer = parsed.remaining;
                const response = await handleRequest(parsed.message, socket);
                writeMessage(socket, response);

                try {
                    parsed = parseMessage(buffer);
                } catch (e) {
                    logError('Parse error:', e.message);
                    buffer = Buffer.alloc(0);
                    return;
                }
            }
        });

        socket.on('error', (err) => {
            if (err.code !== 'ECONNRESET' && err.code !== 'EPIPE') {
                log('Socket error:', err.message);
            }
        });

        socket.on('close', () => {
            log('Client disconnected');
        });
    });

    server.on('error', (err) => {
        if (err.code === 'EADDRINUSE') {
            logError('Socket already in use:', SOCKET_PATH);
            logError('Another instance may be running. Exiting.');
            process.exit(1);
        }
        logError('Server error:', err.message);
    });

    server.listen(SOCKET_PATH, () => {
        // Set socket permissions (owner-only access)
        try {
            fs.chmodSync(SOCKET_PATH, 0o700);
        } catch (e) {
            // Non-fatal
        }
        log(`Listening on ${SOCKET_PATH}`);
        console.log(`${LOG_PREFIX} Service started on ${SOCKET_PATH}`);
    });

    // Graceful shutdown
    const shutdown = () => {
        log('Shutting down...');
        vm.stopVM().catch(() => {}).finally(() => {
            server.close();
            cleanupSocket();
            process.exit(0);
        });
    };

    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
    process.on('uncaughtException', (err) => {
        logError('Uncaught exception:', err);
        shutdown();
    });
}

// ============================================================
// Entry Point
// ============================================================

// Always clean up stale socket and start. The app's retry wrapper has a
// dedup flag (_svcLaunched) preventing duplicate daemon launches, so a
// simple synchronous cleanup avoids the race condition where an async
// connection test delays startup while the app is already retrying.
cleanupSocket();
startServer();
