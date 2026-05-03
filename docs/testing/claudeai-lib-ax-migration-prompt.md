# lib/claudeai.ts AX-tree migration — implementation prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
self-correction loop depends on the exact directives below.

---

## Prompt to paste

You're picking up after the v7 fingerprint walker + U01 wire-up
landed. Walker, resolver, and U01 are all on the AX-tree substrate.
The page-object library `tools/test-harness/src/lib/claudeai.ts` is
still on the old substrate — `document.querySelector` against
minified-tailwind class shapes (`button[aria-haspopup="menu"]` +
`span.truncate.max-w-[Npx]`) — and that's where every claude.ai UI
spec couples to upstream's React DOM. Your job is to migrate the
brittle CSS-shape walks in `claudeai.ts` to AX-tree resolution using
the v7 walker primitives, run the H/S spec families that consume
them, and iterate until those specs pass without DOM-shape coupling.

### Authoritative reference

Read these in order. They contain the design, the gotchas, and the
runtime contract — the prompt below assumes them as background.

- `docs/testing/fingerprint-v7-plan.md` — design contract for the v7
  fingerprint, kind-strictness matrix, resolver fallback chain. Skim
  the "Capture algorithm" and "Resolver / fallback chain" sections;
  the migration consumes the same primitives.
- `docs/learnings/test-harness-ax-tree-walker.md` — the five
  non-obvious AX-tree traps (AX-enable async lag, navigateTo no-op,
  flat dialog>button[] lists, more-options shape, sidebar
  virtualization). All apply here too — `lib/claudeai.ts` calls run
  inside the same renderer the walker drives.
- `tools/test-harness/src/lib/claudeai.ts` — the migration target.
  ~340 lines, eight functions plus two classes (`CodeTab`,
  `LocalEnvPill`). Every public function is a discovery walk against
  `evalInRenderer` with `document.querySelectorAll`.

### Why this iteration

Per the v7 plan's design goal §2 "Resilient to cosmetic drift" —
upstream regenerates tailwind class signatures on rebuild
(`max-w-[Npx]`, `df-pill`-style atoms), so `claudeai.ts`'s CSS-shape
walks break on any minor UI rebuild even when the AX-computed role
and accessible name are stable. The U01 wire-up confirmed the AX
tree is a usable substrate end-to-end (~7s/test, 89/90 stable across
two consecutive sweeps). Pulling `claudeai.ts` onto the same
substrate eliminates the recurring "tailwind regen breaks H05/S31
again" failure mode.

Acceptance per the plan: H05 + S29-S37 + T-prefix specs that consume
`claudeai.ts` keep passing on the same account, with zero new
flakes. Migration is mechanical (replace the eval-string walks with
AX-tree queries) and the existing tests are the contract.

### Repo conventions

- Tabs for indentation, lines under 80 chars, single quotes for
  literals, TypeScript strict mode (`tools/test-harness/tsconfig.json`
  enforces it).
- Comments only when the WHY is non-obvious — write the `because:`
  clause, not the `that:` clause.
- No backward-compatibility shims. If a function's signature needs
  to change, change every caller. Don't keep both code paths.
- Don't commit. The user reviews and commits.

### Code anchors

