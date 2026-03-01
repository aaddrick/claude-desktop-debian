# Cowork Mode Linux Implementation - Handover Document

## Summary

This work enables Claude Desktop's Cowork mode on Linux by patching the Electron app to use the Windows-style TypeScript VM client (instead of the macOS `@ant/claude-swift` native addon) and routing it through a Unix domain socket to a custom Node.js service daemon.

The service daemon uses a pluggable backend architecture with three isolation levels: **KvmBackend** (full QEMU/KVM VM with vsock + virtiofs), **BwrapBackend** (bubblewrap namespace sandbox), and **HostBackend** (no isolation, direct execution). The backend is auto-detected based on available system capabilities, or can be forced via the `COWORK_VM_BACKEND` environment variable.

## Target Architecture

```
Claude Desktop (Electron)
    ↕ Unix domain socket (length-prefixed JSON, same protocol as Windows pipe)
cowork-vm-service (Node.js daemon)
    └── VMManager (thin dispatcher)
            → delegates to this.backend (auto-detected or COWORK_VM_BACKEND override)

Backend selection (priority order):
  1. KvmBackend   — QEMU/KVM + vsock + virtiofs (full VM isolation)
  2. BwrapBackend — bubblewrap namespace sandbox (lightweight isolation)
  3. HostBackend  — direct on host, no isolation (fallback)

KvmBackend path:
  QEMU/KVM (qemu-system-x86_64 -enable-kvm ...)
      ↕ virtio-vsock (socat bridge: Unix socket ↔ vsock CID:port)
      ↕ virtiofsd (host directory sharing via vhost-user-fs-pci)
  Linux VM (rootfs.qcow2 overlay)
      └── sdk-daemon → Claude Code CLI

BwrapBackend path:
  bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run \
        --bind $workDir $workDir --unshare-pid --die-with-parent --new-session
      └── Claude Code CLI (sandboxed)

HostBackend path:
  spawn(claude-code-cli, args)  ← direct execution, no isolation
```

**Current state (Phases 1-3 implemented)**: All three backends are implemented. The active backend is auto-detected at daemon startup based on system capabilities. The KVM backend requires a rootfs image, which has not yet been tested with the actual Anthropic rootfs; the bwrap and host backends are functional and tested.

> **ISOLATION NOTE**: The default backend depends on what is installed. With no additional packages, the HostBackend runs Claude Code directly on the host with full user permissions. Install `bubblewrap` for namespace-level sandbox isolation, or set up QEMU/KVM with a rootfs image for full VM isolation. The `--doctor` flag shows which backend will be active.

## Dependencies

**Build-time (all backends)**:
- Node.js 20+ (already required)
- All existing build.sh dependencies

**Runtime Dependencies by Backend**:

| Dependency | HostBackend | BwrapBackend | KvmBackend | Notes |
|------------|:-----------:|:------------:|:----------:|-------|
| Claude Code CLI | Required | Required | — | Resolved via `installSdk` or `which` |
| `bubblewrap` (`bwrap`) | — | Required | — | Namespace sandbox |
| `/dev/kvm` (read+write) | — | — | Required | KVM acceleration |
| `qemu-system-x86_64` | — | — | Required | VM hypervisor |
| `qemu-img` | — | — | Required | Overlay disk creation |
| `/dev/vhost-vsock` | — | — | Required | Host↔guest communication |
| `socat` | — | — | Required | vsock bridge (Unix socket ↔ vsock) |
| `virtiofsd` | — | — | Recommended | Host directory sharing via virtiofs |
| `rootfs.qcow2` | — | — | Required | VM disk image in `~/.local/share/claude-desktop/vm/` |
| `zstd` | — | — | Optional | Rootfs decompression (build-time) |

The `--doctor` flag checks all of these and shows distro-specific install commands.

## What Was Done

### Files Modified
- **`build.sh`** — Added `patch_cowork_linux()` function (6 patches), removed `@ant/claude-swift` stub references, added service daemon to build output. Patch 4 updated to extract real file entries from the win32 manifest (rootfs.vhdx, vmlinuz, initrd with checksums) instead of empty arrays.
- **`scripts/cowork-vm-service.js`** — Refactored from monolithic VMManager into pluggable backend architecture:
  - **BackendBase** — Abstract base class defining the interface (`init`, `startVM`, `stopVM`, `spawn`, `kill`, `writeStdin`, etc.)
  - **HostBackend** — Original Phase 1 logic moved here verbatim (direct execution, no isolation)
  - **BwrapBackend** — Wraps commands in `bwrap` with namespace isolation (`--unshare-pid`, `--die-with-parent`, `--new-session`)
  - **KvmBackend** — Full QEMU/KVM with overlay disks, virtiofsd, socat vsock bridge, QMP monitor, graceful shutdown (ACPI -> QMP quit -> SIGKILL)
  - **VMManager** — Now a thin dispatcher that delegates all methods to `this.backend`
  - **Shared helpers extracted** — `filterEnv()`, `buildSpawnEnv()`, `cleanSpawnArgs()`, `resolveWorkDir()`, `resolveCommand()` used by all backends
  - **`detectBackend()`** — Auto-detection function with `COWORK_VM_BACKEND` env override
