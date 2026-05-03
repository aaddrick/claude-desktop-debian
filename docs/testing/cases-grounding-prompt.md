# docs/testing/cases grounding sweep — implementation prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

---

## Prompt to paste

You're picking up after the v7 walker, U01 wire-up, and the
`claudeai.ts` AX-tree migration all landed. The page-objects are
stable against the live renderer (T17_folder_picker passes on
KDE-W). The next workstream is **grounding the case docs in
`docs/testing/cases/` against actual upstream behavior**.

The cases were written from outside-in — observed user-visible
flows, expected outcomes, diagnostic captures. Many describe
behavior the test author *believed* exists in upstream Claude
Desktop, but no one has cross-checked each Step / Expected against
the actual extracted source. Your job is to spawn one subagent per
case file, have each one read the case + grep the build-reference
extract for the relevant feature, and report what's accurate, what's
stale, and what's missing — then make in-place adjustments to the
case files so each one is grounded in concrete code anchors before
the next sweep cycle.

### Authoritative reference

Read these in order. They're the substrate the subagents will pull
from.

- `docs/testing/cases/README.md` — the case-doc structure (severity,
  surface, applies-to, steps, expected, diagnostics, references).
  The "Standard test body" template at the bottom is the contract
  every case currently follows.
- `docs/testing/matrix.md` — live Pass/Fail/Pending matrix per row.
  Tells you which cases have a runner and which are still
  human-execution-only.
- `build-reference/app-extracted/.vite/build/` — the extracted +
  beautified Claude Desktop source. ~14 files; `index.js` is the
  main process (~546k lines after beautification), `mainView.js` /
  `mainWindow.js` / `quickWindow.js` are renderer preloads,
  `coworkArtifact.js` is the cowork BrowserView preload,
  `buddy.js` is the supervisor, etc. **This is the ground truth.**
- `tools/test-harness/src/runners/` — existing runners that *do*
  have working selectors / event hooks. Sometimes the runner has
  more accurate code anchors than the case doc.
- `CLAUDE.md` (project root) — project conventions, attribution
  format, commit style. Don't violate.

### Case files in scope

Eleven files plus the README. One subagent per file:

| File | Tests covered |
|---|---|
| `code-tab-foundations.md` | T15-T20 |
| `code-tab-handoff.md` | T23-T25, T34, T38, T39 |
| `code-tab-workflow.md` | T21-T22, T29-T32 |
| `distribution.md` | S01-S05, S15, S16, S26 |
| `extensibility.md` | T11, T33, T35-T37, S27, S28 |
| `launch.md` | T01, T02, T13, T14 |
| `platform-integration.md` | T09, T10, T12, S17, S18, S22-S25 |
| `routines.md` | T26-T28, S19-S21 |
| `shortcuts-and-input.md` | T05, T06, S06-S14, S29-S37 |
| `tray-and-window-chrome.md` | T03, T04, T07, T08, S08, S13 |

### Why this iteration

Several cases have been silently bit-rotting against upstream
changes — a Step says "click the X menu" but X was renamed two
upstream versions ago, or an Expected references a behavior the
team shipped behind a feature flag that's now off by default. When
the sweep runs against a row that's stale, the failure looks like a
Linux compatibility issue but is actually a doc-vs-upstream drift.
Grounding the cases against the actual extracted source closes
that gap and makes future sweeps interpretable.

This isn't a one-time correctness pass — it's a cycle. After every
upstream version bump (`CLAUDE_DESKTOP_VERSION` rolls in
`scripts/setup/detect-host.sh`), the grounding can drift again.
Optimise for **leaving concrete code-anchor breadcrumbs** in each
case so the next grounding pass is fast.

### Repo conventions

- Tabs for indentation in code; markdown is space-indented as the
  existing files do it.
- Markdown lines wrap at ~80 chars unless they're tables or links
  that don't break naturally.
- Don't commit. The user reviews and commits.
- Don't run the host Claude Desktop. The user runs it. Read from
  `build-reference/` instead — that's already extracted +
  beautified specifically so you don't have to attach to a live
  app to verify behavior.

### Code anchors

- `build-reference/app-extracted/.vite/build/index.js` — main
  process. Every IPC channel registration, window-management
  decision, app-lifecycle hook, tray-menu construction, autostart
  toggle, dialog invocation, and protocol handler lives here.
- `build-reference/app-extracted/.vite/build/quickWindow.js` —
  Quick Entry preload + window setup.
