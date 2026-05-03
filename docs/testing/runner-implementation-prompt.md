# test-harness runner implementation — implementation prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

---

## Prompt to paste

You're picking up after the cases-grounding sweep, the
`grounding-probe.ts` runtime probe, and the `CLAUDE_HARNESS_USE_WAYLAND`
flag all landed. The case docs are now anchored to upstream code +
wrapper scripts and the harness can swap backends with one env var.
The next workstream is **wiring runners for the 61 of 76 tests that
still don't have one**.

Today the harness has 15 specs covering 4 of 39 cross-env tests (T01,
T03, T04, T17) and 11 of 37 env-specific tests (S09, S12, S29-S37
Quick Entry sweep) — plus 5 H-prefix harness self-tests. Everything
else is human-execution-only. The smoke set in
[`docs/testing/README.md`](docs/testing/README.md#smoke-set) lists T01,
T03, T04, T05, T07, T08, T11, T15, T16, T17 as the release gate; only
4 of those are wired. The rest of the gate goes through a manual
clicker.

This is too many to land in one session — don't try. Triage first,
land the cheap probes, get the single-launch wins, defer the rest
with explicit reasons. Optimise for **broad coverage of cheap
checks** over deep coverage of one renderer-heavy surface.

### Authoritative reference

Read these in order before fanning out:

- `docs/testing/cases/README.md` — case-doc structure and the four
  anchor scopes (upstream / wrapper / SPA / CLI). Each test you wire
  needs to either consume an existing anchor or surface a new one.
- `tools/test-harness/README.md` — runner conventions, the 5 distinct
  shapes of TS code already in `lib/` (xprop / dbus-next / inspector
  attach / `app.asar` reads / `/proc/$pid/cmdline` reads / pgrep), the
  isolation defaults, the CDP-gate workaround.
- `tools/test-harness/src/lib/` — the existing primitives. Most new
  runners are recombinations:
  - `electron.ts` — `launchClaude()`, `app.attachInspector()`,
    `app.waitForReady('window'|'mainVisible'|'claudeAi'|'userLoaded')`
  - `inspector.ts` — `evalInMain()`, `evalInRenderer()`,
    `getAccessibleTree()`, `clickByBackendNodeId()`
  - `claudeai.ts` — page-objects against the AX-tree substrate
  - `quickentry.ts` — shared QE primitives (`installInterceptor`,
    `openAndWaitReady`)
  - `sni.ts` — DBus StatusNotifierWatcher attribution by pid
  - `wm.ts` — xprop wrappers; `findX11WindowByPid`,
    `getNetFrameExtents`
  - `argv.ts` — `/proc/$pid/cmdline` flag check
  - `asar.ts` — in-place `app.asar` content reads (no temp extract)
  - `row.ts` — `skipUnlessRow()` / `skipOnRow()`
  - `diagnostics.ts` — launcher log + `--doctor` capture
- `tools/test-harness/src/runners/` — every existing spec is a
  template. Match the layer (L1 / L2 / file / argv / pid) to the
  test's assertion shape. Don't reinvent — `T17_folder_picker.spec.ts`
  for L1 click chains, `T03_tray_icon_present.spec.ts` for DBus,
  `T04_window_decorations.spec.ts` for xprop, `S33_electron_version_capture.spec.ts`
  for asar reads, `S12_global_shortcuts_portal_flag.spec.ts` for argv.
- `docs/testing/cases/*.md` — the spec each runner asserts. The
  **Code anchors:** field tells you exactly where upstream implements
  the feature.
- `CLAUDE.md` (project root) — code style, attribution, commit format.

### Tests in scope

The 61 missing runners, by source file:

| File | Missing |
|---|---|
| `launch.md` | T02, T13, T14 |
| `tray-and-window-chrome.md` | T07, T08, S08, S13 |
| `shortcuts-and-input.md` | T05, T06, S06, S07, S10, S11, S14 |
| `code-tab-foundations.md` | T15, T16, T18, T19, T20 |
| `code-tab-workflow.md` | T21, T22, T29, T30, T31, T32 |
| `code-tab-handoff.md` | T23, T24, T25, T34, T38, T39 |
| `routines.md` | T26, T27, T28, S19, S20, S21 |
| `extensibility.md` | T11, T33, T35, T36, T37, S27, S28 |
| `distribution.md` | S01, S02, S03, S04, S05, S15, S16, S26 |
| `platform-integration.md` | T09, T10, T12, S17, S18, S22, S23, S24, S25 |

### Why this iteration

The matrix today is mostly hand-driven. Each cell update requires a
human running through the case-doc steps on a VM and writing a status
into `matrix.md`. That's expensive enough that sweeps happen
infrequently and regressions sit longer than they should. A wider
runner net means more cells get refreshed automatically per release,
the human time goes to the renderer-heavy tests that genuinely need
it, and the Smoke + Critical gate stops being a manual-clicker
bottleneck on every tag.

This isn't one-session work — it's the start of a series. Optimise
for **landing what's tractable in this session and clearly handing
off the rest** with concrete next-steps per deferred test.

### Constraints to respect (don't violate)

- **Default isolation.** Every `launchClaude()` gets a fresh
  `XDG_CONFIG_HOME` sandbox, cleaned on `close()`. Tests that need a
  signed-in claude.ai must opt out via `launchClaude({ isolation: null })`
  AND gate themselves on `CLAUDE_TEST_USE_HOST_CONFIG=1`. Never write
  to the user's real config without that gate.
- **CDP auth gate is alive.** `_electron.launch()` and
  `chromium.connectOverCDP()` both inject `--remote-debugging-port`
  which exits the app. The harness uses `SIGUSR1` runtime-attach via
  `app.attachInspector()` — same code path as Developer → Enable Main
  Process Debugger. Don't try to use Playwright's electron launcher.
- **BrowserWindow Proxy gotcha.** `frame-fix-wrapper.js` returns the
  electron module wrapped in a Proxy. `electron.BrowserWindow.getAllWindows()`
  returns 0. Use `webContents.getAllWebContents()` instead. Constructor-
  level wraps don't take — use prototype-method hooks (see
  `docs/learnings/test-harness-electron-hooks.md`).
