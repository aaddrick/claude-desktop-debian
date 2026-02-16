# Cowork Mode Linux Implementation - Handover Document

## Summary

This work enables Claude Desktop's Cowork mode on Linux by patching the Electron app to use the Windows-style TypeScript VM client (instead of the macOS `@ant/claude-swift` native addon) and routing it through a Unix domain socket to a custom Node.js service daemon.

## Target Architecture

```
Claude Desktop (Electron)
    ↕ Unix domain socket (length-prefixed JSON, same protocol as Windows pipe)
cowork-vm-service (Node.js daemon)
    ↕ QEMU/KVM subprocess management       ← Phase 3 (not yet implemented)
    ↕ virtio-vsock or SSH (host ↔ guest)   ← Phase 3
Linux VM (Anthropic rootfs.img from downloads.claude.ai)
    └── sdk-daemon → bubblewrap → Claude Code CLI
```

**Current state (Phase 1 stub)**: The service daemon runs Claude Code directly on the host with no VM or sandbox isolation. This is functionally equivalent to the old `claude-swift-stub.js` approach but using the proper TypeScript VM client protocol.

> **SECURITY WARNING**: The stub implementation runs Claude Code directly on the host with full user permissions. There is NO VM isolation, NO sandbox, and NO filesystem restrictions. Users should understand that Claude has access to their entire home directory. Real VM isolation requires Phase 3 (QEMU/KVM).

## Dependencies

**Current (Phase 1)**:
- Node.js 20+ (build-time, already required)
- All existing build.sh dependencies

**Future (Phase 3)**:
- `qemu-system-x86_64` with KVM support (runtime)
- `zstd` for rootfs decompression (build-time, already available)
- Linux kernel with `vhost_vsock` module for host↔guest communication

## What Was Done

### Files Modified
- **`build.sh`** — Added `patch_cowork_linux()` function (6 patches), removed `@ant/claude-swift` stub references, added service daemon to build output
- **`scripts/cowork-vm-service.js`** — New stub service daemon implementing the Windows pipe protocol over Unix socket
- **`scripts/claude-swift-stub.js`** — Deleted (replaced by TypeScript VM client approach)

### Patches Applied to index.js (via `patch_cowork_linux()`)

All patches use unique string anchors and dynamic variable extraction to be version-agnostic (minified variable names change between releases).

| # | Patch | Anchor String | Status |
|---|-------|--------------|--------|
| 1 | Platform check in `fz()`: add `&&t!=="linux"` | `"Unsupported platform"` | **WORKS** |
| 2a | Module loading log: add `\|\|process.platform==="linux"` | `"vmClient (TypeScript)"` | **WORKS** |
| 2b | Module assignment: same OR condition | `{vm:` near `@ant/claude-swift` | **WORKS** (fixed: optional parens for minified code) |
| 3 | Socket path: Unix domain socket on Linux | `"cowork-vm-service"` | **WORKS** |
| 4 | Bundle manifest: add `linux:{x64:[],arm64:[]}` | SHA hash near `files:` | **WORKS** (empty arrays = no download needed, vacuous truth) |
| 5 | Auto-launch service daemon in `Ma()` retry | `"VM service not running. The service failed to start."` | **PARTIALLY WORKS** (see issues) |

### Service Daemon (`cowork-vm-service.js`)

Implements the Windows named pipe protocol over a Unix domain socket:
- **Transport**: Unix socket at `$XDG_RUNTIME_DIR/cowork-vm-service.sock`
- **Framing**: 4-byte big-endian length prefix + JSON payload
- **Methods**: configure, createVM, startVM, stopVM, isRunning, isGuestConnected, spawn, kill, writeStdin, isProcessRunning, mountPath, readFile, installSdk, addApprovedOauthToken, subscribeEvents
- **Events**: Persistent connection via `subscribeEvents`, broadcasts stdout/stderr/exit/error/networkStatus/apiReachability

## What Works

1. **Platform gate passes** — `fz()` returns `{status: "supported"}` for Linux
2. **TypeScript VM client loads** — Log shows `[VM] Loading vmClient (TypeScript) module...` + `Module loaded successfully`
3. **Full VM startup sequence completes** — download_and_sdk_prepare → load_swift_api → callbacks → network connected → sdk_install → startup complete (541ms on warm start)
4. **Service daemon launches** — Socket created, responds to all protocol methods
5. **Spawn succeeds** — Claude Code CLI is spawned, stdin chunks are flushed
6. **Event field names fixed** — Events use `id` (not `processId`) matching client expectations
7. **Clean environment** — Strips `CLAUDECODE` (session detection trigger) and `ELECTRON_*` from daemon's inherited env. Preserves app-provided `CLAUDE_CODE_*` vars (OAuth tokens, API keys, entrypoint config) that Claude Code needs to function.
8. **Error events use correct field name** — Events use `message` field matching client expectations (was `error`, fixed)
9. **SDK binary path tracked** — `installSdk` resolves and stores the downloaded binary path for use in `spawn`
10. **VM guest paths handled** — `CLAUDE_CONFIG_DIR` and `cwd` pointing to `/sessions/...` are detected and corrected to host paths. Args `--plugin-dir` and `--add-dir` with VM guest paths are stripped.
11. **Stale socket cleanup is synchronous** — No race condition on restart; socket is always cleaned up before `listen`
12. **Messages work end-to-end** — Cowork mode sends messages and receives responses

