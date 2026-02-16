#!/usr/bin/env node

/**
 * Linux Cowork VM Service Daemon
 *
 * Replaces the Windows cowork-vm-service for Linux. Listens on a Unix domain
 * socket using the same length-prefixed JSON protocol as the Windows named pipe.
 * Manages a QEMU/KVM virtual machine running Anthropic's rootfs image.
 *
 * Protocol:
 *   Transport: Unix domain socket at $XDG_RUNTIME_DIR/cowork-vm-service.sock
 *   Framing:   4-byte big-endian length prefix + JSON payload
 *   Request:   { method: "methodName", params: {...} }
 *   Response:  { success: true, result: {...} } or { success: false, error: "..." }
 *   Events:    { type: "stdout"|"stderr"|"exit"|"error"|"networkStatus"|"apiReachability", ... }
 *
 * STATUS: Phase 1 - Stub service for protocol validation
 *   - Socket listener: WORKS
 *   - Length-prefixed JSON framing: WORKS
 *   - Method dispatch: WORKS (stub responses)
 *   - QEMU management: PLACEHOLDER (Phase 3)
 *   - Guest communication: PLACEHOLDER (Phase 3)
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');

// ============================================================
// Configuration
// ============================================================

const SOCKET_PATH = (process.env.XDG_RUNTIME_DIR || '/tmp') +
    '/cowork-vm-service.sock';
const DEBUG = process.env.COWORK_VM_DEBUG === '1' ||
    process.env.CLAUDE_LINUX_DEBUG === '1';
const LOG_PREFIX = '[cowork-vm-service]';

// The daemon is forked with stdio:'ignore', so console output goes nowhere.
// Write logs to a file so they're accessible for debugging.
const LOG_FILE = path.join(
    process.env.HOME || '/tmp',
    '.config', 'Claude', 'logs', 'cowork_vm_daemon.log'
);
function _writeLog(level, args) {
    const ts = new Date().toISOString();
    const msg = `${ts} [${level}] ${LOG_PREFIX} ` +
        args.map(a => typeof a === 'string' ? a : JSON.stringify(a))
            .join(' ') + '\n';
    try {
        fs.appendFileSync(LOG_FILE, msg);
    } catch (e) {
        // Ignore write errors (dir may not exist yet)
    }
}

function log(...args) {
    if (DEBUG) {
        _writeLog('debug', args);
        console.log(LOG_PREFIX, ...args);
    }
}

function logError(...args) {
    _writeLog('error', args);
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
// VM State Manager
// ============================================================

class VMManager extends EventEmitter {
    constructor() {
        super();
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.vmProcess = null;
        this.running = false;
        this.guestConnected = false;
        this.bundlePath = null;
        this.sdkBinaryPath = null;
        this.processes = new Map();
        this.eventSubscribers = new Set();
    }

    // --- VM Lifecycle ---

    configure(params) {
        if (params.memoryMB !== undefined) {
            this.config.memoryMB = params.memoryMB;
        }
        if (params.cpuCount !== undefined) {
            this.config.cpuCount = params.cpuCount;
        }
        log('Configured:', this.config);
        return {};
    }

    async createVM(params) {
        this.bundlePath = params.bundlePath;
        const diskSizeGB = params.diskSizeGB || 10;
        log(`createVM: bundle=${this.bundlePath}, disk=${diskSizeGB}GB`);

        // Phase 3: Create/prepare VM disk image
        // For now, acknowledge the request
        return {};
    }

    async startVM(params) {
        this.bundlePath = params.bundlePath;
        const memoryGB = params.memoryGB || this.config.memoryMB / 1024;
        log(`startVM: bundle=${this.bundlePath}, memory=${memoryGB}GB`);

        if (this.running) {
            log('VM already running');
            return {};
        }

        // Phase 3: Launch QEMU with KVM
        // qemu-system-x86_64 \
        //   -enable-kvm -m ${memoryGB}G -cpu host -smp ${cpuCount} \
        //   -nographic \
        //   -drive file=rootfs.img,format=raw,if=virtio \
        //   -device vhost-vsock-pci,guest-cid=3 \
        //   -monitor unix:/tmp/cowork-qemu-monitor.sock,server,nowait \
        //   -netdev user,id=net0 -device virtio-net-pci,netdev=net0

        // For Phase 1 stub: simulate VM startup
        this.running = true;

        // Simulate async guest connection (guest agent connects via vsock)
        setTimeout(() => {
            this.guestConnected = true;
            this.broadcastEvent({
                type: 'networkStatus',
                status: 'connected',
            });
            log('Guest connected (stub)');
        }, 500);

        return {};
    }

    async stopVM() {
        log('stopVM');

        // Kill all spawned processes
        for (const [id, proc] of this.processes) {
            try {
                if (proc.kill) proc.kill();
            } catch (e) {
                log(`Error killing process ${id}:`, e.message);
            }
        }
        this.processes.clear();

        // Phase 3: Send ACPI shutdown to QEMU, then force kill after timeout

        this.running = false;
        this.guestConnected = false;
        this.broadcastEvent({ type: 'networkStatus', status: 'disconnected' });
        return {};
    }

    isRunning() {
        return { running: this.running };
    }

    isGuestConnected() {
        return { connected: this.guestConnected };
    }

    // --- Process Management ---

    async spawn(params) {
        const { id, name, command, args, cwd, env,
            additionalMounts, isResume, allowedDomains,
            sharedCwdPath, oneShot } = params;

        log(`spawn: id=${id}, name=${name}, command=${command}`);

        // Phase 3: Forward to guest SDK daemon via vsock
        // The SDK daemon runs the command inside bubblewrap sandbox

        // Phase 1 stub: Run directly on host (like old swift stub)
        const { spawn } = require('child_process');
        const os = require('os');

        let workDir = cwd || os.homedir();
        if (sharedCwdPath) {
            workDir = path.join(os.homedir(), sharedCwdPath);
        } else if (cwd && cwd.startsWith('/sessions/')) {
            log(`spawn: cwd is VM guest path "${cwd}", using home dir`);
            workDir = os.homedir();
        }

        if (!fs.existsSync(workDir)) {
            log(`spawn: cwd "${workDir}" does not exist, using home dir`);
            workDir = os.homedir();
        }

        // Find the actual command binary
        // Priority: 1) SDK binary from installSdk, 2) command path, 3) which
        let actualCommand = command;
        if (this.sdkBinaryPath && fs.existsSync(this.sdkBinaryPath)) {
            actualCommand = this.sdkBinaryPath;
            log(`spawn: using SDK binary: ${actualCommand}`);
        } else if (!fs.existsSync(command)) {
            const basename = path.basename(command);
            try {
                const { execSync } = require('child_process');
                actualCommand = execSync(`which ${basename}`,
                    { encoding: 'utf-8' }).trim();
                log(`spawn: resolved via which: ${actualCommand}`);
            } catch (e) {
                this.broadcastEvent({
                    type: 'stderr',
                    id: id,
                    data: `Error: ${command} not found\n`,
                });
                this.broadcastEvent({
                    type: 'exit',
                    id: id,
                    exitCode: 127,
                    signal: null,
                });
                return {};
            }
        }

        // Build a clean environment for the spawned process.
        // Strip from the daemon's inherited env (from Electron):
        //   - CLAUDECODE: triggers "cannot be launched inside another session"
        //   - ELECTRON_*: not needed for the CLI process
        //   - CLAUDE_CODE_*: daemon inherited these from Electron, but the
        //     app provides its own set via the env param below
        const cleanEnv = {};
        for (const [k, v] of Object.entries(process.env)) {
            if (k.startsWith('CLAUDE_CODE_') ||
                k === 'CLAUDECODE' ||
                k === 'ELECTRON_RUN_AS_NODE' ||
                k === 'ELECTRON_NO_ASAR') {
                continue;
            }
            cleanEnv[k] = v;
        }

        // The app-provided env contains vars Claude Code needs to operate
        // (API keys, OAuth tokens, entrypoint, etc.). Keep all of these
        // EXCEPT the session-detection var CLAUDECODE.
        const cleanAppEnv = {};
        for (const [k, v] of Object.entries(env || {})) {
            if (k === 'CLAUDECODE' ||
                k === 'ELECTRON_RUN_AS_NODE' ||
                k === 'ELECTRON_NO_ASAR') {
                continue;
            }
            cleanAppEnv[k] = v;
        }

        // Build merged env, then fix VM guest paths
        const mergedEnv = { ...cleanEnv, ...cleanAppEnv, TERM: 'xterm-256color' };

        // CLAUDE_CONFIG_DIR from the app points to a VM guest path
        // (/sessions/<name>/mnt/.claude) that doesn't exist on the host.
        // Remove it so Claude Code uses its default (~/.claude/).
        if (mergedEnv.CLAUDE_CONFIG_DIR &&
            mergedEnv.CLAUDE_CONFIG_DIR.startsWith('/sessions/')) {
            log(`spawn: removing VM guest CLAUDE_CONFIG_DIR: ${mergedEnv.CLAUDE_CONFIG_DIR}`);
            delete mergedEnv.CLAUDE_CONFIG_DIR;
        }

        // Filter out args that reference VM guest paths (/sessions/...).
        // Flags like --add-dir and --plugin-dir point to paths inside the VM
        // that don't exist on the host.
        let cleanArgs = args || [];
        const filteredArgs = [];
        for (let i = 0; i < cleanArgs.length; i++) {
            if ((cleanArgs[i] === '--add-dir' || cleanArgs[i] === '--plugin-dir') &&
                i + 1 < cleanArgs.length &&
                cleanArgs[i + 1].startsWith('/sessions/')) {
                log(`spawn: removing ${cleanArgs[i]} ${cleanArgs[i + 1]} (VM guest path)`);
                i++; // skip the value too
                continue;
            }
            filteredArgs.push(cleanArgs[i]);
        }
        cleanArgs = filteredArgs;

        log(`spawn: command=${actualCommand}, args=${JSON.stringify(cleanArgs)}`);
        log(`spawn: cwd=${workDir}`);

        const proc = spawn(actualCommand, cleanArgs, {
            cwd: workDir,
            env: mergedEnv,
            stdio: ['pipe', 'pipe', 'pipe'],
        });

        log(`spawn: pid=${proc.pid}`);
        this.processes.set(id, proc);

        proc.stdout.on('data', (data) => {
            this.broadcastEvent({
                type: 'stdout',
                id: id,
                data: data.toString(),
            });
        });

        proc.stderr.on('data', (data) => {
            this.broadcastEvent({
                type: 'stderr',
                id: id,
                data: data.toString(),
            });
        });

        proc.on('exit', (exitCode, signal) => {
            log(`Process ${id} exited: code=${exitCode}, signal=${signal}`);
            this.processes.delete(id);
            this.broadcastEvent({
                type: 'exit',
                id: id,
                exitCode,
                signal,
            });
        });

        proc.on('error', (err) => {
            this.broadcastEvent({
                type: 'error',
                id: id,
                message: err.message,
            });
        });

        return {};
    }

    async kill(params) {
        const { id, signal } = params;
        const proc = this.processes.get(id);
        if (proc) {
            try {
                proc.kill(signal || 'SIGTERM');
            } catch (e) {
                log(`Kill failed for ${id}:`, e.message);
            }
            return {};
        }
        return {};
    }

    async writeStdin(params) {
        const { id, data } = params;
        const proc = this.processes.get(id);
        if (proc && proc.stdin && !proc.stdin.destroyed) {
            proc.stdin.write(data);
            return {};
        }
        return {};
    }

    isProcessRunning(params) {
        const { id } = params;
        const proc = this.processes.get(id);
        return { running: !!proc };
    }

    // --- File System ---

    async mountPath(params) {
        const { processId, subpath, mountName, mode } = params;
        log(`mountPath: ${mountName} -> ${subpath} (${mode})`);

        // Phase 3: Set up 9p or virtiofs share with QEMU
        // For now, return the host path directly
        const os = require('os');
        const guestPath = path.join(os.homedir(), subpath || '');
        return { guestPath };
    }

    async readFile(params) {
        const { processName, filePath } = params;
        log(`readFile: ${filePath}`);

        try {
            const content = fs.readFileSync(filePath, 'utf8');
            return { content };
        } catch (e) {
            return { error: e.message };
        }
    }

    // --- SDK Management ---

    async installSdk(params) {
        const { sdkSubpath, version } = params;
        log(`installSdk: ${sdkSubpath}@${version}`);

        // The app downloads Claude Code to ~/sdkSubpath/version/claude
        // Track this path so spawn() can use the correct binary
        if (sdkSubpath && version) {
            const os = require('os');
            const candidatePath = path.join(
                os.homedir(), sdkSubpath, version, 'claude'
            );
            try {
                fs.accessSync(candidatePath, fs.constants.X_OK);
                this.sdkBinaryPath = candidatePath;
                log(`SDK binary found: ${this.sdkBinaryPath}`);
            } catch (e) {
                log(`SDK binary not found or not executable: ${candidatePath}`);
            }
        }

        return {};
    }

    // --- OAuth ---

    async addApprovedOauthToken(params) {
        log('addApprovedOauthToken');
        // Phase 3: Configure OAuth proxy in guest
        return {};
    }

    // --- Events ---

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

// Always clean up stale socket and start. The app's Ma() retry wrapper has
// a dedup flag (_svcLaunched) preventing duplicate daemon launches, so a
// simple synchronous cleanup avoids the race condition where an async
// connection test delays startup while the app is already retrying.
cleanupSocket();
startServer();
