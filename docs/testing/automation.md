# Automation Plan

*Last updated: 2026-04-30*

> **Status:** Direction agreed; first vertical slice scaffolded at
> [`tools/test-harness/`](../../tools/test-harness/) covering T01, T03, T04,
> T17 on KDE-W. The [Decisions](#decisions) table captures the calls
> already made; [Still open](#still-open) is the short list of things
> genuinely undecided. This file will fold into [`README.md`](./README.md)
> and [`runbook.md`](./runbook.md) once the harness has run a few real
> sweeps.

The [`README.md`](./README.md) automation roadmap is one paragraph. This file
is the longer version — what shape the harness takes, which tools fit which
tests, which anti-patterns to design against, and what to build first.

## Why this exists

The 67 tests in [`cases/`](./cases/) plus the 10 surfaces in [`ui/`](./ui/)
already have stable IDs, standardized bodies, and per-element checklists. That
structure is unusually friendly to automation — but only if the harness is
shaped to match the corpus, rather than the other way around. Three things
make that non-trivial:

1. The tests aren't homogeneous. Some are pure-renderer (Code tab), some are
   native-OS-level (tray, autostart, URL handler), some are visual/UX checks
   that probably stay manual forever.
2. The matrix is nine environments, four display servers, and two package
   formats. Input injection on Wayland is genuinely different from X11, and
   X11 is the project's default backend (Wayland-native is opt-in until
   portal coverage matures across compositors).
3. Many failures are environment-specific by construction (mutter XWayland
   key-grab, BindShortcuts on Niri, Omarchy Ozone-Wayland env exports). A
   single "run everything everywhere" harness will mis-skip those.

## Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Single language: TypeScript.** Every runner is `.ts`; OS tools are shelled out via `child_process` and wrapped as TS helpers. Python only as a last-resort escape hatch for AT-SPI cases that resist portal mocking. | Playwright Electron is JS-native (post-Spectron); `dbus-next` covers DBus end-to-end; portal mocking removes the dogtail dependency for most native-dialog tests. Three-language overhead doesn't pay back. |
| 2 | **Harness location: `tools/test-harness/`.** Sibling to `scripts/`. | Keeps `docs/testing/` documentation-only; matches the project's existing `tools/` / `scripts/` split. |
| 3 | **VM images: Packer for imperative distros + Nix flake for `Hypr-N`.** | Packer builds golden snapshots that boot fast and rebuild as code; Nix flake handles NixOS natively without a second wrapper. Vagrant's per-boot provisioning model is the wrong tradeoff for hermetic per-test snapshots. |
| 4 | **No CI infrastructure initially.** Harness is invokable from CI (orchestrator is a bash script with `ROW`, `ARTIFACT`, `OUTPUT_DIR` env vars), but sweeps run manually from the dev box for the first ~20 tests. CI wrapper comes after there's signal on which tests are stable enough to run unattended. | Avoids weeks of GHA / nested-KVM debugging for tests that aren't ready to be unattended. The bash orchestrator is the same code either way. |
| 5 | **Selectors: semantic locators only (`getByRole`, `getByLabel`, `getByText`).** No CSS classes against minified renderer output. No proactive `data-testid` injection patch. Escalate per-test only when a specific test proves unstable: first ask upstream for a stable `data-testid`; only carry an `app-asar.sh` patch if upstream declines. | Building selector-injection infrastructure up front is a guess at where rot will happen. Modern React apps usually have enough ARIA roles and visible text for `getByRole`/`getByText` to be durable. Measure before patching. |
| 6 | **X11-default verification is Smoke. Wayland-native characterization is Should.** Add a Smoke test asserting the launcher log shows X11/XWayland selected on each row (the project's release-gate behavior). Add per-row Should tests characterizing what happens if Electron's default Wayland selection is allowed — these are informational, not release-gating. | The project chose X11 default because portal `GlobalShortcuts` coverage is patchy. The new Wayland-default tests exist to map that landscape, not to gate releases on it. |
| 7 | **Diagnostic retention: last 10 greens + all reds, on `main` only.** Captures `--doctor`, launcher log, screenshot every run. Reds retained indefinitely; greens rotate. | Cheap regression-bisect baseline; bounded storage; reds are the things you actually need to look at six weeks later. |
| 8 | **JUnit XML lives as workflow-run artifacts.** Each sweep run uploads `results-${ROW}-${DATE}.tar.zst` containing JUnit + diagnostic bundle. Default 90-day retention, extend to 365 if needed. The matrix-regen step downloads the latest run's artifacts and updates `matrix.md` in a PR. | Zero new infrastructure; GH provides storage, lifecycle, auth. If cross-run analytics later require longer history, promote to a separate `claude-desktop-debian-test-history` repo *then* — not before there's signal on what to keep. |

## The three layers

Looking at the corpus, every test falls into one of three buckets, and each
bucket maps to a different shape of TS code (not a different language):

| Layer | What it covers | Implementation |
|-------|----------------|----------------|
| **L1 — Renderer** | Code tab, plugin install, settings, prompt area, slash menu, side chat, most of `ui/code-tab-panes.md`, `prompt-area.md`, `settings.md` | `playwright-electron` (`_electron.launch()`) directly |
| **L2 — Native / OS** | Tray (DBus), window decorations, URL handler (`xdg-open`), autostart, `--doctor`, multi-instance, hide-to-tray, native file picker (T17) | TS + `dbus-next` for DBus; `child_process` shell-outs wrapped as TS helpers (`xprop`, `wlr-randr`, `swaymsg`, `niri msg`, `pgrep`, `ydotool`); `dbus-next`-driven portal mocking for native-dialog tests |
| **L3 — Manual** | "Icon is crisp on HiDPI", drag-and-drop feel, T28 catch-up after suspend (real wall-clock), subjective UX checks | Human eyes; capture in [`runbook.md`](./runbook.md) sweep loop |

The `runner:` field [`README.md`](./README.md) hints at is the right unit.
One TS file per test under `tools/test-harness/runners/`, free to mix L1 and
L2 calls within a single test file. Tests without a `runner:` field stay
manual indefinitely — that's a feature, not a TODO.

## Architecture

```
host (orchestrator)              per-row VM (or Nobara host for KDE-W)
─────────────────────            ──────────────────────────────────────
tools/sweep.sh         ssh →     tools/test-harness/run.ts
                                   ├── L1 runners  (playwright-electron)
                                   ├── L2 runners  (dbus-next + shell-outs)
                                   └── junit.xml + diagnostic bundle
tools/render-matrix.sh ← scp     /tmp/results-${ROW}-${DATE}.tar.zst
matrix.md (regenerated)
```

The orchestrator is dumb: copy artifact in, kick the harness, copy results
out. Per-row variation lives in `tools/test-images/${ROW}/` (Packer recipe +
cloud-init / autoinstall, or a Nix flake for `Hypr-N`). The harness inside
each VM is the same checked-in TS code, branched on `XDG_CURRENT_DESKTOP` /
`XDG_SESSION_TYPE` for env-specific helpers.

Result format pivots on **JUnit XML** — well-trodden ground. Several actions
already exist that turn JUnit into Markdown summaries
([`junit-to-md`](https://github.com/davidahouse/junit-to-md), the
[Test Summary Action](https://github.com/marketplace/actions/junit-test-dashboard)).
The matrix-regen step is just "download artifact, merge per-row JUnit, render
cells, commit a PR."

### Why not drive Playwright over the wire?

The obvious sketch is "orchestrator on the host opens a CDP / DevTools port
on each VM and runs the whole suite from one place." It looks clean but has
real costs:

- CDP over network is fragile; port forwards are a constant footgun on
  flaky links.
- Doesn't help with L2 at all — DBus calls, `xprop`, `pgrep`, file-system
  probes still have to run in-VM.
- You'd end up maintaining two transports anyway, so the centralization
  win evaporates.

In-VM Playwright via `_electron.launch()` is the [official Electron
recommendation](https://www.electronjs.org/docs/latest/tutorial/automated-testing)
since Spectron was archived in Feb 2022. No remote debug port needed; it
spawns Electron directly and gives you a context.

## Toolchain choices per layer

### L1 — `playwright-electron`

- Spawn via `_electron.launch({ args: ['main.js'] })` — no `--remote-debugging-port`.
- Gate `nodeIntegration: true` and `contextIsolation: false` behind
  `process.env.CI === '1'` so tests get full main-process access without
  weakening production security. (Electron docs explicitly recommend this
  pattern.)
- **Locator policy: semantic only.** `getByRole`, `getByLabel`,
  `getByText`, `getByPlaceholder`. No CSS selectors against minified class
  names — they rot every upstream release. No `data-testid` infrastructure
  built up front; if a specific test proves unstable, first ask upstream
  for a stable `data-testid`, only carry an `app-asar.sh` patch as a last
  resort.
- Use Playwright auto-wait. No fixed `sleep`s anywhere in the harness.

### L2 — `dbus-next` + wrapped shell-outs

The unifying observation: most of L2 is either DBus (which `dbus-next`
handles natively from TS) or short subprocess invocations of OS tools
(which `child_process.exec()` handles, wrapped as a typed TS helper). No
parallel bash test scripts; the test code reads as TS.

- **DBus everywhere it applies.**
  [`dbus-next`](https://github.com/dbusjs/node-dbus-next) is actively
  maintained, has TypeScript typings, and is designed for Linux desktop
  integration. Replaces `gdbus call ...` invocations:
  - Tray / SNI state queries (`org.kde.StatusNotifierWatcher`,
    `org.freedesktop.DBus`).
  - Portal availability checks (`org.freedesktop.portal.Desktop`).
  - Suspend inhibitor inspection (`org.freedesktop.login1`).
  - AT-SPI introspection where actually needed
    (`org.a11y.atspi.*`).
- **Compositor / window-manager state via shell-out helpers.** No good
  Node bindings exist for `xprop`, `wlr-randr`, `swaymsg`, `niri msg` —
  but invoking them from `child_process.exec()` inside a TS helper is
  perfectly fine, and the test code stays unified:
  ```ts
  // tools/test-harness/lib/wm.ts
  export async function listToplevels(): Promise<Toplevel[]> { ... }
  ```
  Each helper is a thin typed wrapper; the test reads as TS, not
  bash-with-extra-steps.
- **Native dialogs (T17 folder picker, etc.) via portal mocking.** The
  `org.freedesktop.portal.FileChooser` interface is just DBus. For tests
  that exercise the *integration* (does Claude make the right portal call
  and handle the result?) — which is what T17 actually tests — register
  a mock backend over `dbus-next`, intercept the call, return a canned
  path. No real dialog ever renders. This is both faster and a more
  honest unit of test than driving a real chooser.
- **AT-SPI escape hatch.** For the rare test where portal mocking isn't
  enough (driving an *actual* GTK/Qt dialog tree), the fallback is a
  small Python [`dogtail`](https://pypi.org/project/dogtail/) script
  invoked via `child_process.exec()` — same shape as the other shell-out
  helpers, just Python on the other end. Today, T17 is the only test
  that might need this; portal mocking probably covers it. We adopt
  Python only when a specific test forces it, not speculatively.

### Input injection — `ydotool` now, `libei` next

- [`ydotool`](https://github.com/ReimuNotMoe/ydotool) goes through
  `/dev/uinput`, so it works on both X11 and Wayland. Needs root or a
  `uinput` group; not a problem inside a test VM. Invoked via the same
  `child_process` shell-out pattern — `tools/test-harness/lib/input.ts`.
- Portal-grabbed shortcuts (T06, S11, S14) `ydotool` **cannot** trigger.
  That's a kernel-vs-compositor boundary issue, not a tool gap. Those
  tests stay manual until libei is widely available.
- The future-correct path is
  [`libei`](https://www.phoronix.com/news/LIBEI-Emulated-Input-Wayland) +
  the `RemoteDesktop` portal via `libportal`. KDE, GNOME, and wlroots
  are all moving there. Worth a roadmap note that the shortcut tests
  have a path to automation — just not today.

### VM lifecycle

- One image-build recipe per row in `tools/test-images/${ROW}/`. Packer
  for the imperative distros (Fedora 43, Ubuntu 24.04, OmarchyOS, and
  manual-install rows like i3 / Niri); Nix flake for `Hypr-N`.
- Rebuild nightly or per release-tag sweep — don't `apt update` /
  `dnf update` inside a test run; mirrors hiccup, tests go red for the
  wrong reason.
- Each test gets a hermetic `XDG_CONFIG_HOME` / `CLAUDE_CONFIG_DIR`
  (S19 is already the test-isolation primitive). No shared state
  between tests.

## The CDP auth gate

*Discovered during the first KDE-W run-through (commit `3ffd762` and follow-on).*

The shipped `index.pre.js` contains an authenticated-CDP gate:

```js
uF(process.argv) && !qL() && process.exit(1);
```

Where:
- `uF(argv)` matches `--remote-debugging-port` or `--remote-debugging-pipe` on argv
- `qL()` validates a token in `CLAUDE_CDP_AUTH` (signed payload `${timestamp_ms}.${base64(userDataDir)}`, ed25519 against a hardcoded public key, 5-minute TTL) plus a matching `CLAUDE_USER_DATA_DIR` env var

**If `--remote-debugging-port` is on argv and a valid token is not in env, the app exits with code 1 immediately after `frame-fix-wrapper` completes.** Both Playwright's `_electron.launch()` and `chromium.connectOverCDP()` inject `--remote-debugging-port=0`, so both trigger the gate. The signing key is held by upstream — we can't forge tokens locally.

Implication for this harness: **CDP-driven L1 testing is blocked until one of the following lands**:

1. **Upstream provides a signing token** scoped to test/CI use. Anthropic obviously has the key (they wrote the gate); the question is whether they'd issue dev/test tokens for a downstream packaging project. Worth asking — this is the cleanest answer if available.
2. **Carry an `app-asar.sh` patch that neutralizes the gate.** The project already maintains a robust patch set against minified upstream code (frame fix, autostart shim, hybrid topbar). One more `sed` replacing `process.exit(1)` in that line with `void 0` (or removing the gate entirely) is well within the project's existing pattern. Tradeoff: the patch needs to track upstream changes (variable names like `uF` and `qL` are minified and may rename), and it weakens upstream's deliberately-shipped security posture inside the *test* build — fine if the patch is gated behind a build flag, less fine if it leaks into release builds.
3. **Drive the renderer via accessibility (dogtail / AT-SPI).** Skips CDP entirely. The L3 escape-hatch already noted in Decision 1. More work, less reliable than CDP for arbitrary renderer assertions, but bypasses the gate cleanly.

**What the v1 harness does today** (no CDP, no gate trigger): spawn Electron without any debug-port flags and probe externally — `xprop` for window state, `dbus-next` for tray and portal calls. T01 verifies "an X11 window appeared with our pid" rather than "navigator.userAgent says X11"; T03/T04 are external-probe tests already; T17 stays skipped pending the v2 portal mock under `dbus-run-session`. This works for L2 entirely and gives L1 a smoke-test signal (window-exists), but renderer-internal assertions (which test IDs are present, which buttons are clickable, what the URL is) are unavailable.

This is genuine new information — the [Decisions](#decisions) table assumed Playwright would own L1. It can't, today. The split now is:

- **L2 today** — fully working (T03 tray, T04 frame extents, and any future DBus / xprop / portal-mock test).
- **L1 today** — limited to "process exists, X11 window appeared, window title matches" (T01).
- **L1 deeper** — blocked on the gate. Reopen Decision 1 / Decision 5 once we know which of the three options above the project takes.

## Notable shifts since the existing roadmap was written

These three changed the landscape in 2025 and the existing
[`README.md`](./README.md) Automation roadmap section predates them:

1. **Electron 38+ defaults to native Wayland.** [Electron 38 release
   notes](https://www.electronjs.org/blog/electron-38-0) and the
   [Wayland tech talk](https://www.electronjs.org/blog/tech-talk-wayland)
   document this. Electron now has a Wayland CI job upstream. The project
   keeps X11 as the default backend (Decision 6) because portal coverage
   for `GlobalShortcuts` is uneven across compositors — the new tests
   characterize what works where, not what to ship by default.
2. **Spectron is dead.** Archived Feb 2022; Playwright is the
   [official recommendation](https://www.electronjs.org/blog/spectron-deprecation-notice).
   No discussion needed about which framework — that's settled.
3. **`libei` is real and shipping.** KWin, mutter, and wlroots have all
   moved. The shortcut-test gap (T06 / S11 / S14) is automatable in the
   medium term, not "manual forever."

## Anti-patterns to design against

Pulled from the [Playwright flaky-test
checklist](https://testdino.com/blog/playwright-automation-checklist/),
the [Codepipes anti-patterns
catalogue](https://blog.codepipes.com/testing/software-testing-antipatterns.html),
and the [TestDevLab top 5
list](https://www.testdevlab.com/blog/5-test-automation-anti-patterns-and-how-to-avoid-them).
Designing the harness with these in mind from day one is much cheaper than
backing them out later:

| Anti-pattern | What it looks like | How to avoid in this project |
|---|---|---|
| Silent retry | Test passes on attempt 2; dashboard shows green; flake hidden | Log retry count to JUnit; `matrix.md` shows `✓*` for retried-pass; treat retried-pass as a Should-fix bug |
| Async-wait by `sleep` | `sleep 5` instead of `waitFor`; ICSE 2021 found ~45% of UI flakes here | No fixed sleeps in `tools/test-harness/`. Always poll a condition (window exists, log line, DBus name owned). Lint for `\bsleep\b` and `setTimeout` with literal numbers in test code |
| Mixing orchestration with verification | One test installs the package, launches, checks tray, asserts URL handler — five failure modes, one red cell | One test, one assertion class. Setup goes in shared fixtures, not test bodies |
| End-to-end as the only layer | All regressions caught at full-stack UI level | Keep `scripts/patches/*.sh` independently testable; add unit-level tests on patcher logic separately from the full-app sweep |
| Implementation-coupled selectors | `div.css-7xz92q` deep selectors against minified renderer classes | Decision 5: semantic locators only. If a selector proves unstable, first ask upstream for a stable `data-testid`; only carry an `app-asar.sh` patch as a last resort, per-test |
| Timing-sensitive assertions | "Within 500ms after click, X appears" | Time bounds are upper-bound sanity only. Use Playwright's auto-wait with a generous `timeout`; don't fight the framework |
| Hidden global state across tests | Test 4 fails because test 2 left `~/.config/Claude/SingletonLock` behind | Hermetic per-test `XDG_CONFIG_HOME` / `CLAUDE_CONFIG_DIR` (S19). Treat shared state as an isolation bug, not a known quirk |
| Long-lived VM state drift | Six-month-old snapshot has stale package mirrors; tests fail with 404s | Image rebuild as code (Packer / Nix flake); rebuild nightly or per release-tag. Never `apt update` mid-test |
| Treating skip as fail | wlroots-only test fails on KDE because it can't be skipped properly | `?` and `-` are first-class in [`matrix.md`](./matrix.md). Map JUnit `<skipped>` → `-`, `<error>` (harness broke) → `?`, only `<failure>` → `✗` |
| Diagnostics only on failure | Test goes red; capture fires; previous green run had no baseline to diff against | Decision 7: capture `--doctor`, launcher log, screenshot **on every run**. Last 10 greens + all reds on `main` |
| Network coupling | "Tray icon present" fails because Cloudflare hiccupped during sign-in | Tests that don't *need* network shouldn't touch it. Sign-in is one fixture; tray test runs on a pre-signed-in profile snapshot |

## What stays manual (for now)

These have no automation path that's worth the cost today, and that's
honest to call out in the roadmap rather than pretending they'll be
automated "soon":

- **T06 / S11 / S14** — global shortcut tests behind portal grabs. Path
  exists (libei + RemoteDesktop portal) but compositor-side support is
  patchy. Revisit when libei adoption broadens.
- **T15** — sign-in browser handoff. Needs a fixture account and an
  upstream auth flow that won't necessarily welcome scripted login.
- **T28** — scheduled task catch-up after suspend. Real wall-clock event;
  not worth simulating.
- **Anything in `ui/` tagged "looks right"** — HiDPI sharpness, theme
  rendering, drag-feel. AT-SPI sees the tree, not the pixels.

T17 (folder picker) was previously in this list. Portal mocking via
`dbus-next` moves it into L2. If real-dialog testing turns out to be
necessary anyway, the dogtail escape hatch covers it.

The matrix already supports leaving these manual via the `?` / `-` /
existing-cell semantics — no schema change needed.

## Suggested first vertical slice

The smallest end-to-end that proves every architectural decision:

- **One row:** KDE-W (daily-driver host, no VM startup tax).
- **One test:** T01 — App launch.
- **Full pipeline:** orchestrator glue → harness entry → Playwright
  `_electron.launch()` → JUnit XML → matrix-regen step → cell flips
  from `?` to `✓` automatically.

That single slice forces every decision out into the open: harness
language (TS), JUnit emission, results-bundle layout, matrix-regen
rules, diagnostic-capture format. Resist building the orchestrator
before there's a passing test it can orchestrate. Once the slice is
real, adding tests 2–10 is mostly mechanical.

After T01: the next sensible additions are T03 (tray — exercises
`dbus-next` end-to-end), T04 (window decorations — exercises the
shell-out helper pattern), and T17 (folder picker — exercises portal
mocking). Those four runners cover every distinct shape of TS code in
the harness; everything else after them is a recombination.

## Still open

Most of the framing decisions are settled in the [Decisions](#decisions)
table. What remains:

1. **Owner assignments per row.** [`MEMORY.md`](https://github.com/aaddrick/claude-desktop-debian/blob/main/.claude/projects/-home-aaddrick-source-claude-desktop-debian/memory/MEMORY.md)
   notes cowork → @RayCharlizard, nix → @typedrat. Hypr-N row is the
   natural fit for @typedrat once the Nix flake exists. The other eight
   rows: aaddrick by default, but worth asking the contributor base in a
   discussion thread.
2. **AT-SPI escape-hatch trigger.** Decision 1 punts on Python until a
   specific test forces it. T17 is the only candidate today, and portal
   mocking probably covers it. If T17 actually needs real-dialog
   automation, that's the first reopen.
3. **Selector rot rate.** Decision 5 starts with semantic locators and
   measures. After ~20 tests on the renderer, revisit whether
   `getByRole`/`getByText` is holding up or whether per-test
   `data-testid` patches are warranted. No prediction; this is a
   measure-and-decide.
4. **CI execution model.** Decision 4 punts on this entirely until the
   harness has signal on which tests are stable. Reopen after the first
   ~20 tests have run from the dev box for a few weeks.
5. **Smoke-set Wayland-default test wording.** Decision 6 calls for a
   Smoke test asserting X11/XWayland selection on each row, plus
   per-row Should tests for Wayland characterization. The exact T-IDs
   and case-file homes for those tests need to be drafted next time
   `cases/` is touched.

## Sources

Background reading the recommendations draw on. Linked here so the
calls have receipts:

### Electron testing & Playwright
- [Electron — Automated Testing](https://www.electronjs.org/docs/latest/tutorial/automated-testing) — official tutorial, recommends Playwright
- [Electron — Spectron Deprecation Notice](https://www.electronjs.org/blog/spectron-deprecation-notice) — Feb 2022 archive
- [Playwright — Electron class](https://playwright.dev/docs/api/class-electron)
- [Playwright — ElectronApplication class](https://playwright.dev/docs/api/class-electronapplication)
- [Testing Electron apps with Playwright and GitHub Actions (Simon Willison)](https://til.simonwillison.net/electron/testing-electron-playwright)
- [`spaceagetv/electron-playwright-example`](https://github.com/spaceagetv/electron-playwright-example) — multi-window Playwright + Electron example

### DBus / TypeScript
- [`dbus-next` — actively-maintained Node DBus library with TS typings](https://github.com/dbusjs/node-dbus-next)
- [`dbus-next` on npm](https://www.npmjs.com/package/dbus-next)

### Wayland / X11 / input injection
- [Electron — Tech Talk: How Electron went Wayland-native](https://www.electronjs.org/blog/tech-talk-wayland)
- [Electron 38.0.0 release notes](https://www.electronjs.org/blog/electron-38-0)
- [PR #33355: fix calling X11 functions under Wayland](https://github.com/electron/electron/pull/33355)
- [LIBEI — Phoronix overview](https://www.phoronix.com/news/LIBEI-Emulated-Input-Wayland)
- [libei + RemoteDesktop portal — RustDesk discussion](https://github.com/rustdesk/rustdesk/discussions/4515)
- [`ydotool` README](https://github.com/ReimuNotMoe/ydotool)
- [`kwin-mcp` — KDE Plasma 6 Wayland automation tools](https://github.com/isac322/kwin-mcp)

### Portals / AT-SPI
- [XDG Desktop Portal — main repo](https://github.com/flatpak/xdg-desktop-portal)
- [`org.freedesktop.portal.FileChooser` interface XML](https://github.com/flatpak/xdg-desktop-portal/blob/main/data/org.freedesktop.portal.FileChooser.xml)
- [File Chooser portal documentation](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html)
- [`dogtail` on PyPI](https://pypi.org/project/dogtail/) — fallback only
- [Automation through Accessibility — Fedora Magazine](https://fedoramagazine.org/automation-through-accessibility/)

### Anti-patterns / flaky tests
- [Playwright automation checklist to reduce flaky tests (TestDino)](https://testdino.com/blog/playwright-automation-checklist/)
- [Flaky Tests: The Complete Guide to Detection & Prevention (TestDino)](https://testdino.com/blog/flaky-tests/)
- [5 Test Automation Anti-Patterns (TestDevLab)](https://www.testdevlab.com/blog/5-test-automation-anti-patterns-and-how-to-avoid-them)
- [Software Testing Anti-patterns (Codepipes)](https://blog.codepipes.com/testing/software-testing-antipatterns.html)

### JUnit XML reporting
- [`junit-to-md`](https://github.com/davidahouse/junit-to-md)
- [Test Summary GitHub Action](https://github.com/marketplace/actions/junit-test-dashboard)
- [Test Reporter](https://github.com/marketplace/actions/test-reporter)

### CI / VM matrix
- [Transient — QEMU CI wrapper](https://www.starlab.io/blog/simple-painless-application-testing-on-virtualized-hardwarenbsp)
- [`cirruslabs/tart` — VMs for CI automation](https://github.com/cirruslabs/tart)

---

*Once the first vertical slice (KDE-W + T01) ships, the relevant pieces of
this file fold into [`README.md`](./README.md) (Automation roadmap) and
[`runbook.md`](./runbook.md) (the harness invocation). Until then: working
notes that have crossed from brainstorm to plan.*
