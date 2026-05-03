# Platform Integration

Tests covering autostart, Cowork integration, WebGL graceful degradation, `.desktop`-launch env inheritance, encrypted env-var storage, the macOS/Windows-only Computer Use feature, and Dispatch session pairing. See [`../matrix.md`](../matrix.md) for status.

## T09 — AutoStart via XDG

**Severity:** Critical
**Surface:** XDG Autostart
**Applies to:** All rows
**Issues:** [PR #450](https://github.com/aaddrick/claude-desktop-debian/pull/450)

**Steps:**
1. In Settings, toggle "Open at Login" / "Start at boot" ON.
2. Inspect `~/.config/autostart/` for a `.desktop` entry.
3. Logout/login. Verify app launches automatically.
4. Toggle OFF. Verify the autostart entry is removed.

**Expected:** Toggling ON creates a `~/.config/autostart/*.desktop` entry that is XDG-spec compliant (not a custom systemd unit or shell hook). After login, app launches automatically. Toggling OFF removes the entry.

**Diagnostics on failure:** `ls -la ~/.config/autostart/`, content of the .desktop file, `desktop-file-validate` on it, launcher log.

**References:** [PR #450](https://github.com/aaddrick/claude-desktop-debian/pull/450)

**Code anchors:**
- `scripts/frame-fix-wrapper.js:376` — XDG Autostart shim
  intercepting `app.{get,set}LoginItemSettings` (writes/removes
  `$XDG_CONFIG_HOME/autostart/claude-desktop.desktop`).
- `scripts/frame-fix-wrapper.js:429` — `buildAutostartContent()`
  emits the spec-compliant `[Desktop Entry]` block.
- `build-reference/app-extracted/.vite/build/index.js:524205` —
  upstream `isStartupOnLoginEnabled` / `setStartupOnLoginEnabled` IPC
  surface that the wrapper interposes on.

## T10 — Cowork integration

**Severity:** Should
**Surface:** Cowork tab + VM daemon
**Applies to:** All rows
**Issues:** [`docs/learnings/cowork-vm-daemon.md`](../../learnings/cowork-vm-daemon.md)

**Steps:**
1. Sign into the app. Open the Cowork tab.
2. Confirm Cowork-specific UI renders (ghost icon in topbar, Cowork menus).
3. Trigger a Cowork action that needs the VM daemon.
4. Kill the VM daemon process; verify it respawns within the documented timeout.

**Expected:** Cowork features render. VM daemon spawns when needed, files are visible, daemon respawns within the documented timeout if it crashes.

**Diagnostics on failure:** `pgrep -af cowork`, daemon logs, launcher log, the respawn-logic code path (see learnings doc).

**References:** [`docs/learnings/cowork-vm-daemon.md`](../../learnings/cowork-vm-daemon.md)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:143371` —
  upstream's Windows named-pipe path (`\\.\pipe\cowork-vm-service`)
  that `scripts/patches/cowork.sh` Patch 1 rewrites to
  `$XDG_RUNTIME_DIR/cowork-vm-service.sock`.
- `build-reference/app-extracted/.vite/build/index.js:143453` —
  `kUe()` retry loop (5 attempts, 1 s gap) that the auto-launch
  injection from Patch 6 piggybacks on after the rewrite.
- `scripts/patches/cowork.sh:244` — Patch 6 (auto-launch + stdio
  pipe + 10 s rate-limited respawn — issue #408).
- `scripts/patches/cowork.sh:365` — Patch 6b (extends the
  reinstall-delete list with `sessiondata.img` / `rootfs.img.zst`
  so a wedged daemon can self-recover).

## T12 — WebGL warn-only

**Severity:** Could
**Surface:** Chromium GPU diagnostics
**Applies to:** All rows (especially VM rows and hybrid-GPU laptops)
**Issues:** —

**Steps:**
1. Launch the app. Open DevTools → navigate to `chrome://gpu`.
2. Inspect WebGL1/WebGL2 status.
3. Use the app for ~5 minutes — exercise UI, sidebar, settings.

**Expected:** WebGL1/2 may report as blocklisted (typical on virtio-gpu in VMs and on hybrid GPU laptops). This is informational. UI continues to render without graphical glitches; no feature is broken by the blocklist.

**Diagnostics on failure:** `chrome://gpu` full content, screenshot of any visual glitch, `glxinfo | head -20` (X11) or `eglinfo` (Wayland), `lspci -k | grep -A2 VGA`.

**References:** —

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:524809` —
  `app.disableHardwareAcceleration()` is gated on the user-toggleable
  `isHardwareAccelerationDisabled` setting; upstream does not pass
  `--ignore-gpu-blocklist` or `--use-gl=*`, so chrome://gpu reflects
  Chromium's stock blocklist behaviour.
- `build-reference/app-extracted/.vite/build/index.js:500571` —
  the only `webgl:!1` override is scoped to the feedback popup
  (`in-memory-feedback` partition); main UI does not disable WebGL.

## S17 — App launched from `.desktop` inherits shell `PATH`

**Severity:** Critical
**Surface:** `.desktop`-launch env handling
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Configure `~/.bashrc` (or `~/.zshrc`) with `export PATH="$HOME/.custom-bin:$PATH"` and a custom binary in that dir.
2. Launch the app via dmenu/krunner/GNOME Activities/Plasma launcher (i.e. **not** from a terminal).
3. Open a Code-tab terminal pane. Run `which <custom-binary>`.
4. Repeat for `npm`, `node`, `git`, `gh`.

**Expected:** Code session can find tools defined in the user's shell profile, even when the app was launched non-interactively. Either the launcher script sources the user's shell profile, or the app reads `~/.bashrc` / `~/.zshrc` to extract `PATH` the way macOS does.

**Diagnostics on failure:** `echo $PATH` from inside the integrated terminal, the env passed to the app process (`cat /proc/$(pgrep -f electron)/environ | tr '\0' '\n' | grep PATH`), launcher log.

**References:** [Local sessions](https://code.claude.com/docs/en/desktop#local-sessions), [Session not finding installed tools](https://code.claude.com/docs/en/desktop#session-not-finding-installed-tools)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:259300` —
  `SLr()` resolves the bundled `shell-path-worker/shellPathWorker.js`.
- `build-reference/app-extracted/.vite/build/index.js:259349` —
  `NLr()` forks it via `utilityProcess.fork`; on success
  `FX()` (line 259311) merges the extracted env into `process.env`.
- `build-reference/app-extracted/.vite/build/shell-path-worker/shellPathWorker.js:205`
  — `extractPathFromShell()` runs the user's login shell (`-l -i`)
  and parses the printed `$PATH` between sentinels (mac-style env
  inheritance now applied on Linux too).

## S18 — Local environment editor persists across reboot

**Severity:** Should
**Surface:** Local env editor / encrypted store
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Open the local environment editor. Add `TEST_VAR=hello`.
2. Restart the app — verify variable is still there.
3. Reboot the host. Sign back in. Verify variable is still there.

**Expected:** Variables saved via the local environment editor (per-app, encrypted) survive a logout/login cycle and a full reboot. On Linux this implies the encrypted store is wired to libsecret / kwallet / gnome-keyring and unlocks at session start.

**Diagnostics on failure:** `secret-tool search` (libsecret), `kwallet5-query` (KDE), `seahorse` UI inspection (GNOME), launcher log, the env-editor IPC call.

**References:** [Local sessions](https://code.claude.com/docs/en/desktop#local-sessions)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:259251` —
  `I2t = new K_({ name: "ccd-environment-config", ... })` electron-store
  backing file (`~/.config/Claude/ccd-environment-config.json`).
- `build-reference/app-extracted/.vite/build/index.js:259253` —
  `hLr()` writes via `safeStorage.encryptString` (libsecret on Linux).
- `build-reference/app-extracted/.vite/build/index.js:259268` —
  `J1()` decrypts on read; bails to `{}` if `safeStorage` reports
  encryption unavailable (no keyring backend running).
- `build-reference/app-extracted/.vite/build/index.js:70782` —
  `LocalSessionEnvironment.save` IPC entry that calls into `hLr`.

## S22 — Computer-use toggle is absent or visibly disabled on Linux

**Severity:** Should
**Surface:** Settings → Desktop app → General
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Open Settings → Desktop app → General.
2. Look for the "Computer use" toggle.

**Expected:** Toggle either does not render on Linux, or renders as a disabled control with a clear "not supported on Linux" hint. Must not appear functional and silently fail (e.g. flip on but never produce screen-control behavior).

**Diagnostics on failure:** Screenshot of the Settings page, DevTools inspection of the toggle DOM (is it conditionally hidden? disabled? always-rendered?), launcher log.

**References:** [Let Claude use your computer](https://code.claude.com/docs/en/desktop#let-claude-use-your-computer), [Dispatch and computer use](https://claude.com/blog/dispatch-and-computer-use)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:240557` —
  `qDA = new Set(["darwin", "win32"])` excludes Linux from the
  computer-use platform set.
- `build-reference/app-extracted/.vite/build/index.js:241190` —
  `TF()` (the master enable check) short-circuits to `false` when
  `qDA.has(process.platform)` is false, so toggling
  `chicagoEnabled` on Linux can't activate the feature.
- `build-reference/app-extracted/.vite/build/index.js:242387` —
  `tvr()` returns `{ status: "unsupported", reason: "Computer use
  is not available on this platform", unsupportedCode:
  "unsupported_platform" }` for the Settings UI — confirms the
  toggle should render with a platform-unavailable hint, not silent
  failure.

## S23 — Dispatch-spawned sessions don't soft-lock on a never-approvable computer-use prompt

**Severity:** Critical (for Dispatch users)
**Surface:** Dispatch session lifecycle on Linux
**Applies to:** All rows with Dispatch enabled
**Issues:** —

**Steps:**
1. From a paired phone, dispatch a task that would invoke computer use.
2. Observe the Code-tab session that spawns on the desktop.
3. Try to interact with other parts of the app.

**Expected:** Permission prompt times out or denies cleanly rather than hanging the session indefinitely. User can continue interacting with the rest of the app.

**Diagnostics on failure:** Screenshot of session state, launcher log, sidebar state (is the Dispatch session blocking the whole sidebar?), `pgrep -af claude`.

**References:** [Sessions from Dispatch](https://code.claude.com/docs/en/desktop#sessions-from-dispatch)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:512789` —
  `tool_permission_request` notification handler explicitly skips
  `toolName.startsWith("computer:")`, so the desktop never queues a
  user-facing prompt for computer-use tool calls (which couldn't run
  on Linux anyway — see S22).
- `build-reference/app-extracted/.vite/build/index.js:241190` —
  `TF()` gates computer-use execution off entirely on Linux, so a
  Dispatch-spawned session that requests it should hit the upstream
  "Set up computer use" remote-client setup card
  (`index.js:330114`) rather than block on a desktop prompt.

## S24 — Dispatch-spawned Code session appears with badge and notification

**Severity:** Critical
**Surface:** Dispatch handoff
**Applies to:** All rows with Dispatch enabled
**Issues:** —

**Steps:**
1. From a paired phone, dispatch a task that routes to Code (e.g. "fix this bug").
2. Observe the desktop sidebar.
3. Confirm a desktop notification fires.
4. Open the session and confirm 30-min approval expiry per upstream docs.

**Expected:** Dispatch task creates a sidebar entry tagged **Dispatch**, posts a desktop notification, and lands ready for review. App-permission approvals on this session expire after 30 minutes per upstream docs.

**Diagnostics on failure:** Screenshot of sidebar (badge present?), notification daemon state, launcher log, the Dispatch pairing config under `~/.config/Claude/`.

**References:** [Sessions from Dispatch](https://code.claude.com/docs/en/desktop#sessions-from-dispatch), [Dispatch and computer use](https://claude.com/blog/dispatch-and-computer-use)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:144561` —
  `Sd = "dispatch_child"` session-type constant.
- `build-reference/app-extracted/.vite/build/index.js:512200` —
  `onRemoteSessionStart` IPC routes a Dispatch-initiated child
  session into the local sidebar via `dispatchOnRemoteSessionStart`.
- `build-reference/app-extracted/.vite/build/index.js:285621` —
  `notifyDispatchParentIfNeeded()` posts the
  `Task "<title>" <state>` meta-notification when the dispatch
  child finishes (lands the result in the parent thread's
  notification queue).
- `build-reference/app-extracted/.vite/build/index.js:285954` —
  `kind:"dispatch_child"` is the sidebar badge tag.

## S25 — Mobile pairing survives Linux session restart

**Severity:** Should
**Surface:** Dispatch pairing persistence
**Applies to:** All rows with Dispatch enabled
**Issues:** —

**Steps:**
1. Pair the desktop with a phone.
2. Quit the app fully. Re-launch.
3. Try a Dispatch task. Verify pairing still works without re-pairing.
4. Logout/login the desktop. Re-test.

**Expected:** Pairing remains active across app restart and logout/login. Pairing token is stored under `~/.config/Claude/` (or wherever the secure store lives) and survives.

**Diagnostics on failure:** `ls -la ~/.config/Claude/`, secret-store inspection, launcher log, pairing-flow IPC.

**References:** [Sessions from Dispatch](https://code.claude.com/docs/en/desktop#sessions-from-dispatch)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:511984` —
  `ZEe = "coworkTrustedDeviceToken"` electron-store key for the
  trusted-device token.
- `build-reference/app-extracted/.vite/build/index.js:511989` —
  `oYn()` writes the token via `safeStorage.encryptString` (libsecret
  on Linux); `aYn()` (`:512003`) decrypts on read.
- `build-reference/app-extracted/.vite/build/index.js:512022` —
  `gYn()` re-enrolls via `POST /api/auth/trusted_devices` only when
  there's no cached token, so a successful pair survives restart.
- `build-reference/app-extracted/.vite/build/index.js:330229` —
  `_5r = "bridge-state.json"` (per-org/account bridge state under
  `~/.config/Claude/bridge-state.json`); `JF()`/`X0A()` at `:330230`
  read/locate it.
