# AX-tree substrate migration — implementation prompt

This file is meant to be **copied verbatim into a fresh Claude Code session** as the initial user message. Don't paraphrase it; the self-correction loop depends on the exact directives below.

---

## Prompt to paste

You are migrating the v7 fingerprint walker from DOM ancestor walking to Chromium's accessibility tree. The fingerprint shape doesn't change — only the substrate the walker captures from. Capture and resolve must switch together; they have to agree on the same name-and-role computation path or U01 will miss on cosmetic divergence between DOM-derived names and AX-derived names.

### Authoritative reference

- `docs/testing/fingerprint-v7-plan.md` — design contract for the fingerprint shape. Don't change the shape.
- `docs/testing/fingerprint-v7-implementation-prompt.md` — the prompt that built the current DOM-walk implementation. Read for context; don't re-do what's already there.

### Why this migration

Today `snapshotSurface` walks `el.parentElement` in a renderer IIFE and derives (role, name) from a hand-rolled tag→role implicit map (`HEADER`→`banner`, `NAV`→`navigation`, …) plus an `aria-label` / `aria-labelledby` / text-content cascade. That misses:

- `aria-owns` reparenting — DOM walk sees ancestors at the DOM position, AX tree shows them where the author logically reparented them.
- `aria-hidden` subtrees — DOM walk emits the nodes, AX tree prunes them.
- Authoritative name computation: `<input type=submit value=Send>`'s implicit name from `value`, image `alt` / `title` cascade, SVG `<title>` text, `<label for>` association.
- Role override edge cases: `<button role=link>` is treated as button by the implicit-map walk, link by AX.

The inspector already exposes `getAccessibleTree(urlFilter)` (wraps `Accessibility.getFullAXTree` via `webContents.debugger`). Use it.

### Repo conventions

- Tabs for indentation, lines under 80 chars, single quotes for literals, TypeScript strict mode (`tools/test-harness/tsconfig.json` enforces it).
- Comments only when the WHY is non-obvious.
- No backward-compatibility shims. DOM-walk and AX-tree paths cannot coexist; cutover is atomic.
- Don't commit. The user reviews and commits.

### Code anchors

`tools/test-harness/explore/walker.ts`:
- `snapshotSurface` — replace the renderer IIFE entirely.
- `RawElement` / `RawAncestor` — modify; `ancestors[]` now comes from AX parent walk, add `backendDOMNodeId` for click correlation, consider dropping `tagName` from RawAncestor (only used by `walkLandmarkAncestors` for nothing structural — verify).
- `walkLandmarkAncestors`, `queryAccessibleTree`, `captureFingerprint`, `idTailFromFingerprint` — contracts unchanged. Verify they still operate correctly on AX-derived RawElements.
- `findByFingerprint` — already delegates to `snapshotSurface` + `queryAccessibleTree`, so the resolve path follows capture automatically. Read it end-to-end and confirm no leftover renderer-side IIFE doing attribute matching.
- `clickRawElement` — currently locates the DOM node by `aria-label`/`role`/`textContent`. That fallback no longer makes sense when names come from AX (the DOM may not even have the attribute the AX name was computed from). Replace with backendNodeId-based click.
- `selfTest` — synthetic-AX-tree fixtures replace the synthetic `RawElement` `ancestors: [...]` fixtures. The plan example traces must produce the same fingerprint tails as today.

`tools/test-harness/src/lib/inspector.ts`:
- `getAccessibleTree` — already exists. The `Accessibility.enable` is idempotent + already-enabled tolerant.
- Add `clickByBackendNodeId(urlFilter, backendNodeId)`: `DOM.resolveNode({backendNodeId})` → objectId → `Runtime.callFunctionOn({objectId, functionDeclaration: 'function() { this.click(); }'})`.

### Phases

#### Phase A — AX-tree → RawElement adapter

Replace `snapshotSurface` so the rest of the walker doesn't change shape.

