# Fingerprint v7 Plan — Contextual, Account-Portable Identification

This is an executable plan for the v6 → v7 migration of the inventory
fingerprint shape used by `tools/test-harness/explore/walker.ts` and
`tools/test-harness/src/runners/U01_ui_visibility.spec.ts`. It can be
picked up by a fresh session — start at "Phase 1" and walk down.

## Where we are

`docs/testing/ui-inventory.json` v6 (captured 2026-05-03 against app
1.5354.0, 383 entries) records each interactive element with a
fingerprint of this shape:

```ts
fingerprint: {
  selector: 'button[aria-label="Search"]',
  ariaLabel: 'Search',
  role: null,
  tagName: 'BUTTON',
  textContent: null,
}
```

`U01` resolves entries by handing the `selector` field to Playwright.
The current scheme has three load-bearing failure modes:

1. **Account-specific names baked into selectors and IDs.** Entries
   like `root.button.awaaddrick-max` (the user's plan badge,
   `button:has-text("AWAaddrick·Max")`) hardcode the walker-author's
   username + plan tier. Any contributor running U01 against their
   own auth fails this entry on selector match — the element is
   structurally present, just labeled differently.
2. **Instance text in selectors of "stable" entries.** Search-result
   options, recent-conversations buttons, and pinned conversations
   carry titles like "Fine-tuning diffusion models with reinforcement
   learning" in their selectors. These are inherently per-account; the
   `kind: instance` taxonomy already exists to handle them, but the
   selector still encodes the literal title, so the v6 capture
   couldn't actually leverage `instance` semantics.
3. **Selector brittleness under cosmetic redesigns.** `button:has-text(...)`
   selectors break under any label change. `button[aria-label="..."]`
   selectors break under any aria-label rewrite (which the upstream
   team does for accessibility audits without warning). Neither
   strategy carries enough redundancy to recover when one signal drifts.

The reconciliation doc (`ui-inventory-reconciliation.md`) flags these
as "Walker coverage gap" and "Account-state-dependent" categories,
and the U01 brief lists per-user inventory regeneration as "a
separate workstream." This is that workstream.

## Design goals

In priority order:

1. **Account-portable.** A v7 inventory walked against User A's
   account matches against User B's renderer for any entry whose
   target element is structurally present in both accounts. Entries
   that genuinely don't exist in B's account fall back to the existing
   "skip if absent" semantics (`kind: instance` + ancestor-presence
   check).
2. **Resilient to cosmetic drift.** Label changes, aria-label
   rewrites, minified-class churn, and CSS rewrites must not
   invalidate the fingerprint when the element's semantic role and
   structural position survive.
3. **Surface drift before failure.** Soft drift (primary aria-path
   missed, relaxed-scope match recovered) attaches a warning to the
   test rather than passing silently. Hard drift (no strategy
   resolves) fails as today. The sweep gains a third state:
   `passed-with-drift`.
4. **Atomic cutover, not gradual migration.** v7 walker, v7 inventory
   schema, and v7 resolver land together. The committed v6 inventory
   gets invalidated the moment v7 walker ships; no parallel-emit
   compatibility window, no `legacy` selector fallback in the
   resolver. Two systems are worse than one.

Non-goals:

- Pixel-level visual diff. Separate concern; H05 is the right shape.
- AI / embedding-based matching. Out of scope for a Linux repackager.
- Behavioral fingerprints (click-and-verify-effect). Too expensive at
  383 entries.

## v7 schema

```ts
interface FingerprintV7 {
  // Primary: accessibility-tree path from nearest landmark down to
  // the leaf. Each step carries (role, optional name).
  ariaPath: AriaStep[];

  // The element itself. Drops `name` entirely when role + ariaPath
  // suffice for uniqueness on the captured surface.
  leaf: {
    role: string;                     // "button", "link", "menuitem", ...
    name: NameMatcher | null;
    siblingIndex: SiblingIndex | null;
  };

  // Stability classification — drives how strictly the resolver
  // matches. See "Kind-strictness matrix" below. Distinct from the
  // existing `kind` field (persistent / structural / menu / instance)
  // which captures *lifecycle*, not *match strictness*.
  classification: 'stable' | 'positional' | 'instance';
}

interface AriaStep {
  role: string;          // landmark / region / grouping role
  name: NameMatcher | null;  // optional — only included when needed
}

type NameMatcher =
  | { kind: 'literal'; value: string }       // "Search", "Cowork"
  | { kind: 'pattern'; regex: string };      // "\\w+·(Free|Pro|Max|...)"

interface SiblingIndex {
  role: string;          // role of siblings being indexed
  position: number;      // 0-based
  total: number;         // total siblings of that role at capture
}
```

