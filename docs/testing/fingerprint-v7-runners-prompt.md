# U-prefix runner wire-up — implementation prompt

This file is meant to be **copied verbatim into a fresh Claude Code session** as the initial user message. Don't paraphrase it; the self-correction loop depends on the exact directives below.

---

## Prompt to paste

You're picking up where the v7 fingerprint migration left off. The walker is shipping (`docs/testing/ui-inventory.json` is fresh, walker version 7), the resolver chain is in place (`findByFingerprint` in `tools/test-harness/explore/walker.ts`), and the codegen already exists (`tools/test-harness/explore/gen-render-specs.ts`). Your job is to wire `U01_ui_visibility.spec.ts` against the fresh inventory, run it against the live signed-in renderer, and iterate until the sweep produces an honest pass/drift/fail baseline.

### Authoritative reference

Read these in order. They contain the design, the gotchas, and the runtime contract — the prompt below assumes them as background.

- `docs/testing/fingerprint-v7-plan.md` — design contract, kind-strictness matrix, resolver fallback chain, `drift-warning` attachment shape, and the **Live-walk shakedown** subsection (the bug class you'll be working with).
- `docs/learnings/test-harness-ax-tree-walker.md` — the five non-obvious AX-tree traps. If a redrive cascade lights up, check this list first.
- `docs/testing/ui-inventory.json` + `docs/testing/ui-inventory.meta.json` — the source of truth. v7-shaped, captured with `seedFromHost` against a real signed-in account. Don't regenerate without re-walking.

### Why this iteration

Phase 3 of the v7 plan calls for the resolver-rewrite + drift-warning runner work, with U01 as the assertion surface. The file currently in tree (`tools/test-harness/src/runners/U01_ui_visibility.spec.ts`) is the placeholder stub from the v7 cutover — 18 lines that skip with `v7 cutover — re-walk required`. The walker's now produced a fresh inventory; that stub has to go and a real generated runner has to take its place.

Acceptance per the plan: U01 against a fresh walker pass produces 0 unexplained failures on the same account; drift warnings only appear when actually-drifted elements are encountered. We won't hit 0 every iteration — that's why this is autonomous.

### Repo conventions

- Tabs for indentation, lines under 80 chars, single quotes for literals, TypeScript strict mode (`tools/test-harness/tsconfig.json` enforces it).
- Comments only when the WHY is non-obvious — write the `because:` clause, not the `that:` clause.
- No backward-compatibility shims. If the generated U01 needs a different shape than `gen-render-specs.ts` currently emits, change the codegen and regenerate. Don't hand-edit the generated file.
- Don't commit. The user reviews and commits.

### Code anchors

- `tools/test-harness/explore/gen-render-specs.ts` — emits `U01_ui_visibility.spec.ts` from the inventory. Pure file in/out. Refuses on stale walker version or `partial: true` meta. Read top-to-bottom (~517 lines) before editing — the structure is one `runEntry()` closure shared across N generated `test()` cases under one `test.describe()`, with shared launch lifecycle in `beforeAll` / `afterAll`.
- `tools/test-harness/explore/walker.ts` — exports `findByFingerprint`, `redrivePath`, `currentUrl`, `waitForStable`, `waitForAxTreeStable`. The runner consumes those; don't duplicate logic.
- `tools/test-harness/src/lib/electron.ts` — `launchClaude`, `waitForReady('userLoaded' | 'claudeAi')`, `ClaudeApp` shape. Match the launch pattern H05 uses.
- `tools/test-harness/src/lib/isolation.ts` — `createIsolation({ seedFromHost: true })`. The U01 generated spec should use this when `CLAUDE_TEST_USE_HOST_CONFIG` is unset (i.e. default isolation), and fall back to `isolation: null` only when the flag is set (mirroring H05).
- `tools/test-harness/src/runners/H05_ui_drift_check.spec.ts` — reference implementation for launchClaude + waitForReady + per-test re-drive pattern. The shapes you want for U01 are here.

### Phases

#### Phase A — regenerate U01

1. `cd tools/test-harness && npm run typecheck` — must pass before doing anything.
2. `npx tsx explore/gen-render-specs.ts` — should overwrite `src/runners/U01_ui_visibility.spec.ts` with the v7-driven version. If it errors out, read the error and fix the codegen — common causes:
   - inventory shape changed (e.g. new optional field on `InventoryEntry`)
   - the codegen string-literal for the runner's imports is stale
3. `npm run typecheck` — must pass on the freshly generated spec.
4. Skim the generated file. Confirm:
   - One `test()` per non-denylisted entry (90 entries in the current inventory → roughly 90 tests, minus denylisted).
   - `test.describe()` groups by surface so the test list reads as a hierarchy.
   - `runEntry()` calls `redrivePath` then `findByFingerprint`, attaches `drift-warning` on `result.drift`, attaches `fingerprint-miss` on `!result.found`, and respects the kind-strictness matrix from the plan.
   - `beforeAll` does `createIsolation({ seedFromHost: true })` + `launchClaude({ isolation })` + `waitForReady('userLoaded')`. `afterAll` closes the inspector + the app + the isolation.

#### Phase B — first sweep

1. Make sure no host Claude Desktop is running (`pgrep -af '/usr/lib/claude-desktop/node_modules/electron'` should be empty). Ask the user to kill it if it is — `seedFromHost` will SIGKILL the host otherwise and the user may have unsaved work.
2. `npm test -- --grep "U01"` (or whatever the playwright invocation is — confirm by reading `package.json` and `playwright.config.ts`).
3. Capture the run. Tally:
   - **passed** — fingerprint resolved cleanly via primary aria-tree match.
   - **passed-with-drift** — resolved via the relaxed-scope fallback; `drift-warning` attachment present.
   - **failed** — `result.found === false`. Read the `fingerprint-miss` attachment for each.
   - **errored** — `redrivePath` threw before assertion; `redrive-failure` attachment.

The sweep will take several minutes — 90 entries at ~1.5s each + redrive overhead ≈ 5–10 min. Run it in the background with `Bash run_in_background: true` and a Monitor on the playwright reporter output, not the raw stderr (otherwise the AX-stable polling chatter will spam events).

#### Phase C — iterate

For each failure / errored test, decide which class it belongs to and apply the corresponding fix. Cap iterations at **5 sweep cycles** total (plan + first sweep + 4 fix-rerun cycles) — past that, stop and report.

##### Failure classes

1. **Resolver bug.** `findByFingerprint` rejects an element that's clearly present on the resolved surface. Likely places to look:
   - `queryAccessibleTree` — does the candidate's `walkLandmarkAncestors` output match `pathMatches` against the recorded ariaPath? Common subtlety: a literal-named ancestor that's now anonymous.
   - `nameMatches` for pattern matchers — is the regex actually anchored correctly?
   - kind-strictness gate — `expectExactlyOne` rejects ≥2 matches; check whether the kind should accept `≥1` instead.
   Fix in `walker.ts`. Re-run typecheck + selfTest. Re-run sweep.
2. **Walker capture bug.** The entry should never have been emitted, or was emitted with a wrong fingerprint (e.g. a per-row button that escaped the list-row collapse and got stable-named). Fix:
   - Add an `INSTANCE_SHAPES` entry in `tools/test-harness/src/lib/name-classifier.ts` if there's a bounded shape.
   - Lower the `SIBLING_LIST_THRESHOLD` (currently 15) only as a last resort — it's load-bearing for marketplace dialogs.
   - Re-walk via `npx tsx explore/walk-isolated.ts --verbose --max-elements 2000` (slow — 5+ min, runs in background). Then regenerate and re-run.
3. **Redrive cascade.** Many tests `errored` in a row, all sharing a path prefix. Almost always one of the AX-tree traps from `docs/learnings/test-harness-ax-tree-walker.md`. Look at the prefix and check:
   - Is `waitForAxTreeStable` getting called on the right path? (post-navigateTo, post-reload, baked into `snapshotSurface`.)
   - Is `reloadPage` being used at the start of `redrivePath` instead of `navigateTo`?
   - Did claude.ai add a new state that survives reload (URL params, localStorage)?
4. **Genuine UI drift.** The element really isn't there anymore. Confirm by attaching DevTools to the running Claude Desktop manually (the user may help) and inspecting. If confirmed: re-walk the inventory and re-generate. Don't paper over with try/catch.
5. **Per-test timeout.** A single test exceeded `test.setTimeout(120_000)`. If isolated, bump the timeout for that specific surface (rare). If pervasive, look at why redrive is slow — usually a missing `waitForAxTreeStable` somewhere making `clickById` retry-thrash.

##### What "fix" means

A fix is one of:
- A code change in `walker.ts`, `name-classifier.ts`, `inspector.ts`, or `gen-render-specs.ts`.
- A re-walk + regenerate (when the inventory itself is wrong).
- A justified `testInfo.skip` in the generator (when the entry genuinely can't be tested — e.g. a permanently-denylisted destructive action that somehow leaked through. Document why.)

Not a fix:
- `// eslint-disable-next-line` / `// @ts-ignore` / `as unknown as ...`.
- A try/catch around the assertion that reports success.
- Bumping timeout to mask a real perf issue.

### Self-correction loop (general protocol)

After each phase's specific loop:

1. If `npm run typecheck` reports errors, fix root causes — no `// @ts-ignore`, no `any`, no `as unknown as ...`.
2. If `npx tsx explore/walker.ts` (selfTest) fails, the change broke an algorithmic invariant. Don't relax the test; fix the change.
3. **Cap fix attempts per problem class at 3.** After 3 attempts on the same class without progress, stop and report.
4. Mark Phase complete only when every step in that Phase passes cleanly.

### Termination conditions

Stop and write a final report when one of:

1. **Sweep is clean.** 0 unexplained failures, drift warnings only on entries you can identify as legitimate drift. Report final pass/drift/fail tallies.
2. **Hit the 5-sweep cap.** Report what's done, what's blocked, and what each remaining failure looks like.
3. **Hit the 3-attempt cap on a non-trivial issue.** Report attempts, why each failed, what's blocked.
4. **The plan needs to change.** E.g. the kind-strictness matrix in the v7 plan is producing wrong outcomes for an inventory shape that wasn't anticipated. Stop, document the contradiction, ask the user before editing the plan.

### What you should NOT do

- Don't commit. The user reviews everything.
- Don't run the host Claude Desktop. The user runs it. `seedFromHost` will SIGKILL it on launch — confirm with the user before running any sweep that uses the launchClaude isolation path.
- Don't hand-edit `src/runners/U01_ui_visibility.spec.ts` — it's auto-generated. Edits will be overwritten.
- Don't widen the resolver's strictness to make tests pass. The resolver's strictness is the contract; loosening it makes the inventory worthless as a render check.
- Don't add new abort thresholds without understanding why the existing ones exist. The 75/5 split between lookup_failure and inspector_timeout in `walker.ts` is load-bearing — see the comment.
- Don't poll for the playwright run to finish. Use `Monitor` on the reporter output and let it notify you.
- Don't keep both v6 and v7 codepaths. The cutover is atomic.
- Don't drill into a runner-specific workaround that other U-prefix runners (when they exist) would have to duplicate. If a fix wants to live in a helper, put it in `walker.ts` or the inspector.

### Final report format

```markdown
## Sweep summary

- Total tests:       N
- Passed:            N (X%)
- Passed with drift: N (X%)
- Failed:            N (X%)
- Errored:           N (X%)
- Skipped:           N (X%)

## Iteration log

### Sweep 1
- Result: ...
- Failures by class:
  - Resolver bug: N (...)
  - Walker capture bug: N (...)
  - Redrive cascade: N (...)
  - Drift: N (...)
  - Timeout: N (...)
- Fixes applied: ...

### Sweep 2
... (one block per sweep cycle)

## Open issues
- ...

## Files touched
git status output

## Diff for review
git diff --stat output
```

### Operational notes

- Background runs: use `Bash run_in_background: true` for the playwright sweep, the walker, and any other long-running command. Tail the output with `Monitor` and a tight grep filter (`PASSED|FAILED|drift|Error|errored|^Running|✘|✓`). Stop the monitor explicitly when the run completes.
- Check for leftover Electron processes between runs (`pgrep -af '/usr/lib/claude-desktop/node_modules/electron'`) and stale tmpdirs (`ls /tmp/claude-test-*`) — clean both up if the prior run errored before teardown.
- The walker uses `seedFromHost: true` in `walk-isolated.ts` and the H05 runner; the U01 runner should use the same default (per `gen-render-specs.ts` template). Don't accidentally run against the host config — it'll mutate the user's profile.

Begin with Phase A. Read `gen-render-specs.ts` end-to-end first — in particular the `runEntry()` closure structure and the `beforeAll` / `afterAll` blocks — so you understand what the generator emits before you regenerate.