- **`skipUnlessRow()` always first.** First line of every `test()`
  body. JUnit `<skipped>` → matrix `-`, never `✗` for an
  inapplicable row.
- **No fixed sleeps.** `retryUntil` from `lib/retry.ts`, or
  Playwright's auto-wait. Fixed `sleep(N)` is a smell.
- **Diagnostics on every run** (Decision 7), not just failures.
  `testInfo.attach()` the launcher log, `--doctor` output, frame
  extents, click attempts, etc. Captured as JSON dumps for
  multi-state tests (S31 pattern).
- **Tag with annotations.** `severity:` and `surface:` annotations on
  every test so JUnit carries them through to matrix-regen.
- **Tabs in TS, ~80-char wrap as the existing files do.** Match the
  surrounding style.
- **Don't break existing runners.** `npm run typecheck` must stay
  clean. Run the full `npm test` against KDE-W if you have access;
  if not, document the verification path in your report.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass; if
   not, stop and report.
2. Read `tools/test-harness/README.md` end-to-end and one full runner
   (suggest `T04_window_decorations.spec.ts` — small, file probe
   adjacent, easy to follow). Confirm you understand the spec
   contract before fanning out.
3. Pick T02 (doctor exit code) as a calibration runner. Read
   `docs/testing/cases/launch.md` T02, find the existing anchors in
   `scripts/doctor.sh`, sketch a runner in your head: spawn
   `claude-desktop --doctor`, assert `exit code === 0`, attach the
   stdout. ~30 lines. Don't write it yet — just confirm you can plan
   the shape from the spec.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
spec contract not understood), stop and report. Don't fan out
subagents against an unverified workflow.

#### Phase 1 — triage

Spawn ONE subagent (`subagent_type: 'general-purpose'`) that reads
every case file in scope and produces a **tiered runner-implementation
plan**. Plan output goes to
`docs/testing/runner-implementation-plan.md` (new file) with this
shape:

