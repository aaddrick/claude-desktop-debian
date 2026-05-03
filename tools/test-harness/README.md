# Linux Compatibility Test Harness

In-VM (or on-host) Playwright + DBus runner for the test cases under
[`docs/testing/cases/`](../../docs/testing/cases/). See
[`docs/testing/automation.md`](../../docs/testing/automation.md) for the
architecture, decisions, and rationale.

## Status

Sixty-one specs wired (24 cross-env T-tests, 32 env-specific S-tests,
5 H-prefix harness self-tests). See
[`docs/testing/runner-implementation-plan.md`](../../docs/testing/runner-implementation-plan.md)
for the tiered triage of remaining tests and the per-spec rationale
behind tier classification.

| Test | What it checks | Layer |
|------|----------------|-------|
| [T01](../../docs/testing/cases/launch.md#t01--app-launch) | X11 window with our pid appears within 15s; title matches `/claude/i` | L2 (xprop) |
| [T02](../../docs/testing/cases/launch.md#t02--doctor-health-check) | `claude-desktop --doctor` exits 0 | spawn probe |
| [T03](../../docs/testing/cases/tray-and-window-chrome.md#t03--tray-icon-present) | A `StatusNotifierItem` is registered by the claude-desktop pid AND exactly one (no rebuild-race duplicates) | L2 (DBus) |
| [T04](../../docs/testing/cases/tray-and-window-chrome.md#t04--window-decorations-draw) | Window has `_NET_FRAME_EXTENTS` (sum > 0) and a "Claude" title | L2 (xprop) |
| [T05](../../docs/testing/cases/shortcuts-and-input.md#t05--claude-url-handler) | `xdg-open 'claude://...'` delivers via `app.on('second-instance')` to the running app | spawn + L1 hook |
| [T06](../../docs/testing/cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused) | `globalShortcut.isRegistered('Ctrl+Alt+Space')` returns true after `mainVisible` | L1 |
| [T07](../../docs/testing/cases/tray-and-window-chrome.md#t07--in-app-topbar) | Five topbar buttons render with non-zero rects (uses `seedFromHost` for hermetic auth) | L1 + DOM |
| [T08](../../docs/testing/cases/tray-and-window-chrome.md#t08--close-x-hides-to-tray) | `win.close()` fires the wrapper interceptor; window hidden, proc alive | L1 |
| [T09](../../docs/testing/cases/platform-integration.md#t09--autostart-via-xdg) | `setLoginItemSettings({ openAtLogin })` writes/removes `$XDG_CONFIG_HOME/autostart/claude-desktop.desktop` | L1 + filesystem |
| [T10](../../docs/testing/cases/platform-integration.md#t10--cowork-integration) | After H04-style spawn detection, `kill -9` the daemon and confirm a *different* pid respawns within ~20s (Patch 6 cooldown + retry) | pgrep delta + spawn delta |
| [T11](../../docs/testing/cases/extensibility.md#t11--plugin-install) | Plugin-install code path fingerprints present in bundled `index.js` | file probe |
| [T12](../../docs/testing/cases/platform-integration.md#t12--webgl-warn-only) | `app.getGPUFeatureStatus()` returns a populated object; renderer reached visible | L1 |
| [T13](../../docs/testing/cases/launch.md#t13--doctor-reports-correct-package-format) | `--doctor` does not false-flag rpm/deb installs as missing-dpkg AppImage | spawn + stdout grep |
| [T14a](../../docs/testing/cases/launch.md#t14--multi-instance-behavior) | `requestSingleInstanceLock` + `'second-instance'` strings in bundled `index.js` (file probe) | file probe |
| [T14b](../../docs/testing/cases/launch.md#t14--multi-instance-behavior) | Second invocation under same isolation exits cleanly; primary pid stays alive (runtime probe) | spawn delta + pgrep |
| [T16](../../docs/testing/cases/code-tab-foundations.md#t16--code-tab-loads) | After `seedFromHost` + `userLoaded`, `CodeTab.activate()` resolves and ≥1 compact pill renders (env pill = Code-body mounted) | L1 + AX-tree |
| [T17](../../docs/testing/cases/code-tab-foundations.md#t17--folder-picker-opens) | Code df-pill → env pill → Local → Select folder → Open folder triggers `dialog.showOpenDialog` (requires `CLAUDE_TEST_USE_HOST_CONFIG=1`) | L1 |
| [T18](../../docs/testing/cases/code-tab-foundations.md#t18--drag-and-drop-files-into-prompt) | Bundled `mainView.js` preload contains the path-resolution bridge fingerprints: `getPathForFile` (2× — property key + the `webUtils.getPathForFile(` call, both at case-doc :9267), `webUtils`, `filePickers`, and the `claudeAppSettings` `contextBridge.exposeInMainWorld` namespace (case-doc :9552) — pins the load-bearing wiring without faking OS-level XDND drag (xdotool can't put file URIs on the X11 selection; Wayland needs per-compositor IPC + libei) | file probe |
| [T22](../../docs/testing/cases/code-tab-workflow.md#t22--pr-monitoring-via-gh) | Bundled `index.js` contains `LocalSessions_$_getPrChecks` eipc channel name *and* `gh CLI not found in PATH` Linux-fallthrough throw site (Tier 1 fingerprint — eipc registry not introspectable from main) | file probe |
| [T23](../../docs/testing/cases/code-tab-handoff.md#t23--desktop-notifications-fire) | Firing `new Notification({title})` from main reaches the session bus's `org.freedesktop.Notifications.Notify` (observed via `dbus-monitor`) | L1 + DBus subprocess |
| [T24](../../docs/testing/cases/code-tab-handoff.md#t24--open-in-external-editor) | After `installOpenExternalMock` mirroring T25's pattern, `evalInMain` calls `shell.openExternal('vscode://file/...')`; mock records the URL verbatim, no real editor launch | L1 (mocked egress) |
| [T25](../../docs/testing/cases/code-tab-handoff.md#t25--show-in-files--file-manager) | After `installShowItemInFolderMock` mirroring T17's dialog-mock pattern, `evalInMain` calls `shell.showItemInFolder(<synthetic path>)`; mock records the call verbatim, no throw — no host side effect | L1 (mocked egress) |
| [T26](../../docs/testing/cases/routines.md#t26--routines-page-renders) | After `seedFromHost` + `userLoaded`, click "Routines" sidebar AX button; assert "New routine" / "All" / "Calendar" anchor renders | L1 + AX-tree |
| [T30](../../docs/testing/cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge) | Bundled `index.js` colocates the auto-archive sweep cadence (`300*1e3` ≤ `3600*1e3` ≤ `AutoArchiveEngine`) with the `ccAutoArchiveOnPrClose` gate key (single-regex multi-string fingerprint) | file probe |
| [T31](../../docs/testing/cases/code-tab-workflow.md#t31--side-chat-opens) | Bundled `index.js` contains all three side-chat eipc channel names (`startSideChat`, `sendSideChatMessage`, `stopSideChat`) — load-bearing trio | file probe |
| [T32](../../docs/testing/cases/code-tab-workflow.md#t32--slash-command-menu) | Bundled `index.js` contains `LocalSessions_$_getSupportedCommands` eipc channel + `slashCommands` schema field | file probe |
| [T33](../../docs/testing/cases/extensibility.md#t33--plugin-browser) | Bundled `index.js` contains `CustomPlugins_$_listMarketplaces` and `CustomPlugins_$_listAvailablePlugins` eipc channel names (browser populate flow) | file probe |
| [T35](../../docs/testing/cases/extensibility.md#t35--mcp-server-config-picked-up) | Bundled `index.js` contains the four-needle MCP-config separation fingerprint: `claude_desktop_config.json` (chat-tab path), `.claude.json` + `.mcp.json` (Code-tab loaders), `"user","project","local"` (settingSources triple Code-session passes to the agent SDK) — pins per-tab separation without launch | file probe |
| [T36](../../docs/testing/cases/extensibility.md#t36--hooks-fire) | Bundled `index.js` contains the hooks runtime fingerprint: `hook_started` / `hook_progress` / `hook_response` (single-occurrence Verbose-transcript runtime emits) plus `PreToolUse` / `UserPromptSubmit` registry tokens — pins the runtime hook-fire path the case-doc Verbose-transcript claim hangs on | file probe |
| [T37](../../docs/testing/cases/extensibility.md#t37--claudemd-memory-loads) | Bundled `index.js` contains `[GlobalMemory] Copied CLAUDE.md` log line + `CLAUDE.md` filename literal + `CLAUDE_CONFIG_DIR` env-var token (memory-loading wiring) | file probe |
| [T38](../../docs/testing/cases/code-tab-handoff.md#t38--continue-in-ide) | Bundled `index.js` contains `LocalSessions_$_openInEditor` eipc channel name (Tier 1 fingerprint — reclassified from session 2's broken `ipcMain._invokeHandlers` probe; eipc registry is closure-local) | file probe |
| H01 | CDP auth gate exits with code 1 when spawned with `--remote-debugging-port` and no `CLAUDE_CDP_AUTH` token | spawn probe |
| H02 | `frame-fix-wrapper.js` + `frame-fix-entry.js` injected into `app.asar` (Proxy + main-field reference) | file probe |
| H03 | Build-pipeline patch fingerprints all present in `app.asar` (KDE gate, frame-fix inject, tray, cowork, claude-code) | file probe |
| H04 | cowork daemon spawns under app and exits with app — soft-skips on rows where it isn't gated to spawn | pgrep delta |
| H05 | UI-drift canary against the AX-tree fingerprint walker (requires `CLAUDE_TEST_USE_HOST_CONFIG=1`) | L1 (AX) |
| [S01](../../docs/testing/cases/distribution.md#s01--appimage-launches-without-manual-libfuse2t64) | AppImage launches without `libfuse.so.2` complaint (skips on non-AppImage rows) | spawn + stderr grep |
| [S02](../../docs/testing/cases/distribution.md#s02--xdg_current_desktopubuntugnome-prefix-form-doesnt-break-de-detection) | No strict `==` equality against `XDG_CURRENT_DESKTOP` in launcher / patches (regression detector) | source-tree probe |
| [S03](../../docs/testing/cases/distribution.md#s03--deb-install-pulls-runtime-deps) | `dpkg-query Depends:` field non-empty (currently fails as upstream-contract regression detector) | dpkg-query |
| [S04](../../docs/testing/cases/distribution.md#s04--rpm-install-pulls-runtime-deps) | `rpm -qR` has at least one non-`rpmlib(...)` requirement (currently fails per #autoreqprov off) | rpm -qR |
| [S05](../../docs/testing/cases/distribution.md#s05--doctor-recognises-dnf-installed-package-doesnt-false-flag-as-appimage) | Doctor does not false-flag rpm-installed package (skips when `rpm -qf` doesn't claim the binary) | spawn + stdout grep |
| [S07](../../docs/testing/cases/shortcuts-and-input.md#s07--claude_use_waylandvar) | Under `CLAUDE_HARNESS_USE_WAYLAND=1`, spawned Electron has `--ozone-platform=wayland` on argv | argv probe |
| [S08](../../docs/testing/cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update) | `setImage`-based in-place fast-path injected by `tray.sh` (KDE-only, file probe) | file probe |
| [S09](../../docs/testing/cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate) | KDE-gate string present in bundled `index.js` (patch ran at build) | file probe |
| [S10](../../docs/testing/cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame) | KDE-W only — popup runtime `getBackgroundColor() === '#00000000'` after Quick Entry opens (regression-detector against electron#50213 if bundled Electron in 41.0.4-bisect-window) | L1 + ydotool |
| [S11](../../docs/testing/cases/shortcuts-and-input.md#s11--quick-entry-shortcut-fires-from-any-focus-on-wayland-mutter-xwayland-key-grab) | GNOME-X / Ubu-X only (X11-side regression detector) — spawn xterm marker, `xdotool windowfocus` to it, verify `_NET_ACTIVE_WINDOW` shifted, fire `Ctrl+Alt+Space` via ydotool, assert popup visible. Wayland-side mutter regression (#404) is a primitive gap — needs Wayland-native focus injection (libei) | L1 + xdotool focus + ydotool shortcut |
| S12 | `--enable-features=GlobalShortcutsPortal` in Electron argv (GNOME-W only — currently a known-failing regression detector) | argv probe |
| [S15](../../docs/testing/cases/distribution.md#s15--appimage-extraction---appimage-extract-works-as-documented-fallback) | `--appimage-extract` exits 0; `squashfs-root/AppRun --version` runs without FUSE error | spawn + filesystem |
| [S16](../../docs/testing/cases/distribution.md#s16--appimage-mount-cleans-up-on-app-exit) | `mount(8)` shows new `.mount_claude` while app is up; gone within 10s of close | mount delta |
| [S17](../../docs/testing/cases/platform-integration.md#s17--app-launched-from-desktop-inherits-shell-path) | Shell-path-worker overlays user's login-shell PATH onto a deliberately-scrubbed env | L1 + utilityProcess |
| [S19](../../docs/testing/cases/routines.md#s19--claude_config_dir-redirects-scheduled-task-storage) | `extraEnv: { CLAUDE_CONFIG_DIR }` reaches main-process `process.env`; `cE()`-equivalent resolves under the override path | L1 + extraEnv |
| [S21](../../docs/testing/cases/routines.md#s21--lid-close-still-suspends-per-os-policy) | No `handle-lid-switch` / `HandleLidSwitch` strings in bundle (lid policy deferred to OS) | asar absence probe |
| [S22](../../docs/testing/cases/platform-integration.md#s22--computer-use-toggle-absent-or-visibly-disabled-on-linux) | `new Set(["darwin","win32"])` platform gate present; no 2-element Set pairing linux (file-probe form) | asar regex |
| [S25](../../docs/testing/cases/platform-integration.md#s25--mobile-pairing-survives-linux-session-restart) | `safeStorage.encryptString → file → app restart → file → safeStorage.decryptString` round-trips the same plaintext (skips when `isEncryptionAvailable === false`) | L1 + shared isolation handle |
| [S26](../../docs/testing/cases/distribution.md#s26--auto-update-is-disabled-when-installed-via-aptdnf) | `setFeedURL` present + project suppression marker present (currently fails — gated on #567) | asar fingerprint |
| [S27](../../docs/testing/cases/extensibility.md#s27--plugins-install-per-user) | `installed_plugins.json` + homedir resolver present; no `*/plugins` system paths in bundle | asar fingerprint |
| [S28](../../docs/testing/cases/extensibility.md#s28--worktree-creation-surfaces-clear-error-on-read-only-mounts) | Bundled `index.js` contains the worktree permission classifier expression (`"Permission denied" \|\| "Access is denied" \|\| "could not lock config file" → "permission-denied"`) plus the `Failed to create git worktree:` log line | asar fingerprint |
| [S29](../../docs/testing/cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity) | Popup opens when main is hidden-to-tray (lazy-create sanity) | L1 |
| [S30](../../docs/testing/cases/shortcuts-and-input.md#s30--quick-entry-shortcut-becomes-a-no-op-after-full-app-exit) | No new claude-desktop pid spawns after post-exit shortcut press | pgrep delta + ydotool |
| [S31](../../docs/testing/cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) | Submit reaches new chat from visible / minimized / hidden-to-tray (QE-7/8/9) | L1 + ydotool |
| S32 | GNOME mutter stale-`isFocused()` regression (GNOME-W/Ubu-W only — known-failing today) | L1 + ydotool |
| [S33](../../docs/testing/cases/shortcuts-and-input.md#s33--quick-entry-transparent-rendering-tracked-against-bundled-electron-version) | Captures bundled Electron version against the #370 / electron#50213 bisect threshold | file read |
| [S34](../../docs/testing/cases/shortcuts-and-input.md#s34--quick-entry-shortcut-focuses-fullscreen-main-window-instead-of-showing-popup) | Popup does **not** appear when main is fullscreen (upstream contract) | L1 + ydotool |
| [S35](../../docs/testing/cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts) | Popup position persists across invocations *and* across app restart (two-launch test) | L1 + shared isolation handle + ydotool |
| S36 | Multi-monitor fallback — skip-on-single-monitor with documented `fixme` for the disconnect orchestration | display probe |
| S37 | Main-window destroy unreachable on Linux per close-to-tray override — documented skip | — |

These specs exercise the substrate primitives in `lib/`: `xprop`
shell-outs (T01, T04), `dbus-next` (T03), `dbus-monitor` subprocess
eavesdrop (T23), Node-inspector runtime-attach
(T07/T16/T17/T26/S10/S29-S35/T05-T14b L1 specs), `app.asar` content reads
(S08/S09/S21/S22/S26/S27/S28/T11/T14a/T18/T22/T30/T31/T32/T33/T35/T36/T37/T38/H02/H03/S33 — mostly `index.js`; T18 reads `mainView.js`),
`/proc/$pid/cmdline` reads (S07/S12), pgrep-based pid deltas
(T10/T14b/H04/S16/S30), `mount(8)` parsing (S16), source-tree probes
against `scripts/launcher-common.sh` (S02), `dpkg-query` / `rpm -qR` /
`rpm -qf` calls (S03/S04/S05/T13), `safeStorage.encryptString`
round-trip across two launches (S25), `extraEnv` precedence over
isolation env (S19), the `lib/electron-mocks.ts` mock-then-call
helpers — `installOpenDialogMock` (T17), `installShowItemInFolderMock`
(T25), `installOpenExternalMock` (T24) — the `lib/input.ts`
focus-shifter (`focusOtherWindow` + `spawnMarkerWindow` for S11; X11
only — `WaylandFocusUnavailable` thrown on native Wayland) — and the
`createIsolation({ seedFromHost: true })` primitive that lets
login-required tests run hermetically against a copy of the host's
signed-in auth state (T07, T16, T26).

Note on eipc channels: the `LocalSessions_$_*` and `CustomPlugins_$_*`
channel names referenced in the case-doc Code anchors do not register
through Electron's standard `ipcMain.handle()` registry — they use a
custom `$eipc_message$_<UUID>_$_claude.web_$_<name>` message-port
protocol whose registry is closure-local and not reachable from
`globalThis` at any ready level. T22, T31, T33, T38 anchor on the
eipc channel-name *strings* in the bundle (Tier 1 fingerprint) rather
than introspecting a registry. See
[`runner-implementation-plan.md`](../../docs/testing/runner-implementation-plan.md)
session 3 status section for the finding.

Per-row pass/skip counts depend on which sweep runs against the row;
see `runner-implementation-plan.md` for tier classification and
matrix-regen for the most-recent per-row outcomes. The Quick Entry
runners (S29-S35) all share the same primitive set (`installInterceptor()`
+ `openAndWaitReady()` + scenario-specific state setup).

## Prerequisites

On the host or VM running the sweep:

- Node.js ≥ 20
- `claude-desktop` installed (deb / rpm / AppImage), reachable via `claude-desktop` on `PATH` or `CLAUDE_DESKTOP_LAUNCHER` env var
- `xprop` (for L2 window queries — `dnf install xorg-x11-utils` on Fedora; `apt install x11-utils` on Debian/Ubuntu)
- `zstd` (optional — used to bundle results)

### Quick Entry runners (S29–S37, future QE-*)

Quick Entry tests inject the OS-level shortcut via `ydotool` /
`/dev/uinput`. One-time setup per host or VM:

```sh
# Install the binary + daemon
sudo dnf install -y ydotool   # or: sudo apt install ydotool

# Make ydotoold's socket world-writable so the test runner reaches it
sudo mkdir -p /etc/systemd/system/ydotool.service.d
sudo tee /etc/systemd/system/ydotool.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/ydotoold --socket-perm=0666
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ydotool.service
```

After this, `ydotool key 29:1 29:0` (Ctrl tap) should exit 0. The
runner sets `YDOTOOL_SOCKET=/tmp/.ydotool_socket` automatically;
override the env var if your daemon binds elsewhere.

ydotool **cannot** drive portal-grabbed shortcuts (kernel uinput
events vs compositor portal grabs) — those tests stay manual until
libei adoption broadens. See [`docs/testing/automation.md`](../../docs/testing/automation.md#input-injection--ydotool-now-libei-next).

## Install

```sh
cd tools/test-harness
npm install
```

`package-lock.json` is gitignored for now; commit it once the dep set is settled.

## Run

```sh
# All four tests against the locally installed claude-desktop
ROW=KDE-W ./orchestrator/sweep.sh

# Single test
npx playwright test src/runners/T01_app_launch.spec.ts

# Headed (watch the app launch in front of you)
npx playwright test --headed

# Run the full suite under native Wayland instead of X11/XWayland
CLAUDE_HARNESS_USE_WAYLAND=1 npm test

# Grounding probe — dump runtime state for the case-doc grounding sweep
npm run grounding-probe -- --launch --include-synthetic \
  --out ../../docs/testing/cases-grounding-runtime.json
```

Results land at `results/results-${ROW}-${DATE}/`:

```
results/results-KDE-W-20260430T143000Z/
├── junit.xml             # JUnit summary (matrix-regen input)
├── html/                 # Playwright HTML report
└── test-output/          # Per-test attachments (screenshots, logs, etc.)
```

A bundled `results-${ROW}-${DATE}.tar.zst` sits next to the dir if `zstd`
is installed.

## Environment variables

| Var | Default | Purpose |
|-----|---------|---------|
| `ROW` | `KDE-W` | Matrix row label, propagated into the bundle name and per-test annotations. Drives `skipUnlessRow()` in spec files |
| `CLAUDE_DESKTOP_LAUNCHER` | `claude-desktop` (PATH lookup) | Path to the launcher / Electron binary Playwright spawns |
| `CLAUDE_DESKTOP_ELECTRON` | probed | Override the resolved Electron binary path (skips deb/rpm install probing) |
| `CLAUDE_DESKTOP_APP_ASAR` | probed | Override the resolved `app.asar` path |
| `CLAUDE_TEST_USE_HOST_CONFIG` | unset | When `1`, opt out of per-test isolation and use the host's real `~/.config/Claude`. Required for tests that need a signed-in claude.ai (S31, future submit-side QE runners). **Side effect:** these tests write to your real account — chats / settings persist |
| `CLAUDE_HARNESS_USE_WAYLAND` | unset | When `1`, every runner spawns Electron with the native-Wayland backend (`--ozone-platform=wayland` + sibling flags from `launcher-common.sh`) instead of the default X11-via-XWayland. `CLAUDE_USE_WAYLAND=1` is also exported into the spawn env for in-app paths that read it. Per-launch overrides via `launchClaude({ extraEnv })` still win |
| `YDOTOOL_SOCKET` | `/tmp/.ydotool_socket` | Path to the `ydotoold` socket. Override only if the daemon binds elsewhere |
| `OUTPUT_DIR` | `./results` | Where bundles land |
| `RESULTS_DIR` | per-run derived | Single-run output dir (set by `sweep.sh`; usually you don't set this manually) |

### Per-test isolation default

`launchClaude()` creates a fresh `XDG_CONFIG_HOME` / `CLAUDE_CONFIG_DIR`
under `$TMPDIR/claude-test-*` for every launch and removes it on
`close()`. This is the default to prevent state leaks between tests
(SingletonLock collisions, persisted Quick Entry positions, etc. —
see Decision 1 in [`docs/testing/automation.md`](../../docs/testing/automation.md)).
Three escape hatches:

- **`launchClaude()`** — default, fresh per-launch isolation.
- **`launchClaude({ isolation })`** — pass a shared `Isolation` handle
  to launch the same app twice with persistent state (e.g. S35
  position-memory across restart).
- **`launchClaude({ isolation: null })`** — opt out entirely; share
  the host's `~/.config/Claude`. Used by tests gated on
  `CLAUDE_TEST_USE_HOST_CONFIG` for signed-in claude.ai access.

## Layout

```
tools/test-harness/
├── package.json
├── tsconfig.json
├── playwright.config.ts
├── src/
│   ├── lib/                       # shared helpers
│   │   ├── electron.ts            # spawn + isolation + inspector attach
│   │   ├── inspector.ts           # Node-inspector RPC client (SIGUSR1 path)
│   │   ├── dbus.ts                # dbus-next session-bus + helpers
│   │   ├── sni.ts                 # StatusNotifierWatcher / Item
│   │   ├── wm.ts                  # xprop wrappers (X11 + XWayland)
│   │   ├── env.ts                 # XDG_CURRENT_DESKTOP / SESSION_TYPE branching
│   │   ├── row.ts                 # skipUnlessRow / skipOnRow primitives
│   │   ├── isolation.ts           # per-test XDG_CONFIG_HOME sandbox
│   │   ├── argv.ts                # /proc/$pid/cmdline reader + flag check
│   │   ├── asar.ts                # in-place app.asar reads (no temp extract)
│   │   ├── quickentry.ts          # Quick Entry domain wrapper (popup, MainWindow, ydotool)
│   │   ├── claudeai.ts            # claude.ai renderer UI domain (CodeTab, dialog mock, atoms)
│   │   ├── electron-mocks.ts      # mock-then-call helpers (dialog/showItemInFolder/openExternal)
│   │   ├── input.ts               # focus-shifter primitive (X11 only — xdotool + xprop verify; spawnMarkerWindow xterm)
│   │   ├── retry.ts               # poll-until-true with timeout
│   │   └── diagnostics.ts         # launcher log, --doctor, session env
│   └── runners/                   # one .spec.ts per test ID
│       ├── T01_app_launch.spec.ts
│       ├── T03_tray_icon_present.spec.ts
│       ├── T04_window_decorations.spec.ts
│       ├── T17_folder_picker.spec.ts
│       ├── S09_quick_window_patch_only_kde.spec.ts
│       ├── S12_global_shortcuts_portal_flag.spec.ts
│       ├── S29_quick_entry_lazy_create_closed_to_tray.spec.ts
│       ├── S30_quick_entry_noop_after_app_exit.spec.ts
│       ├── S31_quick_entry_submit_reaches_new_chat.spec.ts
│       ├── S32_quick_entry_submit_gnome_stale_isfocused.spec.ts
│       ├── S33_electron_version_capture.spec.ts
│       ├── S34_shortcut_focuses_fullscreen_main.spec.ts
│       ├── S35_quick_entry_position_persisted_across_restarts.spec.ts
│       ├── S36_quick_entry_fallback_to_primary_display.spec.ts
│       ├── S37_quick_entry_popup_after_main_destroy.spec.ts
│       ├── H01_cdp_gate_canary.spec.ts
│       ├── H02_frame_fix_wrapper_present.spec.ts
│       ├── H03_patch_fingerprints.spec.ts
│       └── H04_cowork_daemon_lifecycle.spec.ts
├── probe.ts                       # one-off renderer-DOM probe (debugger on :9229)
├── grounding-probe.ts             # case-grounding runtime capture (see "Grounding probe" below)
└── orchestrator/
    └── sweep.sh                   # row-aware harness invocation
```

H-prefix specs are harness self-tests — they validate the harness's
preconditions and the build pipeline's invariants (CDP gate alive,
patches landed, daemon lifecycle clean). Cheap, run in <1s each
except H04 which launches the app.

## How L1 testing works (the SIGUSR1 path)

The shipped Electron has a CDP auth gate that exits the app whenever
`--remote-debugging-port` or `--remote-debugging-pipe` is on argv and a
valid `CLAUDE_CDP_AUTH` token isn't in env. Both Playwright's
`_electron.launch()` and `chromium.connectOverCDP()` inject the gated
flag, so both are blocked.

The gate doesn't check `--inspect` or runtime `SIGUSR1`, which is the
same code path as the in-app `Developer → Enable Main Process Debugger`
menu item. So:

1. `launchClaude()` spawns Electron with no debug-port flags (gate
   asleep) and waits for the X11 window.
2. `app.attachInspector()` sends `SIGUSR1` to the pid; Node's inspector
   opens on port 9229.
3. `lib/inspector.ts` connects via WebSocket and exposes
   `evalInMain(body)` and `evalInRenderer(urlFilter, js)` for tests.

From the inspector you can:
- Drive the renderer via `webContents.executeJavaScript()`
- Install main-process mocks (e.g. `dialog.showOpenDialog` for T17)
- Inspect any Electron API state

Two gotchas worth knowing:

- `BrowserWindow.getAllWindows()` returns 0 because frame-fix-wrapper
  substitutes the BrowserWindow class. Use `webContents.getAllWebContents()`
  instead — works correctly and includes both the shell window and the
  embedded claude.ai BrowserView.
- `Runtime.evaluate` with `awaitPromise: true` returns empty objects for
  awaited Promise resolutions. `inspector.evalInMain<T>()` returns
  `JSON.stringify(value)` from the IIFE and parses on the caller side
  to dodge this.

Full writeup with rationale and tradeoffs:
[`docs/testing/automation.md` "The CDP auth gate"](../../docs/testing/automation.md#the-cdp-auth-gate-and-the-runtime-attach-workaround-that-beats-it).

## Grounding probe

`grounding-probe.ts` is a separate entry-point — not a Playwright spec —
that connects to a live Claude Desktop and dumps the runtime state
backing the load-bearing claims in
[`docs/testing/cases/`](../../docs/testing/cases/). It exists because
static grep against the 546k-line beautified bundle has known blind
spots (lazy `import()`s, dynamic handler tables, conditional wiring),
and some claims (S26 autoUpdater gate, S20 powerSaveBlocker path) can
only be verified at runtime.

```sh
# Self-contained: launchClaude() + capture + tear down
npm run grounding-probe -- --launch

# Plus the one synthetic probe (powerSaveBlocker start+stop)
npm run grounding-probe -- --launch --include-synthetic

# Attach to an already-running app (manual --inspect=9229 setup)
npm run grounding-probe -- --port 9229 --out /tmp/probe.json
```

Output is keyed by test ID — see the file's header comment for the
full table. Diff captures across upstream version bumps to spot
behavior drift the static sweep would miss. Surfaces inside modals
or popups (T22 PR toolbar, T26 preset list, T31 side chat, T32 slash
menu) need the surface open at probe time — the AX-tree fingerprint
is a snapshot of what's currently on screen.

## Known limitations
- **T04** uses `xprop` (no `xdotool` dependency — walks `_NET_CLIENT_LIST` + `_NET_WM_PID`). Works on X11 native and KDE Wayland (XWayland), **not** on native-Wayland sessions where the app is running through Ozone-Wayland directly. Per Decision 6, project default is X11; native-Wayland window-state queries are deferred until those tests get added.
- **T17** is shallow — it intercepts `dialog.showOpenDialog` at the Electron main process level. The integration question "does Claude make the right *portal* call?" is a v2 concern; portal-level mocking via `dbus-next` is sketched in [`docs/testing/automation.md`](../../docs/testing/automation.md) but requires displacing the running portal service or running under `dbus-run-session`.
- **`render-matrix.sh`** isn't here yet. `sweep.sh` prints a summary; the `matrix.md` regen step from JUnit is the next addition.
- **No CI wrapper.** Decision 4: the harness is invokable from CI but sweeps run from the dev box for the first ~20 tests.

## Adding a test

1. Pick the `T##` / `S##` from [`docs/testing/cases/`](../../docs/testing/cases/).
2. Drop `src/runners/T##_short_name.spec.ts`. Use the existing five as templates — match the layer (L1 / L2) to the test's assertion shape.
3. First line of the test body: `skipUnlessRow(testInfo, ['KDE-W', ...])`. JUnit `<skipped>` → matrix `-`, never `✗` for a row that doesn't apply.
4. Tag the test with `severity` and `surface` annotations so the JUnit output carries them.
5. Capture diagnostics via `testInfo.attach()` — these become Decision 7 "always-on" captures regardless of pass/fail. For tests that need richer state on failure, wrap your scenarios in a results-collector and attach a single JSON dump (S31's pattern).
6. No fixed `sleep`s. Use `retryUntil` or Playwright's auto-wait.

### Hooking Electron — read this before reaching for `BrowserWindow`

`scripts/frame-fix-wrapper.js` returns the `electron` module wrapped
in a `Proxy` whose `get` trap returns a closure-captured
`PatchedBrowserWindow`. **Constructor-level wraps don't work** — your
`electron.BrowserWindow = WrappedCtor` write lands on the underlying
module but the Proxy keeps returning `PatchedBrowserWindow` on
read, so the wrap is bypassed. The reliable hook is at the
**prototype-method level**:

```ts
// in inspector.evalInMain(...)
const proto = electron.BrowserWindow.prototype;
const orig = proto.loadFile;
proto.loadFile = function(filePath, ...rest) {
  // record `this` + filePath; identify popups by filePath suffix
  return orig.call(this, filePath, ...rest);
};
```

This captures every instance regardless of subclass identity.
Construction-time options (`transparent: true`, `frame: false`,
etc.) aren't observable through this hook — use runtime
equivalents instead (`getBackgroundColor()`, `getContentBounds()
vs getBounds()`, `isAlwaysOnTop()`). `lib/quickentry.ts` is the
worked example.
