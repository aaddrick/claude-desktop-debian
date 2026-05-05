# Testing Runbook

*Last updated: 2026-05-03*

How to run a test sweep, capture diagnostics, file failures, and update [`matrix.md`](./matrix.md). For the test specs themselves, see [`cases/`](./cases/). For the automation harness, see [`automation.md`](./automation.md) and [`tools/test-harness/`](../../tools/test-harness/). For the grounding sweep workflow (verify case docs against the live build), see [Grounding sweep](#grounding-sweep) below.

## When to sweep

| Trigger | Scope | Rows |
|---------|-------|------|
| Release tag (`vX.Y.Z+claude...`) | Smoke set | KDE-W + Hypr-N (or Sway) |
| Release tag, monthly | Smoke + Critical | All active rows |
| Upstream Claude Desktop bump | Smoke set + [grounding sweep](#grounding-sweep) | KDE-W + one wlroots row |
| PR touching `scripts/patches/*.sh` | Tests in the affected surface (use surface tags in cases files) | KDE-W minimum |
| Bug report citing an env | The relevant test on the reporter's row | Just that row |

## Setup: VM matrix

Each non-host row in [`matrix.md`](./matrix.md) is a QEMU/KVM guest. Standard config:

- 4 GB RAM, 2 vCPU minimum
- virtio-gpu **with** `gl=on` (3D acceleration). On hybrid GPU hosts, pin `rendernode=/dev/dri/renderD129` (AMD); avoid renderD128 (NVIDIA, EGL init fails on aaddrick's laptop)
- 32 GB qcow2 disk
- Bridged networking
- Virgil 3D enabled where possible (helps WebGL detection in T12)

ISOs / images per row:

| Row | Source |
|-----|--------|
| Fedora 43 (KDE-W, KDE-X, GNOME, Sway, i3, Niri) | https://fedoraproject.org/spins/ for KDE/GNOME, https://fedoraproject.org/sericea/ for Sway, manual install for i3/Niri |
| Ubuntu 24.04 (Ubu) | https://ubuntu.com/download/desktop |
| OmarchyOS (Hypr-O) | https://omarchy.org |
| NixOS (Hypr-N) | https://nixos.org/download with Hyprland module |

For the host (KDE-W), test against Nobara directly — no VM needed.

## Setup: building the install candidate

```bash
# Build from the branch under test
./build.sh --build appimage --clean no
./build.sh --build deb --clean no
./build.sh --build rpm --clean no

# Or pull from CI artifacts for a tagged release
gh run download <RUN_ID> -n claude-desktop-deb-amd64
gh run download <RUN_ID> -n claude-desktop-rpm-amd64
gh run download <RUN_ID> -n claude-desktop-appimage-amd64
```

Drop the resulting `.deb` / `.rpm` / `.AppImage` into a shared folder mounted into each guest, or `scp` per-guest.

## Running a sweep: the standard loop

For each test in scope:

1. **Read the test spec** in `cases/<surface>.md` (or `ui/<surface>.md` for UI checklists). Note the `Severity`, `Steps`, and `Expected` sections.
2. **Execute the steps** as described.
3. **Compare against Expected.** Mark internally as `✓`, `✗`, `🔧`, or `?` (untested if you couldn't run it for env reasons; `-` if N/A).
4. **On `✗`**: capture the diagnostics from the test's `Diagnostics on failure` block (see [diagnostic capture](#diagnostic-capture) below). File an issue if one isn't already linked.
5. **Update [`matrix.md`](./matrix.md)** in a single PR per row per sweep, titled `test: <ROW> sweep YYYY-MM-DD`.

## Diagnostic capture

Standard captures referenced from test `Diagnostics on failure` blocks:

### `--doctor` output

```bash
claude-desktop --doctor 2>&1 | tee /tmp/doctor.txt
```

Or for AppImage:

```bash
./claude-desktop-*.AppImage --doctor 2>&1 | tee /tmp/doctor.txt
```

### Launcher log

```bash
cat ~/.cache/claude-desktop-debian/launcher.log
```

Truncate and re-run if the file is stale:

```bash
: > ~/.cache/claude-desktop-debian/launcher.log
claude-desktop 2>&1 | tee -a ~/.cache/claude-desktop-debian/launcher.log
```

### Session env

```bash
echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
echo "XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "DISPLAY=$DISPLAY"
echo "GDK_BACKEND=$GDK_BACKEND"
echo "QT_QPA_PLATFORM=$QT_QPA_PLATFORM"
echo "OZONE_PLATFORM=$OZONE_PLATFORM"
echo "ELECTRON_OZONE_PLATFORM_HINT=$ELECTRON_OZONE_PLATFORM_HINT"
```

### Tray / DBus state (KDE)

```bash
# List registered tray icons
gdbus call --session --dest=org.kde.StatusNotifierWatcher \
  --object-path=/StatusNotifierWatcher \
  --method=org.freedesktop.DBus.Properties.Get \
  org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems

# Find which process owns a connection
gdbus call --session --dest=org.freedesktop.DBus \
  --object-path=/org/freedesktop/DBus \
  --method=org.freedesktop.DBus.GetConnectionUnixProcessID ":1.XXXX"
```

### Portal availability (Wayland)

```bash
systemctl --user status xdg-desktop-portal
busctl --user tree org.freedesktop.portal.Desktop
```

### Suspend inhibitors

```bash
systemd-inhibit --list
```

### App version

```bash
claude-desktop --version
gh variable get CLAUDE_DESKTOP_VERSION
gh variable get REPO_VERSION
```

Always include the upstream version + project version in the issue body and the matrix-update commit message.

## Filing failures

Issue title format: `[<row>] <T## or S##>: <one-line symptom>`

Issue body template:

```markdown
**Test:** [T17 — Folder picker opens](./docs/testing/cases/code-tab-foundations.md#t17--folder-picker-opens)
**Environment:** GNOME (Fedora 43, Wayland)
**Project version:** v1.3.23+claude1.4758.0
**Upstream version:** 1.4758.0

## Steps
<paste from test spec>

## Expected
<paste from test spec>

## Actual
<observed behavior>

## Diagnostics
<--doctor output, launcher log, session env, anything else from the test's Diagnostics block>

## Notes
<any hypotheses, related PRs, recent regressions>
```

Link the issue back into [`matrix.md`](./matrix.md) on the affected cell using the standard format: `✗ #NNN`.

## Updating the matrix

One PR per sweep per row. Bundle every status change for that row into a single commit so the matrix history reads as a sequence of sweep events, not individual cell flips.

Commit message template:

```
test(<row>): sweep <YYYY-MM-DD> — <project_version>+claude<upstream_version>

- T01 ? → ✓
- T03 ? → ✓
- T05 ? → ✗ (filed #NNN)
- T17 ? → ✓
- ...
```

If the same sweep also turned up new tests worth adding, those go in a separate commit before the status update so the diff stays focused.

## Severity guidance for new tests

When adding a test to `cases/` or `ui/`, pick severity using these heuristics:

| Tier | Pick when | Example |
|------|-----------|---------|
| Smoke | First-launch experience; if this fails the app is unusable for normal users | T01 (app launch), T03 (tray), T16 (Code tab loads) |
| Critical | Feature is documented in upstream docs **and** breaks core workflows when broken | T22 (PR monitoring), T34 (connector OAuth), T17 (folder picker) |
| Should | Quality-of-life or documented edge case; users hit it but have a workaround | T28 (catch-up after suspend), S26 (auto-update vs apt) |
| Could | Niche, env-specific, or graceful-degradation checks | T39 (`/desktop` CLI N/A), S22 (computer-use toggle absent on Linux) |

When in doubt, file as **Should**. Smoke and Critical mean release gates — be conservative about adding gates.

## Adding a new test

1. Pick the right surface file in `cases/` (or create one with prior buy-in if no existing surface fits — don't sprinkle new files lightly).
2. Use the next free ID: highest `T##` + 1 for cross-env, highest `S##` + 1 for env-specific. Don't reuse retired IDs.
3. Follow the standard structure: `**Severity:**`, `**Surface:**`, `**Applies to:**`, `**Steps:**`, `**Expected:**`, `**Diagnostics on failure:**`, `**References:**`.
4. Add the row to [`matrix.md`](./matrix.md) with all-`?` initial state.
5. Mention the new test in the PR description so reviewers know to read the spec.

For UI checklist additions, append rows to the relevant `ui/<surface>.md` table. UI rows don't need `T##` / `S##` IDs — the surface file + element name is the identity.

## Automated runs

The harness at [`tools/test-harness/`](../../tools/test-harness/) drives any
test with a `runner:` field. As of 2026-04-30, that's T01, T03, T04, T17.

### Invoking a sweep

```sh
cd tools/test-harness
npm install                       # first time only
ROW=KDE-W ./orchestrator/sweep.sh
```

Output:

- `results/results-${ROW}-${DATE}/junit.xml` — the JUnit summary (one
  testsuite per `.spec.ts` file, with the test's annotations preserved as
  metadata).
- `results/results-${ROW}-${DATE}/test-output/<test>/` — per-test
  attachments (screenshots, launcher log, session env, frame extents,
  click-attempt diagnostics, etc.). Captured on every run, not just on
  failure (Decision 7).
- `results/results-${ROW}-${DATE}/html/` — Playwright's HTML report.
- `results/results-${ROW}-${DATE}.tar.zst` — bundled artifact for
  off-machine inspection (when `zstd` is available).

`sweep.sh` prints a summary line at the end:

```
summary: tests=4 failures=0 errors=0 skipped=1
```

### Translating results to the matrix

JUnit `<failure>` → `✗`, `<error>` (harness broke) → `?`, `<skipped>` →
`-` (when intentionally not applicable) or stays `?` (when the test
couldn't reach an assertion — common case for renderer tests that need
sign-in or selectors that haven't been tuned). For now this mapping is
manual: open `junit.xml`, update `matrix.md` cells, commit. A
`render-matrix.sh` to do this automatically is on the to-do list.

### Coexistence with manual tests

Tests without a `runner:` continue to flow through the manual loop above.
The matrix doesn't distinguish automated from manual cells — a `✓` is a
`✓` regardless of how it was produced. The `runner:` field on each case
makes the source-of-truth explicit per-test.

### Path through the CDP auth gate (why this works)

The shipped Electron exits if `--remote-debugging-port` is on argv
without a valid `CLAUDE_CDP_AUTH` token. Both `_electron.launch()` and
`chromium.connectOverCDP()` inject that flag. The harness sidesteps the
gate by spawning Electron clean and attaching the Node inspector via
`SIGUSR1` at runtime — same code path as `Developer → Enable Main
Process Debugger`. From there, main-process JS evaluation reaches the
renderer through `webContents.executeJavaScript()`. Full writeup:
[`automation.md`](./automation.md#the-cdp-auth-gate-and-the-runtime-attach-workaround-that-beats-it).

### Wayland-mode sweep

Default backend is X11-via-XWayland (matches `launcher-common.sh`'s
default). To sweep the suite under native Wayland, set
`CLAUDE_HARNESS_USE_WAYLAND=1`:

```sh
CLAUDE_HARNESS_USE_WAYLAND=1 ROW=KDE-W ./orchestrator/sweep.sh
```

Every `launchClaude()` swaps to the Wayland flag set
(`--ozone-platform=wayland` + WaylandWindowDecorations / IME / text-
input-version=3, mirroring `scripts/launcher-common.sh:132-139`) and
exports `CLAUDE_USE_WAYLAND=1` + `GDK_BACKEND=wayland` into the spawn
env. Per-launch overrides via `launchClaude({ extraEnv })` still win,
so a single test can opt back to X11 inside a Wayland-mode sweep.

Caveat: T04 (`_NET_FRAME_EXTENTS` xprop check) only works under
XWayland — native-Wayland sessions have no X11 client list, so T04
will skip with a "no X11 client list" diagnostic.

## Grounding sweep

Separate from the test sweep. Where the test sweep verifies *upstream
Linux compat behavior* against case specs, the grounding sweep
verifies *the specs themselves* against upstream behavior — making
sure the Steps and Expected fields haven't bit-rotted past what the
shipped build actually does. Run on every upstream `CLAUDE_DESKTOP_VERSION`
bump.

### Static pass

For each file under [`cases/`](./cases/), confirm every test's
`**Code anchors:**` field still resolves and the Steps/Expected match
behavior. The convention is documented in
[`cases/README.md`](./cases/README.md#anchor-scope) — anchors are
either upstream code (`build-reference/app-extracted/.vite/build/`),
wrapper scripts (`scripts/`), v7 walker inventory, or out-of-scope
(CLI binary, server-rendered SPA).

When a test drifts, edit Steps/Expected in place. When a feature is
gone from the build, prepend
`> **⚠ Missing in build X.Y.Z** — <note>. Re-verify after next
upstream bump.` under the test heading.

### Runtime pass

Run [`tools/test-harness/grounding-probe.ts`](../../tools/test-harness/grounding-probe.ts)
against the live build:

```sh
cd tools/test-harness
npm run grounding-probe -- --launch --include-synthetic \
  --out ../../docs/testing/cases-grounding-runtime.json
```

Captures runtime state for tests where static greps can't disambiguate
(IPC handler registry, `globalShortcut.isRegistered()` for known
accelerators, `app.getLoginItemSettings()`, `safeStorage`,
`autoUpdater.getFeedURL()`, SNI tray registration, AX-tree fingerprint
of whatever's on screen). Output is keyed by test ID — diff against
the previous version's capture to spot drift the static pass missed.

Surfaces inside modals or popups (T22 PR toolbar, T26 preset list,
T31 side chat, T32 slash menu) need the surface open at probe time.
Open the relevant view in the running app before re-running with
`--port 9229` (attach mode).
