# Linux Compatibility Test Harness

In-VM (or on-host) Playwright + DBus runner for the test cases under
[`docs/testing/cases/`](../../docs/testing/cases/). See
[`docs/testing/automation.md`](../../docs/testing/automation.md) for the
architecture, decisions, and rationale.

## Status

Sixteen specs wired; ten pass on KDE-W, five skip cleanly per spec
intent, T17 holds at the same selector-tuning point.

| Test | What it checks | Layer |
|------|----------------|-------|
| [T01](../../docs/testing/cases/launch.md#t01--app-launch) | X11 window with our pid appears within 15s; title matches `/claude/i` | L2 (xprop) |
| [T03](../../docs/testing/cases/tray-and-window-chrome.md#t03--tray-icon-present) | A `StatusNotifierItem` is registered by the claude-desktop pid | L2 (DBus) |
| [T04](../../docs/testing/cases/tray-and-window-chrome.md#t04--window-decorations-draw) | Window has `_NET_FRAME_EXTENTS` (sum > 0) and a "Claude" title | L2 (xprop) |
| [T17](../../docs/testing/cases/code-tab-foundations.md#t17--folder-picker-opens) | Inspector attach + dialog mock + Code tab nav — selector-tuning pending | L1 |
| [S09](../../docs/testing/cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate) | KDE-gate string present in bundled `index.js` (patch ran at build) | file probe |
| S12 | `--enable-features=GlobalShortcutsPortal` in Electron argv (GNOME-W only — currently a known-failing regression detector) | argv probe |
| [S29](../../docs/testing/cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity) | Popup opens when main is hidden-to-tray (lazy-create sanity) | L1 |
| [S30](../../docs/testing/cases/shortcuts-and-input.md#s30--quick-entry-shortcut-becomes-a-no-op-after-full-app-exit) | No new claude-desktop pid spawns after post-exit shortcut press | pgrep delta + ydotool |
| [S31](../../docs/testing/cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state) | Submit reaches new chat from visible / minimized / hidden-to-tray (QE-7/8/9) | L1 + ydotool |
| S32 | GNOME mutter stale-`isFocused()` regression (GNOME-W/Ubu-W only — known-failing today) | L1 + ydotool |
| [S33](../../docs/testing/cases/shortcuts-and-input.md#s33--quick-entry-transparent-rendering-tracked-against-bundled-electron-version) | Captures bundled Electron version against the #370 / electron#50213 bisect threshold | file read |
| [S34](../../docs/testing/cases/shortcuts-and-input.md#s34--quick-entry-shortcut-focuses-fullscreen-main-window-instead-of-showing-popup) | Popup does **not** appear when main is fullscreen (upstream contract) | L1 + ydotool |
| [S35](../../docs/testing/cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts) | Popup position persists across invocations *and* across app restart (two-launch test) | L1 + shared isolation handle + ydotool |
| S36 | Multi-monitor fallback — skip-on-single-monitor with documented `fixme` for the disconnect orchestration | display probe |
| S37 | Main-window destroy unreachable on Linux per close-to-tray override — documented skip | — |

These specs exercise five distinct shapes of TS code: `xprop`
shell-outs (T01, T04), `dbus-next` (T03), Node-inspector runtime-
attach (T17, S29-S35), `app.asar` content reads (S09, S33),
`/proc/$pid/cmdline` reads (S12), and pgrep-based pid deltas (S30).
The Quick Entry runners (S29-S35) all share the same primitive set:
`installInterceptor()` + `openAndWaitReady()` + scenario-specific
state setup. New QE variants are mostly recombinations of those.

The full sweep on KDE-W runs in ~2.2 minutes against the locally
installed claude-desktop with `CLAUDE_TEST_USE_HOST_CONFIG=1`
(signed-in claude.ai required for the submit-side Critical
assertions; default isolation skips those tests).

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
│       └── S37_quick_entry_popup_after_main_destroy.spec.ts
└── orchestrator/
    └── sweep.sh                   # row-aware harness invocation
```

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
