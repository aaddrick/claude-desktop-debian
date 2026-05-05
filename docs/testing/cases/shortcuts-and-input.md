# Shortcuts & Input

Tests covering URL handling, the Quick Entry global shortcut, and DE-specific shortcut/input failure modes. See [`../matrix.md`](../matrix.md) for status.

## T05 — `claude://` URL handler opens links in-app

**Severity:** Smoke
**Surface:** URL handler / xdg-open
**Applies to:** All rows
**Issues:** —

**Steps:**
1. With Claude Desktop running, in another app run `xdg-open 'claude://chat/new?q=hello'` (or click a `claude://` link in a browser/terminal).
2. Observe.

**Expected:** Link is delivered to the running Claude Desktop process — no new browser tab, no crash, no error dialog. (Upstream's `claudeURLHandler` only accepts the `claude:`, `claude-dev:`, `claude-nest:`, `claude-nest-dev:`, `claude-nest-prod:` schemes; bare `https://claude.ai/...` clicks route through the user's default browser, not Claude Desktop. The `.desktop` file registers `MimeType=x-scheme-handler/claude` only, matching the upstream contract.)

**Diagnostics on failure:** `xdg-mime query default x-scheme-handler/claude`, the registered `.desktop` file content, launcher log, app crash report (if any), `coredumpctl list claude-desktop` (if subprocess died — see [S06](#s06--url-handler-doesnt-segfault-on-native-wayland)).

**References:** upstream `index.js:495996-496009` (`bEe()` protocol filter), `index.js:524819` (`setAsDefaultProtocolClient("claude")`), `index.js:525140-525148` (macOS `open-url`), `index.js:525162-525172` (Linux/Win `second-instance` argv path), project `scripts/packaging/{deb,rpm,appimage}.sh` (MimeType registration).
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:495996, 524819, 525140, 525162

## T06 — Quick Entry global shortcut (unfocused)

**Severity:** Critical
**Surface:** Global shortcut / Electron globalShortcut
**Applies to:** All rows
**Issues:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406), [PR #102](https://github.com/aaddrick/claude-desktop-debian/pull/102), [PR #153](https://github.com/aaddrick/claude-desktop-debian/pull/153)

**Steps:**
1. Launch app, focus another application (browser, terminal).
2. Press the configured Quick Entry shortcut (default `Ctrl+Alt+Space`).
3. Type a prompt and submit.
4. Repeat from a different virtual desktop / workspace.

**Expected:** Quick Entry prompt opens regardless of focused app or workspace. Shortcut is globally registered, not focus-bound. Submitting creates a new session and shows it in the main window.

**Diagnostics on failure:** Launcher log (look for `Using X11 backend via XWayland (for global hotkey support)` or portal-shortcut markers), `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, output of `gdbus call --session --dest=org.freedesktop.portal.Desktop --object-path=/org/freedesktop/portal/desktop --method=org.freedesktop.DBus.Introspectable.Introspect`, the active patch set in `scripts/patches/`.

**References:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406)
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:499376 (`ort` default accelerator: `"Ctrl+Alt+Space"` non-mac, `"Alt+Space"` on mac), 499416 (`globalShortcut.register`), 525287-525290 (Quick Entry trigger callback registered against `Pw.QUICK_ENTRY`).

## S06 — URL handler doesn't segfault on native Wayland

**Severity:** Critical (for wlroots rows)
**Surface:** URL handler subprocess
**Applies to:** Sway, Niri, Hypr-O, Hypr-N (any native-Wayland session)
**Issues:** —

**Steps:**
1. Launch the app on a native Wayland session (no XWayland forcing).
2. From another app, click a `claude.ai` link or run `xdg-open https://claude.ai/...`.

**Expected:** Link opens in-app cleanly. No `Failed to connect to Wayland display` errors followed by a SIGSEGV from the URL handler subprocess.

**Diagnostics on failure:** `coredumpctl info claude-desktop`, `WAYLAND_DISPLAY` env in the subprocess (if capturable via `strace -f -e execve`), launcher log, full env dump.

**Currently:** Sway capture shows `Failed to connect to Wayland display: No such file or directory (2)` followed by `Segmentation fault` from the URL handler subprocess. The main app process keeps running; the URL handler dies. Not yet filed.

**References:** —
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:495996 (`bEe()` URL handler), 525140-525148 (`open-url` macOS), 525162-525172 (`second-instance` argv path on Linux); project `scripts/launcher-common.sh:96-99` (`--ozone-platform=x11` default), `scripts/launcher-common.sh:41-44` (Niri force-native-Wayland).

## S07 — `CLAUDE_USE_WAYLAND=1` opt-in path works without crashing

**Severity:** Should
**Surface:** Native Wayland mode
**Applies to:** Sway, Niri, Hypr-O, Hypr-N
**Issues:** [PR #228](https://github.com/aaddrick/claude-desktop-debian/pull/228), [PR #232](https://github.com/aaddrick/claude-desktop-debian/pull/232)

**Steps:**
1. Set `CLAUDE_USE_WAYLAND=1`. Launch the app.
2. Use the app for ~5 minutes — open chats, switch tabs, exercise basic flows.

**Expected:** App forces native Wayland (no XWayland), continues to render and respond. Previously broken paths in PR #228 still hold.

**Diagnostics on failure:** Launcher log (confirm Wayland mode active), `--doctor`, full env dump, screenshot of any crash dialog.

**References:** [PR #228](https://github.com/aaddrick/claude-desktop-debian/pull/228), [PR #232](https://github.com/aaddrick/claude-desktop-debian/pull/232)
**Code anchors:** project `scripts/launcher-common.sh:28-29` (`CLAUDE_USE_WAYLAND=1` opt-out of XWayland), 100-111 (native-Wayland Electron flags: `UseOzonePlatform,WaylandWindowDecorations`, `--ozone-platform=wayland`, `--enable-wayland-ime`, `--wayland-text-input-version=3`, `GDK_BACKEND=wayland`).

## S09 — Quick window patch runs only on KDE (post-#406 gate)

**Severity:** Critical
**Surface:** Patch gate
**Applies to:** All rows (verifies the gate, not the feature)
**Issues:** [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406), [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393)

**Steps:**
1. On a KDE row, launch the app. Inspect launcher log for quick-window-patch markers.
2. On a non-KDE row, launch the app. Inspect launcher log — the markers should be absent.

**Expected:** On KDE sessions the quick-window patch is applied (Quick Entry uses the patched code path). On non-KDE sessions the patch is **not** applied, preventing the [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393) regression on GNOME etc.

**Diagnostics on failure:** Launcher log, `XDG_CURRENT_DESKTOP`, the patch-gate code path in `scripts/patches/`.

**References:** [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406), [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393)
**Code anchors:** project `scripts/patches/quick-window.sh:32-42` (KDE-gated `blur()` insertion), 115-125 (KDE-gated focus/visibility check replacement); upstream sites the patch rewrites are around `index.js:515374-515471` (Quick Entry popup construction + handlers).

## S10 — Quick Entry popup is transparent (no opaque square frame)

**Severity:** Should
**Surface:** Quick Entry window (KDE Wayland)
**Applies to:** KDE-W
**Issues:** [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370), [#223](https://github.com/aaddrick/claude-desktop-debian/issues/223), [PR #244](https://github.com/aaddrick/claude-desktop-debian/pull/244)

**Steps:**
1. On KDE Plasma Wayland, invoke Quick Entry.
2. Observe the popup background.

**Expected:** Quick Entry popup renders with a transparent background — no opaque square frame visible behind the rounded prompt UI.

**Diagnostics on failure:** Screenshot, KDE compositor settings (`kwriteconfig5 --read kwinrc Compositing/Backend`), launcher log, BrowserWindow construction args.

**References:** [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370) (current open report), [#223](https://github.com/aaddrick/claude-desktop-debian/issues/223) (closed predecessor), [PR #244](https://github.com/aaddrick/claude-desktop-debian/pull/244)
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515380 (`transparent: !0`), 515383 (`backgroundColor: "#00000000"`), 515381 (`frame: !1`), 515377 (`skipTaskbar: !0`).

## S11 — Quick Entry shortcut fires from any focus on Wayland (mutter XWayland key-grab)

**Severity:** Critical (for GNOME users)
**Surface:** Global shortcut on GNOME mutter
**Applies to:** GNOME, Ubu
**Issues:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406)

**Steps:**
1. On GNOME/mutter Wayland, launch the app.
2. Focus another application; press the Quick Entry shortcut.
3. Repeat from another virtual desktop.

**Expected:** Shortcut fires regardless of focused app or workspace.

**Diagnostics on failure:** Launcher log (note `Using X11 backend via XWayland (for global hotkey support)`), `XDG_CURRENT_DESKTOP`, mutter version (`gnome-shell --version`), the active patch set.

**Currently:** Fedora 43 GNOME Wayland reproduces [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404) — mutter doesn't honour the XWayland-side key grab, so the shortcut is focus-bound. On Ubuntu 24.04 GNOME, the [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406) KDE-only gate prevents the regressing patch from running, leaving the older (working) code path active — hence `🔧` on Ubu. The unsolved fix path is [S12](#s12----enable-featuresglobalshortcutsportal-launcher-flag-wired-up-for-gnome-wayland).

**References:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406)
**Code anchors:** project `scripts/launcher-common.sh:96-99` (XWayland-default `--ozone-platform=x11`); upstream `index.js:499416` (`globalShortcut.register`).

## S12 — `--enable-features=GlobalShortcutsPortal` launcher flag wired up for GNOME Wayland

**Severity:** Critical
**Surface:** Launcher flag wiring
**Applies to:** GNOME, Ubu (any GNOME Wayland)
**Issues:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404)

**Steps:**
1. On GNOME Wayland, launch the app.
2. Inspect the Electron command line via `pgrep -af claude-desktop` — look for `--enable-features=GlobalShortcutsPortal`.
3. Test Quick Entry shortcut from unfocused state (see [T06](#t06--quick-entry-global-shortcut-unfocused)).

**Expected:** Launcher detects GNOME Wayland and appends `--enable-features=GlobalShortcutsPortal` to Electron's argv, routing global shortcuts through XDG Desktop Portal instead of X11 key grabs. Once wired, [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404) is closeable.

**Diagnostics on failure:** Full process argv (`cat /proc/$(pgrep -f electron)/cmdline | tr '\0' ' '`), launcher log, `XDG_CURRENT_DESKTOP`.

**Currently:** Not yet implemented. Tracking under [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404).

> **⚠ Missing in build 1.5354.0** — `--enable-features=GlobalShortcutsPortal` is not appended by `scripts/launcher-common.sh` for any GNOME Wayland variant. Re-verify after next upstream bump and after #404 lands.

**References:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404)
**Code anchors:** project `scripts/launcher-common.sh:59-112` (`build_electron_args` — no `GlobalShortcutsPortal` branch present).

## S14 — Global shortcuts via XDG portal work on Niri

**Severity:** Critical (for Niri users)
**Surface:** XDG Desktop Portal `BindShortcuts`
**Applies to:** Niri
**Issues:** —

**Steps:**
1. On Niri, launch the app (the launcher special-cases Niri to native Wayland + portal).
2. Configure the Quick Entry shortcut.
3. Observe portal interaction in launcher log.

**Expected:** `BindShortcuts` succeeds. Configured Quick Entry shortcut is registered and fires.

**Diagnostics on failure:** Launcher log capture of the `BindShortcuts` call, `busctl --user tree org.freedesktop.portal.Desktop`, Niri version, full env.

**Currently:** `Failed to call BindShortcuts (error code 5)` — portal global shortcuts fail on Niri. Different root cause from [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), same user-visible symptom (Quick Entry shortcut doesn't fire). Not yet filed.

**References:** —
**Code anchors:** project `scripts/launcher-common.sh:41-44` (Niri force-native-Wayland branch); upstream `index.js:499416` (`globalShortcut.register`, which on native Wayland routes through Electron's `xdg-desktop-portal` `BindShortcuts` path inside Chromium).

## S29 — Quick Entry popup is created lazily on first shortcut press (closed-to-tray sanity)

**Severity:** Critical
**Surface:** Quick Entry popup lifecycle
**Applies to:** All rows
**Issues:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393)

**Steps:**
1. Launch app, wait for main window to appear, hide-to-tray (close via X — see [T08](./tray-and-window-chrome.md#t08--hide-to-tray-on-close)).
2. Confirm no Claude window is mapped (e.g. `wmctrl -l | grep -i claude` returns empty on X11; `swaymsg -t get_tree` for Wayland equivalents).
3. Press the Quick Entry shortcut.
4. Type `hello`, press Enter.

**Expected:** Popup appears even though no Claude window was mapped before the keypress. Upstream constructs the popup `BrowserWindow` lazily on first shortcut invocation (`if (!Ko || ...) Ko = new BrowserWindow(...)` near `index.js:515375`), so the popup does not need a pre-existing main window. New chat session is created and reachable on submit.

**Diagnostics on failure:** Launcher log, `~/.config/Claude/logs/`, `XDG_CURRENT_DESKTOP`, screenshot of empty desktop after shortcut press.

**References:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393), upstream `index.js:515375-515397`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515374 (`if (!Ko ...) Ko = new BrowserWindow(...)` lazy construction guard), 515394 (`preload: ".vite/build/quickWindow.js"`), 515438 (`Ko.loadFile(".vite/renderer/quick_window/quick-window.html")`).

## S30 — Quick Entry shortcut becomes a no-op after full app exit

**Severity:** Should
**Surface:** Global shortcut unregistration
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Launch app. Confirm Quick Entry shortcut works (popup opens).
2. Quit Claude Desktop fully via tray → Quit (or `pkill -f app.asar`). Confirm no `electron` processes for the app remain.
3. Press the Quick Entry shortcut.

**Expected:** No popup appears. No error dialog. No zombie process. Electron unregisters the global shortcut on app exit; the shortcut becomes a system-level no-op.

**Diagnostics on failure:** `pgrep -af app.asar` output, `journalctl --user -e -n 100`, OS-level shortcut bindings (`gsettings list-recursively | grep -i shortcut`).

**References:** upstream `index.js:499416` (registration site)
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:499398-499428 (`nG()` register/unregister wrapper — passing `null` accelerator unregisters), 499416 (`hA.globalShortcut.register`), 499403 (`hA.globalShortcut.unregister`).

## S31 — Quick Entry submit makes the new chat reachable from any main-window state

**Severity:** Critical
**Surface:** Submit → main window show
**Applies to:** All rows
**Issues:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406)

**Steps:**
1. For each main-window state: (a) visible-and-focused, (b) minimized, (c) hidden-to-tray, (d) on a different workspace, (e) closed via X (project's hide-to-tray override).
2. Set the state, then invoke Quick Entry, type `hello`, submit.
3. Record what happens to the main window: auto-restored, requires tray click, came to current workspace, stayed on its own workspace.

**Expected:** The new chat session is **reachable** from each starting state. Acceptance is "user can reach the new chat" — not "main window auto-restored." Upstream calls `mainWin.show()` + `mainWin.focus()` only (`index.js:515566, 515599`), with no `restore()`, no `setVisibleOnAllWorkspaces()`, no `moveTop()`. Whether `show()` un-minimizes or migrates workspaces is purely compositor-dependent. The failure case is "new chat created but the user has no way to surface it" — that's a regression. Anything that reaches the chat (even via a tray click) is upstream-acceptable.

**Diagnostics on failure:** `~/.config/Claude/logs/`, screenshot at each state, output of `wmctrl -l` (X11) or `swaymsg -t get_tree` (sway), launcher log.

**Currently:** On non-KDE rows, the post-#406 KDE-only patch gate leaves the upstream code path (`isFocused()` short-circuit) active. Andrej730's #393 GNOME repro shows the stale-`isFocused()` bug can still suppress `show()` in tray-only state. See [S32](#s32--quick-entry-submit-on-gnome-mutter-doesnt-trip-electron-stale-isfocused).

**References:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393), upstream `index.js:515566, 515599, 105164-171`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515567 (`h1() || ut.show(), ut.focus()` in `gHn()` existing-chat path), 515598-515599 (`h1() || ut.show(), ut.focus()` in `ynt()` new-chat path), 105164-105171 (`h1()` returns `ut.isFocused() || mainView.webContents.isFocused()`).

## S32 — Quick Entry submit on GNOME mutter doesn't trip Electron stale-`isFocused()`

**Severity:** Critical (for GNOME users)
**Surface:** Electron `BrowserWindow.isFocused()` on Linux
**Applies to:** GNOME, Ubu
**Issues:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393)

**Steps:**
1. On GNOME Wayland, launch the app, then close to tray.
2. Confirm the app is in tray-only state (no window mapped, no Dash entry, no taskbar entry).
3. Invoke Quick Entry, type `hello`, submit.
4. Repeat after re-pinning the app to the Dash and reproducing the tray-only state from there.

**Expected:** Submit produces a reachable new chat session in both Dash-pinned and not-pinned cases. **The Dash distinction is empirical, not code-driven** — upstream has no notion of Dash presence. The underlying failure mode is Electron's `BrowserWindow.isFocused()` returning stale-true on Linux mutter, which causes upstream's `h1() || ut.show()` short-circuit (`index.js:515566`) to skip `show()`. Andrej730 traced this on #393.

**Diagnostics on failure:** Bundled `index.js` h1() body (extract via `npx asar extract`); add temporary logging in `h1()` per Andrej730's diff in #393 if reproducing locally; `gnome-shell --version`; `~/.config/Claude/logs/`.

**Currently:** Open. The KDE-only gate from PR #406 leaves this path unfixed on GNOME. Resolution requires either (a) widening the patch to all DEs by dropping the `isFocused()` fallback in the patched code, or (b) waiting for an upstream Electron fix to `isFocused()` on Linux.

**References:** [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393) (Andrej730's diagnosis with `eU()` logging output)
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:105164-105171 (`h1()` body — the exact short-circuit Andrej730 instrumented), 515567 + 515598 (the two `h1() || ut.show()` call sites the suppression hits).

## S33 — Quick Entry transparent rendering tracked against bundled Electron version

**Severity:** Should
**Surface:** Bundled Electron version
**Applies to:** All rows (relevant where #370 reproduces)
**Issues:** [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370)

**Steps:**
1. After install, capture the Electron version bundled with the app: extract `app.asar.unpacked` and run the bundled Electron with `--version`, or read it from the bundled binary's metadata.
2. Record the version in [`../matrix.md`](../matrix.md) per row, alongside the [S10](#s10--quick-entry-popup-is-transparent-no-opaque-square-frame) status.

**Expected:** Captured version is recorded. If the version is **41.0.4 through 41.x.y** and S10 fails, the upstream electron/electron#50213 regression hypothesis (per @noctuum's bisect on #370) holds and the issue is blocked on upstream. If the version is **41.0.3 or earlier** and S10 fails, the bisect is wrong — investigate. If the version is **a later release that includes a CSD-rendering fix** and S10 still fails, the upstream-regression hypothesis is also wrong.

**Diagnostics on failure:** Output of the version capture command, link to electron/electron#50213, the BrowserWindow construction args from the bundled `index.js`.

**Currently:** Per @noctuum's bisect, 41.0.4 introduced the regression. No upstream fix shipped as of last check.

**References:** [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370), upstream `index.js:515380, 515383` (already sets `transparent: true` and `backgroundColor: "#00000000"`)
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515380 (`transparent: !0`), 515383 (`backgroundColor: "#00000000"`), 515374-515397 (popup `BrowserWindow` construction args block, including `frame: !1`, `hasShadow: Zr`, `type: Zr ? "panel" : void 0`).

## S34 — Quick Entry shortcut focuses fullscreen main window instead of showing popup

**Severity:** Should
**Surface:** Shortcut behavior on fullscreen main
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Launch app. Put the main window into native fullscreen (F11 or platform equivalent).
2. Press the Quick Entry shortcut.

**Expected:** Popup does **not** appear. Main window receives focus and `ide()` runs (upstream behavior at `index.js:525287-525290`). This is intentional upstream UX — assumes the user wants to interact with the existing fullscreen Claude rather than overlay a popup on it.

**Diagnostics on failure:** Screenshot, launcher log, confirm fullscreen state via `wmctrl -l -G` / Wayland equivalent.

**References:** upstream `index.js:525287-525290`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:525287-525290 (Quick Entry callback: `ut && !ut.isDestroyed() && ut.isFullScreen() ? (ut.focus(), ide()) : Yri()`), 515234-515241 (`ide()` — `show()` + `focus()` + `webContents.send(TEe.cmdK)` for the cmd-K dispatch).

## S35 — Quick Entry popup position is persisted across invocations and across app restarts

**Severity:** Should
**Surface:** Popup placement memory
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Launch app. Invoke Quick Entry. Note the popup position (record monitor + coordinates if possible — e.g. `xdotool getactivewindow getwindowgeometry` on X11).
2. Dismiss (Esc). Re-invoke. Position should be unchanged across this dismiss/re-invoke cycle.
3. Quit Claude Desktop fully (`pkill -f app.asar`). Re-launch. Invoke Quick Entry.
4. Confirm position matches the pre-restart capture.

**Expected:** Popup reappears at the same monitor + position before and after a full app restart. Upstream persists position via `an.get("quickWindowPosition")` (`index.js:515491-515526`), keyed on monitor label + resolution.

**Diagnostics on failure:** Captured coordinates pre/post-restart, content of any persisted settings file (project's settings storage location varies by OS).

**References:** upstream `index.js:515491-515526`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515444-515461 (`Ko.on("hide", …)` persists `quickWindowPosition` via `an.set(...)`), 515491-515521 (`aHn()` resolves saved monitor by `label + bounds.width + bounds.height`, falling back to label-only or proportional placement), 515489 (`Ko.setPosition(...)` after show).

## S36 — Quick Entry popup falls back to primary display when saved monitor is gone

**Severity:** Smoke
**Surface:** Multi-monitor placement
**Applies to:** All rows with a multi-monitor capable host
**Issues:** —

**Steps:**
1. **Multi-monitor required.** With an external monitor connected, invoke Quick Entry on the external monitor. Trigger position persistence (per [S35](#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts)).
2. Disconnect the external monitor (libvirt: detach the second display device; bare metal: unplug).
3. Invoke Quick Entry.

**Expected:** Popup appears on the primary display, not at off-screen coordinates. Upstream falls back to `cHn()` when the saved monitor is no longer present (`index.js:515502`).

**Diagnostics on failure:** `xrandr` (X11) / `wlr-randr` (wlroots) output before and after disconnect, captured popup coordinates, screenshot.

**Skip when:** Single-monitor VM or host. Skip with `-` in the dashboard.

**References:** upstream `index.js:515502`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515502 (`return cHn();` early-return when no saved position), 515523-515527 (`cHn()` centres popup on `screen.getPrimaryDisplay()` workArea), 515514-515515 (`label`-only match fallback before primary-display fallback).

## S37 — Quick Entry popup remains functional after main window destroy

**Severity:** Should
**Surface:** Popup lifecycle independence from main window
**Applies to:** All rows (where reachable)
**Issues:** —

**Steps:**
1. Launch app, focus main window.
2. **Trigger main window destroy without quitting the app.** On this project, the X-button hide-to-tray override means the standard close path does **not** destroy `ut`. Reach the destroy path via one of:
   - DevTools console on the main window: `require('electron').remote.getCurrentWindow().destroy()` (if `remote` is exposed; not guaranteed).
   - A debug build with the hide-to-tray override removed.
   - Skip and mark `-` if unreachable.
3. After destroy: invoke Quick Entry, type `hello`, submit.

**Expected:** Popup appears and accepts input. Upstream's `!ut || ut.isDestroyed()` guard at `index.js:515595` skips the show/focus block without crashing. The new chat is created in the data layer; whether it has a window to surface in is a separate question (upstream contract is "popup itself does not crash").

**Diagnostics on failure:** Crash dump, `~/.config/Claude/logs/`, sequence of actions taken to reach the destroy path.

**Currently:** Likely unreachable on Linux without a debug build, due to project's hide-to-tray override of the X button. Mark `-` (N/A) on rows where the destroy path can't be triggered.

**References:** upstream `index.js:515595`
**Code anchors:** build-reference/app-extracted/.vite/build/index.js:515595-515602 (`setTimeout(() => { !ut || ut.isDestroyed() || (h1() || ut.show(), ut.focus(), Qe == null || Qe.webContents.focus(), iri()); }, 0)` — guard skips show/focus block on destroy without throwing); 515547 (companion guard in `nde()` chat-id submit path: `else if (ut && !ut.isDestroyed())`).