- **`scripts/launcher-common.sh`** — Added `--doctor` checks for Cowork mode dependencies: KVM accessibility, vsock module, QEMU, qemu-img, socat, virtiofsd, bubblewrap, VM image presence. Includes distro-specific package install hints (Debian/Ubuntu, Fedora, Arch). Shows summary of active backend.
- **`scripts/claude-swift-stub.js`** — Deleted (replaced by TypeScript VM client approach)

### Patches Applied to index.js (via `patch_cowork_linux()`)

All patches use unique string anchors and dynamic variable extraction to be version-agnostic (minified variable names change between releases).

| # | Patch | Anchor String | Status |
|---|-------|--------------|--------|
| 1 | Platform check in `fz()`: add `&&t!=="linux"` | `"Unsupported platform"` | **WORKS** |
| 2a | Module loading log: add `\|\|process.platform==="linux"` | `"vmClient (TypeScript)"` | **WORKS** |
| 2b | Module assignment: same OR condition | `{vm:` near `@ant/claude-swift` | **WORKS** (fixed: optional parens for minified code) |
| 3 | Socket path: Unix domain socket on Linux | `"cowork-vm-service"` | **WORKS** |
| 4 | Bundle manifest: add `linux:{x64:[...],arm64:[...]}` | SHA hash near `files:` | **WORKS** (extracts win32 file entries — rootfs.vhdx, vmlinuz, initrd with checksums — and reuses them as linux entries; falls back to empty arrays if extraction fails) |
| 5 | Auto-launch service daemon in `Ma()` retry | `"VM service not running. The service failed to start."` | **PARTIALLY WORKS** (see issues) |

### Service Daemon (`cowork-vm-service.js`)

Implements the Windows named pipe protocol over a Unix domain socket:
- **Transport**: Unix socket at `$XDG_RUNTIME_DIR/cowork-vm-service.sock`
- **Framing**: 4-byte big-endian length prefix + JSON payload
- **Architecture**: VMManager (thin dispatcher) -> BackendBase subclass
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

## Backend Detection

The `detectBackend()` function selects the active backend at daemon startup. The `COWORK_VM_BACKEND` environment variable can override auto-detection.

### Auto-detection order:

1. **KVM** — Requires ALL of:
   - `/dev/kvm` readable and writable
   - `qemu-system-x86_64` in PATH
   - `/dev/vhost-vsock` readable
   - `~/.local/share/claude-desktop/vm/rootfs.qcow2` exists

2. **Bwrap** — Requires:
   - `bwrap` in PATH
   - `bwrap --ro-bind / / true` succeeds (functional test)

3. **Host** — Always available (fallback)

### Override:

```bash
# Force a specific backend
COWORK_VM_BACKEND=host ./claude-desktop.AppImage
COWORK_VM_BACKEND=bwrap ./claude-desktop.AppImage
COWORK_VM_BACKEND=kvm ./claude-desktop.AppImage

# Check which backend is active
./claude-desktop.AppImage --doctor
# Output: "Cowork isolation: KVM (full VM isolation)" or
#         "Cowork isolation: bubblewrap (namespace sandbox)" or
#         "Cowork isolation: none (host-direct, no isolation)"
```

The selected backend is logged to `~/.config/Claude/logs/cowork_vm_daemon.log` at startup.

## Service Daemon Method Reference

