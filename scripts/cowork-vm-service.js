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
 *   1. bwrap — if bwrap is installed and functional (default)
 *   2. kvm   — if /dev/kvm, qemu-system-x86_64, and /dev/vhost-vsock
 *              are available (rootfs checked at startVM time)
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

// Ensure the log directory exists once at startup so writeLog() isn't
// silently discarded when the daemon is the first thing writing under
// ~/.config/Claude/logs/ (issue #408 — crashes otherwise leave no trace).
try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
} catch (_) {
    // Best-effort — writeLog() still catches any later write errors.
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

// Always-on lifecycle logger for startup/shutdown/crash events so the
// death of the daemon is never silent regardless of COWORK_VM_DEBUG.
function logLifecycle(event, detail) {
    const stack = detail && detail.stack
        ? detail.stack
        : (detail !== undefined ? String(detail) : '');
    writeLog('lifecycle', stack ? [event, stack] : [event]);
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

// ============================================================
// Guest-Path Translation
// ============================================================

/**
 * Translate a VM guest path (/sessions/{id}/mnt/{name}[/rest]) to a host
 * path using mountMap. Returns the translated path, or null on failure.
 */
function translateGuestPath(guestPath, mountMap) {
    if (!guestPath || !guestPath.startsWith('/sessions/')) return null;
    if (!mountMap || Object.keys(mountMap).length === 0) return null;

    const match = guestPath.match(
        /^\/sessions\/[^/]+\/mnt\/([^/]+)(\/.*)?$/
    );
    if (!match) return null;

    const mountName = match[1];
    const rest = match[2] || '';

    // Electron's ta() normalizer strips leading dots, so try both
    // "skills" and ".skills" style lookups.
    const hostBase = mountMap[mountName]
        || mountMap['.' + mountName]
        || mountMap[mountName.replace(/^\./, '')];
    if (!hostBase) {
        log(`translateGuestPath: no mapping for "${mountName}"`);
        return null;
    }

    const translated = rest ? path.join(hostBase, rest) : hostBase;
    const normalized = path.resolve(translated);

    // Prevent path traversal outside the mount base
    if (normalized !== hostBase &&
        !normalized.startsWith(hostBase + path.sep)) {
        log(`translateGuestPath: traversal blocked: ${guestPath} -> ${normalized}`);
        return null;
    }

    log(`translateGuestPath: ${guestPath} -> ${normalized}`);
    return normalized;
}

/**
 * Resolve a subpath that may be root-relative (e.g. "home/user/.config/...")
 * or home-relative (e.g. ".config/..."). app.asar generates root-relative
 * subpaths via path.relative('/', absolutePath), so path.join('/', subpath)
 * recovers the original absolute path. Falls back to home-relative for
 * legacy or genuinely relative subpaths.
 *
 * Fix for https://github.com/aaddrick/claude-desktop-debian/issues/373
 */
function resolveSubpath(subpath) {
    if (!subpath) return os.homedir();
    const asRoot = path.resolve(path.join('/', subpath));
    if (asRoot.startsWith(os.homedir() + path.sep) || asRoot === os.homedir()) {
        return asRoot;
    }
    return path.resolve(path.join(os.homedir(), subpath));
}

/**
 * Build a mount-name -> host-path mapping from mountBinds (prior
 * mountPath() calls) and additionalMounts (spawn params).
 * additionalMounts entries take precedence over mountBinds.
 */
function buildMountMap(additionalMounts, mountBinds) {
    const map = {};

    if (mountBinds) {
        for (const [name, hostPath] of mountBinds) {
            map[name] = hostPath;
        }
    }

    if (additionalMounts) {
        const homeDir = os.homedir();
        for (const [name, info] of Object.entries(additionalMounts)) {
            if (!info || !info.path) continue;
            const resolved = resolveSubpath(info.path);
            if (resolved !== homeDir &&
                !resolved.startsWith(homeDir + path.sep)) {
                log(`buildMountMap: rejecting "${name}" — resolves outside home: ${resolved}`);
                continue;
            }
            map[name] = resolved;
        }
    }

    return map;
}

/**
 * Find the primary user mount name in mountMap — the first key that
 * is not a dotfile mount (e.g. .claude, .auto-memory) and not the
 * uploads mount. Used by both resolveWorkDir (HostBackend) and
 * BwrapBackend.spawn to derive a sensible cwd from the user-selected
 * project folder when the Electron app sends a session-root path with
 * no /mnt/{name} component to translate.
 *
 * Returns the mount name (string) or null if no user mount exists.
 */
function findPrimaryMount(mountMap) {
    if (!mountMap) return null;
    return Object.keys(mountMap).find(
        n => !n.startsWith('.') && n !== 'uploads',
    ) || null;
}

/**
 * Build a merged environment for a spawned process. Combines filtered
 * daemon env with app-provided env, and translates guest paths in
 * CLAUDE_CONFIG_DIR and CLAUDE_COWORK_MEMORY_PATH_OVERRIDE using mountMap.
 */
function buildSpawnEnv(appEnv, mountMap) {
    const mergedEnv = {
        ...filterEnv(process.env, ['CLAUDE_CODE_']),
        ...filterEnv(appEnv || {}),
        TERM: 'xterm-256color',
    };

    // Translate CLAUDE_CONFIG_DIR from guest path to host path, or
    // remove it so Claude Code falls back to ~/.claude/.
    if (mergedEnv.CLAUDE_CONFIG_DIR) {
        if (mergedEnv.CLAUDE_CONFIG_DIR.startsWith('/sessions/')) {
            // translate guest path to host path
            const translated = translateGuestPath(
                mergedEnv.CLAUDE_CONFIG_DIR, mountMap
            );
            if (translated !== mergedEnv.CLAUDE_CONFIG_DIR) {
                log(`buildSpawnEnv: translated CLAUDE_CONFIG_DIR: ${mergedEnv.CLAUDE_CONFIG_DIR} -> ${translated}`);
                mergedEnv.CLAUDE_CONFIG_DIR = translated;
            }
        } else {
            // Host path — may be doubled by app.asar's own
            // path.join(homedir, rootRelativeSubpath). Extract the
            // relative part and resolve it properly.
            const homeDir = os.homedir();
            if (mergedEnv.CLAUDE_CONFIG_DIR.startsWith(homeDir + path.sep)) {
                const relative = mergedEnv.CLAUDE_CONFIG_DIR.slice(homeDir.length + 1);
                const fixed = resolveSubpath(relative);
                if (fixed !== mergedEnv.CLAUDE_CONFIG_DIR) {
                    log(`buildSpawnEnv: fixed doubled CLAUDE_CONFIG_DIR: ${mergedEnv.CLAUDE_CONFIG_DIR} -> ${fixed}`);
                    mergedEnv.CLAUDE_CONFIG_DIR = fixed;
                }
            }
        }
    }


    // Translate CLAUDE_COWORK_MEMORY_PATH_OVERRIDE from guest path to
    // host path. The Electron app sets this to /sessions/{id}/mnt/.auto-memory
    // regardless of backend, but on HostBackend the /sessions/ directory
    // does not exist. Try translateGuestPath first (works if .auto-memory
    // is in mountMap via additionalMounts), then fall back to resolving
    // the mount-name portion the way HostBackend.mountPath() would —
    // via resolveSubpath() — so the path resolves to a writable host
    // location (typically ~/.auto-memory).
    if (mergedEnv.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE) {
        const memPath = mergedEnv.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE;
        if (memPath.startsWith('/sessions/')) {
            const translated = translateGuestPath(memPath, mountMap);
            if (translated) {
                log(`buildSpawnEnv: translated CLAUDE_COWORK_MEMORY_PATH_OVERRIDE: ${memPath} -> ${translated}`);
                mergedEnv.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE = translated;
            } else {
                // .auto-memory is an internal Cowork path typically not
                // present in additionalMounts. Extract the mount-name
                // (and any trailing subpath) and resolve via
                // resolveSubpath, mirroring HostBackend.mountPath().
                const match = memPath.match(
                    /^\/sessions\/[^/]+\/mnt\/([^/]+)(\/.*)?$/
                );
                if (match) {
                    const hostPath = path.join(
                        resolveSubpath(match[1]),
                        match[2] || ''
                    );
                    log(`buildSpawnEnv: resolved CLAUDE_COWORK_MEMORY_PATH_OVERRIDE via fallback: ${memPath} -> ${hostPath}`);
                    mergedEnv.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE = hostPath;
                } else {
                    log(`buildSpawnEnv: could not translate CLAUDE_COWORK_MEMORY_PATH_OVERRIDE, removing: ${memPath}`);
                    delete mergedEnv.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE;
                }
            }
        }
    }
    return mergedEnv;
}

/**
 * Split a CSV --allowedTools / --disallowedTools value into entries
 * while respecting parentheses. Tool patterns may legitimately contain
 * commas inside parens (e.g. "Bash(npm test, npm build)"), so a naive
 * split on "," would corrupt them. Returns an array of entries with no
 * trimming applied.
 */
function splitToolList(csv) {
    const result = [];
    if (!csv) return result;
    let depth = 0;
    let start = 0;
    for (let i = 0; i < csv.length; i++) {
        const ch = csv[i];
        if (ch === '(') depth++;
        else if (ch === ')') depth = Math.max(0, depth - 1);
        else if (ch === ',' && depth === 0) {
            result.push(csv.slice(start, i));
            start = i + 1;
        }
    }
    result.push(csv.slice(start));
    return result;
}

/**
 * Translate VM guest paths embedded inside a CSV tool-permission
 * string (e.g. --allowedTools value). Each entry is either "Tool"
 * (passed through) or "Tool(pattern)" (pattern is translated if it
 * looks like a /sessions/ guest path). Entries whose guest path can't
 * be mapped to a host path are dropped — a permission rule that
 * can never match is worse than absent.
 *
 * Defensively normalizes leading double slashes (the Electron app
 * emits "//sessions/..." due to an upstream path.join('/', ...) on an
 * already-absolute path).
 */
function translateEmbeddedGuestPaths(csv, mountMap) {
    if (!csv) return csv;
    const out = [];
    for (const entry of splitToolList(csv)) {
        const m = entry.match(/^(\w+)\(([^)]+)\)$/);
        if (!m) {
            out.push(entry);
            continue;
        }
        const tool = m[1];
        const normalized = m[2].replace(/^\/+/, '/');
        if (!normalized.startsWith('/sessions/')) {
            out.push(entry);
            continue;
        }
        const translated = translateGuestPath(normalized, mountMap || {});
        if (!translated) {
            log(`translateEmbeddedGuestPaths: dropping "${entry}" (no host mapping)`);
            continue;
        }
        log(`translateEmbeddedGuestPaths: ${entry} -> ${tool}(${translated})`);
        out.push(`${tool}(${translated})`);
    }
    return out.join(',');
}

/**
 * Translate args that reference VM guest paths (/sessions/...) to host
 * paths using mountMap. Two flag styles are handled:
 *   - Single-path flags (--add-dir, --plugin-dir): the value is one
 *     guest path. Translation failure drops the whole flag pair.
 *   - Tool-list flags (--allowedTools, --disallowedTools): the value
 *     is a CSV of "Tool" or "Tool(pattern)" entries. Each entry is
 *     translated independently; entries that fail are dropped from
 *     the CSV but the flag itself is retained.
 */
function cleanSpawnArgs(rawArgs, mountMap) {
    const cleanArgs = [];
    const guestPathFlags = new Set(['--add-dir', '--plugin-dir']);
    const toolListFlags = new Set(['--allowedTools', '--disallowedTools']);
    for (let i = 0; i < rawArgs.length; i++) {
        const flag = rawArgs[i];
        const value = rawArgs[i + 1];

        if (guestPathFlags.has(flag) &&
            i + 1 < rawArgs.length &&
            value.startsWith('/sessions/')) {
            let hostPath = translateGuestPath(value, mountMap);
            if (hostPath) {
                // --plugin-dir needs the plugin root, not a skills/
                // subdirectory — walk up to find it.
                if (flag === '--plugin-dir') {
                    hostPath = resolvePluginRoot(
                        hostPath, os.homedir()
                    );
                }
                log(`cleanSpawnArgs: translated ${flag} ${value} -> ${hostPath}`);
                cleanArgs.push(flag, hostPath);
            } else {
                log(`cleanSpawnArgs: removing ${flag} ${value} (no host mapping)`);
            }
            i++;
            continue;
        }

        if (toolListFlags.has(flag) && i + 1 < rawArgs.length) {
            cleanArgs.push(
                flag,
                translateEmbeddedGuestPaths(value, mountMap),
            );
            i++;
            continue;
        }

        cleanArgs.push(flag);
    }
    return cleanArgs;
}

/**
 * Walk up from pluginPath (at most 3 levels) looking for the plugin
 * root (contains .claude-plugin/plugin.json or manifest.json).
 * Will not walk above mountBase. Returns pluginPath if no root found.
 */
function resolvePluginRoot(pluginPath, mountBase) {
    let candidate = pluginPath;
    for (let i = 0; i < 3; i++) {
        try {
            const hasPluginJson = fs.existsSync(
                path.join(candidate, '.claude-plugin', 'plugin.json')
            );
            const hasManifest = fs.existsSync(
                path.join(candidate, 'manifest.json')
            );
            if (hasPluginJson || hasManifest) {
                if (candidate !== pluginPath) {
                    log(`resolvePluginRoot: adjusted ${pluginPath} -> ${candidate}`);
                }
                return candidate;
            }
        } catch (_) {
            break;
        }
        const parent = path.dirname(candidate);
        if (parent === candidate) break;
        if (mountBase &&
            parent !== mountBase &&
            !parent.startsWith(mountBase + path.sep)) break;
        candidate = parent;
    }
    return pluginPath;
}

/**
 * Resolve the working directory from spawn params. Translates guest
 * paths using mountMap, falls back to homedir if translation fails
 * or the directory does not exist.
 */
function resolveWorkDir(cwd, sharedCwdPath, mountMap) {
    let workDir = cwd || os.homedir();
    if (sharedCwdPath) {
        workDir = resolveSubpath(sharedCwdPath);
    } else if (cwd && cwd.startsWith('/sessions/')) {
        const translated = translateGuestPath(cwd, mountMap || {});
        if (translated) {
            log(`resolveWorkDir: translated "${cwd}" -> "${translated}"`);
            workDir = translated;
        } else {
            // Session-root path (e.g. /sessions/bold-sharp-clarke) has no
            // /mnt/ component, so translateGuestPath can't resolve it.
            // Derive cwd from the primary user mount, mirroring what
            // BwrapBackend does at spawn time.
            const primaryMount = findPrimaryMount(mountMap);
            if (primaryMount && mountMap[primaryMount]) {
                log(`resolveWorkDir: session root "${cwd}", using primary mount "${primaryMount}" -> "${mountMap[primaryMount]}"`);
                workDir = mountMap[primaryMount];
            } else {
                log(`resolveWorkDir: cwd is VM guest path "${cwd}", no primary mount found, using home dir`);
                workDir = os.homedir();
            }
        }
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
        resolveSubpath(sdkSubpath), version, 'claude'
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
 * Priority: 1) SDK binary (only when basename is `claude`),
 * 2) command path, 3) which
 * Returns { command, error } — error is set if command not found.
 */
