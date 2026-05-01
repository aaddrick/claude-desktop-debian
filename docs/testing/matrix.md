# Test Status Matrix

*Last updated: 2026-04-30 · Tested against: claude-desktop 1.4758.0 (project varies per row)*

This is the live dashboard. Update this file (and only this file) when status changes. For the test specs themselves, see [`cases/`](./cases/). For orientation, see [`README.md`](./README.md).

Status legend: `✓` pass · `✗` fail · `🔧` mitigated · `?` untested · `-` N/A. Cells include linked issue/PR numbers when relevant.

## Cross-environment matrix (T-series)

| Test | KDE-W | KDE-X | GNOME | Ubu | Sway | i3 | Niri | Hypr-O | Hypr-N |
|------|-------|-------|-------|-----|------|----|------|--------|--------|
| [T01](./cases/launch.md#t01--app-launch) | ✓ | ? | ? | ? | ? | ? | ? | ? | ✓ |
| [T02](./cases/launch.md#t02--doctor-health-check) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T03](./cases/tray-and-window-chrome.md#t03--tray-icon-present) | ✓ | ? | ? | ? | ? | ? | ? | ? | ? |
| [T04](./cases/tray-and-window-chrome.md#t04--window-decorations-draw) | ✓ | ? | ? | ? | ? | ? | ? | ? | ✓ |
| [T05](./cases/shortcuts-and-input.md#t05--url-handler-opens-claudeai-links-in-app) | ? | ? | ? | ? | ✗ | ? | ? | ? | ? |
| [T06](./cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused) | ✓ | ✓ | ✗ [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404) | 🔧 [#406](https://github.com/aaddrick/claude-desktop-debian/pull/406) | ? | ? | ✗ | ? | ? |
| [T07](./cases/tray-and-window-chrome.md#t07--in-app-topbar-renders--clickable) | ? | ? | ? | ? | ? | ? | ? | ✗ [#538](https://github.com/aaddrick/claude-desktop-debian/pull/538) | ✓ |
| [T08](./cases/tray-and-window-chrome.md#t08--hide-to-tray-on-close) | ✓ | ? | ? | ? | ? | ? | ? | ? | ? |
| [T09](./cases/platform-integration.md#t09--autostart-via-xdg) | ✓ | ? | ? | ? | ? | ? | ? | ? | ? |
| [T10](./cases/platform-integration.md#t10--cowork-integration) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T11](./cases/extensibility.md#t11--plugin-install-anthropic--partners) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T12](./cases/platform-integration.md#t12--webgl-warn-only) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T13](./cases/launch.md#t13--doctor-reports-correct-package-format) | ✗ | ✗ | ✗ | ? | ✗ | ✗ | ✗ | ? | ? |
| [T14](./cases/launch.md#t14--multi-instance-behavior) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T15](./cases/code-tab-foundations.md#t15--sign-in-completes-via-browser-handoff) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T16](./cases/code-tab-foundations.md#t16--code-tab-loads) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T17](./cases/code-tab-foundations.md#t17--folder-picker-opens) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T18](./cases/code-tab-foundations.md#t18--drag-and-drop-files-into-prompt) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T19](./cases/code-tab-foundations.md#t19--integrated-terminal) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T20](./cases/code-tab-foundations.md#t20--file-pane-opens-and-saves) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T21](./cases/code-tab-workflow.md#t21--dev-server-preview-pane) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T22](./cases/code-tab-workflow.md#t22--pr-monitoring-via-gh) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T23](./cases/code-tab-handoff.md#t23--desktop-notifications-fire) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T24](./cases/code-tab-handoff.md#t24--open-in-external-editor) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T25](./cases/code-tab-handoff.md#t25--show-in-files-file-manager) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T26](./cases/routines.md#t26--routines-page-renders) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T27](./cases/routines.md#t27--scheduled-task-fires-and-notifies) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T28](./cases/routines.md#t28--scheduled-task-catch-up-after-suspend) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T29](./cases/code-tab-workflow.md#t29--worktree-isolation) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T30](./cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T31](./cases/code-tab-workflow.md#t31--side-chat-opens) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T32](./cases/code-tab-workflow.md#t32--slash-command-menu) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T33](./cases/extensibility.md#t33--plugin-browser) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T34](./cases/code-tab-handoff.md#t34--connector-oauth-round-trip) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T35](./cases/extensibility.md#t35--mcp-server-config-picked-up) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T36](./cases/extensibility.md#t36--hooks-fire) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T37](./cases/extensibility.md#t37--claudemd-memory-loads) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T38](./cases/code-tab-handoff.md#t38--continue-in-ide) | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| [T39](./cases/code-tab-handoff.md#t39--desktop-cli-handoff-graceful-na) | ? | ? | ? | ? | ? | ? | ? | ? | ? |

## Environment-specific status

### Ubuntu / DEB

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S01](./cases/distribution.md#s01--appimage-launches-without-manual-libfuse2t64-install) | AppImage launches without manual `libfuse2t64` install | ✗ | Workaround documented; not yet filed |
| [S02](./cases/distribution.md#s02--xdg_current_desktopubuntu-gnome-doesnt-break-de-detection) | `XDG_CURRENT_DESKTOP=ubuntu:GNOME` doesn't break DE detection | ? | — |
| [S03](./cases/distribution.md#s03--deb-install-via-apt-pulls-all-required-runtime-deps) | DEB install via APT pulls all required runtime deps | ? | — |

### Fedora / RPM

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S04](./cases/distribution.md#s04--rpm-install-via-dnf-pulls-all-required-runtime-deps) | RPM install via DNF pulls all required runtime deps | ? | — |
| [S05](./cases/distribution.md#s05--doctor-recognises-dnf-installed-package-doesnt-false-flag-as-appimage) | Doctor recognises dnf-installed package (no AppImage false-flag) | ✗ | Affects KDE-W, KDE-X, GNOME, Sway, i3, Niri (T13) |

### Wayland-native (wlroots)

Applies to: Sway, Niri, Hypr-O, Hypr-N (any session running native Wayland rather than XWayland).

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S06](./cases/shortcuts-and-input.md#s06--url-handler-doesnt-segfault-on-native-wayland) | URL handler doesn't segfault on native Wayland | ✗ on Sway | Captured; not yet filed |
| [S07](./cases/shortcuts-and-input.md#s07--claude_use_wayland1-opt-in-path-works-without-crashing) | `CLAUDE_USE_WAYLAND=1` opt-in path works | ? | [#228](https://github.com/aaddrick/claude-desktop-debian/pull/228), [#232](https://github.com/aaddrick/claude-desktop-debian/pull/232) |

### KDE

Applies to: KDE-W, KDE-X.

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S08](./cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update) | Tray icon doesn't duplicate after `nativeTheme` update | 🔧 | [`tray-rebuild-race.md`](../learnings/tray-rebuild-race.md) |
| [S09](./cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate) | Quick window patch runs only on KDE | ✓ | [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406) |
| [S10](./cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame) | Quick Entry popup is transparent | ? | [#370](https://github.com/aaddrick/claude-desktop-debian/issues/370), [#223](https://github.com/aaddrick/claude-desktop-debian/issues/223) |

### GNOME

Applies to: GNOME, Ubu (Ubuntu's GNOME), and any other mutter session.

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S11](./cases/shortcuts-and-input.md#s11--quick-entry-shortcut-fires-from-any-focus-on-wayland-mutter-xwayland-key-grab) | Quick Entry shortcut fires from any focus | ✗ on GNOME, 🔧 on Ubu | [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404), [PR #406](https://github.com/aaddrick/claude-desktop-debian/pull/406) |
| [S12](./cases/shortcuts-and-input.md#s12----enable-featuresglobalshortcutsportal-launcher-flag-wired-up-for-gnome-wayland) | `--enable-features=GlobalShortcutsPortal` wired up | ? | [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404) |

### Omarchy

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S13](./cases/tray-and-window-chrome.md#s13--hybrid-topbar-shim-survives-omarchys-ozone-wayland-env-exports) | Hybrid topbar shim survives Omarchy's Ozone-Wayland env exports | ✗ | [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538) |

### Niri

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S14](./cases/shortcuts-and-input.md#s14--global-shortcuts-via-xdg-portal-work-on-niri) | Global shortcuts via XDG portal work on Niri | ✗ | Captured; not yet filed |

### AppImage

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S15](./cases/distribution.md#s15--appimage-extraction---appimage-extract-works-as-documented-fallback) | AppImage extraction (`--appimage-extract`) works as fallback | ? | — |
| [S16](./cases/distribution.md#s16--appimage-mount-cleans-up-on-app-exit) | AppImage mount cleans up on app exit | ? | — |

### Linux launcher / `.desktop` env handling

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S17](./cases/platform-integration.md#s17--app-launched-from-desktop-inherits-shell-path) | App launched from `.desktop` inherits shell `PATH` | ? | — |
| [S18](./cases/platform-integration.md#s18--local-environment-editor-persists-across-reboot) | Local environment editor persists across reboot | ? | — |
| [S19](./cases/routines.md#s19--claude_config_dir-redirects-scheduled-task-storage) | `CLAUDE_CONFIG_DIR` redirects scheduled-task storage | ? | — |

### Idle-sleep / suspend

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S20](./cases/routines.md#s20--keep-computer-awake-inhibits-idle-suspend) | "Keep computer awake" inhibits idle suspend | ? | — |
| [S21](./cases/routines.md#s21--lid-close-still-suspends-per-os-policy) | Lid-close still suspends per OS policy | ? | — |

### Computer Use (Linux: out-of-scope per upstream)

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S22](./cases/platform-integration.md#s22--computer-use-toggle-is-absent-or-visibly-disabled-on-linux) | Computer-use toggle is absent or visibly disabled | ? | — |
| [S23](./cases/platform-integration.md#s23--dispatch-spawned-sessions-dont-soft-lock-on-a-never-approvable-computer-use-prompt) | Dispatch sessions don't soft-lock on never-approvable prompt | ? | — |

### Dispatch

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S24](./cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification) | Dispatch-spawned Code session appears with badge + notification | ? | — |
| [S25](./cases/platform-integration.md#s25--mobile-pairing-survives-linux-session-restart) | Mobile pairing survives Linux session restart | ? | — |

### Auto-update vs. system package manager

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S26](./cases/distribution.md#s26--auto-update-is-disabled-when-installed-via-apt--dnf) | Auto-update is disabled when installed via `apt` / `dnf` | ? | — |

### Plugin / worktree storage

| ID | Test | Status | Notes |
|----|------|--------|-------|
| [S27](./cases/extensibility.md#s27--plugins-install-per-user-not-into-system-paths) | Plugins install per-user, not into system paths | ? | — |
| [S28](./cases/extensibility.md#s28--worktree-creation-surfaces-clear-error-on-read-only-mounts) | Worktree creation surfaces clear error on read-only mounts | ? | — |

## Known failures rollup

Tests currently `✗` somewhere — investigation priority order:

| Test | Failing on | Root cause |
|------|------------|------------|
| [T05 / S06](./cases/shortcuts-and-input.md#s06--url-handler-doesnt-segfault-on-native-wayland) | Sway | URL handler subprocess SIGSEGV on native Wayland — `Failed to connect to Wayland display` |
| [T06 / S11](./cases/shortcuts-and-input.md#s11--quick-entry-shortcut-fires-from-any-focus-on-wayland-mutter-xwayland-key-grab) | GNOME | mutter doesn't honour XWayland-side key grab |
| [T06 / S14](./cases/shortcuts-and-input.md#s14--global-shortcuts-via-xdg-portal-work-on-niri) | Niri | `BindShortcuts` returns error code 5 |
| [T07 / S13](./cases/tray-and-window-chrome.md#s13--hybrid-topbar-shim-survives-omarchys-ozone-wayland-env-exports) | Hypr-O | Hybrid topbar shim partial render under Omarchy's Ozone-Wayland env exports |
| [T13 / S05](./cases/launch.md#t13--doctor-reports-correct-package-format) | every Fedora row | Doctor only checks dpkg, false-flags every dnf install as AppImage |
| [S01](./cases/distribution.md#s01--appimage-launches-without-manual-libfuse2t64-install) | Ubuntu 24.04 | AppImage requires `libfuse2t64`; not auto-pulled |

## Notes on the current state

- Most cells are `?` because every captured VM in the recent test session ran the **released** build (`dnf install` / `apt install` / current AppImage), which predates [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538). Topbar verification (T07) on the VM rows specifically requires a branch build deployed before any cell can flip from `?`.
- KDE-W status reflects @aaddrick's daily-driver host (Nobara KDE Plasma Wayland) where multiple features have been in continuous use.
- Hypr-N status reflects @typedrat's report on [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538) ("Working great on NixOS with Hyprland").
- Hypr-O status reflects @lukedev45's broken-case report on [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538) (partial render, root cause unconfirmed but Omarchy-env-specific — see [S13](./cases/tray-and-window-chrome.md#s13--hybrid-topbar-shim-survives-omarchys-ozone-wayland-env-exports)).
- T13 is `✗` on every Fedora row because the dpkg false-flag is a deterministic property of the doctor script, not a per-environment failure mode. It will flip to `✓` everywhere once the doctor learns to detect rpm/dnf installs.
- T15–T39 are derived from upstream Claude Code Desktop docs (`code.claude.com/docs/en/desktop*`) — features whose Linux behavior is officially undocumented (the docs explicitly state "Linux is not supported" for the Code tab). All cells start as `?` because the upstream Code-tab feature surface has not been systematically exercised on the patched Linux build.
