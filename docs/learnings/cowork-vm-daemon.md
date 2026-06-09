# Cowork VM Daemon — Learnings

## Architecture Overview

Cowork mode on Linux uses a custom Node.js daemon
([`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js))
that replaces the Windows cowork-vm-service. The Electron app talks to
it over a Unix domain socket at
`$XDG_RUNTIME_DIR/cowork-vm-service.sock` using length-prefixed JSON —
the same wire format as the Windows named pipe.

The daemon is forked by **Patch 6** in the
`patch_cowork_linux()` function (`scripts/patches/cowork.sh`), which
injects auto-launch code into the Electron app's retry loop for the
VM-service connection.

## Daemon Lifecycle

1. First connect attempt: the app tries `$XDG_RUNTIME_DIR/cowork-vm-service.sock`.
2. `ENOENT` / `ECONNREFUSED`: retry loop catches the error (the
   `ECONNREFUSED` branch is Linux-only, added by Patch 6 step 1 so
   stale sockets don't bypass retry).
3. Auto-launch (Patch 6 step 2): the injected code forks the daemon
   via `child_process.fork()` with `detached:true`, stdio redirected
   to `~/.config/Claude/logs/cowork_vm_daemon.log`.
4. Spawn cooldown: `FUNC._lastSpawn = Date.now()` — subsequent
   iterations only re-fork after 10 s have elapsed. This replaces the
   old one-shot `_svcLaunched` boolean so the retry loop can recover
   after mid-session daemon death (issue #408).
5. Retry: the loop waits and reconnects, which now succeeds.

## Issue #408 — Daemon Recovery

### Root cause (one-shot guard)

Before the fix, Patch 6 injected:

```javascript
process.platform==="linux" && !FUNC._svcLaunched && (
    FUNC._svcLaunched = true,
    /* fork daemon */
)
```

`FUNC._svcLaunched` was set on the first successful spawn and never
cleared, so when the daemon died mid-session the retry loop saw the
guard already set and skipped the re-fork. The client looped forever
on `connect ENOENT`.

### Fix (rate-limited respawn)

Timestamp-based cooldown replaces the boolean:

```javascript
process.platform==="linux" &&
(!FUNC._lastSpawn || Date.now() - FUNC._lastSpawn > 1e4) &&
(FUNC._lastSpawn = Date.now(), /* fork daemon */)
```

10 s is short enough that the retry loop (which sleeps on the order of
seconds between iterations) recovers promptly after a crash, and long
enough that a crash-looping daemon can't turn into a fork bomb.

### Secondary cause (preserved images block recovery)

The app's `_ue()` / `deleteVMBundle()` function deletes a whitelist of
reinstall files on auto-reinstall. Upstream deliberately preserves
`sessiondata.img` and `rootfs.img.zst` to avoid re-download.

On 1.2773.0 those preserved files put the daemon into an unstartable
state that persists across app restart and OS reboot. The client's
symptom is `connect ENOENT` (daemon never got far enough to create the
socket) rather than `ECONNREFUSED` (daemon started, crashed, socket
stayed). RayCharlizard (2026-04-16) confirmed that manually wiping
`~/.config/Claude/vm_bundles/claudevm.bundle/` is required to recover,
even after rolling back the AppImage to a known-good version.

### Fix (extend delete list — Patch 6b)

`scripts/patches/cowork.sh` now matches the `const NAME=["rootfs.img",...]` array at
module level and appends `"sessiondata.img"` and `"rootfs.img.zst"` if
they're not already present. The auto-reinstall path now wipes these
too. Trade-off: the next successful startup re-downloads/re-extracts
these files. Acceptable because auto-reinstall only runs after startup
has already failed — biasing toward recovery over re-download
avoidance is correct.

Not included in the delete list: `~/.config/Claude/claude-code-vm/`.
That's CLI-binary storage (`2.1.x/claude`), unrelated to the VM
daemon, and has its own version-check logic at `this.vmStorageDir`
inside the app. Wiping it would just force a slow re-download of the
CLI on every auto-reinstall.

## Silent Death — Now Logged

Before the fix the daemon was forked with `stdio:"ignore"`, and its
internal `log()` function was gated by `COWORK_VM_DEBUG=1`, so a crash
left no trace anywhere.

Two changes together make crashes visible:

1. **Patch 6 (client side)** redirects the forked daemon's stdout +
   stderr to `~/.config/Claude/logs/cowork_vm_daemon.log`. Any
   Node-level crash dump (uncaught exception pre-handler, native
   assertion, etc.) now lands in that file.
2. **`cowork-vm-service.js` (daemon side)** adds `logLifecycle()` —
   an always-on writer that bypasses `DEBUG` for startup, SIGTERM,
   SIGINT, `uncaughtException`, `unhandledRejection`, and `exit`
   events. It also proactively `mkdirSync`'s the log directory so the
   first write doesn't get swallowed if the daemon is the first thing
   writing under `~/.config/Claude/logs/`.

Interpreting the log after a failure:

| Last line | Diagnosis |
|-----------|-----------|
| `lifecycle startup ...` + gap + no further entries | SIGKILL'd (OOM killer, `kill -9`, etc.) — no handler fires |
| `lifecycle startup` + `lifecycle listening` + nothing else | Daemon running fine but died by signal with no handler (rare; check `dmesg`) |
| `lifecycle uncaughtException ...` | JS-level crash, stack is in the log entry |
| `lifecycle SIGTERM received` + `lifecycle exit code=0` | Clean app-initiated shutdown |
| No `startup` entry at all | `fork()` didn't complete; check launcher.log for `[cowork-autolaunch]` errors |
| No `cowork_vm_daemon.log` file at all **and** no `[cowork-autolaunch]` line | The auto-launch `fs.existsSync()` guard returned false — `app.asar.unpacked/` isn't traversable by the running user. Packaging perms bug; see [below](#packaging--appasarunpacked-must-be-traversable-by-the-run-time-user). |

## Packaging — `app.asar.unpacked/` must be traversable by the run-time user

The auto-launch fork is guarded by an existence check:

```javascript
const _d = _p.join(process.resourcesPath, "app.asar.unpacked",
    "cowork-vm-service.js");
if (_fs.existsSync(_d)) { /* fork daemon */ }
```

`fs.existsSync()` returns **false** when the directory can't be
traversed, not only when the file is genuinely absent — and there is no
`else`/`catch`, so the fork is skipped with zero log output. If the
packaged `app.asar.unpacked/` ships as mode `0700` owned by the build
uid (a restrictive build umask, plus `dpkg-deb` recording ownership
verbatim when not run under fakeroot or `--root-owner-group`), the
desktop user — a *different* uid — can't enter it. `existsSync` is
false, the daemon never forks, and the client loops forever on `connect
ENOENT`. The tell is that **both** the daemon log file and the
`[cowork-autolaunch]` error line are absent: nothing was even attempted.

Confirm what the run-time user actually sees, not what root sees:

```bash
svc=.../app.asar.unpacked/cowork-vm-service.js
test -r "$svc" && echo OK || echo BLOCKED   # run as the desktop user
stat -c '%A %U:%G' "$(dirname "$svc")"      # 0700 + foreign uid == broken
```

Fixed at the packaging boundary (not in the app code): `deb.sh` and
`appimage.sh` normalize the staged tree to canonical modes (directories
and executables `755`, other files `644`) before building, and the deb
is built with `dpkg-deb --root-owner-group` so ownership is `root:root`.
RPM has the same exposure through *file* modes: `%defattr(-, root,
root, 0755)` forces directory modes in the payload, but the `-` in its
first field preserves file modes verbatim from the buildroot, which
`%install` populates with plain `cp -r` — so a `umask 077` build ships
an unreadable `app.asar` and a non-executable electron binary (louder
symptom: EACCES, since the forced `0755` keeps directories
traversable). `rpm.sh` therefore normalizes file modes in `%install`
too. To unstick an already-installed package without rebuilding:
`sudo chmod -R o+rX /usr/lib/claude-desktop` (preserves the setuid
`chrome-sandbox`).

## Key Files

- [`scripts/patches/cowork.sh`](../../scripts/patches/cowork.sh)
  inside `patch_cowork_linux()` — Patch 6 (auto-launch + stdio pipe +
  rate limiter) and Patch 6b (reinstall array extension). Search for
  `# Patch 6` anchors; line numbers drift between upstream releases.
- [`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js)
  lines ~49-86 — log infrastructure, including `logLifecycle()`.
- [`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js)
  lines ~2399-2440 — signal handlers and entry point.
- [`scripts/launcher-common.sh`](../../scripts/launcher-common.sh) — `--doctor` checks.
- [`docs/cowork-linux-handover.md`](../cowork-linux-handover.md) — architecture reference.

## Diagnostic Commands

```bash
# Is the daemon running?
pgrep -af cowork-vm-service

# Socket present?
ls -la "${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

# Watch lifecycle events as they happen
tail -f ~/.config/Claude/logs/cowork_vm_daemon.log

# Look for the last startup / exit pair
grep -E 'lifecycle (startup|exit|SIGTERM|SIGINT|uncaughtException|unhandledRejection)' \
    ~/.config/Claude/logs/cowork_vm_daemon.log | tail -20

# Find any orphan sockets
lsof -U 2>/dev/null | grep -iE 'cowork|claude'

# Force a respawn test: kill daemon, watch client log for reconnect
pkill -9 -f cowork-vm-service.js
tail -f ~/.cache/claude-desktop-debian/launcher.log

# Find the daemon script inside a mounted AppImage
find /tmp -path '*claude*cowork-vm-service*' 2>/dev/null
```

## Testing Notes

- **Host-direct** (`COWORK_VM_BACKEND=host`): no isolation, direct
  execution. Matches the `--doctor` "host-direct (no isolation, via
  override)" line. This is what issue #408 was reported against.
- **Bwrap** (`COWORK_VM_BACKEND=bwrap`): Bubblewrap sandbox; requires
  `bwrap` installed.
- **KVM** (`COWORK_VM_BACKEND=kvm`): full VM; requires QEMU, KVM,
  rootfs image.
- **Debug** (`COWORK_VM_DEBUG=1` or `CLAUDE_LINUX_DEBUG=1`): verbose
  logging via the existing `log()` path. `logLifecycle()` is always
  on regardless of this flag.
- **Force-cooldown test**: kill the daemon, relaunch a Cowork session
  within 10 s — the guard should block that single retry. Wait 10 s
  and retry: should succeed. Confirms the cooldown boundary.