function resolveCommand(command, sdkBinaryPath) {
    const basename = path.basename(command);

    if (basename === 'claude' &&
            sdkBinaryPath && fs.existsSync(sdkBinaryPath)) {
        log(`resolveCommand: using SDK binary: ${sdkBinaryPath}`);
        return { command: sdkBinaryPath, error: null };
    }

    if (fs.existsSync(command)) {
        return { command, error: null };
    }

    try {
        const resolved = execFileSync('which', [basename],
            { encoding: 'utf-8' }).trim();
        log(`resolveCommand: resolved via which: ${resolved}`);
        return { command: resolved, error: null };
    } catch (e) {
        return { command: null, error: `${command} not found` };
    }
}

/**
 * Probe for an executable at the given path.
 * Guards against broken symlinks, directories, and non-executable
 * files so stale install artifacts don't masquerade as a binary.
 */
function isExecutableFile(p) {
    try {
        const st = fs.statSync(p);
        if (!st.isFile()) return false;
        fs.accessSync(p, fs.constants.X_OK);
        return true;
    } catch (_) {
        return false;
    }
}

/**
 * Locate the virtiofsd binary.
 *
 * On Debian/Ubuntu virtiofsd ships at /usr/libexec/virtiofsd, on
 * Arch/CachyOS/Manjaro at /usr/lib/virtiofsd — neither directory is
 * on the default PATH, so `spawn('virtiofsd', ...)` ENOENTs even
 * when the package is installed. KvmBackend silently falls back to
 * virtio-9p in that case (lower performance).
 *
 * Search order (matches scripts/doctor.sh::_find_virtiofsd):
 *   1. COWORK_VM_VIRTIOFSD_BIN — explicit user override
 *   2. PATH (via `which`)
 *   3. Known install locations
 *
 * Override _COWORK_VFSD_PATHS (colon-separated) replaces the built-in
 * fallback list. Shared with doctor.sh so doctor's diagnosis and the
 * daemon's actual probe stay in lock-step. Internal test hook —
 * underscore prefix signals "not a user knob".
 *
 * Returns the absolute path to the binary, or null on miss.
 */