- `build-reference/app-extracted/.vite/build/mainWindow.js` —
  main shell BrowserWindow preload (claude.ai is loaded into a
  child BrowserView; this preload runs in the shell frame).
- `build-reference/app-extracted/.vite/build/mainView.js` —
  preload running inside the claude.ai BrowserView itself.
- `build-reference/app-extracted/.vite/build/coworkArtifact.js` —
  preload running inside cowork's iframe-shaped artifact view.
- `build-reference/app-extracted/.vite/build/buddy.js` — supervisor
  process (the daemon that respawns the cowork worker; see
  `docs/learnings/cowork-vm-daemon.md`).
- `build-reference/app-extracted/package.json` — declared main /
  preloads, electron version, native deps. Quick reference for
  whether a feature is wired up at all.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass; if
   not, stop and report.
2. Read `docs/testing/cases/README.md` end-to-end and one full case
   file (suggest `launch.md` — small, four tests, easy
   surface-area). Confirm you understand the case-doc contract
   before fanning out.
3. Pick T01 (App launch) as a calibration case. Manually grep
   `build-reference/app-extracted/.vite/build/index.js` for the
   launcher-log / backend-selection logic referenced in T01's
   Expected. Confirm you can read the beautified source and locate
   the relevant code. Report the anchor (`index.js:N-M`) so the
   user knows the workflow is sound before you fan out.

If Phase 0 surfaces a problem (build-reference stale relative to
the case doc, calibration anchor not findable, README structure
unclear), stop and report. Don't fan out subagents against an
unverified workflow.

#### Phase 1 — fan-out

Spawn one subagent per case file (eleven total). Use
`subagent_type: 'general-purpose'`. Send them in **parallel** —
they're independent. Keep the prompt to each subagent
self-contained; the subagent has no context from this conversation.

Per-subagent prompt template (fill in the case file path):

```
You're grounding ONE test-case file in
docs/testing/cases/<FILE>.md against the extracted Claude Desktop
source at build-reference/app-extracted/.vite/build/.

Read these first:
- docs/testing/cases/README.md (case-doc contract)
- docs/testing/cases/<FILE>.md (your case file)
- CLAUDE.md (project conventions)

For each test in the file:

1. Read the test's Steps + Expected.
2. Identify the load-bearing claim — the upstream behavior the
   test depends on (an IPC channel, a tray-menu item, a
   dialog.showOpenDialog call, a globalShortcut.register, a
   nativeTheme listener, etc.).
3. Grep build-reference/app-extracted/.vite/build/ for that claim.
   Use ripgrep / grep -E. The code is beautified but minified
   variable names — anchor on string literals, IPC channel names,
   menu labels, event names, not variable identifiers.
4. Classify the result:
   - **Grounded** — claim verified, anchor found. Append a
     `**Code anchors:** <file>:<line>` line to the test body
     directly under the existing References field.
   - **Drifted** — feature exists but the case's Steps or Expected
     don't match what's actually shipping. Edit the case to
     match upstream behavior. Note what changed.
   - **Missing** — feature isn't in the build at all (deprecated,
     never shipped, behind unset flag). Mark the test with a
     prepended block:
     `> **⚠ Missing in build 1.5354.0** — <one-line note>. Re-verify after next upstream bump.`
   - **Ambiguous** — claim could be one of several upstream code
     paths and you can't disambiguate from the case alone. Don't
     edit; report under "Open questions".

Per-test, prefer concrete code anchors over wordy explanations.
The next person reading this case should see exactly where
upstream implements the feature.

Constraints:
- Don't fabricate anchors. If you can't find it, mark Missing or
  Ambiguous — never invent a `index.js:12345` reference.
- Don't restructure the case files. Keep the existing template
  (Severity / Surface / Applies to / Issues / Steps / Expected /
  Diagnostics / References). Only add code anchors and edit
  Steps/Expected for drift.
- Don't expand scope. If you notice an unrelated bug or missing
  test, note it under "Open questions" — don't fix it inline.
- Don't run the host Claude Desktop. Read from build-reference/
  only.

Report shape (~300-500 words):

## <FILE>.md grounding

- Tests reviewed: N
- Grounded: N
- Drifted (edited): N (one-line per: <test-id> — <what changed>)
- Missing (marked): N (one-line per: <test-id> — <what's gone>)
- Ambiguous (flagged): N (one-line per: <test-id> — <why>)

### Code anchor highlights
- <test-id>: <file>:<line> — <what the anchor proves>

### Open questions
- ...

### Files touched
- docs/testing/cases/<FILE>.md
```