## Capture algorithm

Run during walker.ts's element emission, after the surface has settled.

```text
captureFingerprint(element, surface):
  ariaPath = walkLandmarkAncestors(element)
    // Stop at <body>; emit a step for each role in
    // {banner, main, navigation, region, complementary,
    //  contentinfo, search, form, toolbar, menu, menubar,
    //  listbox, list, dialog, tablist, tabpanel, group}
    // with grouping role plus optional accessible name.

  role = element.role
  name = element.accessibleName

  // Step 1: try uniqueness without the name.
  matches = surface.queryAccessibleTree({
    ariaPath,
    leaf: { role }
  })
  if matches.length == 1:
    return { ariaPath, leaf: { role, name: null, siblingIndex: null },
             classification: 'stable' }

  // Step 2: still too broad — try the name as a discriminator,
  // shaping it if it looks instance-specific.
  classification = classifyName(name, surface)
  if classification != 'instance':
    nameMatcher = (classification == 'positional')
      ? null
      : (looksInstanceShaped(name)
          ? { kind: 'pattern', regex: shapeOfName(name) }
          : { kind: 'literal', value: name })
    matches = surface.queryAccessibleTree({
      ariaPath, leaf: { role, name: nameMatcher }
    })
    if matches.length == 1:
      return { ariaPath, leaf: { role, name: nameMatcher,
               siblingIndex: null },
               classification }

  // Step 3: still ambiguous — fall through to sibling position.
  siblings = element.parent.childrenWithRole(role)
  if siblings.length > 1:
    siblingIndex = {
      role,
      position: siblings.indexOf(element),
      total: siblings.length
    }
    return { ariaPath, leaf: { role, name: null, siblingIndex },
             classification: 'positional' }

  // Step 4: instance — assert ≥1 match within ariaPath.
  return { ariaPath, leaf: { role, name: null, siblingIndex: null },
           classification: 'instance' }
```

`queryAccessibleTree` should hit `Accessibility.getFullAXTree` over
CDP, not the DOM. The accessibility tree is what screen readers see
and what the platform APIs query — it's the substrate that aria
roles and accessible names actually live in.

## Name classifier

`classifyName(name, surface)` decides whether a name is `stable`,
`instance`, or `positional` (no usable name). Heuristics in priority
order:

```text
1. Empty / whitespace name      → 'positional'
2. Element is a list-row child  → 'instance'  (handled by ancestor
   role: option/listitem inside listbox/list)
3. Name matches a known
   instance-shape regex          → 'instance'  (record as pattern)
4. Name is in the corpus of
   "stable UI vocabulary"        → 'stable'
5. Default                       → 'stable' but flag for review
```

### Known instance-shape regexes

| Regex | Example match | Shape recorded |
|---|---|---|
| `/^.+·(Free\|Pro\|Max\|Team\|Enterprise)$/` | `AWAaddrick·Max` | `\\w+·<PLAN>` |
| `/^Opus \d/` `/^Sonnet \d/` `/^Haiku \d/` | `Opus 4.7Adaptive` | model-name passthrough (stable across users, just versioned) |
| `/\d{1,3}%$/` | `Usage: plan 11%` | `Usage: plan \d+%` |
| `/Today\|Yesterday\|\d+ (day\|hour\|minute)s? ago/` | `Today+12` | `<RELATIVE-DATE>(\\+\d+)?` |
| `/^\d+\.\d+ \w+/` | `1.5 GB` | `\d+\.\d+ \w+` |
| `/@\w+/` | `@aaddrick` | `@\w+` (treat as user-handle) |
| `/[A-Z][a-z]+ [A-Z][a-z]+ [a-z]/` (3+ word title-case) | `Fine-tuning diffusion models...` | treat as `'instance'`, no pattern |

These regexes live in a registry that's part of the v7 capture
config. Adding a new shape is a one-file change; the registry should
be ordered (first match wins) so specific patterns take precedence
over general ones.

