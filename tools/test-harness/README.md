# Linux Compatibility Test Harness

In-VM (or on-host) Playwright + DBus runner for the test cases under
[`docs/testing/cases/`](../../docs/testing/cases/). See
[`docs/testing/automation.md`](../../docs/testing/automation.md) for the
architecture, decisions, and rationale.

## Status

First vertical slice — covers four tests on KDE-W:

| Test | What it checks | Layer |
|------|----------------|-------|
| [T01](../../docs/testing/cases/launch.md#t01--app-launch) | Main window opens within 10s; launcher log mentions X11/XWayland on Wayland sessions | L1 + L2 |
| [T03](../../docs/testing/cases/tray-and-window-chrome.md#t03--tray-icon-present) | A `StatusNotifierItem` is registered by the claude-desktop pid | L2 (DBus) |
| [T04](../../docs/testing/cases/tray-and-window-chrome.md#t04--window-decorations-draw) | Window has `_NET_FRAME_EXTENTS` (sum > 0) and a "Claude" title | L2 (xprop only — walks `_NET_CLIENT_LIST` + `_NET_WM_PID`) |
| [T17](../../docs/testing/cases/code-tab-foundations.md#t17--folder-picker-opens) | Renderer triggers `dialog.showOpenDialog` (shallow v1; portal mock is v2) | L1 (Electron-level intercept) |

These four exercise every distinct shape of TS code in the harness:
`playwright-electron`, `dbus-next`, shell-out helpers (`xprop`), and
Electron-main-process intercepts. Everything beyond them should be
recombination.

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

## Known limitations (v1)

- **`_electron.launch()` currently fails on this build.** First-run finding from KDE-W: Playwright spawns Electron with `--inspect=0 --remote-debugging-port=0`, the Node-inspector ws connects, Frame Fix reports "Patches built successfully", then the inspector ws disconnects (code 1006) before the renderer ever advertises its DevTools port. Playwright concludes the launch failed and kills the process. Standalone `electron --inspect=0 ... app.asar` (same flags, no Playwright) runs cleanly and shows "Starting app" + window creation, so the failure is specific to Playwright's launch flow under Electron 41 + Frame Fix. Open question: is this a Playwright/Electron 41 compatibility regression, or is something in `index.pre.js` reacting to Playwright's startup signal injection? The harness scaffolding (TS lib, runners, orchestrator) is otherwise sound — L2 tests (T03 tray, T04 window decorations) don't depend on Playwright owning the process and could run by spawning Electron via `child_process` and using `dbus-next` / `xprop` directly. Switching the launch path to `chromium.connectOverCDP()` against an externally-spawned Electron with a fixed `--remote-debugging-port` is the most likely workaround. See `electron.ts` comments.
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