| Method | Params | Returns | Status |
|--------|--------|---------|--------|
| `configure` | `{memoryMB?, cpuCount?}` | `{}` | Stores config, delegates to backend `init()` |
| `createVM` | `{bundlePath, diskSizeGB?}` | `{}` | No-op (KVM creates overlay on `startVM`) |
| `startVM` | `{bundlePath, memoryGB?}` | `{}` | Host/Bwrap: sets running=true. KVM: starts QEMU, virtiofsd, socat bridge, waits for guest |
| `stopVM` | — | `{}` | Host/Bwrap: kills spawned procs. KVM: ACPI shutdown -> QMP quit -> SIGKILL, cleans session dir |
| `isRunning` | — | `{running: bool}` | Works (all backends) |
| `isGuestConnected` | — | `{connected: bool}` | Host/Bwrap: true after startVM. KVM: true after guest responds to ping |
| `spawn` | `{id, name, command, args, cwd?, env?, additionalMounts?, isResume?, allowedDomains?, sharedCwdPath?, oneShot?}` | `{}` | Host: direct spawn. Bwrap: wrapped in `bwrap` sandbox. KVM: forwarded to guest sdk-daemon via vsock |
| `kill` | `{id, signal?}` | `{}` | Works (all backends) |
| `writeStdin` | `{id, data}` | `{}` | Works (all backends) |
| `isProcessRunning` | `{id}` | `{running: bool}` | Works (all backends) |
| `mountPath` | `{processId, subpath, mountName, mode}` | `{guestPath}` | Host: returns host path. Bwrap: stores for `--bind` on next spawn. KVM: returns `/mnt/host/...` if virtiofs active |
| `readFile` | `{processName, filePath}` | `{content}` | Host/Bwrap: reads from host. KVM: forwards to guest, falls back to host |
| `installSdk` | `{sdkSubpath, version}` | `{}` | Tracks binary path for spawn (all backends) |
| `addApprovedOauthToken` | `{token}` | `{}` | Host/Bwrap: no-op. KVM: forwards to guest |
| `subscribeEvents` | — | `{}` + persistent event stream | Works (all backends) |

**Event types pushed on subscribeEvents connection:**

| Event | Fields | Notes |
|-------|--------|-------|
| `stdout` | `{type, id, data}` | Process stdout output |
| `stderr` | `{type, id, data}` | Process stderr output |
| `exit` | `{type, id, exitCode, signal}` | Process exited |
| `error` | `{type, id, message}` | Process error |
| `networkStatus` | `{type, status}` | `"connected"` or `"disconnected"` |
| `apiReachability` | `{type, status}` | API reachability status |

## QEMU Configuration

The KvmBackend builds QEMU arguments dynamically. The actual command is:

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m ${memoryGB}G \
  -cpu host \
  -smp ${cpuCount} \
  -nographic \
  -kernel ${VM_BASE_DIR}/vmlinuz \           # if present
  -initrd ${VM_BASE_DIR}/initrd \            # if present
  -append "root=/dev/vda1 console=ttyS0 quiet" \
  -drive file=${sessionDir}/overlay.qcow2,format=qcow2,if=virtio \
  -device vhost-vsock-pci,guest-cid=${cid} \
  -qmp unix:${sessionDir}/qmp.sock,server,nowait \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -chardev socket,id=virtiofs,path=${sessionDir}/virtiofs.sock \  # if virtiofsd
  -device vhost-user-fs-pci,chardev=virtiofs,tag=hostshare        # if virtiofsd
```

### Key details:
- **Overlay disks**: Each session creates a qcow2 overlay backed by `rootfs.qcow2`, so the base image is never modified. Session dir: `~/.local/share/claude-desktop/vm/sessions/<uuid>/`
- **Guest CID**: Allocated incrementally starting at 3 (0-2 are reserved), tracked via `~/.local/share/claude-desktop/vm/.next_cid`
- **VHDX conversion**: If `rootfs.vhdx` exists but `rootfs.qcow2` does not, `qemu-img convert` runs automatically on first init
- **virtiofsd**: Started separately, shares user's home directory to guest via `vhost-user-fs-pci` with tag `hostshare`
- **socat bridge**: `socat UNIX-LISTEN:${bridgeSock},fork VSOCK-CONNECT:${cid}:2222` bridges Unix socket to vsock for host->guest communication
- **Graceful shutdown**: ACPI power-down via QMP -> wait 10s -> QMP quit -> wait 3s -> SIGKILL
- **Kernel+initrd**: Optional; if `vmlinuz` exists in `VM_BASE_DIR`, direct kernel boot is used. Otherwise falls back to full disk boot.

### Remaining rootfs questions:
- The actual Anthropic rootfs format (VHDX from Windows downloads) needs testing with the conversion path
- Guest sdk-daemon vsock port and protocol need verification
- virtiofs mount point inside the guest needs confirmation

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

### Phase 2 — Backend Architecture (implemented)
- [x] Refactor VMManager into thin dispatcher with pluggable backends
- [x] Extract shared helpers: `filterEnv`, `buildSpawnEnv`, `cleanSpawnArgs`, `resolveWorkDir`, `resolveCommand`
- [x] HostBackend: move existing logic verbatim
- [x] BwrapBackend: `bwrap` namespace sandbox with `--unshare-pid`, `--die-with-parent`, `--new-session`
- [x] KvmBackend: QEMU/KVM with overlay disks, virtiofsd, socat vsock bridge, QMP
- [x] `detectBackend()` auto-detection with `COWORK_VM_BACKEND` env override
- [x] `--doctor` checks for all dependencies (KVM, vsock, QEMU, socat, virtiofsd, bwrap)
- [x] Distro-specific install hints in `--doctor` (Debian/Ubuntu, Fedora, Arch)
- [x] Patch 4 updated to extract real win32 file entries for linux manifest

### Phase 3 — VM Integration (implemented, needs testing with real rootfs)
- [x] QEMU boots with overlay disk, vsock, QMP monitor, and virtiofs
- [x] socat bridge created for host->guest communication
- [x] Guest readiness polling via ping over bridge socket
- [x] Service daemon forwards spawn/kill/writeStdin/readFile to guest sdk-daemon
- [x] Event forwarding: subscribes to guest events and relays to Electron app
- [x] Host directory sharing via virtiofsd + vhost-user-fs-pci
- [x] Graceful VM shutdown: ACPI -> QMP quit -> SIGKILL
- [x] Per-session overlay disks (base image never modified)
- [x] Session directory cleanup on stopVM
- [ ] Download rootfs from `https://downloads.claude.ai/vms/linux/x64/{sha}/rootfs.img.zst`
- [ ] Decompress and convert rootfs (zstd -> VHDX -> qcow2)
- [ ] Boot actual Anthropic rootfs and verify guest sdk-daemon starts
- [ ] End-to-end test: Cowork session with KVM backend
- [ ] Verify virtiofs mounts are accessible inside guest