function findVirtiofsd() {
    const override = process.env.COWORK_VM_VIRTIOFSD_BIN;
    if (override) {
        return isExecutableFile(override) ? override : null;
    }

    try {
        const onPath = execFileSync('which', ['virtiofsd'],
            { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }
        ).trim();
        if (onPath && isExecutableFile(onPath)) return onPath;
    } catch (_) { /* fall through to fallback-path probe */ }

    const fallbackEnv = process.env._COWORK_VFSD_PATHS;
    const fallbacks = fallbackEnv
        ? fallbackEnv.split(':').filter(Boolean)
        : [
            '/usr/libexec/virtiofsd',   // deb/rpm
            '/usr/lib/qemu/virtiofsd',  // legacy Debian
            '/usr/lib/virtiofsd',       // Arch/CachyOS/Manjaro
        ];
    for (const p of fallbacks) {
        if (isExecutableFile(p)) return p;
    }
    return null;
}

// ============================================================
// Bwrap Mount Configuration
// ============================================================

const FORBIDDEN_MOUNT_PATHS = new Set(['/', '/proc', '/dev', '/sys']);

function validateMountPath(mountPath, opts) {
    opts = opts || {};
    if (!mountPath || !path.isAbsolute(mountPath)) {
        return { valid: false, reason: 'Path must be absolute' };
    }

    const normalized = path.resolve(mountPath);

    // Resolve symlinks when the path exists on disk (defense-in-depth).
    // This is a TOCTOU situation, but bwrap is the real security boundary;
    // this just catches honest configuration mistakes.
    let resolved = normalized;
    try {
        resolved = fs.realpathSync(normalized);
    } catch (_) {
        // Path doesn't exist yet — use the unresolved form
    }

    function checkForbidden(p) {
        if (FORBIDDEN_MOUNT_PATHS.has(p)) {
            return `Path is forbidden: ${p}`;
        }
        for (const forbidden of FORBIDDEN_MOUNT_PATHS) {
            if (forbidden !== '/' && p.startsWith(forbidden + '/')) {
                return `Path is under forbidden path: ${forbidden}`;
            }
        }
        return null;
    }

    const normalizedErr = checkForbidden(normalized);
    if (normalizedErr) {
        return { valid: false, reason: normalizedErr };
    }

    if (resolved !== normalized) {
        const resolvedErr = checkForbidden(resolved);
        if (resolvedErr) {
            return { valid: false, reason: `Symlink resolves to forbidden path: ${resolved}` };
        }
    }

    if (opts.readWrite) {
        const home = os.homedir();
        const check = resolved !== normalized ? resolved : normalized;
        if (check !== home && !check.startsWith(home + '/')) {
            return { valid: false, reason: 'Read-write mounts must be under $HOME' };
        }
    }

    return { valid: true };
}