Keep the report tight. The orchestrator reads eleven of these and
synthesizes.

#### Phase 2 — synthesis

Once all eleven subagents return:

1. Aggregate per-classification counts across all files. Big
   numbers in any column are signals:
   - Lots of **Drifted** → upstream had a recent feature shuffle;
     the team should know.
   - Lots of **Missing** → either the case doc was written
     speculatively or upstream removed features without telling.
   - Lots of **Ambiguous** → the case-doc template needs a
     "Implementation hint" field so future grounding has a
     starting point.
2. Cross-check: did any subagent edit the same anchor differently?
   (Unlikely since each owns one file, but worth a sanity pass.)
3. Check that `git diff docs/testing/cases/` matches what the
   subagents reported. If a subagent claimed Drifted but didn't
   write to disk, surface it.
4. Build the user-facing summary (see "Final report format" below).

Don't make the user re-read the eleven subagent reports — give
them the synthesised view + the per-file links.

### Self-correction loop

After Phase 1 returns:

1. If any subagent failed (no report, error, hit token limit),
   re-spawn just that one with a tighter scope (e.g. "process
   tests T15-T17 only, not the full file").
2. If a subagent's report claims edits but `git diff` shows no
   changes, the subagent silently dropped the writes — re-spawn
   with explicit instruction to use the Edit tool.
3. If two subagents flag the same upstream code path with
   contradictory claims (one says Grounded, one says Missing),
   re-read the source yourself and adjudicate.

Cap re-spawns at **2 per file** — past that, mark the file as
"needs human review" in the final report and move on.

### Termination conditions

Stop and write a final report when one of:

1. **All eleven files grounded.** Per-file classification counts +
   diff stat. Done.
2. **Hit the re-spawn cap on 3+ files.** Stop, write up which
   files are blocked, what each blocker looks like.
3. **Build-reference is stale.** If multiple subagents report
   "Missing" against features the user knows shipped, the
   extract may be out of date — verify the version
   (`build-reference/app-extracted/package.json` `version` field
   vs `CLAUDE_DESKTOP_VERSION` repo variable) before continuing.

### What you should NOT do

- Don't commit. The user reviews everything.
- Don't restructure the case-doc template. Eleven files, one
  shape — keep it that way.
- Don't add new tests. Grounding is a verify-and-anchor pass, not
  a coverage expansion.
- Don't run the host Claude Desktop. The build-reference extract
  exists specifically so you don't have to attach to a live app.
- Don't edit anything outside `docs/testing/cases/`. If you find
  a runner discrepancy (case says "click X", runner clicks "Y"),
  flag it under Open questions; don't edit the runner.
- Don't invent anchors. If the grep doesn't find the literal,
  classify Missing or Ambiguous — never write a fictional
  `index.js:12345` reference.

### Final report format

```markdown
## Cases grounding summary

- Files reviewed:    11 / 11
- Tests reviewed:    N (sum across all files)
- Grounded:          N (with code anchors added)
- Drifted (edited):  N
- Missing (marked):  N
- Ambiguous:         N
- Files needing
  human review:      N

## Per-file breakdown

| File | Reviewed | Grounded | Drifted | Missing | Ambiguous |
|---|---|---|---|---|---|
| code-tab-foundations.md | ... | ... | ... | ... | ... |
| ... | | | | | |

## Notable findings
- <test-id>: <one-line significance>
- ...

## Open questions
- ...

## Files touched
git status output (only docs/testing/cases/*.md should appear)

## Diff summary
git diff --stat docs/testing/cases/
```

### Operational notes

- Subagents are launched in parallel via a single message with
  multiple Agent tool calls. Don't serialize them — Phase 1 takes
  ~15 minutes serial, ~3 minutes parallel.
- Each subagent's Edit calls land directly in the working tree.
  No merge conflicts because each owns one file.
- The build-reference `index.js` is 546k lines. Subagents should
  use `grep -nE` with anchored string literals, not full reads.
  Recommended grep pattern style:
  `grep -nE 'globalShortcut\.register\([^)]*' build-reference/app-extracted/.vite/build/index.js`
- If a subagent needs to verify a renderer-side claim (DOM event
  flow, React component shape), the relevant preload is in
  `mainView.js` / `mainWindow.js`. Don't grep `index.js` for
  renderer-only behavior.

Begin with Phase 0. Don't fan out until calibration succeeds.