## Next Steps

### Phase 1 — ALL DONE
1. ~~Fix stale socket handling~~ — Synchronous `unlink` before `listen`
2. ~~Fix error event field name~~ — `error` → `message` in broadcastEvent
3. ~~Fix VM guest paths~~ — Strip `/sessions/...` from `CLAUDE_CONFIG_DIR`, `cwd`, `--plugin-dir`, `--add-dir`
4. ~~Track SDK binary path~~ — `installSdk` stores path, `spawn` uses it
5. ~~Fix `CLAUDECODE` session detection~~ — Strip from daemon env, keep app-provided `CLAUDE_CODE_*`
6. ~~Verify end-to-end message flow~~ — Messages sent and responses received

### Phase 2: Backend Architecture — DONE
1. ~~Refactor VMManager into dispatcher + backend pattern~~
2. ~~Extract shared helpers~~
3. ~~Implement BwrapBackend with namespace isolation~~
4. ~~Implement KvmBackend with QEMU/KVM, vsock, virtiofs~~
5. ~~Add `detectBackend()` auto-detection~~
6. ~~Add `--doctor` checks for all cowork dependencies~~
7. ~~Update Patch 4 with real bundle manifest entries~~

### Phase 3: VM Integration — DONE (code complete, needs rootfs testing)
1. ~~QEMU startup with overlay disks, QMP monitor~~
2. ~~virtiofsd for host directory sharing~~
3. ~~socat vsock bridge for host↔guest communication~~
4. ~~Guest readiness polling~~
5. ~~Request forwarding to guest sdk-daemon~~
6. ~~Event forwarding from guest to Electron app~~
7. ~~Graceful VM shutdown (ACPI -> QMP quit -> SIGKILL)~~

### Remaining Work
1. **Rootfs analysis** — Download actual Anthropic rootfs, decompress (zstd), convert (VHDX->qcow2), mount and inspect for sdk-daemon, vsock port, systemd services
2. **End-to-end KVM testing** — Boot rootfs in QEMU, verify guest connects via vsock, test full Cowork session
3. **Service daemon lifecycle** — Validate restart behavior (kill app, relaunch, verify reconnect)
4. **Clean exit** — Verify service daemon stops on normal app close
5. **BwrapBackend testing** — Verify sandbox isolation works for real Cowork sessions
6. **ARM64 support** — KvmBackend currently uses `qemu-system-x86_64`; ARM64 would need `qemu-system-aarch64`

## Build & Test Commands

```bash
# Build
./build.sh --build appimage --clean no

# Launch with debug logging
COWORK_VM_DEBUG=1 ./claude-desktop-*.AppImage

# Force a specific backend
COWORK_VM_BACKEND=bwrap COWORK_VM_DEBUG=1 ./claude-desktop-*.AppImage

# Check doctor output for cowork dependencies
./claude-desktop-*.AppImage --doctor

# Check logs
tail -f ~/.config/Claude/logs/cowork_vm_node.log      # Electron VM client logs
tail -f ~/.config/Claude/logs/cowork_vm_daemon.log     # Service daemon logs

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