function loadBwrapMountsConfig(configPath, logFn) {
    const warn = logFn || log;
    const empty = {
        additionalROBinds: [],
        additionalBinds: [],
        disabledDefaultBinds: [],
    };

    if (!configPath) {
        configPath = path.join(
            process.env.HOME || os.homedir(),
            '.config', 'Claude', 'claude_desktop_linux_config.json'
        );
    }

    let raw;
    try {
        raw = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    } catch (_) {
        return empty;
    }

    const mounts = raw && raw.preferences && raw.preferences.coworkBwrapMounts;
    if (!mounts || typeof mounts !== 'object') {
        return empty;
    }

    function filterPaths(arr, readWrite) {
        if (!Array.isArray(arr)) return [];
        return arr.filter(p => {
            if (typeof p !== 'string') return false;
            const result = validateMountPath(p, { readWrite });
            if (!result.valid) {
                warn(`BwrapConfig: rejected path "${p}": ${result.reason}`);
            }
            return result.valid;
        });
    }

    return {
        additionalROBinds: filterPaths(mounts.additionalROBinds, false),
        additionalBinds: filterPaths(mounts.additionalBinds, true),
        disabledDefaultBinds: Array.isArray(mounts.disabledDefaultBinds)
            ? mounts.disabledDefaultBinds
                .filter(p => {
                    if (typeof p !== 'string') return false;
                    if (!path.isAbsolute(p)) {
                        warn(`BwrapConfig: rejected disabled path "${p}": Path must be absolute`);
                        return false;
                    }
                    const normalized = path.resolve(p);
                    if (CRITICAL_MOUNTS.has(normalized)) {
                        warn(`BwrapConfig: cannot disable critical mount: ${normalized}`);
                        return false;
                    }
                    return true;
                })
                .map(p => path.resolve(p))
            : [],
    };
}

const CRITICAL_MOUNTS = new Set(['/', '/dev', '/proc']);