```markdown
## Tier 1 — File / spawn / argv probes (~30min-1hr each)
No app launch needed (or single short-lived spawn). Existing
primitives suffice.
- T02 — `claude-desktop --doctor` exit-code probe. Reuse: lib/diagnostics.ts.
- T13 — same as T02 but parse the package-format line.
- S01 — DEB control file `Depends:` field empty (read post-build).
- S02 — distro substring matching in launcher (asar/script grep).
- ...

## Tier 2 — Single-launch probes (~2-3hrs each)
One launchClaude() + inspector attach. Existing primitives suffice.
- T05 — URL handler `claude://` registered. Verify via xdg-mime + spawn.
- T06 — Quick Entry shortcut registered. globalShortcut.isRegistered().
- ...

## Tier 3 — Multi-step or login-required (~4-8hrs each)
Need claude.ai signed in (CLAUDE_TEST_USE_HOST_CONFIG=1) or multi-
launch state. Defer to follow-up sessions.
- T15 — sign-in flow. Needs OAuth provider mock or live login.
- T16 — Code tab loads. Needs login.
- ...

## Tier 4 — Out of scope or blocked
- T39 — /desktop is the CLI `claude` binary, not the Electron asar.
- S26 — gated on #567 (autoUpdater no-op patch).
- T11, T33 — plugin install needs real plugin + network.
- ...
```

The triage subagent's job is **only** to classify each test into a
tier and record reasoning. No runner code yet.

#### Phase 2 — Tier 1 fan-out

Once the plan is in `docs/testing/runner-implementation-plan.md`, spawn
**one subagent per Tier 1 test** in parallel. Per-subagent prompt:

```
You're implementing ONE test-harness runner for <TEST-ID> in
docs/testing/cases/<FILE>.md.

Read in order:
- docs/testing/cases/<FILE>.md (the spec — focus on the <TEST-ID>
  section, including its Code anchors)
- tools/test-harness/README.md (conventions)
- tools/test-harness/src/runners/<closest-existing-template>.spec.ts
- CLAUDE.md (project conventions)

Write tools/test-harness/src/runners/<TEST-ID>_short_name.spec.ts.
Match the closest template. First line of the test body:
skipUnlessRow(testInfo, ['<rows-this-applies-to>']) per the spec's
Applies to field.

