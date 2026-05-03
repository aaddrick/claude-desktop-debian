# Tray & Window Chrome

Tests covering the tray icon, OS-native window decorations, the hybrid in-app topbar (PR #538), and hide-to-tray on close. See [`../matrix.md`](../matrix.md) for status.

## T03 — Tray icon present

**Severity:** Smoke
**Surface:** System tray / SNI
**Applies to:** All rows
**Issues:** —
**Runner:** [`tools/test-harness/src/runners/T03_tray_icon_present.spec.ts`](../../../tools/test-harness/src/runners/T03_tray_icon_present.spec.ts) — registration only (left-click toggle + theme-switch in-place rebuild are v2)

**Steps:**
1. Launch the app. Wait a few seconds.
2. Locate the tray icon in the system tray / status area.
3. Right-click → confirm standard menu (Show, Quit, etc.). Left-click → confirm window toggles.
4. Switch the system theme between light and dark; observe the tray icon update.

**Expected:** Tray icon appears within a few seconds of app launch. Right-click exposes the standard menu. Left-click toggles main window visibility. Theme changes update the icon in place without spawning a duplicate.

**Diagnostics on failure:** `RegisteredStatusNotifierItems` from the SNI watcher (see [runbook](../runbook.md#tray--dbus-state-kde)), the tray daemon process for the DE (Plasma's `plasmashell`, GNOME's `gnome-shell` + AppIndicator extension state, etc.), launcher log.

**References:** [`docs/learnings/tray-rebuild-race.md`](../../learnings/tray-rebuild-race.md)
**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:525627` (`vy.on("menuBarEnabled", () => { Sde() })` — re-entry), `index.js:525631-525673` (`function Sde()` — tray construction), `index.js:525645` (`new hA.Tray(hA.nativeImage.createFromPath(t))`), `index.js:525646` (`qh.on("click", () => void Yri())` — left-click handler), `index.js:525653` (`qh.setContextMenu(mnt())` — Linux right-click via context menu), `index.js:515150-515169` (`function mnt()` — Show App + Quit menu items), `index.js:525623` (`hA.nativeTheme.on("updated", ...)` — theme-change re-entry).

## T04 — Window decorations draw

**Severity:** Smoke
**Surface:** Window chrome
**Applies to:** All rows
**Issues:** [PR #127](https://github.com/aaddrick/claude-desktop-debian/pull/127), [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)
**Runner:** [`tools/test-harness/src/runners/T04_window_decorations.spec.ts`](../../../tools/test-harness/src/runners/T04_window_decorations.spec.ts) — X11 / XWayland only (checks `_NET_FRAME_EXTENTS`); native-Wayland window-state queries are deferred

**Steps:**
1. Launch the app.
2. Confirm window has a working OS-native frame: close, minimize, maximize render and respond.
3. Resize via window edges.

**Expected:** Frame is drawn by the DE/compositor (not the app). All controls render and respond. Resize works.

**Diagnostics on failure:** `xprop _NET_WM_WINDOW_TYPE` (X11) / `swaymsg -t get_tree` or compositor-equivalent (Wayland), launcher log line for `frame:` setting, screenshot.

**References:** [PR #127](https://github.com/aaddrick/claude-desktop-debian/pull/127), [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538) (hybrid mode keeps native frame), [`docs/learnings/linux-topbar-shim.md`](../../learnings/linux-topbar-shim.md)
**Code anchors:** Upstream factory passes `titleBarStyle: "hidden"` and `titleBarOverlay: ys` (Windows-only flag) to `BrowserWindow` at `build-reference/app-extracted/.vite/build/index.js:524892-524909` (`Ori()`). On Linux the wrapper at `scripts/frame-fix-wrapper.js:122` overrides to `options.frame = true` and at `scripts/frame-fix-wrapper.js:129-130` deletes the macOS-only `titleBarStyle` / `titleBarOverlay` so the DE draws the frame. (Hybrid-mode plumbing — `CLAUDE_TITLEBAR_STYLE` resolution and the `native`/`hybrid`/`hidden` branches — lives on `main` per PR #538; the docs/compat-matrix branch's `frame-fix-wrapper.js` carries only the unconditional `frame:true` patch, which is sufficient for T04's "frame draws" assertion.)

## T07 — In-app topbar renders + clickable

**Severity:** Smoke
**Surface:** In-app topbar (hybrid mode)
**Applies to:** All rows on PR #538 builds
**Issues:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538), [PR #127](https://github.com/aaddrick/claude-desktop-debian/pull/127)

**Steps:**
1. Launch a PR #538 build.
2. Observe the in-app topbar below the OS frame.
3. Click each of: hamburger menu, sidebar toggle, search, back, forward, Cowork ghost.

**Expected:** All five topbar buttons render below the native frame. Each responds to mouse clicks (no implicit drag region capturing the events). If any single button fails to render or click, the test is `✗` — note which one in the linked issue.

**Diagnostics on failure:** Screenshot, env (`OZONE_PLATFORM`, `ELECTRON_OZONE_PLATFORM_HINT`, `GDK_BACKEND`, `QT_QPA_PLATFORM`, `MOZ_ENABLE_WAYLAND`, `SDL_VIDEODRIVER`), launcher log, DevTools `document.querySelector('.topbar')` HTML if accessible.

**References:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538), [PR #127](https://github.com/aaddrick/claude-desktop-debian/pull/127), [`docs/learnings/linux-topbar-shim.md`](../../learnings/linux-topbar-shim.md)
**Code anchors:** UA-spoof shim source `scripts/wco-shim.js` (lines 1-30 module guard / `CLAUDE_TITLEBAR_STYLE != 'native'` gate, lines 184-191 `navigator.userAgent` redefinition matching `/(win32|win64|windows|wince)/i`, lines 52-53 `CONTROLS_WIDTH=140` / `TITLEBAR_HEIGHT=40`); injection orchestrator `scripts/patches/wco-shim.sh` (`patch_wco_shim()` prepends shim source to `mainView.js`); hybrid-mode wrapper branch `scripts/frame-fix-wrapper.js:62-70` (`VALID_TITLEBAR_STYLES`, default `hybrid`) and `:152-240` (per-mode `frame` / `titleBarStyle` handling).

## T08 — Hide-to-tray on close

**Severity:** Smoke
**Surface:** Window lifecycle
**Applies to:** All rows
**Issues:** [PR #451](https://github.com/aaddrick/claude-desktop-debian/pull/451)

**Steps:**
1. Launch the app. Click the window close (X) button.
2. Confirm app process is still running (`pgrep -af claude-desktop`).
3. Click the tray icon (or invoke Quick Entry) → window restores.
4. Quit explicitly via tray menu or `Ctrl+Q`.

**Expected:** Close button hides main window to tray, doesn't quit. App keeps running. Tray-click restores. Explicit Quit ends the process.

**Diagnostics on failure:** `pgrep -af claude-desktop` after close, launcher log, screenshot of any dialog.

**References:** [PR #451](https://github.com/aaddrick/claude-desktop-debian/pull/451)
**Code anchors:** Upstream Linux quit-on-last-close at `build-reference/app-extracted/.vite/build/index.js:525550-525552` (`hA.app.on("window-all-closed", () => { Zr || Ap() })` — `Zr` is darwin). Wrapper interception at `scripts/frame-fix-wrapper.js:178-185` (`this.on('close', e => { if (!result.app._quittingIntentionally && !this.isDestroyed()) { e.preventDefault(); this.hide() } })`) and `scripts/frame-fix-wrapper.js:370-374` (`app.on('before-quit', () => { app._quittingIntentionally = true })` — arms the bypass for tray-Quit / `Ctrl+Q` / SIGTERM). `CLOSE_TO_TRAY` gate (Linux + `CLAUDE_QUIT_ON_CLOSE !== '1'`) at `scripts/frame-fix-wrapper.js:49-51`. Tray Quit menu item `mnt()` `click: rde` at `index.js:515166`; `function rde()` at `index.js:515306-515308` calls `Ap(!1)`.

## S08 — Tray icon doesn't duplicate after `nativeTheme` update

**Severity:** Should
**Surface:** Tray (KDE)
**Applies to:** KDE-W, KDE-X
**Issues:** [`docs/learnings/tray-rebuild-race.md`](../../learnings/tray-rebuild-race.md)

**Steps:**
1. Launch the app on KDE.
2. Toggle system theme (light ↔ dark).
3. Observe the tray for ~10 seconds.

**Expected:** Tray icon updates in place via `setImage` + `setContextMenu`. SNI service stays registered — no de-register / re-register churn that would leave a duplicate icon visible until KDE garbage-collects.

**Diagnostics on failure:** SNI watcher state before/after theme switch (see [runbook](../runbook.md#tray--dbus-state-kde)), launcher log, `journalctl --user -u plasma-plasmashell -n 50`.

**References:** [`docs/learnings/tray-rebuild-race.md`](../../learnings/tray-rebuild-race.md). Mitigated upstream — the in-place fast-path is the current behavior.
**Code anchors:** Upstream destroy+recreate slow-path at `build-reference/app-extracted/.vite/build/index.js:525643` (`qh && (qh.destroy(), (qh = null))`) followed immediately by `new hA.Tray(...)` at `:525645` and `setContextMenu(mnt())` at `:525653` — the SNI re-register that races on KDE. Fast-path injection in `scripts/patches/tray.sh` `patch_tray_inplace_update()` (lines 95-231): extracts `tray_var` / `menu_func` / `path_var` / `enabled_var` dynamically, then injects `if (TRAY && ENABLED !== false) { TRAY.setImage(EL.nativeImage.createFromPath(PATH)); process.platform !== "darwin" && TRAY.setContextMenu(MENU()); return }` before the destroy block. Idempotency marker at `tray.sh:174-180` keys on the post-rename `setImage(...nativeImage.createFromPath(PATH_VAR))` literal. Mutex + 250 ms DBus settle delay (the prior mitigation, kept for the legitimate slow-path entries) at `tray.sh:48-60`.

## S13 — Hybrid topbar shim survives Omarchy's Ozone-Wayland env exports

**Severity:** Critical (for Omarchy users)
**Surface:** In-app topbar (hybrid mode) under Omarchy env
**Applies to:** Hypr-O
**Issues:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)

**Steps:**
1. On OmarchyOS, export Omarchy's session-wide env (`ELECTRON_OZONE_PLATFORM_HINT=wayland`, `OZONE_PLATFORM=wayland`, `GDK_BACKEND=wayland,x11,*`, `QT_QPA_PLATFORM=wayland;xcb`, `MOZ_ENABLE_WAYLAND=1`, `SDL_VIDEODRIVER=wayland,x11`).
2. Launch a PR #538 build.
3. Click each of the five topbar buttons.

**Expected:** The hybrid-mode topbar shim (`scripts/wco-shim.js`) loads in time to spoof the UA before claude.ai's `isWindows()` check fires. All five topbar buttons render and click.

**Diagnostics on failure:** Full session env, launcher log, `--doctor`, screenshot, video (per @lukedev45's bug report on PR #538), DevTools console for shim-load errors.

**Currently:** Reproduces partial render on OmarchyOS Hyprland per [@lukedev45](https://github.com/lukedev45)'s video on [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538). @aaddrick attempted local repro on KDE Plasma + Wayland with the same env vars and could not reproduce; root cause TBD pending diagnostic capture from a broken run.

**References:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538), [`docs/learnings/linux-topbar-shim.md`](../../learnings/linux-topbar-shim.md)
**Code anchors:** Shim is inlined at the top of `mainView.js` (the BrowserView preload), not loaded via `require` — see the rationale at `scripts/patches/wco-shim.sh:23-40` ("Sandboxed preloads can only require a fixed allowlist of modules…"). The injection prepends `scripts/wco-shim.js` source at the start of `app.asar.contents/.vite/build/mainView.js` so the UA override fires before the bundle's `isWindows()` regex (`/(win32|win64|windows|wince)/i`) ever runs in the page main world (`scripts/wco-shim.js:184-191`). The shim's IIFE no-ops on non-Linux at `wco-shim.js:29` and on `CLAUDE_TITLEBAR_STYLE === 'native'` at `wco-shim.js:30-32`, so the only env-export interaction with `OZONE_PLATFORM` etc. is via Chromium's own platform plumbing — none of those exports are read by the shim itself, which makes the partial-render repro on Omarchy mysterious to static analysis.