function mergeBwrapArgs(defaultArgs, config) {
    const result = [];
    const disabled = new Set(
        config.disabledDefaultBinds.filter(p => !CRITICAL_MOUNTS.has(p))
    );

    const TWO_ARG_FLAGS = new Set([
        '--tmpfs', '--dev', '--proc', '--dir',
        '--remount-ro', '--file', '--unsetenv',
        '--chdir', '--size', '--perms',
    ]);
    const THREE_ARG_FLAGS = new Set([
        '--ro-bind', '--bind', '--symlink',
        '--ro-bind-try', '--bind-try',
        '--dev-bind', '--dev-bind-try',
        '--chmod', '--setenv',
    ]);

    let i = 0;
    while (i < defaultArgs.length) {
        const flag = defaultArgs[i];

        if (THREE_ARG_FLAGS.has(flag) && i + 2 < defaultArgs.length) {
            const dest = defaultArgs[i + 2];
            if (disabled.has(dest)) {
                i += 3;
                continue;
            }
            result.push(defaultArgs[i], defaultArgs[i + 1], defaultArgs[i + 2]);
            i += 3;
        } else if (TWO_ARG_FLAGS.has(flag) && i + 1 < defaultArgs.length) {
            const dest = defaultArgs[i + 1];
            if (disabled.has(dest)) {
                i += 2;
                continue;
            }
            result.push(defaultArgs[i], defaultArgs[i + 1]);
            i += 2;
        } else {
            result.push(defaultArgs[i]);
            i++;
        }
    }

    for (const p of config.additionalROBinds) {
        result.push('--ro-bind', p, p);
    }
    for (const p of config.additionalBinds) {
        result.push('--bind', p, p);
    }

    return result;
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
     * Builds a mount map to translate VM guest paths in args, env, and cwd.
     */
    _prepareSpawn(params) {
        const { id, name, command, args, cwd, env,
            sharedCwdPath, additionalMounts } = params;

        log(`${this.backendName} spawn: id=${id}, name=${name}, command=${command}`);

        const mountMap = buildMountMap(
            additionalMounts, this.mountBinds
        );
        // Store for readFile() — last spawn wins (single-session in practice)
        this.lastMountMap = mountMap;

        if (Object.keys(mountMap).length > 0) {
            log(`${this.backendName} spawn: mountMap=${JSON.stringify(mountMap)}`);
        }

        const workDir = resolveWorkDir(cwd, sharedCwdPath, mountMap);
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
            name,
            actualCommand: resolved.command,
            cleanArgs: cleanSpawnArgs(args || [], mountMap),
            mergedEnv: buildSpawnEnv(env, mountMap),
            workDir,
            mountMap,
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

        let resolved;
        if (filePath && filePath.startsWith('/sessions/')) {
            resolved = translateGuestPath(
                filePath, this.lastMountMap || {}
            );
            if (!resolved) {
                return { error: `Cannot translate guest path: ${filePath}` };
            }
            log(`${this.backendName} readFile: translated ${filePath} -> ${resolved}`);
        } else {
            resolved = path.resolve(filePath);
        }

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
        const guestPath = resolveSubpath(subpath);
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
        this.bwrapMountsConfig = loadBwrapMountsConfig(null, log);
        const mc = this.bwrapMountsConfig;
        if (mc.additionalROBinds.length
            || mc.additionalBinds.length
            || mc.disabledDefaultBinds.length) {
            log('BwrapBackend: custom mount config: '
                + mc.additionalROBinds.length + ' RO, '
                + mc.additionalBinds.length + ' RW, '
                + mc.disabledDefaultBinds.length + ' disabled');
        }
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

        const { id, name, actualCommand } = prepared;
        const { additionalMounts } = params;
        const mountMap = this.lastMountMap || {};

        // Guest paths (/sessions/...) exist inside our bwrap sandbox,
        // so pass args and env through as-is (no guest->host translation).
        const rawArgs = params.args || [];
        const mergedEnv = {
            ...filterEnv(process.env, ['CLAUDE_CODE_']),
            ...filterEnv(params.env || {}),
            TERM: 'xterm-256color',
        };

        // Build a minimal sandbox: empty tmpfs root with only the
        // necessary system paths bound in read-only. This avoids
        // exposing the real home directory and allows creating the
        // /sessions/ guest path structure that claude-code-vm expects.
        const defaultBwrapArgs = [
            '--tmpfs', '/',
            '--ro-bind', '/usr', '/usr',
            '--ro-bind', '/etc', '/etc',
            '--dev', '/dev',
            '--proc', '/proc',
            '--tmpfs', '/tmp',
            '--tmpfs', '/run',
        ];

        // Handle /bin, /lib, /lib64, /sbin: on merged-usr distros
        // (Fedora, recent Debian/Ubuntu) these are symlinks into /usr.
        // On others they are real directories needing separate mounts.
        for (const dir of ['/bin', '/lib', '/lib64', '/sbin']) {
            try {
                const target = fs.readlinkSync(dir);
                defaultBwrapArgs.push('--symlink', target, dir);
            } catch (_) {
                if (fs.existsSync(dir)) {
                    defaultBwrapArgs.push('--ro-bind', dir, dir);
                }
            }
        }

        // Preserve DNS resolution: /etc/resolv.conf is often a symlink
        // to /run/systemd/resolve/stub-resolv.conf which --tmpfs /run
        // wipes out. Bind-mount the resolved target back in.
        try {
            const resolvedConf = fs.realpathSync('/etc/resolv.conf');
            if (resolvedConf.startsWith('/run/')) {
                const resolvedDir = path.dirname(resolvedConf);
                defaultBwrapArgs.push('--ro-bind', resolvedDir, resolvedDir);
            }
        } catch (e) {
            log('BwrapBackend: could not resolve /etc/resolv.conf:', e.message);
        }

        // Merge user-configured mounts (disable overrides + additional mounts)
        const bwrapArgs = mergeBwrapArgs(defaultBwrapArgs, this.bwrapMountsConfig);

        // Create home directory (needed for ~ expansion) but don't
        // expose real home contents. Must come before any --ro-bind of
        // subdirectories inside $HOME (e.g. the SDK binary path),
        // otherwise bwrap processes --dir after the bind and shadows it.
        const homeDir = os.homedir();
        bwrapArgs.push('--dir', homeDir);

        // Bind the SDK binary read-only
        const sdkDir = path.dirname(actualCommand);
        bwrapArgs.push('--ro-bind', sdkDir, sdkDir);

        // Create /sessions/<name>/mnt/ guest path structure and mount
        // host directories at guest paths, matching the KVM backend
        // layout. The claude-code-vm binary translates all paths to
        // /sessions/ internally, so these must exist inside the sandbox.
        const sessionMnt = `/sessions/${name}/mnt`;
        bwrapArgs.push('--dir', `/sessions/${name}`);
        bwrapArgs.push('--dir', sessionMnt);

        for (const [mountName, hostPath] of Object.entries(mountMap)) {
            try {
                // Fix #342: upstream fs-extra can create .mcpb-cache
                // as a self-referential symlink after repeated sessions.
                // Detect and remove before mkdir so the bind mount works.
                try {
                    const st = fs.lstatSync(hostPath);
                    if (st.isSymbolicLink()) {
                        const target = fs.readlinkSync(hostPath);
                        const resolved = path.resolve(
                            path.dirname(hostPath), target
                        );
                        if (resolved === hostPath) {
                            log(`BwrapBackend spawn: removing self-referential symlink: ${hostPath}`);
                            fs.unlinkSync(hostPath);
                        }
                    }
                } catch { /* ENOENT is fine — path doesn't exist yet */ }
                if (!fs.existsSync(hostPath)) {
                    fs.mkdirSync(hostPath, { recursive: true });
                }
            } catch (e) {
                log(`BwrapBackend spawn: could not create ${hostPath}: ${e.message}`);
                continue;
            }
            const guestPath = `${sessionMnt}/${mountName}`;
            const mode = additionalMounts?.[mountName]?.mode;
            const bindType = mode === 'ro' ? '--ro-bind' : '--bind';
            bwrapArgs.push(bindType, hostPath, guestPath);
            log(`BwrapBackend spawn: mount ${mountName}: ${hostPath} -> ${guestPath} (${mode || 'rw'})`);
        }

        // Namespace isolation + actual command
        bwrapArgs.push(
            '--unshare-pid',
            '--die-with-parent',
            '--new-session',
            '--',
            actualCommand,
            ...rawArgs,
        );

        // Use the primary user mount as cwd (first non-dotfile, non-uploads mount)
        const primaryMount = findPrimaryMount(mountMap);
        const guestWorkDir = primaryMount
            ? `${sessionMnt}/${primaryMount}`
            : sessionMnt;

        log(`BwrapBackend spawn: bwrap args=${JSON.stringify(bwrapArgs)}`);
        log(`BwrapBackend spawn: cwd=${guestWorkDir}`);

        // Use host-side cwd for Node's spawn (guest paths don't exist
        // on host). bwrap --chdir sets the actual cwd inside the sandbox.
        this._spawnLocal(id, 'bwrap',
            ['--chdir', guestWorkDir, ...bwrapArgs],
            os.homedir(), mergedEnv);
        return {};
    }

    async mountPath(params) {
        const { subpath, mountName } = params;
        log(`BwrapBackend mountPath: ${mountName} -> ${subpath}`);
        const hostPath = resolveSubpath(subpath);
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
const HOME_SHARE_MOUNT_TAG = 'claudeshared';
const HOME_SHARE_GUEST_MOUNT = '/mnt/.virtiofs-root';
const QMP_CAPABILITIES = JSON.stringify({ execute: 'qmp_capabilities' });

/** Event types forwarded from the guest sdk-daemon to subscribers. */
const FORWARDED_EVENTS = new Set([
    'stdout', 'stderr', 'exit', 'networkStatus', 'apiReachability',
    'ready', 'startupStep',
]);

class KvmBackend extends BackendBase {
    constructor(emitEvent) {
        super(emitEvent);
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.running = false;
        this.guestConnected = false;
        this.qemuProcess = null;
        this.virtiofsdProcess = null;
        this.homeShareType = null; // 'virtiofs', '9p', or null
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

        // Convert VHDX to qcow2 if present in VM_BASE_DIR (manual
        // placement). The main conversion happens in startVM() using
        // the app-provided bundlePath.
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

        this.bundlePath = params.bundlePath || VM_BASE_DIR;
        const memoryGB = params.memoryGB ||
            Math.ceil(this.config.memoryMB / 1024);
        const cpuCount = this.config.cpuCount;

        this.emitEvent({
            type: 'startupStep',
            step: 'prepare_session', status: 'running',
        });

        // The app downloads VM images (rootfs.vhdx, vmlinuz, initrd)
        // to bundlePath (~/.config/Claude/vm_bundles/claudevm.bundle/).
        // Convert VHDX to qcow2 if needed (the app downloads VHDX
        // format using the win32 manifest entries).
        const bundleDir = this.bundlePath;
        const vhdxPath = path.join(bundleDir, 'rootfs.vhdx');
        const qcow2Path = path.join(bundleDir, 'rootfs.qcow2');
        if (fs.existsSync(vhdxPath) && !fs.existsSync(qcow2Path)) {
            log('KvmBackend: converting rootfs.vhdx to qcow2...');
            try {
                execFileSync('qemu-img', [
                    'convert', '-f', 'vhdx', '-O', 'qcow2',
                    vhdxPath, qcow2Path
                ], { stdio: 'pipe', timeout: 300000 });
                log('KvmBackend: rootfs conversion complete');
            } catch (e) {
                logError('KvmBackend: rootfs conversion failed:',
                    e.message);
                throw new Error(
                    `rootfs conversion failed: ${e.message}`);
            }
        }

        // Fall back: check VM_BASE_DIR if bundle has no rootfs
        const basePath = fs.existsSync(qcow2Path)
            ? qcow2Path
            : path.join(VM_BASE_DIR, 'rootfs.qcow2');
        if (!fs.existsSync(basePath)) {
            throw new Error(
                `rootfs not found in ${bundleDir} or ${VM_BASE_DIR}`);
        }

        // Create session directory
        const sessionId = crypto.randomUUID();
        this.sessionDir = path.join(VM_SESSION_DIR, sessionId);
        fs.mkdirSync(this.sessionDir, { recursive: true });

        // Create overlay disk
        const overlayPath = path.join(this.sessionDir, 'overlay.qcow2');
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

        const vmlinuzPath = path.join(bundleDir, 'vmlinuz');
        const initrdPath = path.join(bundleDir, 'initrd');

        // Start home directory share for guest VM.
        // Try virtiofsd first (best performance), fall back to virtio-9p
        // (built into QEMU, no daemon needed, works unprivileged).
        //
        // On stock Debian/Ubuntu/Arch the virtiofsd binary lives outside
        // the default PATH, so resolve it via findVirtiofsd() before
        // spawning — otherwise `spawn('virtiofsd', ...)` ENOENTs and we
        // silently drop to 9p even though the package is installed.
        const virtiofsSock = path.join(this.sessionDir, 'virtiofs.sock');
        const virtiofsdBin = findVirtiofsd();
        if (!virtiofsdBin) {
            log('KvmBackend: virtiofsd binary not found on PATH or at '
                + 'known install locations (/usr/libexec, /usr/lib/qemu, '
                + '/usr/lib); using virtio-9p fallback. Install the '
                + 'virtiofsd package or set COWORK_VM_VIRTIOFSD_BIN to '
                + 'use virtiofs.');
        } else {
            log(`KvmBackend: virtiofsd resolved: ${virtiofsdBin}`);
            // Local flag so the socket-wait loop can bail the moment
            // the async 'error' event fires (e.g. binary removed between
            // probe and exec) instead of stalling for the full 5s.
            let spawnFailed = false;
            try {
                this.virtiofsdProcess = spawnProcess(virtiofsdBin, [
                    `--socket-path=${virtiofsSock}`,
                    '-o', `source=${os.homedir()}`,
                    '-o', 'cache=auto',
                ], {
                    stdio: ['ignore', 'pipe', 'pipe'],
                });
                this.virtiofsdProcess.on('error', (err) => {
                    log('KvmBackend: virtiofsd error:', err.message);
                    spawnFailed = true;
                    this.virtiofsdProcess = null;
                });
                log(`KvmBackend: virtiofsd started, ` +
                    `socket=${virtiofsSock}`);

                // Wait for virtiofsd to create its socket before
                // starting QEMU. Bail early on async spawn failure.
                const vfsWaitStart = Date.now();
                while (!spawnFailed && !fs.existsSync(virtiofsSock) &&
                       Date.now() - vfsWaitStart < 5000) {
                    await new Promise(r => setTimeout(r, 100));
                }
                if (!spawnFailed && fs.existsSync(virtiofsSock)) {
                    log('KvmBackend: virtiofsd socket ready ' +
                        `(${Date.now() - vfsWaitStart}ms)`);
                    this.homeShareType = 'virtiofs';
                } else {
                    const reason = spawnFailed
                        ? 'spawn failed'
                        : 'socket not ready after 5s';
                    log(`KvmBackend: virtiofsd ${reason}, ` +
                        'will try virtio-9p fallback');
                    if (this.virtiofsdProcess) {
                        this.virtiofsdProcess.kill();
                        this.virtiofsdProcess = null;
                    }
                }
            } catch (e) {
                log(`KvmBackend: virtiofsd not available: ${e.message}`);
                this.virtiofsdProcess = null;
            }
        }

        // Fallback: use virtio-9p if virtiofsd failed. virtio-9p is
        // built into QEMU — no external daemon, no privileges needed.
        // Lower performance than virtiofs but works everywhere.
        if (!this.virtiofsdProcess) {
            log('KvmBackend: using virtio-9p for home directory share');
            this.homeShareType = '9p';
        }

        // Build QEMU arguments
        // When virtiofs is used, QEMU requires shared memory backend for
        // vhost-user-fs-pci. Use memory-backend-memfd with share=on.
        const useSharedMem = this.homeShareType === 'virtiofs';
        const qemuArgs = [
            '-enable-kvm',
            ...(useSharedMem
                ? ['-object', `memory-backend-memfd,id=mem,size=${memoryGB}G,share=on`,
                   '-numa', 'node,memdev=mem',
                   '-m', `${memoryGB}G`]
                : ['-m', `${memoryGB}G`]),
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

        // Disk (rootfs overlay → /dev/vda)
        qemuArgs.push(
            '-drive', `file=${overlayPath},format=qcow2,if=virtio`
        );

        // Session disk (→ /dev/vdb, formatted by guest sdk-daemon)
        const sessionDiskPath = path.join(this.sessionDir, 'sessiondata.qcow2');
        try {
            execFileSync('qemu-img', [
                'create', '-f', 'qcow2', sessionDiskPath, '2G'
            ], { stdio: 'pipe' });
            qemuArgs.push(
                '-drive', `file=${sessionDiskPath},format=qcow2,if=virtio`
            );
            log(`KvmBackend: session disk created at ${sessionDiskPath}`);
        } catch (e) {
            logError('KvmBackend: session disk creation failed:', e.message);
        }

        // smol-bin disk (contains SDK binaries → /dev/vdc, detected
        // by guest via blkid). The app copies smol-bin.vhdx from
        // resources to bundleDir at startup. Convert to qcow2 if needed.
        const smolVhdx = path.join(bundleDir, 'smol-bin.vhdx');
        const smolQcow2 = path.join(bundleDir, 'smol-bin.qcow2');
        if (fs.existsSync(smolVhdx) && !fs.existsSync(smolQcow2)) {
            log('KvmBackend: converting smol-bin.vhdx to qcow2...');
            try {
                execFileSync('qemu-img', [
                    'convert', '-f', 'vhdx', '-O', 'qcow2',
                    smolVhdx, smolQcow2
                ], { stdio: 'pipe', timeout: 60000 });
                log('KvmBackend: smol-bin conversion complete');
            } catch (e) {
                log(`KvmBackend: smol-bin conversion failed: ${e.message}`);
            }
        }
        // Check bundle dir first, then VM_BASE_DIR.
        // Not fatal if missing — SDK can be accessed via virtiofs.
        const smolBinPath =
            [bundleDir, VM_BASE_DIR]
                .map(d => path.join(d, 'smol-bin.qcow2'))
                .find(p => fs.existsSync(p));
        if (smolBinPath) {
            qemuArgs.push(
                '-drive',
                `file=${smolBinPath},format=qcow2,if=virtio,readonly=on`
            );
            log(`KvmBackend: smol-bin attached from ${smolBinPath}`);
        } else {
            log('KvmBackend: smol-bin.qcow2 not found — ' +
                'SDK will be accessed via virtiofs if available');
        }

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

        // Home directory share device
        if (this.homeShareType === 'virtiofs') {
            // virtiofs: high performance, requires virtiofsd daemon
            qemuArgs.push(
                '-chardev', `socket,id=virtiofs,path=${virtiofsSock}`,
                '-device',
                `vhost-user-fs-pci,chardev=virtiofs,tag=${HOME_SHARE_MOUNT_TAG}`,
            );
        } else if (this.homeShareType === '9p') {
            // virtio-9p: built into QEMU, no daemon, works unprivileged.
            // security_model=none: like passthrough but ignores chown
            // failures — designed for unprivileged QEMU operation.
            qemuArgs.push(
                '-virtfs',
                `local,path=${os.homedir()},mount_tag=${HOME_SHARE_MOUNT_TAG}` +
                ',security_model=none,id=hostshare',
            );
        }

        // Start QEMU
        this.emitEvent({
            type: 'startupStep',
            step: 'start_vm', status: 'running',
        });
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
        this.emitEvent({
            type: 'startupStep',
            step: 'wait_for_guest', status: 'running',
        });
        await this._waitForGuest();

        this.emitEvent({
            type: 'startupStep',
            step: 'wait_for_guest',
            status: this.guestConnected ? 'completed' : 'failed',
        });

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

            // Log all guest messages as decoded JSON for debugging
            log('KvmBackend: guest message:', JSON.stringify(msg).substring(0, 500));

            if (FORWARDED_EVENTS.has(msg.type)) {
                this.emitEvent(msg);
            } else if (msg.type === 'event' && FORWARDED_EVENTS.has(msg.event)) {
                // Guest sends {type:"event", event:"networkStatus", params:{...}}
                this.emitEvent({ type: msg.event, ...msg.params });
            } else if (msg.type === 'response' || msg.success !== undefined) {
                // Response to a request we sent — route to pending callback
                // Guest sends {type:"response", id:"1", result:{success:true}}
                if (msg.error) {
                    log(`KvmBackend: guest response ERROR for id=${msg.id}:`, JSON.stringify(msg.error));
                }
                if (this._pendingCallbacks && msg.id !== undefined) {
                    const cb = this._pendingCallbacks.get(String(msg.id));
                    if (cb) {
                        this._pendingCallbacks.delete(String(msg.id));
                        cb(msg.result || msg);
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

    async _ensureSdkInstalled() {
        if (!this._pendingSdkInstall || !this.guestConnected) return;
        try {
            log('KvmBackend: installing SDK in guest');
            await this._forwardToGuest({
                method: 'installSdk', params: this._pendingSdkInstall
            });
        } catch (e) {
            log(`KvmBackend: installSdk forward failed: ${e.message}`);
        }
        // Clear regardless of success/failure to avoid infinite retries
        this._pendingSdkInstall = null;
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
                // Guest expects {type:"request", method:..., params:..., id:...}
                const wireMsg = { type: 'request', ...request };
                log('KvmBackend: forwarding to guest:', JSON.stringify(wireMsg).substring(0, 200));
                writeMessage(this._guestConn, wireMsg);
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
        this.homeShareType = null;
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

        // Ensure SDK is installed in the guest before spawning
        await this._ensureSdkInstalled();

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
        // Guest RPC treats stdin as a notification (fire-and-forget),
        // not a request. Sending as type:"request" returns "unknown method".
        if (!this._guestConn || !this.guestConnected) {
            log('KvmBackend: writeStdin: guest not connected');
            return {};
        }
        try {
            writeMessage(this._guestConn, {
                type: 'notification', method: 'stdin', params,
            });
        } catch (e) {
            log(`KvmBackend: writeStdin failed: ${e.message}`);
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

        if (this.homeShareType) {
            // Home share active (virtiofs or 9p) — guest accesses
            // host files via the shared mount
            const guestPath =
                path.join(HOME_SHARE_GUEST_MOUNT, subpath || '');
            return { guestPath };
        }

        // No home share — return host path with a warning
        const hostPath = resolveSubpath(subpath);
        log('KvmBackend: no home share, returning host path');
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
        if (resolved) {
            this.sdkBinaryPath = resolved;
            // Compute the guest-side path via home share mount
            const homeDir = os.homedir();
            const relPath = path.relative(homeDir, resolved);
            if (relPath.startsWith('..')) {
                log('KvmBackend: SDK path is outside home dir,' +
                    ` cannot map to guest: ${resolved}`);
            } else {
                this.guestSdkPath = path.join(
                    HOME_SHARE_GUEST_MOUNT, relPath
                );
                log(`KvmBackend: guest SDK path: ${this.guestSdkPath}`);
            }
        }
        // Forward to guest so it can prepare the SDK (or defer until spawn)
        this._pendingSdkInstall = params;
        if (this.guestConnected) {
            await this._ensureSdkInstalled();
        } else {
            log('KvmBackend: guest not connected yet, will install SDK before spawn');
        }
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

// Classify a failed `bwrap --ro-bind / / true` probe. Returns
// { kind: 'userns' | 'unknown', stderr: string }.
//
// Ubuntu 24.04+ ships `apparmor_restrict_unprivileged_userns=1` by
// default, which blocks bwrap from creating the user namespace it
// needs. The probe then fails with EPERM or an AppArmor denial in
// dmesg; bwrap's own stderr is usually "Creating new user namespace:
// Operation not permitted" or similar. Matching these patterns lets
// the daemon and the `--doctor` check emit a specific, actionable
// diagnosis instead of a generic "bwrap not available" that masks
// the real problem (issue #351).
function classifyBwrapProbeError(e) {
    const stderr = (e && e.stderr ? e.stderr.toString() : '')
        + (e && e.stdout ? e.stdout.toString() : '');
    const haystack = (e && e.message ? e.message : '') + '\n' + stderr;
    const usernsPatterns = [
        /user[ _-]?namespace/i,
        /apparmor/i,
        /operation not permitted/i,
        /setting up (uid|gid) map/i,
        /CLONE_NEW(USER|NS)/i,
        /CAP_SYS_ADMIN/i,
    ];
    const kind = usernsPatterns.some((re) => re.test(haystack))
        ? 'userns'
        : 'unknown';
    return { kind, stderr: stderr.trim() };
}

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

    // Auto-detect: try bwrap first. If bwrap is installed but the
    // sandbox probe fails, stop at host rather than silently falling
    // through to KVM — KVM auto-selection in that state leads users
    // into a broken retry loop when the rootfs isn't ready (#351).
    let bwrapInstalled = false;
    try {
        execFileSync('which', ['bwrap'], { stdio: 'pipe' });
        bwrapInstalled = true;
    } catch (_) {
        log('bwrap not installed');
    }

    if (bwrapInstalled) {
        try {
            execFileSync('bwrap', ['--ro-bind', '/', '/', 'true'], {
                stdio: 'pipe', timeout: 5000
            });
            log('Backend: bwrap');
            // Hint for users upgrading from KVM-first auto-detection
            try {
                fs.accessSync('/dev/kvm',
                    fs.constants.R_OK | fs.constants.W_OK);
                log('Note: KVM is available but bwrap is now the default. '
                    + 'Set COWORK_VM_BACKEND=kvm for full VM isolation.');
            } catch (_) { /* KVM not available, no hint needed */ }
            return new BwrapBackend(emitEvent);
        } catch (e) {
            const { kind, stderr } = classifyBwrapProbeError(e);
            if (kind === 'userns') {
                logError(
                    'bwrap is installed but cannot create a user '
                    + 'namespace. This is common on Ubuntu 24.04+ where '
                    + 'AppArmor blocks unprivileged user namespaces by '
                    + 'default (apparmor_restrict_unprivileged_userns=1). '
                    + 'See the "Cowork on Ubuntu 24.04" section in '
                    + 'docs/TROUBLESHOOTING.md for the AppArmor profile '
                    + 'fix.');
            } else {
                logError(`bwrap probe failed: ${e.message || '(no message)'}`);
            }
            if (stderr) {
                logError(`bwrap stderr: ${stderr.slice(0, 500)}`);
            }
            logError(
                'Falling back to host-direct (no isolation). Set '
                + 'COWORK_VM_BACKEND=kvm to opt into KVM, or fix the '
                + 'bwrap issue above to restore sandbox isolation.');
            return new HostBackend(emitEvent);
        }
    }

    // Note: rootfs is NOT checked here — the app downloads it to
    // bundlePath which isn't known until startVM(). The rootfs
    // check happens at startVM time instead.
    try {
        fs.accessSync('/dev/kvm', fs.constants.R_OK | fs.constants.W_OK);
        execFileSync('which', ['qemu-system-x86_64'], { stdio: 'pipe' });
        fs.accessSync('/dev/vhost-vsock', fs.constants.R_OK);
        log('Backend: kvm (all requirements met)');
        return new KvmBackend(emitEvent);
    } catch (e) {
        log(`KVM not available: ${e.message}`);
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

    // --- Debug Logging ---

    setDebugLogging(params) {
        const { enabled } = params;
        log(`setDebugLogging: ${enabled}`);
        return {};
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
    setDebugLogging: (params) => vm.setDebugLogging(params),
    subscribeEvents: (params, socket) => vm.subscribeEvents(socket),
};

async function handleRequest(request, socket) {
    const { method, params } = request;
    // Redact env block (may contain API keys/tokens)
    if (params) {
        const { env, ...rest } = params;
        const summary = JSON.stringify(rest).substring(0, 2000)
            + (env ? ' [env: redacted]' : '');
        log(`Request: ${method}`, summary);
    } else {
        log(`Request: ${method}`);
    }

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
                // Echo back request id so persistent-connection clients
                // can match responses to pending requests.
                if (parsed.message.id !== undefined) {
                    response.id = parsed.message.id;
                }
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
        logLifecycle('listening', SOCKET_PATH);
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

    process.on('SIGTERM', () => {
        logLifecycle('SIGTERM received');
        shutdown();
    });
    process.on('SIGINT', () => {
        logLifecycle('SIGINT received');
        shutdown();
    });
    process.on('uncaughtException', (err) => {
        logLifecycle('uncaughtException', err);
        logError('Uncaught exception:', err);
        shutdown();
    });
    process.on('unhandledRejection', (reason) => {
        logLifecycle('unhandledRejection', reason);
        logError('Unhandled rejection:', reason);
    });
    process.on('exit', (code) => {
        logLifecycle('exit', `code=${code}`);
    });
}

// ============================================================
// Entry Point
// ============================================================

// Always clean up stale socket and start. The app's retry wrapper has a
// 10s spawn cooldown (_lastSpawn) preventing duplicate daemon launches,
// so a simple synchronous cleanup avoids the race condition where an
// async connection test delays startup while the app is already retrying.
if (require.main === module) {
    logLifecycle('startup', `pid=${process.pid} sock=${SOCKET_PATH}`);
    cleanupSocket();
    startServer();
}

module.exports = {
    FORBIDDEN_MOUNT_PATHS,
    CRITICAL_MOUNTS,
    validateMountPath,
    loadBwrapMountsConfig,
    mergeBwrapArgs,
    classifyBwrapProbeError,
};
