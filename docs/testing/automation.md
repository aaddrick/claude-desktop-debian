# Automation Plan (Draft)

*Last updated: 2026-04-30*

> **Status:** Draft / brainstorm capture. Not committed direction. The [Open
> questions](#open-questions--decisions-needed) section at the end lists the
> decisions still owed before any of this lands as a working harness. Edit
> freely; this file is meant to be argued with.

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
   formats. Input injection on Wayland is genuinely different from X11.
3. Many failures are environment-specific by construction (mutter XWayland
   key-grab, BindShortcuts on Niri, Omarchy Ozone-Wayland env exports). A
   single "run everything everywhere" harness will mis-skip those.

## The three layers

Looking at the corpus, every test falls into one of three buckets, and each
bucket wants a different tool:

| Layer | What it covers | Tool | Where it runs |
|-------|----------------|------|---------------|
| **L1 — Renderer** | Code tab, plugin install, settings, prompt area, slash menu, side chat, most of `ui/code-tab-panes.md`, `prompt-area.md`, `settings.md` | `playwright-electron` (`_electron.launch()`) | In-VM |
| **L2 — Native / OS** | Tray (DBus), window decorations, URL handler (`xdg-open`), autostart, `--doctor`, multi-instance, hide-to-tray, native file picker | Shell + `gdbus` + `xprop` / compositor IPC + `dogtail` for AT-SPI dialogs | In-VM |
| **L3 — Manual forever** | "Icon is crisp on HiDPI", drag-and-drop feel, T28 catch-up after suspend (real wall-clock), subjective UX checks | Human eyes | Local sweep |

The `runner:` field [`README.md`](./README.md) hints at is the right unit.
One file per test under `tools/test-runners/`, free to be `.ts` (Playwright)
or `.sh` (shell + DBus) or `.py` (dogtail), each emitting JUnit XML. Tests
without a `runner:` field stay manual indefinitely — that's a feature, not a
TODO.

## Architecture

The simplest shape that holds up:

```
host (orchestrator)              per-row VM (or Nobara host for KDE-W)
─────────────────────            ──────────────────────────────────────
tools/sweep.sh         ssh →     tools/test-harness/run.sh
                                   ├── L1 runners  (playwright-electron)
                                   ├── L2 runners  (gdbus / xprop / dogtail)
                                   └── junit.xml + diagnostic bundle
tools/render-matrix.sh ← scp     /tmp/results-${ROW}-${DATE}.tar.zst
matrix.md (regenerated)
```

The orchestrator is dumb: copy artifact in, kick the harness, copy results
out. Per-row variation lives in `tools/test-images/${ROW}/` (image build
recipe + cloud-init / Nix config). The harness inside each VM is the same
checked-in code, branched on `XDG_CURRENT_DESKTOP` / `XDG_SESSION_TYPE` for
env-specific helpers.

Result format pivots on **JUnit XML** — well-trodden ground. Several actions
already exist that turn JUnit into Markdown summaries
([`junit-to-md`](https://github.com/davidahouse/junit-to-md), the
[Test Summary Action](https://github.com/marketplace/actions/junit-test-dashboard)).
The matrix-regen step is just "merge per-row JUnit, render cells, commit."

### Why not drive Playwright over the wire?

The obvious sketch is "orchestrator on the host opens a CDP / DevTools port
on each VM and runs the whole suite from one place." It looks clean but has
real costs:

- CDP over network is fragile; port forwards are a constant footgun on
  flaky links.
- Doesn't help with L2 at all — `gdbus`, `xprop`, `pgrep`, file-system
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
- Locator policy: `getByRole`, `getByLabel`, `getByText` only. No CSS
  selectors against minified class names — they rot every upstream release.
  Where upstream's renderer needs a `data-testid`, inject it in
  `scripts/patches/app-asar.sh` at build time. ([Open question 5](#open-questions--decisions-needed).)
- Use Playwright auto-wait. No fixed `sleep`s. Shell-side runners get a
  lint rule for `\bsleep\s+[0-9]+\b`.

### L2 — Shell + DBus + AT-SPI

- **Tray / SNI state:** existing `gdbus` recipes from
  [`runbook.md`](./runbook.md#tray--dbus-state-kde) — direct conversions to
  test runners.
- **Window state:** `xprop` on X11; `wlr-foreign-toplevel-management` for
  wlroots; KWin DBus for KDE Wayland. Each compositor's native IPC beats
  trying to find one cross-compositor hammer.
- **Native file picker (T17), portal dialogs, GTK/Qt menus outside the
  Electron frame:** [`dogtail`](https://pypi.org/project/dogtail/) drives
  AT-SPI. Works on GTK and Qt. Wayland coordinates come via
  `gnome-ponytail-daemon`. Requires `app.setAccessibilitySupport(true)` in
  the CI build (or auto-enabled when AT-SPI requests the tree).
- **Process state:** `pgrep -af claude-desktop`, parse launcher log,
  inspect `~/.config/Claude/SingletonLock`.

### Input injection — `ydotool` now, `libei` next

- [`ydotool`](https://github.com/ReimuNotMoe/ydotool) goes through
  `/dev/uinput`, so it works on both X11 and Wayland. Needs root or a
  `uinput` group; not a problem inside a test VM.
- Portal-grabbed shortcuts (T06, S11, S14) `ydotool` **cannot** trigger.
  That's a kernel-vs-compositor boundary issue, not a tool gap.
- The future-correct path is
  [`libei`](https://www.phoronix.com/news/LIBEI-Emulated-Input-Wayland) +
  the `RemoteDesktop` portal via
  [`libportal`](https://github.com/rustdesk/rustdesk/discussions/4515) —
  KDE, GNOME, and wlroots are all moving there. Worth flagging in the
  roadmap that the shortcut tests have a path to automation, just not
  today.

### VM lifecycle

- One image-build recipe per row in `tools/test-images/${ROW}/`. Packer
  or Vagrant for the imperative distros (Fedora, Ubuntu, OmarchyOS), Nix
  flake for `Hypr-N`.
- Rebuild nightly or per release-tag sweep — don't `apt update` /
  `dnf update` inside a test run; mirrors hiccup, tests go red for the
  wrong reason.
- Each test gets a hermetic `XDG_CONFIG_HOME` / `CLAUDE_CONFIG_DIR` (S19
  is already the test-isolation primitive). No shared state between
  tests.

## Notable shifts since the existing roadmap was written

These three changed the landscape in 2025 and the existing
[`README.md`](./README.md) Automation roadmap section predates them:

1. **Electron 38+ defaults to native Wayland.** [Electron 38 release
   notes](https://www.electronjs.org/blog/electron-38-0) and the
   [Wayland tech talk](https://www.electronjs.org/blog/tech-talk-wayland)
   document this. Electron now has a Wayland CI job upstream.
   Implication for the matrix: S07's "`CLAUDE_USE_WAYLAND=1` opt-in path"
   framing is now backwards — the test should be "Electron defaults to
   native Wayland; opt-out works." A new T-test asserting which backend
   the launcher log actually picked is probably warranted.
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
| Async-wait by `sleep` | `sleep 5` instead of `waitFor`; ICSE 2021 found ~45% of UI flakes here | No fixed sleeps in `tools/test-runners/`. Always poll a condition (window exists, log line, DBus name owned). Lint for `\bsleep\b` in test scripts |
| Mixing orchestration with verification | One test installs the package, launches, checks tray, asserts URL handler — five failure modes, one red cell | One test, one assertion class. Setup goes in shared fixtures, not test bodies |
| End-to-end as the only layer | All regressions caught at full-stack UI level | Keep `scripts/patches/*.sh` independently testable; add unit-level tests on patcher logic separately from the full-app sweep |
| Implementation-coupled selectors | `div.css-7xz92q` deep selectors against minified renderer classes | `getByRole` / `getByLabel` / `getByText` only. Inject `data-testid` via `app-asar.sh` if needed; never depend on minified names |
| Timing-sensitive assertions | "Within 500ms after click, X appears" | Time bounds are upper-bound sanity only. Use Playwright's auto-wait with a generous `timeout`; don't fight the framework |
| Hidden global state across tests | Test 4 fails because test 2 left `~/.config/Claude/SingletonLock` behind | Hermetic per-test `XDG_CONFIG_HOME` / `CLAUDE_CONFIG_DIR` (S19). Treat shared state as an isolation bug, not a known quirk |
| Long-lived VM state drift | Six-month-old snapshot has stale package mirrors; tests fail with 404s | Image rebuild as code; rebuild nightly or per release-tag. Never `apt update` mid-test |
| Treating skip as fail | wlroots-only test fails on KDE because it can't be skipped properly | `?` and `-` are first-class in [`matrix.md`](./matrix.md). Map JUnit `<skipped>` → `-`, `<error>` (harness broke) → `?`, only `<failure>` → `✗` |
| Diagnostics only on failure | Test goes red; capture fires; previous green run had no baseline to diff against | Capture `--doctor`, launcher log, screenshot **on every run**. Retain last N greens on main; reds forever |
| Network coupling | "Tray icon present" fails because Cloudflare hiccupped during sign-in | Tests that don't *need* network shouldn't touch it. Sign-in is one fixture; tray test runs on a pre-signed-in profile snapshot |

## What stays manual (for now)

These have no automation path that's worth the cost today, and that's
honest to call out in the roadmap rather than pretending they'll be
automated "soon":

- T06 / S11 / S14 — global shortcut tests behind portal grabs. Path
  exists (libei + RemoteDesktop portal) but compositor-side support is
  patchy.
- T15 — sign-in browser handoff. Needs a fixture account and an upstream
  auth flow that won't necessarily welcome scripted login.
- T28 — scheduled task catch-up after suspend. Real wall-clock event;
  not worth simulating.
- Anything in `ui/` tagged "looks right" — HiDPI sharpness, theme
  rendering, drag-feel. AT-SPI sees the tree, not the pixels.

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
language, JUnit emission, results-bundle layout, matrix-regen rules,
diagnostic-capture format. Resist building the orchestrator before
there's a passing test it can orchestrate. Once the slice is real,
adding tests 2–10 is mostly mechanical.

## Open questions / decisions needed

These are the calls that need an explicit answer from @aaddrick before
any of this becomes code. Each one shapes a different chunk of the
harness; I've tried to put a recommendation next to each but they're
all real tradeoffs:

1. **Three languages or one?** The L1/L2/L3 split implies TS (Playwright)
   + bash (DBus probes) + Python (dogtail). Cleaner conceptually,
   harder to maintain. Alternative: TS for L1 only, bash for L2+L3
   (skip dogtail / accept that T17 stays manual). My lean: accept
   three languages — the cost is real but the corpus genuinely needs
   it.
2. **Where does the harness live?** `tools/test-harness/` (sibling to
   `scripts/`) or under `docs/testing/runners/` (closer to the specs)?
   I'd lean `tools/test-harness/` — keeps `docs/` documentation-only.
3. **Image build recipes — Packer, Vagrant, or "ad-hoc + checked-in
   docs"?** Real tradeoff. Packer gives you reproducibility but
   another tool to learn; ad-hoc is faster to start but rots.
4. **CI execution model.** Self-hosted runner with nested KVM? Or
   sweeps run on demand from the dev box, results pushed via PR? GHA
   nested KVM is slow enough that per-PR sweeps probably aren't
   viable; a scheduled nightly + per-release-tag run feels right but
   I'd want your read.
5. **Inject `data-testid` upstream-side?** L1 tests are fragile against
   minified class names. Three options: (a) carry a `data-testid`
   injection patch in `scripts/patches/app-asar.sh` that survives
   upstream bumps, (b) request stable test IDs upstream, (c) accept
   selector fragility and budget for selector rot. I'd lean (a) — you
   already maintain a robust patch set, this is one more.
6. **Severity of the new "Electron defaults to Wayland" tests.** Worth
   a fresh T-test (or a couple) given the 38+ shift. Smoke or Should?
7. **Diagnostic retention policy.** Last N greens? All reds? On main
   only? Storage cost is real if every run captures screenshots.
8. **Where do JUnit XML outputs go?** Per-row artifact bundle in a
   release? Branch in this repo? Separate `claude-desktop-debian-test-history`
   repo? Affects how `matrix.md` regen reads them.

If you have answers (or partial answers) to any of those, the next step
is probably "pick the vertical slice (KDE-W + T01) and build it" — but
without those eight answers, even the slice has to make implicit
decisions on each, and I'd rather not.

## Sources

Background reading the brainstorm draws on. Linked here so the
recommendations have receipts:

### Electron testing & Playwright
- [Electron — Automated Testing](https://www.electronjs.org/docs/latest/tutorial/automated-testing) — official tutorial, recommends Playwright
- [Electron — Spectron Deprecation Notice](https://www.electronjs.org/blog/spectron-deprecation-notice) — Feb 2022 archive
- [Playwright — Electron class](https://playwright.dev/docs/api/class-electron)
- [Playwright — ElectronApplication class](https://playwright.dev/docs/api/class-electronapplication)
- [Testing Electron apps with Playwright and GitHub Actions (Simon Willison)](https://til.simonwillison.net/electron/testing-electron-playwright)
- [`spaceagetv/electron-playwright-example`](https://github.com/spaceagetv/electron-playwright-example) — multi-window Playwright + Electron example

### Wayland / X11 / input injection
- [Electron — Tech Talk: How Electron went Wayland-native](https://www.electronjs.org/blog/tech-talk-wayland)
- [Electron 38.0.0 release notes](https://www.electronjs.org/blog/electron-38-0)
- [PR #33355: fix calling X11 functions under Wayland](https://github.com/electron/electron/pull/33355)
- [LIBEI — Phoronix overview](https://www.phoronix.com/news/LIBEI-Emulated-Input-Wayland)
- [libei + RemoteDesktop portal — RustDesk discussion](https://github.com/rustdesk/rustdesk/discussions/4515)
- [`ydotool` README](https://github.com/ReimuNotMoe/ydotool)
- [`kwin-mcp` — KDE Plasma 6 Wayland automation tools](https://github.com/isac322/kwin-mcp)

### AT-SPI / dogtail
- [`dogtail` on PyPI](https://pypi.org/project/dogtail/)
- [Automation through Accessibility — Fedora Magazine](https://fedoramagazine.org/automation-through-accessibility/)
- [`dogtail/qecore` — Automation of Desktop Applications](https://dogtail.gitlab.io/qecore/doc_basic_automation.html)
- [AT-SPI — Linux Foundation wiki](https://wiki.linuxfoundation.org/accessibility/atk/at-spi/start)

### Anti-patterns / flaky tests
- [Playwright automation checklist to reduce flaky tests (TestDino)](https://testdino.com/blog/playwright-automation-checklist/)
- [Flaky Tests: The Complete Guide to Detection & Prevention (TestDino)](https://testdino.com/blog/flaky-tests/)
- [5 Test Automation Anti-Patterns (TestDevLab)](https://www.testdevlab.com/blog/5-test-automation-anti-patterns-and-how-to-avoid-them)
- [Software Testing Anti-patterns (Codepipes)](https://blog.codepipes.com/testing/software-testing-antipatterns.html)

### JUnit XML reporting
- [`junit-to-md`](https://github.com/davidahouse/junit-to-md)
- [Test Summary GitHub Action](https://github.com/marketplace/actions/junit-test-dashboard)
- [Test Reporter](https://github.com/marketplace/actions/test-reporter)
- [LiquidTestReports](https://github.com/kurtmkurtm/LiquidTestReports)

### CI / VM matrix
- [Transient — QEMU CI wrapper](https://www.starlab.io/blog/simple-painless-application-testing-on-virtualized-hardwarenbsp)
- [`cirruslabs/tart` — VMs for CI automation](https://github.com/cirruslabs/tart)

---

*This file will get folded into [`README.md`](./README.md) and
[`runbook.md`](./runbook.md) once the [Open
questions](#open-questions--decisions-needed) above have answers and the
plan is committed direction. For now: working notes.*