- `tools/test-harness/explore/walker.ts` — exports the primitives
  you'll consume:
  - `findByFingerprint(inspector, fingerprint, kind)` — full
    resolver with strictness gating + relaxed-scope fallback.
    Overkill for one-shot lookups against the live renderer.
  - `queryAccessibleTree(elements, query)` — pure filter, used at
    capture and resolve time. Takes a `RawElement[]` snapshot and
    an `AxQuery` (ariaPath + leaf criteria). What you'll likely
    wrap.
  - `axTreeToSnapshot(nodes)` — converts CDP `AxNode[]` to the
    walker's `RawElement[]` shape. Drops ignored nodes.
  - `walkLandmarkAncestors(raw)` — emits the AriaStep[] for an
    element. Useful if a method needs to disambiguate by landmark.
  - `waitForAxTreeStable(inspector, opts)` — gating primitive used
    by walker + U01. Use `{ minNodes: 1, timeoutMs: 10000 }` for
    post-click reads (matches `snapshotSurface`'s default).
- `tools/test-harness/src/lib/inspector.ts` — `getAccessibleTree`
  fetches the raw CDP tree filtered to the claude.ai webContents.
- `tools/test-harness/src/lib/claudeai.ts` — the migration target.
  Read the file-header comment first; it documents the discovery
  strategy you're replacing.
- `tools/test-harness/src/runners/H05_ui_drift_check.spec.ts`,
  `S31_quick_entry_submit_reaches_new_chat.spec.ts`,
  `S32_quick_entry_submit_gnome_stale_isfocused.spec.ts` — primary
  consumers of the methods being migrated.

### Phases

#### Phase A — spike on one method

1. `cd tools/test-harness && npm run typecheck` — must pass before
   doing anything.
2. Pick `openPill(inspector, labelPattern, opts)` as the spike.
   It's the most CSS-shape-coupled method and exercises the
   menu-render polling pattern the rest of `claudeai.ts` reuses.
3. Replace its body with an AX-tree query:
   - Fetch the AX tree (`inspector.getAccessibleTree('claude.ai')`),
     convert via `axTreeToSnapshot`.
   - Filter to elements with `computedRole === 'button'` and
     accessibleName matching `labelPattern`.
   - For each candidate, compute its parent landmark via
     `walkLandmarkAncestors`. The compact-pill discriminator —
     "has a `span.truncate.max-w-[Npx]` child" — needs an AX
     analogue. Most likely: parent is `toolbar` / `group` and the
     element has `aria-haspopup === 'menu'` (exposed in AX as
     `hasPopup` property; check whether `RawElement` carries it
     and extend if needed).
   - Click via `inspector.clickByBackendNodeId(raw.backendDOMNodeId)`.
   - Poll for menu items via AX role match (`menuitem`,
     `menuitemradio`, `menuitemcheckbox`).
4. Run H05 against your branch (`./node_modules/.bin/playwright
   test src/runners/H05_ui_drift_check.spec.ts`). H05 doesn't
   directly call `openPill` but exercises the same renderer state;
   if H05 regresses your AX walk is wrong.
5. Run S31 (`./node_modules/.bin/playwright test
   src/runners/S31_quick_entry_submit_reaches_new_chat.spec.ts`).
   This calls `openPill` indirectly via `CodeTab.activate` →
   `findCompactPills`.
6. If both pass, the AX substrate works for at least one method.
   Commit the shape mentally (don't `git commit` — the user does
   that). If either fails, the spike is in trouble; re-read the
   AX-tree learnings doc for traps you missed and fix the
   primitive before expanding.

#### Phase B — migrate the rest

For each remaining function in `claudeai.ts`, port the discovery
walk to AX:

- `activateTab(inspector, name)` — `button` with
  `accessibleName === name` under root or banner landmark. Existing
  `aria-label="X"` selector → AX `name` literal match.
- `findCompactPills(inspector)` — list of buttons with
  `hasPopup === 'menu'` AND inner `span.truncate.max-w-[…]` text
  child. AX equivalent: button role + hasPopup + a child
  `genericContainer` (or whatever AX exposes for `<span>`) carrying
  the visible text. Returns `{text, maxW, expanded}` today —
  `maxW` is a tailwind artifact and should be dropped from the AX
  shape (callers don't use it for matching, just for diagnostics;
  keep a placeholder or remove from the type).
- `clickMenuItem(inspector, textPattern, opts)` — element with
  role in `{menuitem, menuitemradio, menuitemcheckbox}` and
  accessibleName matching `textPattern`. The CSS attribute selector
  has an AX direct equivalent.
- `pressEscape(inspector)` — keep as-is. It's a keydown dispatch,
  not a discovery walk.
- `CodeTab.activate(opts)` — calls `activateTab` + polls
  `findCompactPills`. Migrates by transitivity.
- `LocalEnvPill` — read its body to enumerate callers.

After each migration:
1. `npm run typecheck` — must pass.
2. `npx tsx explore/walker.ts` — selfTest must pass (you may have
   touched walker.ts to expose new primitives).
3. Run the affected spec(s).

#### Phase C — full sweep

1. Run all H/S/T runners that consume `claudeai.ts`:
   - H05 (UI drift)
   - S31 (Code-tab submit)
   - S32 (GNOME stale isFocused)
   - any T-prefix that uses `installOpenDialogMock` or `pressEscape`
2. Tally pass/fail. The post-migration baseline must equal the
   pre-migration baseline, modulo flakes characterized in
   `docs/learnings/test-harness-ax-tree-walker.md`.

Cap iterations at **5 sweep cycles** total (spike + 4 fix-rerun
cycles) — past that, stop and report.

##### Failure classes

1. **AX-shape mismatch.** Element has the CSS shape the old code
   relied on but a different AX role/name than expected. Fix:
   probe the AX tree for the actual shape (use
   `inspector.getAccessibleTree('claude.ai')` interactively from a
   one-shot script), update the AX query.
2. **Missing AX property exposure.** `hasPopup`, `expanded`, etc.
   may not be in `RawElement` today (the walker only reads role,
   name, ancestors, sibling info). Extend `RawElement` and
   `axTreeToSnapshot` to expose what the migration needs. Update
   walker.ts selfTest if you change the snapshot shape.
3. **Race against menu render.** Old code polled
   `document.querySelectorAll('[role=menuitem]')` every 50ms. AX
   tree updates lag DOM by hundreds of ms; bake a
   `waitForAxTreeStable({ minNodes: 1 })` between click and
   menuitem fetch instead of a short DOM poll.
4. **Tailwind-class diagnostic loss.** `findCompactPills` returns
   `maxW` which callers use only in error messages. If the
   AX-only return shape drops `maxW`, error messages get less
   informative — accept it, don't reintroduce DOM walks just for
   diagnostics. Keep the `maxW` field optional/null in the type.

##### What "fix" means

A fix is one of:
- A code change in `claudeai.ts`, `walker.ts`, or `inspector.ts`.
- A targeted extension of `RawElement` / `axTreeToSnapshot` to
  expose an AX property the migration needs.

Not a fix:
- `// eslint-disable-next-line` / `// @ts-ignore` / `as unknown as ...`.
- Keeping the old `document.querySelector` walk as a fallback.
- Adding an AX walk that wraps a CSS walk that wraps an AX walk.

### Self-correction loop (general protocol)

After each phase's specific loop:

1. If `npm run typecheck` reports errors, fix root causes — no
   `// @ts-ignore`, no `any`, no `as unknown as ...`.
2. If `npx tsx explore/walker.ts` (selfTest) fails, the change broke
   an algorithmic invariant. Don't relax the test; fix the change.
3. **Cap fix attempts per problem class at 3.** After 3 attempts
   on the same class without progress, stop and report.
4. Mark Phase complete only when every step in that Phase passes
   cleanly.

### Termination conditions

Stop and write a final report when one of:

1. **Migration is clean.** All `claudeai.ts` methods on AX
   substrate, all consuming specs pass at the pre-migration
   baseline. Report final pass tallies + diff stat.
2. **Hit the 5-sweep cap.** Report what's done, what's blocked,
   and what each remaining failure looks like.
3. **Hit the 3-attempt cap on a non-trivial issue.** Report
   attempts, why each failed, what's blocked.
4. **AX exposure gap.** A claude.ai surface uses a property the AX
   tree doesn't expose (e.g., custom `data-state` attributes
   without a corresponding ARIA reflection). Stop, document the
   gap, ask the user before adding a hybrid AX+DOM walk.

