# Shortcuts & Input

Tests covering URL handling, the Quick Entry global shortcut, and DE-specific shortcut/input failure modes. See [`../matrix.md`](../matrix.md) for status.

## T05 — URL handler opens claude.ai links in-app

**Severity:** Smoke
**Surface:** URL handler / xdg-open
**Applies to:** All rows
**Issues:** —

**Steps:**
1. With Claude Desktop running, in another app run `xdg-open https://claude.ai/chat/...` (or click a `claude.ai` link in a browser/terminal).
2. Observe.

**Expected:** Link opens inside the running Claude Desktop window — no new browser tab, no crash, no error dialog.

**Diagnostics on failure:** `xdg-mime query default x-scheme-handler/https`, the registered `.desktop` file content, launcher log, app crash report (if any), `coredumpctl list claude-desktop` (if subprocess died — see [S06](#s06--url-handler-doesnt-segfault-on-native-wayland)).

**References:** —

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

**References:** [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404)

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