- Add `axTreeToSnapshot(nodes: AxNode[]): SurfaceSnapshot` to walker.ts.
- For each AX node whose role is in the interactive set (`button`, `link`, `menuitem`, `menuitemradio`, `menuitemcheckbox`, `tab`, `option`), build a RawElement:
  - `role` / `computedRole`: from `node.role.value`. AX is authoritative — they're the same value here, kept as separate fields only for the inventory's `role` column compatibility.
  - `accessibleName`: from `node.name.value`. Drop the `ariaLabel`-vs-`accessibleName` distinction — the AX tree already resolved the cascade. Update `bestName()` to read only `accessibleName`.
  - `ancestors`: walk `node.parentId` up the AX tree, recording `(role, name)` for each. `tagName` isn't on the AX node; if you keep `tagName` on `RawAncestor`, you'll need a per-ancestor `DOM.describeNode({backendNodeId})` round-trip. Don't — drop `tagName` from `RawAncestor` and verify nothing structural depends on it.
  - `siblingPosition` / `siblingTotal`: count parent-AX-node's children whose role matches. Don't double-count `ignored` siblings.
  - `visible`: `node.ignored === false` is the AX-native signal. Keep a defensive `DOM.getBoxModel` check only if Phase A traces show ignored=false nodes that don't actually render.
  - `backendDOMNodeId`: store `node.backendDOMNodeId` for click invocation.
  - Drop the renderer-side filters (`NON_RENDERED_TAGS`, button-with-no-content gate, zero-box). The AX tree handles all three via `ignored: true`. If a Phase A trace surfaces a regression (an interactive node that AX includes but shouldn't), document it and add a targeted filter — don't reinstate the whole gate.
- Replace `snapshotSurface`:
  ```ts
  async function snapshotSurface(inspector: InspectorClient): Promise<SurfaceSnapshot> {
    const url = await currentUrl(inspector);
    const nodes = await inspector.getAccessibleTree('claude.ai');
    return { url, elements: axTreeToSnapshot(nodes).elements };
  }
  ```

**Self-correction loop for Phase A:**
1. `cd tools/test-harness && npm run typecheck` — must pass.
2. `npx tsx explore/walker.ts` — selfTest must pass. Convert each `mkRaw({ ancestors: [...] })` fixture to a synthetic `AxNode[]` fed through `axTreeToSnapshot`. The seven plan-example traces (search / plan-badge / pinned conversation / sibling-positional / vocabulary lookup / list-row early-out / instance collapse) must produce the same `idTailFromFingerprint` outputs as today.
3. **Do not run a live walk.** AX tree latency at large surfaces is the plan's open question §1; that's a live-walk discovery, not a Phase A check.

#### Phase B — click path migration

- Add to inspector.ts: `clickByBackendNodeId(urlFilter: string, backendNodeId: number): Promise<void>`. Use `DOM.resolveNode` → `Runtime.callFunctionOn` with `function() { this.click(); }`.
- Replace `clickRawElement` body with one call: `inspector.clickByBackendNodeId('claude.ai', raw.backendDOMNodeId)`. Drop the aria-label / textContent fallback entirely. If `raw.backendDOMNodeId` is undefined, throw — it shouldn't happen post-Phase-A.
- `clickById` outer logic (snapshot + suffix-match the structural id-tail via `captureFingerprint`) doesn't change.

**Self-correction loop for Phase B:**
1. `npm run typecheck` — must pass.
2. Logical-correctness trace: a click on `root.banner.button-by-shape.plan-badge` resolves to the plan-badge AX node's backendDOMNodeId, not the parent banner's. Spot-check by reading clickById and clickRawElement end-to-end.
3. Do not run a live walk.

#### Phase C — resolve path verification

Phase A's `snapshotSurface` rewrite carries `findByFingerprint` along automatically (it delegates to snapshotSurface + queryAccessibleTree). Read findByFingerprint end-to-end and confirm: there is no remaining renderer-side IIFE doing DOM-attribute matching at resolve time. If you find one, delete it.

**Self-correction loop for Phase C:**
1. `npm run typecheck` — must pass.
2. Read findByFingerprint top to bottom. Confirm: snapshot path → AX tree only; query path → operates on AX-derived RawElements only.

### Self-correction loop (general protocol)

After each phase's specific loop:
1. If typecheck reports errors, fix root causes — no `// @ts-ignore`, no `any`, no `as unknown as …`.
2. Cap fix attempts per problem at **3**. After 3 attempts on the same issue without progress, stop and report.
3. Re-run the entire phase loop from step 1 after fixes.
4. Mark complete only when every step passes cleanly.

### Termination conditions

Stop and write a final report when one of:
1. **All three phases pass.** Report what's done, list manual verification (live walk against signed-in host), outline the diff.
2. **Hit the 3-attempt cap on a non-trivial issue.** Report attempts, why each failed, what's blocked.
3. **The plan needs to change.** E.g. the AX tree doesn't expose enough info for accurate sibling counting, or `ignored: true` covers cases we actually want to assert. Stop, document the contradiction, ask the user before editing.

### What you should NOT do

- Don't run `npm run explore:walk` or `npm run explore:snapshot` — both need a signed-in host.
- Don't commit. The user reviews everything.
- Don't keep both DOM-walk and AX-tree paths. Atomic switch.
- Don't silence type errors. Fix them.
- Don't invent new design decisions. If something comes up the plan doesn't cover (e.g. AX `ignored` nodes that still respond to clicks), ask before deciding.
- Don't regenerate U01 from any inventory. Phase 3 of the prior migration left U01 as a stub; this migration doesn't change that.

### Final report format

```markdown
## Phase A — AX-tree → RawElement adapter
status: complete | blocked
files changed: ...
selfTest results: ...
trace agreement with prior fingerprint tails: ...

## Phase B — click path migration
status: complete | blocked
files changed: ...

## Phase C — resolve path verification
status: complete | blocked
findings: any remaining DOM-attribute matching: ...

## Open issues
- ...

## Diff for review
git diff --stat output
```

Begin with Phase A. Read `tools/test-harness/explore/walker.ts` end-to-end first — in particular `snapshotSurface`, `RawElement`, `RawAncestor`, `walkLandmarkAncestors`, `captureFingerprint`, `findByFingerprint`, `clickRawElement`, and the `selfTest` block — so you understand what the AX migration is replacing.