### Building the stable UI vocabulary

After the walker finishes the BFS, run a second pass:

1. Collect every `accessibleName` from every captured element.
2. Bucket by `kind` (existing taxonomy).
3. Names appearing in 3+ entries with `kind: persistent` or
   `kind: structural`, across 2+ surfaces, are **stable**.
4. Names appearing in only 1 entry with `kind: persistent`/`structural`
   are **suspect** — flag for human triage during reconciliation.
5. Names in `kind: instance` entries are excluded from the corpus
   entirely.

Commit the resulting vocabulary list to
`docs/testing/ui-vocabulary.json` so future walks can use it without
re-deriving. Refresh the vocabulary on each major upstream release.

## Kind-strictness matrix

The existing `kind` field (`persistent` / `structural` / `menu` /
`instance`) tunes how strictly the resolver matches at runtime,
independently from the capture-time `classification`:

| kind | aria-path required | name required | siblingIndex strict | assertion |
|---|---|---|---|---|
| `persistent` | yes (deepest scope) | matcher must hit if present | yes | exactly 1 match |
| `structural` | yes (or 1 step shallower) | matcher OR position | flexible (±1 ok) | exactly 1 match |
| `menu` | yes, scoped to transient menu surface | literal text fallback ok | n/a | ≥1 match |
| `instance` | yes (closest list/listbox ancestor) | ignored | ignored | ≥1 match within scope |

Examples:

- `root.button.search` → `kind: persistent`, `classification: stable`,
  `name: null` (unique by ariaPath alone). Strict 1-match assertion.
- `root.button.awaaddrick-max` → `kind: persistent`, `classification: stable`,
  `name: { kind: 'pattern', regex: '\\w+·(Free|Pro|Max|...)' }`.
  Plan-shape pattern; user-portable.
- `root.button.search.option.untitled-conversationtoday+12` →
  `kind: instance`, `classification: instance`, no name, scoped to
  search-results listbox. Assert ≥1 option in listbox.
- `root.button.fine-tuning-diffusion-models-with-reinforcement-learning` →
  `kind: instance`, scoped to pinned-conversations list. Assert ≥1
  button in pinned list.

## Resolver / fallback chain

In `findByFingerprint`:

```text
resolve(fp):
  // Strategy 1 — primary: full aria-tree path
  result = tryAriaTreeMatch(fp.ariaPath, fp.leaf, fp.kind)
  if result.matched: return { found: true, strategy: 'aria-tree' }

  // Strategy 2 — relaxed aria scope (drop deepest landmark step
  // in the path; keep the rest). Catches the common case where the
  // upstream team adds or removes one container layer.
  if fp.ariaPath.length > 1:
    result = tryAriaTreeMatch(fp.ariaPath.slice(0, -1), fp.leaf, fp.kind)
    if result.matched: return {
      found: true, strategy: 'aria-tree-relaxed', drift: 'scope-shifted'
    }

  return { found: false, strategy: null }
```

When `drift` is set, attach a soft warning to the Playwright test
without failing it:

```ts
testInfo.attach('drift-warning', {
  body: JSON.stringify({
    entryId: entry.id,
    expected: fp.ariaPath,
    matchedVia: result.strategy,
    drift: result.drift,
    note: 'primary aria-tree match failed; recovered via fallback. ' +
          'Re-walk inventory before drift compounds.',
  }, null, 2),
  contentType: 'application/json',
});
```

CI exposes `drift-warning` as a separate counter alongside pass /
fail. Sweep summary becomes `383 passed, 12 with drift, 0 failed`.

## Migration plan

The cutover is atomic — no parallel-emit window. Walker, schema, and
resolver all flip from v6 to v7 in the same merge. The committed v6
inventory becomes invalid; first action after merge is a re-walk.

### Phase 1 — vocabulary scaffold (pre-walker)

The name classifier needs a stable-UI vocabulary corpus to
disambiguate suspect names from known-stable copy. Build it from the
existing v6 inventory before the walker rewrite:

1. Iterate `docs/testing/ui-inventory.json` v6.
2. Names appearing in 3+ entries with `kind: persistent` or
   `kind: structural`, across 2+ surfaces, are **stable**.
3. Names matching any registry regex (plan badge, model version,
   percentage, relative date, user handle) are **instance-shaped**.
