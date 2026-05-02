# Quick Entry Closeout — Test Plan

Focused sweep plan for closing the three open Quick Entry issues:

- [#393](https://github.com/aaddrick/claude-desktop-debian/issues/393) — Submit doesn't open the main window (Ubuntu 24.04 GNOME and friends). Mitigated by [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406)'s KDE-only gate; root cause is `BrowserWindow.isFocused()` returning stale-true on Linux Electron.
- [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404) — Shortcut doesn't fire from unfocused state on Fedora 43 GNOME. mutter no longer honours XWayland-side key grabs. Fix path: wire `--enable-features=GlobalShortcutsPortal` into the launcher on GNOME Wayland.
- [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370) — Opaque square frame behind the transparent Quick Entry popup on KDE Wayland. Bisected to Electron 41.0.4 (electron/electron#50213); upstream regression. Workarounds in `frame-fix-wrapper.js` not yet attempted.

This doc is a **sweep plan**, not a test catalog. Test bodies and diagnostics live in [`cases/`](./cases/); the live status dashboard lives in [`matrix.md`](./matrix.md). The 21 `QE-*` items below map to existing `T*` / `S*` IDs where possible, and call out gaps to add as new `S*` cases.

## Goal

Pass all `QE-*` items in [§ Test list](#test-list) on every row in [§ Mandatory matrix](#mandatory-matrix). When that holds, all three issues are closeable (or, for #370, demonstrably blocked on upstream Electron with reproducible evidence).

## Upstream design intent

Read this before reading the test list. Several `QE-*` rows test things upstream does not actually promise — those tests are still valuable as black-box behavior checks, but the calibration of "expected" matters.

Source for everything below: `build-reference/app-extracted/.vite/build/index.js`. Symbol names (`h1`, `ut`, `Ko`, `ynt`, `nde`, `g3A`, `u7A`) drift between releases — anchor on shape, not name.

### What upstream promises

- **Global shortcut** registered via Electron `globalShortcut.register()` (`:499416`). No app-focus gate — fires regardless of which app is focused.
- **Popup is lazily created** on first shortcut press (`if (!Ko || ...) Ko = new BrowserWindow(...)` near `:515375`). The popup `BrowserWindow` is constructed on demand, not at app startup. This is what makes QE-4 (closed-to-tray) work.
- **Position memory:** popup position persists across invocations via `an.get("quickWindowPosition")` (`:515491-515526`), keyed on monitor label + resolution. If the original monitor is gone, falls back to primary display.
- **Submit always creates a NEW chat session** when no `chatId` is provided (`ynt(e)` at `:515546`). Quick Entry never appends to an existing conversation.
- **Click-outside dismiss** is wired in the main process via the popup `blur` handler (`Ko.on("blur", () => g3A(null))` at `:515465`).
- **Popup survives main-window close.** If the user closes the main window via the X button (not full quit), `!ut || ut.isDestroyed()` guards at `:515595` skip the `show()/focus()` calls; the popup itself remains functional.
- **Window construction** sets `transparent: true`, `backgroundColor: "#00000000"`, `frame: false`, `alwaysOnTop: true` (level `"pop-up-menu"`), `skipTaskbar: true`, `resizable: false`, `show: false` (`:515375-515397`). `hasShadow: Zr` and `type: Zr ? "panel" : void 0` are macOS-only (`Zr === process.platform === "darwin"`).

### What upstream does NOT promise

- **Workspace migration.** No `setVisibleOnAllWorkspaces()`, no `moveTop()`, no `setWorkspace()` is called anywhere in the Quick Entry submit path. Whether the main window comes to the user's current workspace or stays on its own is purely a compositor decision driven by `mainWin.show()` + `mainWin.focus()`. **Linux/Wayland behavior here is not part of the upstream feature spec.**
- **Restore from minimized.** No `restore()` call in the submit path. `show()` un-minimizes on most WMs; whether it does on a given Wayland compositor is up to that compositor.
- **Multi-monitor placement on cursor / focused display.** Upstream uses last-saved position or primary display, never "where the user is right now."
- **Multi-window targeting.** All `show`/`focus` calls go through `ut` (the main window). If the user has multiple windows, behavior is undefined.
- **Popup re-creation if its `BrowserWindow` is destroyed.** Upstream does not re-construct `Ko` after destroy — it's only created on first shortcut press.
- **Compositor-aware behavior.** Upstream has no concept of "GNOME vs KDE vs wlroots." Anywhere our patches branch on `XDG_CURRENT_DESKTOP`, that's our project compensating for compositor-specific Electron breakage, not implementing an upstream-defined contract.

### Edge case: fullscreen main window

`:525287-525290` reads (paraphrased): *"if `ut` exists and `ut.isFullScreen()` is true, focus `ut` and call `ide()`; else show the Quick Entry popup."* So if the main window is fullscreen when the shortcut fires, **the popup does not appear** — the shortcut focuses the main window instead. QE-1 needs this caveat.

### Edge case: `h1()` is a *don't-show-if-already-focused* optimization

The visibility-check function (`h1()` at `:105164-105171`) is upstream's mechanism for "don't redundantly call `show()` if the main window is already focused." Sound design. The reason it's broken on Linux is Electron's `BrowserWindow.isFocused()` returning stale-true after `hide()` on Linux backends — i.e., **the patch we apply is fixing a Linux-Electron bug, not diverging from upstream intent.** Once `isFocused()` returns honest values on Linux, the patch could be retired.

## Test list

Each item is a single check. Severity tier matches the existing scaffolding (Critical / Should / Smoke). Existing test ID in parentheses — `(new)` means this item should be added to [`cases/shortcuts-and-input.md`](./cases/shortcuts-and-input.md) before this sweep is reproducible by anyone else.

### Shortcut activation — covers #404

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-1 | Smoke | App focused (not fullscreen), press shortcut | Popup appears. **Edge case from upstream design:** if main window is fullscreen, the shortcut focuses main and runs `ide()` instead of showing the popup (`:525287-525290`). Test this fullscreen variant separately as QE-1b — popup should *not* appear. | [S34](./cases/shortcuts-and-input.md#s34--quick-entry-shortcut-focuses-fullscreen-main-window-instead-of-showing-popup) (QE-1b only) |
| QE-2 | Critical | Other app focused, press shortcut | Popup appears | [T06](./cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused), [S11](./cases/shortcuts-and-input.md#s11--quick-entry-shortcut-fires-from-any-focus-on-wayland-mutter-xwayland-key-grab) |
| QE-3 | Critical | App on a different workspace, press shortcut | Popup appears on current workspace | [T06](./cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused) |
| QE-4 | Critical | App closed-to-tray (no window mapped), press shortcut | Popup appears | [S29](./cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity) |
| QE-5 | Should | App quit entirely, press shortcut | No popup, no error, no zombie process | [S30](./cases/shortcuts-and-input.md#s30--quick-entry-shortcut-becomes-a-no-op-after-full-app-exit) |
| QE-6 | Should | Inspect Electron argv via `cat /proc/$(pgrep -f 'app\.asar')/cmdline \| tr '\0' ' '` (the launcher script also matches `claude-desktop`, so anchor on `app.asar` to hit the Electron process). Cross-check launcher log line `Using X11 backend via XWayland (for global hotkey support)` vs `Using native Wayland backend (global hotkeys may not work)` (verbatim from `scripts/launcher-common.sh:98, 102`). | **Pre-S12 fix:** flag absent; shortcut fails on GNOME Wayland (this is the #404 repro). **Post-S12 fix:** `--enable-features=GlobalShortcutsPortal` present in argv on GNOME Wayland; QE-2 / QE-3 begin to pass. | [S12](./cases/shortcuts-and-input.md#s12----enable-featuresglobalshortcutsportal-launcher-flag-wired-up-for-gnome-wayland) |

### Submit → main window — covers #393

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-7 | Smoke | Main window visible, submit prompt from QE | Popup closes; main window navigates to a **new** chat session (not appended to current chat — `ynt(e)` at `:515546` always creates new). | [S31](./cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) |
| QE-8 | Critical | Main window minimized, submit | **Upstream calls `show() + focus()` only — no `restore()`.** Whether the WM un-minimizes is compositor-dependent. Test as black-box: record whether the new chat is reachable to the user (window comes back to view, OR user has to click tray/dock to see it). Both outcomes are upstream-acceptable; only "new chat created but unreachable" is a regression. | [S31](./cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) |
| QE-9 | Critical | Main window hidden-to-tray (after [T08](./cases/tray-and-window-chrome.md#t08--hide-to-tray-on-close)), submit | Same as QE-8 — `show()` should re-map a hidden window on most compositors, but upstream doesn't guarantee it. The new chat must be reachable; the path to reach it (auto vs tray-click) is compositor-dependent. | [S31](./cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) |
| QE-10 | Should | Main window on different workspace, submit | **Upstream has no workspace logic** (no `setVisibleOnAllWorkspaces`, no `moveTop`). Outcome is whatever the compositor decides on `show()` + `focus()`. Record observed behavior per row; do not treat any single outcome as the "right" one. | [S31](./cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) |
| QE-11 | Critical | **GNOME-specific (Andrej730 repro):** App in tray, *not* present in Dash/dock, submit | Main window opens. The codebase doesn't reason about Dash presence — this is purely a compositor-observed state. The underlying failure is `BrowserWindow.isFocused()` returning stale-true on GNOME mutter, which causes the patched (KDE) code path's `h1() || ut.show()` chain to short-circuit before `show()`. Test as a black-box repro. | [S32](./cases/shortcuts-and-input.md#s32--quick-entry-submit-on-gnome-mutter-doesnt-trip-electron-stale-isfocused) |
| QE-12 | Should | App in tray, *also* present in Dash/dock, submit | Main window opens (this state should not trip the stale-focus bug, but verify) | [S32](./cases/shortcuts-and-input.md#s32--quick-entry-submit-on-gnome-mutter-doesnt-trip-electron-stale-isfocused) |
| QE-13 | Smoke | Submit prompt with 1-2 chars (`hi`) | Upstream silently drops. The actual gate is `> 2` chars at `index.js:515530, 515533` — anything 3+ submits. So `hi` (2) drops, `hel` (3) submits. Document, do not fix. | — |

### Visual / window appearance — covers #370

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-14 | Should | Inspect popup background | Transparent; no opaque square frame visible behind the rounded UI. **Note:** upstream already sets `transparent: true` and `backgroundColor: "#00000000"` (`:515380, :515383`), so the #370 triage-bot suggestion to "try setting backgroundColor to transparent" is moot — those are already in place. The Electron 41.0.4 regression is at the CSD/shadow rendering layer below those flags, not at the option-passing layer. | [S10](./cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame) |
| QE-15 | Smoke | Inspect popup chrome | No titlebar, no close/min/max buttons (frameless) | [`ui/quick-entry.md`](./ui/quick-entry.md) |
| QE-16 | Smoke | Inspect popup edges | Drop shadow + rounded corners render (compositor-dependent — note where missing) | [`ui/quick-entry.md`](./ui/quick-entry.md) |
| QE-17 | Smoke | Open popup, then click on another window | Popup stays above (always-on-top) | [`ui/quick-entry.md`](./ui/quick-entry.md) |
| QE-18 | Should | `electron --version` against the running app's bundled binary; record version in matrix | When > 41.0.4 ships and #370 still reproduces, the upstream-regression hypothesis is wrong | [S33](./cases/shortcuts-and-input.md#s33--quick-entry-transparent-rendering-tracked-against-bundled-electron-version) |

### Patch-application sanity — regression prevention

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-19 | Critical | **All rows.** Extract the installed `app.asar` (`npx asar extract /usr/lib/claude-desktop/app.asar /tmp/inspect-installed`) and grep the bundled JS for the KDE gate string injected by the patch: `grep -c 'XDG_CURRENT_DESKTOP' /tmp/inspect-installed/.vite/build/index.js`. The patch (`scripts/patches/quick-window.sh:34-35, 117-118`) injects `(process.env.XDG_CURRENT_DESKTOP\|\|"").toLowerCase().includes("kde")` — that string is the runtime fingerprint. Note: the `Patched quick window` / `WARNING: No quick entry show() calls patched` lines from the patch are **build-time stdout** (not in `launcher.log`); check the build log if you built locally. | Bundled JS contains the KDE gate string (patch ran at build time). The patch ships in every build; the KDE-vs-non-KDE branch is decided at runtime by the env-var check. **Runtime gate effectiveness is verified implicitly by QE-7 through QE-12 passing on KDE and the unpatched-equivalent path running on non-KDE.** | [S09](./cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate) |

### Input behavior smoke — catches collateral breakage

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-21 | Smoke | In popup: `Esc` dismisses; click-outside dismisses; `Shift+Enter` inserts newline; `Enter` submits | All four behave as labelled. **Implementation notes for diagnostics:** click-outside is wired in the **main process** via the popup's `blur` handler (`:515465`). `Esc` / `Enter` / `Shift+Enter` are **renderer-side** (not visible in `index.js`); they go through IPC to `requestDismiss()` (`:515409`) and `requestDismissWithPayload()`. If a dismiss key fails, isolate which side is broken before reporting. | [`ui/quick-entry.md`](./ui/quick-entry.md) |

### Popup placement & lifecycle — upstream contract sanity

These verify upstream-promised behaviors that aren't directly broken by #393/#404/#370 but live in the same surface area. Failures here would indicate a separate regression — file a new issue rather than folding it into the close-out trio.

| ID | Severity | Step | Expected | Existing |
|----|----------|------|----------|----------|
| QE-22 | Should | Invoke Quick Entry. Note popup position. Dismiss (Esc). Quit Claude Desktop entirely (`pkill -f app.asar` after closing the main window, or via tray → Quit). Re-launch. Invoke Quick Entry. | Popup reappears at the same monitor + position as before the restart. Upstream persists position via `an.get("quickWindowPosition")` (`:515491-515526`), keyed on monitor label + resolution. Position must survive a full app restart, not just dismiss/re-invoke. | [S35](./cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts) |
| QE-23 | Smoke | **Multi-monitor required.** With an external monitor connected, invoke Quick Entry on the external monitor — let the position be saved (trigger QE-22's persistence path). Disconnect the external monitor (libvirt: `virsh detach-device` for the second display, or unplug the host monitor passing through). Invoke Quick Entry. | Popup falls back to the primary display via `cHn()` (`:515502`). Does **not** appear at off-screen coordinates. Skip this row in single-monitor VMs. | [S36](./cases/shortcuts-and-input.md#s36--quick-entry-popup-falls-back-to-primary-display-when-saved-monitor-is-gone) |
| QE-24 | Should | Launch app, focus main window, then **destroy** the main window without quitting the app. On this project the X button hide-to-tray override means the standard close path won't destroy `ut`; force the destroy via a) DevTools console (`Cmd+Opt+I` / `Ctrl+Shift+I` → `require('electron').remote.getCurrentWindow().destroy()` if exposed), or b) accept that this case is unreachable on Linux without a code change and skip. After destroy, invoke Quick Entry, type, submit. | Popup remains functional (lazy-recreation on shortcut press; the `!ut \|\| ut.isDestroyed()` guard at `:515595` skips the show/focus block but does not crash). New chat creation may not have a window to surface in — if app remains running with no main window, this is the "popup outlives main" path upstream guarantees. **If unreachable on Linux, mark this row N/A and document why.** | [S37](./cases/shortcuts-and-input.md#s37--quick-entry-popup-remains-functional-after-main-window-destroy) |

## Mandatory matrix

The five rows below are the must-pass set to close all three issues. Display server is the **session selected at login** — KDE and GNOME both let you choose Wayland vs Xorg from the greeter.

| Row | Distro | DE | Display server | Closes / verifies | Reporter |
|-----|--------|----|--------------:|-------------------|----------|
| **GNOME-W** | Fedora 43 Workstation | GNOME 49.x | Wayland | #404 (S11/S12), #393 (QE-11/QE-12) | @gianluca-peri (#404), @Andrej730 (#393 root cause) |
| **Ubu-W** | Ubuntu 24.04 LTS | GNOME (Ubuntu) | Wayland | #393 close-out (post-#406 gate). Also catches the `XDG_CURRENT_DESKTOP=ubuntu:GNOME` quirk (S02) | @Andrej730 |
| **KDE-W** | Fedora 43 KDE *or* Nobara 43 KDE | Plasma 6 | Wayland | #370 (S10), QE-19 patch sanity, daily-driver regression baseline | @noctuum (#370), aaddrick |
| **GNOME-X** | Ubuntu 24.04 (GNOME on Xorg session at greeter) | GNOME | Xorg | Differentiates whether #404 is mutter-as-compositor or mutter-XWayland-grabs specifically. **Note:** Fedora 43 GNOME may not ship an X11 session anymore (GNOME 49 deprecation); use Ubuntu's GNOME-on-Xorg session instead. | — |
| **KDE-X** | Fedora 43 KDE (Plasma X11 session at greeter) | Plasma 6 | Xorg | Catches kwin-X11 specifics; regression baseline for the historic working path | — |

## Strongly recommended

Catches generalization gaps but not blocking close-out.

| Row | Distro | DE | Display server | Why |
|-----|--------|----|--------------:|------|
| **COSMIC** | popOS 24.04 (COSMIC alpha) | COSMIC | Wayland | @davidsmorais reported #393 there; not covered by KDE or GNOME branches |
| **Ubu-X** | Ubuntu 24.04 (GNOME on Xorg) | GNOME | Xorg | Already counted under GNOME-X above. Listed here too because the Ubuntu install base is large — counts as its own row in the dashboard |

## Optional

Tracked under different bugs ([S06](./cases/shortcuts-and-input.md#s06--url-handler-doesnt-segfault-on-native-wayland), [S14](./cases/shortcuts-and-input.md#s14--global-shortcuts-via-xdg-portal-work-on-niri)) — skip unless closing those in the same sweep.

| Row | DE | Tracked under |
|-----|----|--------------:|
| Sway | wlroots | S06 |
| Niri | wlroots | S14 |
| Hypr-N (Omarchy) | wlroots | per @typedrat |
| Hypr-O | Hyprland Xorg | per @typedrat |
| i3 | Xorg | matrix |

## VM inventory

Existing host: `~/vms/` (libvirt, qcow2 images on a separate root-owned dir). Per-VM creation scripts in `~/vms/scripts/`. Per-VM test protocol in [`~/vms/README.md`](file:///home/aaddrick/vms/README.md).

### Have

| Row | VM image | Status |
|-----|----------|--------|
| GNOME-W | `claude-fedora43-gnome.qcow2` | Ready |
| Ubu-W | `claude-ubuntu-2404.qcow2` | Ready |
| KDE-W | `claude-fedora43-kde.qcow2` | Ready (Nobara KDE on the bare-metal host is the alternative) |
| GNOME-X | `claude-ubuntu-2404.qcow2` | Ready (use the GNOME-on-Xorg session at the greeter — same VM as Ubu-W) |
| KDE-X | `claude-fedora43-kde.qcow2` | Ready (use the Plasma X11 session at the greeter — same VM as KDE-W) |

### Need to add for full mandatory + recommended coverage

| Row | What | Why |
|-----|------|-----|
| **COSMIC** | popOS 24.04 (COSMIC alpha) ISO + `~/vms/scripts/create-popos-cosmic.sh` | Davidsmorais's #393 environment; otherwise unrepresented |

### Need to add only if closing optional rows in the same sweep

| Row | What | Use existing | Why |
|-----|------|--------------|-----|
| Niri | Fedora-Niri-Live ISO + `~/vms/scripts/create-fedora-niri.sh` | — | S14 (`BindShortcuts` error 5) |
| Hypr-N | Possibly already covered by `claude-omarchy` | `claude-omarchy.qcow2` | Omarchy is a Hypr-N variant; may not exercise stock Hyprland |
| Sway | `claude-fedora43-sway.qcow2` | Existing | S06 URL handler segfault |
| i3 | `claude-fedora43-i3.qcow2` | Existing | Coverage only |

## Minimum viable kill-set

If the goal is the smallest pass that justifies closing all three issues:

- **GNOME-W** — must pass QE-2/3/4/6/7/8/9/11 → closes #404, half of #393.
- **Ubu-W** — must pass QE-7/8/9/11 → closes other half of #393.
- **KDE-W** — must pass QE-7/8/9 + QE-14 + QE-19 → closes #370 (or punts upstream with QE-18 evidence) and confirms the gated patch path still works.

(QE-20 has been folded into QE-19 — the patch ships in every build, so a single bundled-JS check covers both KDE and non-KDE rows.)

Three VMs, ~21 items per row, one full sweep ≈ 90 minutes if the visual checks are batched.

## Per-row pass criteria

| Issue | Closeable when |
|-------|----------------|
| #393 | QE-7 through QE-12 pass on **GNOME-W**, **Ubu-W**, and **KDE-W**. QE-19 confirms the patch was applied at build (KDE gate string present). If QE-11 fails on GNOME-W, the KDE-only gate is preserved as a permanent fix; otherwise the patch can be widened. |
| #404 | QE-2 and QE-3 pass on **GNOME-W**. QE-6 confirms the launcher actually appended `--enable-features=GlobalShortcutsPortal` on GNOME Wayland (S12). |
| #370 | QE-14 passes on **KDE-W**. **OR** QE-18 records an Electron version > 41.0.4 in the bundled binary and QE-14 still fails — at that point the upstream-regression hypothesis is wrong and we re-investigate. |

## Scaffold integration

This sweep is fully wired into the existing test scaffold. The `QE-*` items in [§ Test list](#test-list) map onto formal `S##` test cases in [`cases/shortcuts-and-input.md`](./cases/shortcuts-and-input.md):

| Case | Title | Backs |
|------|-------|-------|
| [S29](./cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity) | Popup created lazily on first shortcut press (closed-to-tray sanity) | QE-4 |
| [S30](./cases/shortcuts-and-input.md#s30--quick-entry-shortcut-becomes-a-no-op-after-full-app-exit) | Shortcut becomes no-op after full app exit | QE-5 |
| [S31](./cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) | Submit makes the new chat reachable from any main-window state | QE-7 through QE-10 |
| [S32](./cases/shortcuts-and-input.md#s32--quick-entry-submit-on-gnome-mutter-doesnt-trip-electron-stale-isfocused) | Submit on GNOME mutter doesn't trip Electron stale-`isFocused()` | QE-11, QE-12 |
| [S33](./cases/shortcuts-and-input.md#s33--quick-entry-transparent-rendering-tracked-against-bundled-electron-version) | Transparent rendering tracked against bundled Electron version | QE-18 |
| [S34](./cases/shortcuts-and-input.md#s34--quick-entry-shortcut-focuses-fullscreen-main-window-instead-of-showing-popup) | Shortcut focuses fullscreen main instead of showing popup | QE-1b |
| [S35](./cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts) | Popup position persisted across invocations and across app restarts | QE-22 |
| [S36](./cases/shortcuts-and-input.md#s36--quick-entry-popup-falls-back-to-primary-display-when-saved-monitor-is-gone) | Popup falls back to primary display when saved monitor is gone | QE-23 |
| [S37](./cases/shortcuts-and-input.md#s37--quick-entry-popup-remains-functional-after-main-window-destroy) | Popup remains functional after main window destroy | QE-24 |

UI-element-level checks for QE-14 through QE-17 and QE-21 live in [`ui/quick-entry.md`](./ui/quick-entry.md), which has been refined against the upstream evidence captured in [§ Upstream design intent](#upstream-design-intent).

(QE-13, QE-21 don't need their own S-IDs — they're documentation items / already covered by `ui/quick-entry.md`.)

## Sweep mechanics

Per-row procedure (one full pass):

1. Boot VM. Confirm session at greeter matches the row (Wayland vs Xorg, correct DE).
2. Install the latest build:
   - DEB: `sudo apt install ./claude-desktop_*.deb`
   - RPM: `sudo dnf install ./claude-desktop-*.rpm`
3. Capture environment baseline: `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`, `gnome-shell --version` or `kwin --version`, `electron --version` (for QE-18).
4. Launch app. Wait for main window. Run QE-21 input smoke first to catch obvious breakage early.
5. Run shortcut tests (QE-1 → QE-6) in order. Each run, scrape `~/.cache/claude-desktop-debian/launcher.log` and `pgrep -af claude-desktop` argv.
6. Run submit tests (QE-7 → QE-13). For each window-state precondition, set the state, then trigger Quick Entry, then submit.
7. Run visual checks (QE-14 → QE-18). Screenshot QE-14 to attach to #370 if still failing.
8. Run patch sanity (QE-19 / QE-20).
9. Update [`matrix.md`](./matrix.md) status cells. Save logs under a row-tagged subdirectory: `~/vms/collected/<row>-<date>/`.

For the deeper #393 bisect (isolating which half of PR #390 regresses GNOME), see the two-variant build instructions in [`~/vms/README.md`](file:///home/aaddrick/vms/README.md) — build a blur-only and a vis-only variant, run QE-7 through QE-11 on each on **Ubu-W** and **GNOME-W**, gate the offending half rather than the whole patch.