## What's Broken / Needs Investigation

### 1. Service Daemon Process Lifecycle
The service daemon runs as a detached forked process. When the app quits, the `stopVM` method is called which sets `running=false`, but the service daemon process continues running. On next app launch, the dedup check should detect it's alive and reuse it, but this path hasn't been validated.

### 2. Message Flow — RESOLVED
All issues preventing message flow have been fixed:
- Error event field mismatch (`error` → `message`) — **FIXED**
- VM guest paths in env vars (`CLAUDE_CONFIG_DIR`, `cwd`) — **FIXED**
- SDK binary path lost from `installSdk` no-op — **FIXED**
- Stale socket race condition on restart — **FIXED**
- `CLAUDECODE=1` env var causing "cannot be launched inside another session" — **FIXED**
- Over-stripping app-provided env vars (OAuth tokens, API keys stripped) — **FIXED**
- VM guest paths in args (`--plugin-dir`, `--add-dir`) — **FIXED**

## Architecture Notes

### How the TypeScript VM Client Works (from beautified reference)

```
App calls method (e.g., spawn)
  → bYe.spawn() calls Ma("spawn", params)
    → Ma() retries up to 5 times with 1s delay
      → yYe() creates one-shot connection to socket
        → Sends length-prefixed JSON request
        → Receives length-prefixed JSON response
        → Connection closes

Events flow on separate persistent connection:
  → nAe() creates persistent connection
    → Sends { method: "subscribeEvents" }
    → Keeps connection open
    → Receives pushed events (stdout, stderr, exit, etc.)
    → Auto-reconnects after 1s if connection drops
```

### Key Internal Codenames
- `yukonSilver` — VM/Cowork feature gate
- `Ci` — `process.platform === "win32"` (minified, changes per version)
- `bYe` — TypeScript VM client object
- `Ma()` — Retry wrapper for socket IPC calls
- `fz()` — Platform support check
- `ov()` — VM startup entry point
- `nAe()` — Persistent event subscription connection
- `Ji` — Event callback registry

### Electron/asar Gotchas Discovered
- `process.execPath` in Electron = Electron binary, NOT Node.js. Using `spawn(process.execPath, [script])` triggers Electron's "open file" handler instead of executing the script
- **Solution**: Use `child_process.fork()` with `ELECTRON_RUN_AS_NODE: "1"` env var
- Files inside `.asar` cannot be executed by `child_process`. Service daemon must be in `app.asar.unpacked/`
- `process.resourcesPath` gives path to the resources directory containing both `app.asar` and `app.asar.unpacked`

## Service Daemon Method Reference

| Method | Params | Returns | Status |
|--------|--------|---------|--------|
| `configure` | `{memoryMB?, cpuCount?}` | `{}` | Stub (stores config) |
| `createVM` | `{bundlePath, diskSizeGB?}` | `{}` | Stub |
| `startVM` | `{bundlePath, memoryGB?}` | `{}` | Stub (sets running=true, fakes guest connect after 500ms) |
| `stopVM` | — | `{}` | Stub (kills spawned procs, sets running=false) |
| `isRunning` | — | `{running: bool}` | Works |
| `isGuestConnected` | — | `{connected: bool}` | Works (always true after startVM) |
| `spawn` | `{id, name, command, args, cwd?, env?, additionalMounts?, isResume?, allowedDomains?, sharedCwdPath?, oneShot?}` | `{}` | Stub (runs on host, not in VM) |
| `kill` | `{id, signal?}` | `{}` | Works |
| `writeStdin` | `{id, data}` | `{}` | Works |
| `isProcessRunning` | `{id}` | `{running: bool}` | Works |
| `mountPath` | `{processId, subpath, mountName, mode}` | `{guestPath}` | Stub (returns host path) |
| `readFile` | `{processName, filePath}` | `{content}` | Works (reads from host) |
| `installSdk` | `{sdkSubpath, version}` | `{}` | Tracks binary path for spawn |
| `addApprovedOauthToken` | `{token}` | `{}` | Stub (no-op) |
| `subscribeEvents` | — | `{}` + persistent event stream | Works |

**Event types pushed on subscribeEvents connection:**

| Event | Fields | Notes |
|-------|--------|-------|
| `stdout` | `{type, id, data}` | Process stdout output |
| `stderr` | `{type, id, data}` | Process stderr output |
| `exit` | `{type, id, exitCode, signal}` | Process exited |
| `error` | `{type, id, message}` | Process error |
| `networkStatus` | `{type, status}` | `"connected"` or `"disconnected"` |
| `apiReachability` | `{type, status}` | API reachability status |