4. Names appearing in only 1 entry, not matching a regex, not in
   `kind: instance` — flag for human triage.
5. Commit the resulting corpus to `docs/testing/ui-vocabulary.json`.

The corpus survives the walker rewrite — it's keyed on names, not on
v6 schema specifics.

### Phase 2 — walker rewrite

1. Add `Accessibility.getFullAXTree` query to walker's surface-settle
   step (or AX subtree at target node if full-tree latency is
   unacceptable; see open questions).
2. Implement `walkLandmarkAncestors`, `queryAccessibleTree`,
   `captureFingerprint` per the algorithm above.
3. Implement the name classifier consuming `ui-vocabulary.json` and
   the instance-shape registry.
4. Replace v6 fingerprint emit with v7. Inventory schema header bumps
   to `walkerVersion: 7`; v6 readers will fail loudly rather than
   silently mis-resolve.
5. Walker passes that fail to compute a v7 fingerprint (AX query
   error, accessible-name-computation failure) emit the entry with
   `classification: 'positional'` and `name: null`, scoped to its
   ariaPath. Uncaptured fingerprints are not silently dropped — they
   become positional entries with explicit looseness.

Acceptance: a walk against the v6-author's account produces v7
fingerprints for ≥98% of the surfaces v6 captured. ≥80% have
`classification: 'stable'`; the rest split between `'positional'` and
`'instance'`.

#### Live-walk shakedown (post-Phase 2)

The first end-to-end walks against the running renderer surfaced five
real bugs the synthetic selfTest couldn't see. All landed in
`walker.ts` / `name-classifier.ts` / `inspector.ts`:

1. **AX-tree settle gate.** `Accessibility.enable` populates the tree
   asynchronously; the existing `waitForStable` (1.5s ceiling on
   DOM-mutation quiescence) returned long before claude.ai's React
   tree mounted. Seed snapshots came back with 4 AX nodes (just the
   `RootWebArea` + a generic shell) and the walker emitted zero
   entries. Fix: `waitForAxTreeStable(inspector, { minNodes: 20 })`
   polls `getFullAXTree` until two consecutive reads return the same
   node count. Called once before the seed snapshot and once after
   each `navigateTo` in `redrivePath`. Baked into every
   `snapshotSurface` call too (with `minNodes: 1`) so post-click
   reads don't race the React update.
2. **`reloadPage` in `redrivePath`.** `navigateTo(url)` short-circuits
   when `currentUrl === url`, but every BFS pop re-navigates to
   `startUrl`, so any state a prior drill left behind (open dialog,
   expanded sidebar, scrolled focus) carried into the next redrive
   and contaminated `clickById`'s snapshot. Replaced the redrive's
   initial `navigateTo` with `location.reload()` to discard the
   React tree.
3. **List-row sibling-count heuristic.** The plan's `isListRowChild`
   check requires `option/listitem` inside `listbox/list`. claude.ai
   exposes the marketplace dialog as `dialog > button[]` with no
   list role at all (~80 cards) and the cowork sidebar as
   `complementary > button[]` (72 sessions). Without a heuristic,
   each row literal-matches by name and emits as a separate stable
   entry. Extension: `LIST_ROW_ROLES` includes `button`,
   `LIST_ANCESTOR_ROLES` includes `group`, AND `siblingTotal >= 15`
   on its own qualifies regardless of ancestor role. Step 3
   (positional fallback) also gates on `!isListRowChild` so list
   rows fall through to step 4's `instance` collapse instead of
   fragmenting into per-index positionals.
4. **Two new instance shapes** in `name-classifier.ts`:
   `cowork-session` matches status-prefixed session titles
   (`^(Idle|Ready|Working|Awaiting input|Pull request merged|Done|Failed|Cancelled)\s`)
   and `row-more-options` matches per-row triggers
   (`^More options for `). Both ordered before `long-title` so the
   pattern wins over the no-pattern instance fallback.
5. **Lookup-failure threshold bump** 25 → 75. Sidebar virtualization
   means the AX tree exposes a slightly different subset of cowork
   sessions on each fresh load; redrives accumulate
   "no element matches" misses in a row that aren't a real wedge.
   The timeout counter (5 strikes) still gates against actual
   renderer hangs.

