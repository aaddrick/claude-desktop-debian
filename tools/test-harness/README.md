# Linux Compatibility Test Harness

In-VM (or on-host) Playwright + DBus runner for the test cases under
[`docs/testing/cases/`](../../docs/testing/cases/). See
[`docs/testing/automation.md`](../../docs/testing/automation.md) for the
architecture, decisions, and rationale.

## Status

First vertical slice — covers four tests on KDE-W:

| Test | What it checks | Layer |
|------|----------------|-------|
| [T01](../../docs/testing/cases/launch.md#t01--app-launch) | An X11 window with our pid appears within 15s; title matches `/claude/i` | L2 (xprop) |
| [T03](../../docs/testing/cases/tray-and-window-chrome.md#t03--tray-icon-present) | A `StatusNotifierItem` is registered by the claude-desktop pid | L2 (DBus) |
| [T04](../../docs/testing/cases/tray-and-window-chrome.md#t04--window-decorations-draw) | Window has `_NET_FRAME_EXTENTS` (sum > 0) and a "Claude" title | L2 (xprop) |
| [T17](../../docs/testing/cases/code-tab-foundations.md#t17--folder-picker-opens) | Inspector attaches via SIGUSR1, dialog mock installs, claude.ai webContents reachable, Code tab nav succeeds — folder-picker click chain awaits selector tuning | L1 (inspector + main-process mock) |

These four exercise three distinct shapes of TS code in the harness:
`xprop` shell-outs (T01, T04), `dbus-next` (T03), and the Node inspector
runtime-attach + `webContents.executeJavaScript` (T17). Everything beyond
them should be recombination — pick the layer that matches the test's
assertion shape and reuse the existing helper.

## Prerequisites

On the host or VM running the sweep:

- Node.js ≥ 20
- `claude-desktop` installed (deb / rpm / AppImage), reachable via `claude-desktop` on `PATH` or `CLAUDE_DESKTOP_LAUNCHER` env var
- `xprop` (for L2 window queries — `dnf install xorg-x11-utils` on Fedora; `apt install x11-utils` on Debian/Ubuntu)
- `zstd` (optional — used to bundle results)

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
| `ROW` | `KDE-W` | Matrix row label, propagated into the bundle name and per-test annotations |
| `CLAUDE_DESKTOP_LAUNCHER` | `claude-desktop` (PATH lookup) | Path to the launcher / Electron binary Playwright spawns |
| `OUTPUT_DIR` | `./results` | Where bundles land |
| `RESULTS_DIR` | per-run derived | Single-run output dir (set by `sweep.sh`; usually you don't set this manually) |

## Layout

```
tools/test-harness/
├── package.json
├── tsconfig.json
├── playwright.config.ts
├── src/
│   ├── lib/                       # shared helpers
│   │   ├── electron.ts            # _electron.launch wrapper
│   │   ├── dbus.ts                # dbus-next session-bus + helpers
│   │   ├── sni.ts                 # StatusNotifierWatcher / Item
│   │   ├── wm.ts                  # xprop wrappers (X11 + XWayland)
│   │   ├── env.ts                 # XDG_CURRENT_DESKTOP / SESSION_TYPE branching
│   │   ├── retry.ts               # poll-until-true with timeout
│   │   └── diagnostics.ts         # launcher log, --doctor, session env
│   └── runners/                   # one .spec.ts per test ID
│       ├── T01_app_launch.spec.ts
│       ├── T03_tray_icon_present.spec.ts
│       ├── T04_window_decorations.spec.ts
│       └── T17_folder_picker.spec.ts
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
2. Drop `src/runners/T##_short_name.spec.ts`. Use the existing four as templates.
3. Tag the test with `severity` and `surface` annotations so the JUnit output carries them.
4. Capture diagnostics via `testInfo.attach()` — these become Decision 7 "always-on" captures regardless of pass/fail.
5. No fixed `sleep`s. Use `retryUntil` or Playwright's auto-wait.