### What you should NOT do

- Don't commit. The user reviews everything.
- Don't keep both substrates. The migration is atomic per method:
  CSS walk out, AX walk in. No fallback chains.
- Don't add new abstractions in `claudeai.ts` that aren't required
  by the migration. The file's shape (one function per UI verb) is
  load-bearing for callers — don't introduce a `PageObject` base
  class or a generic AX builder.
- Don't run the host Claude Desktop. The user runs it. The H/S
  specs use `launchClaude` with `seedFromHost` or `null` isolation
  per spec — confirm with the user before any sweep.
- Don't widen `RawElement` speculatively. Only add fields the
  migration consumes. Each new field bloats every snapshot.
- Don't drill into a single-method workaround that other methods
  would have to duplicate. If a fix wants to live in a helper,
  put it next to `queryAccessibleTree` in `walker.ts`.

### Final report format

```markdown
## Migration summary

- Functions migrated:    N / N
- Walker.ts changes:     <one-line summary>
- Inspector.ts changes:  <one-line summary or none>
- H/S/T specs run:       N
- H/S/T specs passed:    N
- New flakes introduced: N (description)

## Iteration log

### Spike — openPill
- Result: ...
- AX shape used: ...
- Issues hit: ...

### Phase B — remaining methods
- One block per method ...

### Phase C — full sweep
- Per-spec pass/fail tally
- Diff against pre-migration baseline

## Open issues
- ...

## Files touched
git status output

## Diff for review
git diff --stat output
```

### Operational notes

- Background runs: use `Bash run_in_background: true` for any
  multi-spec sweep, and `Monitor` with a tight grep filter
  (`✓|✘|Error|FAIL|EXIT=`) to stream events. Stop the monitor when
  the run completes.
- Check for leftover Electron processes between runs
  (`pgrep -af '/usr/lib/claude-desktop/node_modules/electron'`)
  and stale tmpdirs (`ls /tmp/claude-test-*`) — clean both up if
  the prior run errored before teardown.
- The U01 wire-up landed two `walker.ts` fixes that are part of
  the substrate you're inheriting:
  1. `findByFingerprint`: strictness gate also defers to
     `fingerprint.classification === 'instance'` for degenerate
     fingerprints.
  2. `redrivePath`: navigates to startUrl when current URL drifted;
     reloads only when already at startUrl.
  Both are live in the working tree (or just-merged main,
  depending on when this prompt fires).

Begin with Phase A. Read `claudeai.ts` end-to-end first — in
particular the file-header discovery comment (lines 1-31) and the
`openPill` body (lines 162-202) — so you understand what the
existing CSS-shape walks are anchoring on before you replace them.