Result on the AX migration's first clean walk
(`startUrl: claude.ai/epitaxy`, account: aaddrick, app 1.5354.0):
**90 entries** (37 persistent / 37 structural / 8 dialog / 8
instance), 6 denylisted, 23 non-fatal lookup misses. The marketplace
dialog folded to a single `button-instance+704`; the cowork sidebar
to `button-instance+72`; search history to `option-instance+25`.
Acceptance criteria from §Phase 2 met (≥98% structural overlap is
trivially true on a re-walk; ≥80% stable hit at 75/90 ≈ 83%).

### Phase 3 — resolver rewrite (U01 + walker.ts findByFingerprint)

1. Replace `findByFingerprint` body with the two-strategy chain
   (primary aria-tree, relaxed-scope fallback). Drop the v6
   selector code path entirely.
2. `gen-render-specs.ts` regenerates U01 from the v7 inventory; per-
   entry test bodies consume `entry.fingerprint` (now v7-shaped)
   directly.
3. Add the `drift-warning` attachment shape to U01's test runner.
4. Run U01 against the v7 inventory captured in Phase 2; baseline
   drift counts.

Acceptance: U01 against a fresh walker pass produces 0 drift
warnings on the same account, fails 0 entries. Drift warnings only
appear when actually-drifted elements are encountered.

### Phase 4 — account-portability validation

1. A second contributor walks their own v7 inventory.
2. Diff against the v6-author's v7 inventory: structural overlap
   should be ≥80% on `kind: persistent` and `kind: structural`
   entries (the cross-user-stable subset).
3. Run the v6-author's inventory's U01 against the second
   contributor's renderer (with `seedFromHost` lifting their auth).
4. Expect ≥80% pass on the cross-user-stable subset; `kind: instance`
   entries pass via the ancestor-presence check.

This is the actual goal. If account-portability hits, the inventory
is no longer a "my-account snapshot" but a true render contract.

## Open questions

### Resolved

- **CDP `Accessibility.getFullAXTree` cost.** Not a bottleneck. The
  signed-in `claude.ai/epitaxy` surface returns a 817-node tree;
  `waitForAxTreeStable` settles in <1s once Chromium has populated
  it. The cold-load gate dominates total latency, not per-call
  overhead. Plan B (subtree queries at the target node) is unused.
- **Role overrides.** Confirmed working. `Skip to content` on
  claude.ai is captured as `link` (its AX-computed role) regardless
  of the underlying tag — a class of mismatch the v6 DOM walker
  silently got wrong.
- **`account-bound` kind.** Not needed. The combination of
  shape-patterned name matchers (plan badge, cowork session) +
  the sibling-count list heuristic + persistent collapse handles
  every account-shaped element observed in the first clean walk.
  Re-evaluate if a future surface exposes account state without
  one of those signals.

### Open

- **Accessible-name computation parity.** Chrome's AX-tree-computed
  name should match what Playwright's `getByRole({ name })` matches
  at resolution time, but they're independent implementations of
  the ARIA name-computation spec. Validate at Phase 3 acceptance
  with a sample of 50 entries — capture vs resolve should agree.
- **Stale vocabulary across releases.** When upstream renames
  "Cowork" to "Workspaces" (hypothetical), the corpus needs to
  update. Should vocabulary be re-derived automatically on each walk
  (cheap, drift-following) or pinned to a committed version (stable,
  manual updates)? Provisionally: re-derive on walk, commit the
  derived corpus alongside the inventory so reconciliation can diff
  vocabulary changes.

## Cross-references

- `tools/test-harness/explore/walker.ts` — capture site
- `tools/test-harness/explore/walk-isolated.ts` — driver that runs
  the walk inside the test-harness `launchClaude` + `seedFromHost`
  isolation path (use this rather than `explore walk` to avoid
  mutating the host profile)
- `tools/test-harness/explore/gen-render-specs.ts` — emits U01 from
  inventory; needs to consume v7 fingerprints
- `tools/test-harness/src/runners/U01_ui_visibility.spec.ts` —
  resolver consumer
- `tools/test-harness/src/lib/inspector.ts` — `getAccessibleTree`
  + `clickByBackendNodeId` for the AX-driven capture/click pair
- `docs/testing/ui-inventory-reconciliation.md` — current v6 reconciliation
- `docs/testing/claudeai-ui-mapping-plan.md` — broader UI mapping
  strategy this fits inside