## QEMU Configuration (Phase 3)

Target command for VM boot (flags TBD after rootfs analysis):

```bash
qemu-system-x86_64 \
  -enable-kvm -m ${memoryGB}G -cpu host -smp ${cpuCount} \
  -nographic \
  -drive file=rootfs.img,format=raw,if=virtio \
  -device vhost-vsock-pci,guest-cid=3 \
  -monitor unix:/tmp/cowork-qemu-monitor.sock,server,nowait \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0
```

Exact flags depend on Phase 2 rootfs analysis:
- Boot mechanism: full boot vs kernel+initrd (Windows entries have vmlinuz+initrd)
- Guest CID for vsock communication
- 9p vs virtiofs for host directory sharing
- Console/serial configuration for guest logs

## Verification Checklist

### Phase 1 (current)
- [x] Build: `./build.sh --build appimage --clean no` completes without errors
- [x] Patches: All 6 cowork patches applied (check build output)
- [x] Module: Logs show `[VM] Loading vmClient (TypeScript) module...` (not `@ant/claude-swift`)
- [x] Startup: `[VM:start] Startup complete` appears in cowork_vm_node.log
- [x] Socket: `$XDG_RUNTIME_DIR/cowork-vm-service.sock` exists after startup
- [x] Service: `pgrep -af cowork-vm-service` shows running process
- [x] Messages: Send a message in Cowork, verify response appears
- [ ] Restart: Kill app, relaunch, verify Cowork reconnects without ECONNREFUSED
- [ ] Clean exit: Close app normally, verify service daemon stops

### Phase 2 (future)
- [ ] Download rootfs from `https://downloads.claude.ai/vms/linux/x64/{sha}/rootfs.img.zst`
- [ ] Decompress with `zstd -d rootfs.img.zst`
- [ ] Mount and inspect: find sdk-daemon, systemd services, vsock config
- [ ] Boot in QEMU with KVM: `qemu-system-x86_64 -enable-kvm ...`
- [ ] Verify guest boots and sdk-daemon starts

### Phase 3 (future)
- [ ] QEMU boots rootfs and guest connects via vsock
- [ ] Service daemon forwards spawn/kill/stdin to guest sdk-daemon
- [ ] stdout/stderr events flow back from guest to Electron app
- [ ] Host directory sharing works (9p or virtiofs)
- [ ] Create a Cowork session, send a message, verify Claude Code executes in VM
- [ ] Test file mounts (select a folder, verify access from VM)

## Next Steps

### Immediate — ALL DONE
1. ~~Fix stale socket handling~~ — Synchronous `unlink` before `listen`
2. ~~Fix error event field name~~ — `error` → `message` in broadcastEvent
3. ~~Fix VM guest paths~~ — Strip `/sessions/...` from `CLAUDE_CONFIG_DIR`, `cwd`, `--plugin-dir`, `--add-dir`
4. ~~Track SDK binary path~~ — `installSdk` stores path, `spawn` uses it
5. ~~Fix `CLAUDECODE` session detection~~ — Strip from daemon env, keep app-provided `CLAUDE_CODE_*`
6. ~~Verify end-to-end message flow~~ — Messages sent and responses received

### Phase 2: Rootfs Analysis
1. Download rootfs from `https://downloads.claude.ai/vms/linux/x64/{sha}/rootfs.img.zst`
2. Decompress with zstd, mount and inspect
3. Find sdk-daemon binary, vsock configuration, systemd services
4. Test booting in QEMU with KVM

### Phase 3: Real VM Isolation
1. Replace stub spawn with QEMU/KVM subprocess management
2. Implement vsock communication (host ↔ guest)
3. Forward spawn/kill/stdin to guest sdk-daemon
4. Implement 9p/virtiofs for host directory sharing
5. Add proper VM lifecycle (boot, shutdown, health monitoring)

## Build & Test Commands

```bash
# Build
./build.sh --build appimage --clean no

# Launch with debug logging
COWORK_VM_DEBUG=1 ./claude-desktop-1.1.3189-amd64.AppImage

# Check logs
tail -f ~/.config/Claude/logs/cowork_vm_node.log

# Check service daemon
ls -la $XDG_RUNTIME_DIR/cowork-vm-service.sock
pgrep -af cowork-vm-service

# Kill everything for fresh start
pkill -9 -f "mount_claude"
pkill -9 -f "cowork-vm-service"
rm -f $XDG_RUNTIME_DIR/cowork-vm-service.sock
```

## Reference Files
- `build-reference/app-extracted/.vite/build/index.js` — Beautified v1.1.3189 source (224K lines)
- Blog posts with architecture analysis:
  - `aaddrick.com/blog/reverse-engineering-claude-desktops-cowork-mode-a-deep-dive-into-vm-isolation-and-linux-possibilities.md`
  - `aaddrick.com/blog/claude-desktop-cowork-mode-vm-architecture-analysis.md`