Constraints:
- Tabs, ~80-char wrap.
- Use lib/* primitives; don't reinvent.
- testInfo.attach() the diagnostics from the spec's Diagnostics on
  failure block.
- Tag with severity + surface annotations.
- No fixed sleeps. retryUntil or Playwright auto-wait.
- npm run typecheck must stay clean after your edits.
- Don't commit. The user reviews and commits.

If the test isn't reasonable to implement (the case anchors don't
resolve to anything assertable, the test depends on state you can't
construct, the existing primitives don't cover the surface), DO NOT
write a stub. Report under Open questions and stop.

Report shape (~150 words):
## <TEST-ID> runner

- File written: tools/test-harness/src/runners/<filename>.spec.ts
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) | pgrep
- Assertion shape: <what the test asserts in one sentence>
- Skip rules: <which rows are skipped + why>
- Verification path: <how the user verifies this runs cleanly>
- Open questions: <any caveats>
```

Send Tier 1 subagents in parallel — they're independent, each owns
one runner file. Cap at ~10 subagents at a time to keep the
fan-out manageable.

#### Phase 3 — Tier 2 fan-out

Same shape as Phase 2 but for Tier 2 tests. Single-launch probes are
heavier (each subagent does a full launchClaude() + assertion design)
so cap at ~6 subagents in parallel.

If a Tier 2 subagent hits a blocker that pushes the test into Tier 3
mid-implementation, stop the subagent — don't ship a stub. The
synthesis step will reclassify.

#### Phase 4 — synthesis

Once Tier 1 + Tier 2 land:

1. `cd tools/test-harness && npm run typecheck` — must be clean.
2. Run the new runners against KDE-W if you have access:
   `ROW=KDE-W npx playwright test src/runners/T02_*.spec.ts ...` —
   capture which pass cleanly and which need selector tuning.
3. Write a final report at the end of the session listing:
   - Runners landed (pass / skip / needs-tuning per row)
   - Tier 3 deferred (with the per-test rationale from the plan)
   - Tier 4 out-of-scope (with reasons)
   - Updated coverage stat (was 15/76 = 20%, now N/76 = M%)
4. Don't commit. The user reviews and commits.

### Self-correction loop

After Phase 2 / Phase 3 returns:

1. If a subagent's runner fails typecheck, re-spawn with explicit
   instruction to read the typecheck error and fix it (often a missing
   import or stale type from a renamed primitive).
2. If a subagent claimed a runner exists but `git status` shows no
   new file, the subagent silently dropped the write — re-spawn with
   explicit "use the Write tool" instruction.
3. If two subagents wrote runners that share a primitive but with
   slightly different shapes, refactor the duplication into
   `lib/<topic>.ts` BEFORE shipping — duplication compounds across the
   next 50 runners.

Cap re-spawns at 2 per file. Past that, mark the runner as needing
human review in the final report and move on.

### Termination conditions

Stop and write the final report when one of:

1. **Tier 1 + Tier 2 all landed and typecheck-clean.** Write the
   coverage update, stop. Future sessions handle Tier 3.
2. **Hit re-spawn cap on 3+ runners.** Stop, write up which runners
   are blocked and what each blocker looks like.
3. **Discovered a primitive gap that breaks 5+ Tier 2 tests.** Stop,
   write up the gap, propose where the new primitive should live in
   `lib/`. Future session adds the primitive first, then resumes
   Tier 2.

### What you should NOT do

- **Don't try to land Tier 3 / Tier 4 in this session.** They're
  deferred for documented reasons. If you find one that turns out
  cheaper than the plan estimated, note it and pull it forward to
  Tier 2 — but don't open new can of worms when there are still
  Tier 1 wins on the table.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 in the plan and don't write a placeholder.
- **Don't break existing runners.** `H01-H05` are the canaries.
  `npm test` must still pass H01-H05 after every Tier 1/2 commit.
- **Don't restructure lib/.** Add primitives only when 2+ runners
  need them. Premature shared abstractions will be wrong.
- **Don't run the host Claude Desktop in destructive ways.** Tests
  that need login should gate on `CLAUDE_TEST_USE_HOST_CONFIG=1`.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary

- Tier 1 landed: N / M
- Tier 2 landed: N / M
- Tier 3 deferred: N (see plan)
- Tier 4 out-of-scope: N (see plan)
- Coverage: was 15/76 (20%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-tier breakdown

| Tier | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| 1 | T02 | T02_doctor_exit_code.spec.ts | spawn + exit code | ✓ pass |
| 1 | S01 | S01_deb_control_no_depends.spec.ts | file probe | ✓ pass |
| 2 | T05 | T05_url_handler_claude_scheme.spec.ts | xdg-mime + spawn | ✓ pass |
| 2 | T06 | T06_quick_entry_shortcut.spec.ts | globalShortcut | ⏳ needs ydotool |
| ...

## Notable findings
- ...

## Open questions
- ...

## Files touched
git status output (only tools/test-harness/src/runners/*.spec.ts and
docs/testing/runner-implementation-plan.md should appear; possibly
new lib/ primitives if extraction was needed).

## Diff summary
git diff --stat
```

### Operational notes

- Subagents are launched in parallel via a single message with
  multiple Agent tool calls. Don't serialise.
- Each subagent's Write calls land directly in the working tree.
  Each owns one runner file — no merge conflicts.
- The grounding probe (`tools/test-harness/grounding-probe.ts`) can
  help when implementing a runner that asserts runtime API state —
  capture once with `npm run grounding-probe -- --launch
  --include-synthetic`, grep the output for the IPC channel /
  accelerator / API your runner needs to assert against.
- For tests that touch the AX tree, `claudeai.ts` page-objects are
  the right substrate — see `T17_folder_picker.spec.ts` for an end-
  to-end example. Don't query DOM by CSS selector unless `claudeai.ts`
  doesn't already cover the surface.

Begin with Phase 0. Don't fan out until calibration succeeds.
