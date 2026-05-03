# Fingerprint v7 — Implementation Prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
self-correction loop depends on the exact directives below.

---

## Prompt to paste

You are implementing the v7 fingerprint migration for this repo's
test harness. This is a multi-phase code change with a built-in
self-correction loop. Read the directives below carefully — the
loop only works if you follow it exactly.

### Authoritative reference

- `docs/testing/fingerprint-v7-plan.md` is the design contract. Read
  it end-to-end before touching any code. Anything you implement
  must match that doc; if the doc is wrong, fix the doc *first* and
  ask the user to redline before changing the code.

### Repo conventions you must follow

- `CLAUDE.md` and `STYLEGUIDE.md` at the repo root. Tabs for
  indentation, lines under 80 chars, single quotes for literals,
  TypeScript strict mode (the harness's `tsconfig.json` enforces it).
- Don't add comments that explain WHAT the code does; only add
  comments when the WHY is non-obvious.
- Don't introduce backward-compatibility shims. Per the plan, the v6
  → v7 cutover is atomic. Do not emit both schemas; do not keep a
  legacy selector fallback. If you find yourself writing one, stop
  and re-read the plan's "Design goals" §4.
- Don't commit. The user will review and commit themselves.

### Code anchors

These are the files you'll touch or read:

- `tools/test-harness/explore/walker.ts` — capture site (~2050 lines).
  Read the top comment block first; it explains BFS, re-drive,
  visited-set keying, and current fingerprint shape.
- `tools/test-harness/explore/gen-render-specs.ts` — emits U01 from
  the inventory.
- `tools/test-harness/src/runners/U01_ui_visibility.spec.ts` —
  AUTO-GENERATED. Don't hand-edit; regenerate via the generator
  after walker/gen changes.
- `tools/test-harness/src/lib/inspector.ts` — CDP wrapper. The AX-
  tree query goes through here.
- `docs/testing/ui-inventory.json` — current v6 inventory (383
  entries, captured 2026-05-03). Phase 1 reads this; Phase 2 will
  invalidate it.
- `docs/testing/ui-inventory.meta.json` — schema header.

### Phases

Implement Phases 1, 2, and 3 from the plan, in order. **Phase 4
(account-portability validation) requires a second user with their
own signed-in account — do not attempt it autonomously; report
"Phase 4 needs a second contributor" when you reach it.**

After each phase, run the **self-correction loop** (below) before
proceeding to the next phase. Do not start Phase 2 until Phase 1
passes the loop; do not start Phase 3 until Phase 2 passes.

#### Phase 1 — vocabulary scaffold

Build a one-shot script that derives the stable-UI vocabulary from
the existing v6 inventory and commits the result.

- Add `tools/test-harness/explore/derive-vocabulary.ts` (new file).
- Wire `npm run derive:vocabulary` in
  `tools/test-harness/package.json`.
- Read `docs/testing/ui-inventory.json` v6.
- Apply the classifier rules from
  `fingerprint-v7-plan.md#name-classifier`: stable / instance-shaped
  / suspect.
- Write `docs/testing/ui-vocabulary.json` with three top-level
  arrays: `stable`, `instanceShapes` (the regex registry, ported
  from the plan's table), `suspect`.
- The instance-shape registry must live in code as a typed constant
  exported from `tools/test-harness/src/lib/name-classifier.ts`
  (new file) so Phase 2's walker can consume it. The JSON output
  is for human triage and inventory provenance, not the runtime
  source of truth.

Self-correction loop for Phase 1:
1. `cd tools/test-harness && npm run typecheck`
2. `npm run derive:vocabulary` — must complete without throwing
3. Read the generated `docs/testing/ui-vocabulary.json`. Sanity-
   check by hand: the `stable` array should contain at least
   "Search", "Cowork", "Code", "Chat", "Settings", "New chat",
   "Send" (some of the plan's listed examples). The `suspect` array
   should contain "AWAaddrick·Max" or its constituent shape if the
   plan-badge regex caught it.
4. If the sanity check fails, debug and fix. Don't ship a
   classifier that misses obvious stable words.

#### Phase 2 — walker rewrite

Replace the v6 fingerprint capture in `walker.ts` with v7. This is
the largest change.

- Add an AX-tree query helper to `inspector.ts` that wraps
  `Accessibility.getFullAXTree` (or the subtree variant if full-tree
  latency is prohibitive — see the plan's open questions).
- Implement `walkLandmarkAncestors`, `queryAccessibleTree`, and
  `captureFingerprint` per the plan's "Capture algorithm" section.
- Replace the existing `fingerprint` emit in walker.ts with the v7
  shape. Bump `walkerVersion` to `7` in
  `ui-inventory.meta.json`-emitting code.
- Inventory IDs (today: `root.button.awaaddrick-max`) must derive
  from structural path, not labels. See the plan's "ariaPath" §
  for the new id-shape convention. Pure structural: e.g.
  `banner.toolbar.button[2]` or `banner.button-by-shape.plan-badge`.
- The name classifier consumed by the walker must come from the
  Phase 1 module (`name-classifier.ts`).

Self-correction loop for Phase 2:
1. `npm run typecheck` — must pass.
2. Logical-correctness review: read the new `captureFingerprint` and
   trace by hand that for each example in the plan's
   "Kind-strictness matrix" (root.button.search,
   root.button.awaaddrick-max, search.option.untitled-conversation,
   pinned conversation), the captured fingerprint matches what the
   plan says it should be.
3. **Do not actually run a live walk.** A walk requires killing the
   user's host Claude, lifting auth, and burning ~5 min per
   iteration. Stop at logical correctness and flag the live-walk
   verification as a Phase 2 manual handoff in the final report.

#### Phase 3 — resolver rewrite

Replace the v6 selector resolver in walker.ts (`findByFingerprint`)
and update gen-render-specs to emit v7-shaped U01.

- Rewrite `findByFingerprint` with the two-strategy chain (full
  ariaPath, then relaxed-scope). Drop the old selector code path
  entirely. No legacy fallback.
- Add the `drift-warning` testInfo attachment shape to the U01
  generator output.
- Update `gen-render-specs.ts` to consume `entry.fingerprint` (now
  v7-shaped). The per-entry `test()` body changes from
  `redrivePath + findByFingerprint(selector)` to
  `redrivePath + findByFingerprint(ariaPath, leaf, kind)`.
- Bump the auto-gen header in U01 to reference v7.

Self-correction loop for Phase 3:
1. `npm run typecheck` — must pass.
2. Run `npx tsx explore/gen-render-specs.ts --output /tmp/u01-v7.spec.ts`
   against the *existing v6* inventory. The generator will fail
   because the v6 inventory shape no longer matches v7 expectations.
   That failure is **expected** and is the signal that the migration
   is atomic-correct: a fresh walk is required before U01 can run
   again. Capture the error message.
3. Do not attempt to run U01. Per Phase 2, no live walk happened, so
   there is no v7 inventory to test U01 against.

### Self-correction loop (general protocol)

After each phase's specific loop:

1. If `npm run typecheck` reports errors, read each error
   carefully. Fix root causes — do not suppress with `// @ts-ignore`,
   `any`, or `as unknown as ...` casts. If a type error reveals a
   logic mistake, fix the logic.
2. If a sanity check fails, debug. Don't move on.
3. Cap fix attempts per problem at **3**. After 3 attempts on the
   same issue without progress, stop and report. Do not silently
   work around it.
4. After fixes, **re-run the entire phase loop from step 1**. Don't
   declare success on a partial pass.
5. Mark the phase complete only when every step in the phase loop
   passes cleanly.

### Termination conditions

Stop and write a final report when one of:

1. **All three phases pass.** Report what's done, list the manual
   verification steps that remain (live walk for Phase 2, Phase 4
   in full), and outline the diff for the user to review.
2. **Hit the 3-attempt cap on a non-trivial issue.** Report what was
   attempted, why each attempt failed, what's blocked, and what
   information you'd need to unblock.
3. **The plan needs to change.** If implementation reveals the plan
   has a contradiction or a wrong assumption, stop, write up the
   contradiction, and ask the user before editing the plan or the
   code.

### Final report format

```markdown
## Phase 1 — vocabulary scaffold
status: complete | blocked
files changed: ...
sanity check results: ...

## Phase 2 — walker rewrite
status: complete (logical correctness only) | blocked
files changed: ...
manual verification needed: live walk against signed-in host

## Phase 3 — resolver rewrite
status: complete (no live test possible until Phase 2 walk) | blocked
files changed: ...

## Open issues
- ...

## Diff for review
git diff --stat output
```

### What you should NOT do

- Do not run `npm run explore:walk` or `npm run explore:snapshot` —
  these need a signed-in host and burn time per attempt.
- Do not run U01 — there is no v7 inventory yet.
- Do not commit. The user reviews everything.
- Do not regenerate the auto-generated U01 file from v6. Phase 3 ends
  with the generator failing on v6 input; that's correct.
- Do not introduce a `legacy` field or a v6 fallback in the resolver.
  Cutover is atomic per the plan.
- Do not silence type errors. Fix them.
- Do not invent new design decisions. If the plan doesn't cover
  something, ask before deciding.

Begin with Phase 1. Read `docs/testing/fingerprint-v7-plan.md` first.
