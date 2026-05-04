# test-harness runner implementation — session 14 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new primitive (`lib/ax.ts`) and NO new spec. Session 13 was a pivot:
Phase 0 calibration found the debugger detached on the dev box (port
9229 not listening — Claude was running but Developer → Enable Main
Process Debugger had not been clicked), which blocked Categories A
(operon-mode navigation probe) and C (schema-rev for
`listRemotePluginsPage` / `listSkillFiles`) — both need runtime
probing against a debugger-attached running Claude. Category B (Tier
3 read-only reframes) ALSO effectively needed the debugger for the
smoke-test investigation phase. Session 13 pivoted to the
PRIORITY-flagged DOM unification primitive, which was tractable
without the debugger because both consumer signals existed
statically: `claudeai.ts` had a private `snapshotAx`, T26 had a
duplicate inline copy explicitly noted as "premature abstraction at 1
consumer", plus the user reported recurring AX-query flake. Coverage
unchanged at 74/76 (97%) — primitive-only sessions don't move the
spec count. Two commits on `docs/compat-matrix` expected (SHAs
inserted after the test-harness commit lands — the user reviews and
commits at the end of every session):

- TBD — `test(harness): session 13 lib/ax.ts AX substrate primitive`
  (extracts `snapshotAx` from `claudeai.ts` private + T26 inlined
  duplicate; adds `waitForAxNode` / `waitForAxNodes` predicate-based
  polling helpers; re-exports `RawElement` / `AxNode` /
  `axTreeToSnapshot` / `waitForAxTreeStable` from `explore/walker.ts`
  so consumers stay inside `lib/`; refactors `claudeai.ts` and T26
  to consume the shared substrate).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 13** first, then
**session 12**, then **session 11**, then **session 10**, then
**session 9**, then **session 8**, then **session 7**, then **session
6**, then **session 5**, then **session 4**, then **session 3**, then
**session 2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 13

1. **Pre-existing T16 / T17 / T07 / S25 / S29-S31 flake confirmed
   on KDE-W against the unchanged baseline.** Running the full suite
   surfaced 12 failures, including T16 (CodeTab.activate: no AX-tree
   button with accessibleName="Code" found) and T17. Verified
   pre-existing by stashing the session-13 changes and re-running
   T16 — same failure. Session 13's primitive doesn't fix the existing
   flake; it lays groundwork. Future sessions can build flake-
   reduction patches against `lib/ax.ts`'s `waitForAxNode` (e.g.
   promote `activateTab`'s one-shot snapshot to a proper retry, or
   give T07's CSS-querySelector poll a more durable wait shape if
   that abstraction emerges).
2. **`lib/ax.ts` is the new shared AX-tree substrate.** Surface:
   - `snapshotAx(inspector, opts)` — single AX read with the
     stability gate. `opts.fast` skips the gate for inside-poll
     callers (matches the existing `claudeai.ts`/T26 contract).
   - `waitForAxNode(inspector, predicate, opts)` — repeatedly
     snapshot the tree and return the first matching `RawElement`,
     null on timeout. Gates on stability once at the start
     (configurable), then iterates with `fast: true`. Built against
     the inline polling loops in `CodeTab.activate`, `openPill`,
     `clickMenuItem`, T26 pre/post-click anchor scans — but the
     existing call-sites are NOT migrated this session (their per-
     spec retry budgets are tuned and changing them speculatively
     risks flake). Future call-site migrations are tractable.
   - `waitForAxNodes(inspector, predicate, opts)` — same shape,
     returns every match. For consumers that want to enumerate.
   - Re-exports: `RawElement`, `AxNode`, `axTreeToSnapshot`,
     `waitForAxTreeStable` — so consumers stay inside `lib/`
     instead of reaching into `explore/walker.ts` directly.
3. **The debugger-attachment precondition is binding.** Sessions 9
   through 12 did extensive runtime probing of the per-wc IPC
   registry against the user's debugger-attached Claude. Without
   that probing, Categories A / B / C in this prompt are blocked at
   the smoke-test phase. If the user hasn't clicked Developer →
   Enable Main Process Debugger before the session starts, port 9229
   is closed and the categories pivot to either documentation work
   or the call-site-migration shape that doesn't need runtime
   probing. Phase 0 must check `ss -tln | grep ':9229'` (or `curl
   --max-time 2 http://127.0.0.1:9229/json`) before fanning out.
4. **The reframe pool remains essentially exhausted.** Same status
   as session 12 — every Tier 1 fingerprint with a tractable runtime
   sibling has been promoted. The remaining options are now: (a)
   call-site migration to `waitForAxNode` for flake reduction, (b)
   operon-mode navigation probe (still needs debugger), (c) schema-
   rev for `listRemotePluginsPage` / `listSkillFiles` (still needs
   debugger), (d) Tier 3 read-only reframes (most need user-account
   state). The natural next-session shape is (a) — flake reduction
   builds on session 13's primitive and doesn't need the debugger.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 13**, then
  **session 12**, then **session 11**, **session 10**, **session 9**,
  **session 8**, **session 7**, **session 6**, **session 5**, **session
  4**, **session 3**, **session 2**, then **session 1** "Status (post-
  execution)" sub-sections. The Tier-3 list (search for "## Tier 3")
  is the candidate pool for any further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-74-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note, and the new `lib/ax.ts` substrate (session 13 addition;
  consumer list is `claudeai.ts` page-objects + T26).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Session 13 added `lib/ax.ts`; surface
  is `snapshotAx` / `waitForAxNode` / `waitForAxNodes` plus re-
  exports of `RawElement` / `AxNode` / `axTreeToSnapshot` /
  `waitForAxTreeStable`. The session 8 eipc surface
  (`getEipcChannels` / `findEipcChannel` / `findEipcChannels` /
  `waitForEipcChannel` / `waitForEipcChannels` / `invokeEipcChannel`
  on `lib/eipc.ts`) is unchanged.
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against a
  debugger-attached Claude (`Developer → Enable Main Process
  Debugger` from the menu) to capture the current registry shape.
  Sessions 11 / 12 used small one-off smoke-tests in the test-
  harness dir that clone the InspectorClient connection pattern
  and run N candidate read-sides through M arg shapes; deleted
  after.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 13
  candidates for follow-up:
  - `T26_routines_page_renders.spec.ts` — first consumer of
    `lib/ax.ts`'s exported `snapshotAx` (refactored from inline).
    Other AX-using specs (T16, T17, H05) still call through
    `claudeai.ts` page-objects which use the shared substrate
    transparently.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~1 new spec OR one substantive flake-reduction
deliverable OR one investigation.** Sessions 9-12 each landed 1-2
specs; session 13 landed only a primitive (debugger blocked).
Coverage at 74/76 means the test budget naturally shifts toward
either (a) flake reduction against `lib/ax.ts`'s primitive, (b)
investigation that requires the debugger and was deferred from
sessions 12-13, or (c) Tier 3 read-only reframes that the harness
can construct from existing `seedFromHost` state.

**Phase 0 MUST check the debugger BEFORE picking a category.** Run
`ss -tln 2>/dev/null | grep ':9229'` (or
`curl --max-time 2 http://127.0.0.1:9229/json`). If port 9229 is not
listening, Categories A and C are hard-blocked. Pivot to D or B.

#### **PRIORITY: Call-site migration to `lib/ax.ts`'s
`waitForAxNode` for flake reduction.** Session 13 landed the
substrate; this session can promote the inline retry loops in
`claudeai.ts` (`activateTab` is the strongest candidate — it does a
one-shot snapshot with no retry, which is exactly the failure mode
T16 hits). Smaller-scope candidates: `findCompactPills` (one-shot
snapshot, no retry — same shape as `activateTab`), `openPill`'s
post-click while-loop, `clickMenuItem`'s while-loop. Each migration
is a localized refactor; verify by running the affected specs
(T16/T17/T26/H05) and checking pass rate. Don't speculatively
change the budget defaults — match the existing per-spec retry
budgets so the migration is shape-only. **If this is what session
14 ships, that's a strictly higher-impact outcome than another Tier
2 / Tier 3 reframe — flake reduction touches every existing AX-
using spec.** Doesn't need the debugger.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **D** call-site migration to `waitForAxNode` | `claudeai.ts` page-objects + T26 + future Code-tab AX work | `lib/ax.ts` (session 13 primitive) | The PRIORITY shape this session. Promote `activateTab`'s one-shot snapshot to use `waitForAxNode`; same for `findCompactPills`. Validate by re-running T16 / T17 / T26 / H05 against the migrated form. Doesn't need the debugger. Risk: changing the retry shape can introduce new flake if the budget defaults don't match the existing per-spec tuning — keep migrations shape-only, no budget changes. |
| **A** operon-mode navigation probe | n/a (investigation) + maybe small Tier 2 reframe | new probe + bundle grep for operon URL routes | Session 10 confirmed `OperonBootstrap.ensure` registers eagerly but the other 21 wrapper-exposed operon interfaces remain registry-unconfirmed. Outputs: either an operon-mode URL form recovered from the bundle (search for `operon`-keyed routes in `claude.ai/...` paths) plus a registry re-probe after navigation, OR a deferral note explaining why operon scope can't be reached without an operon-mode entry. **Needs debugger-attached Claude on port 9229.** |
| **B** Tier 3 read-only reframes | Pick from the Tier 3 list | T33c / T35b / T37b template + bundle grep | The Tier 3 list is full of login-required flows; some have read-only entry points that the harness CAN construct. Candidates: T22's `getPrChecks` read-side might accept a non-existent PR number / dry-run mode; T15's OAuth surface has read-only state queries. Most need the user-account-scoped state to fail-fast with a clean error rather than a real network roundtrip — investigate first. **Needs debugger for smoke-test verification.** |
| **C** Schema-rev for `listRemotePluginsPage` / `listSkillFiles` | Bundle grep | session 9 schema-rev pattern | Both methods rejected every smoke-tested arg shape during session 12's investigation. `listRemotePluginsPage` needs `limit: number` at position 0 (rejection: `Argument "limit" at position 0 ...`); `listSkillFiles` needs both `pluginId` and `skillName` (rejection: `Argument "skillName" at position 1 ...`). Bundle-grep on the rejection literals → resolve the schema → ship a narrowly-scoped Tier 2 invocation if it unblocks a case-doc claim. **Needs debugger to verify the recovered schema.** |

If port 9229 is closed, only D is fully tractable. A documentation-
only session that audits the existing AX call-sites and proposes a
migration plan (without shipping) is also acceptable — pre-work for
a future session that DOES land the migration.

#### Category D — call-site migration to `waitForAxNode`

The plan: promote inline AX retry loops in `claudeai.ts` to use
`waitForAxNode` from `lib/ax.ts`.

1. **Audit the call-sites.** `activateTab` does one-shot snapshot,
   no retry — direct candidate. `findCompactPills` same. `openPill`
   post-click while-loop and `clickMenuItem` while-loop both do
   snapshot+filter+sleep — convert to `waitForAxNode` /
   `waitForAxNodes` with the existing budget. T26's pre/post-click
   `retryUntil` blocks are also direct candidates.
2. **Migrate one call-site at a time.** Run the affected specs after
   each migration (T16 / T17 / T26 / H05). Don't migrate all at
   once — one bad budget change can cascade across multiple specs.
3. **Don't change the retry budgets.** The existing per-spec timeouts
   are tuned (CodeTab.activate uses 5s default but T16 passes 15s);
   match them when migrating.
4. **Don't add new functionality.** This is a shape-only refactor.
   If a migration reveals a budget that's clearly wrong (e.g.
   `activateTab` has NO retry today, which is the T16 failure mode),
   that's a small bug-fix the migration corrects — but document it.

#### Category A — operon-mode navigation probe

The plan: find an operon-mode URL form and verify whether the other
21 operon interfaces register lazily.

1. **Bundle grep for operon URL routes.** Search the bundled
   `index.js` and `mainView.js` for `operon`-keyed paths (e.g.
   `/operon/...`, `claude.ai/operon`, etc.). Compile a candidate URL
   list.
2. **Navigate the user's debugger-attached running Claude** to each
   candidate URL via `inspector.evalInRenderer('claude.ai',
   "window.location.href = '<URL>'")`. After each navigation, re-run
   the registry probe and check the operon scope's interface count.
3. **If any URL surfaces additional operon handlers**, ship a small
   Tier 2 reframe spec.
4. **If none of the candidate URLs surface additional handlers**,
   document as "operon scope handlers register lazily on a navigation
   we can't easily construct from the harness" and defer.

**Needs debugger-attached Claude on port 9229.**

#### Category B — Tier 3 read-only reframes

The plan: identify a Tier 3 spec where a non-destructive read-side
is invocable from a fresh `seedFromHost` isolation.

1. **Read the Tier 3 list** in plan-doc and pick 1-2 candidates with
   read-side anchors. Most Tier 3 specs are write-side flows (T15
   OAuth, T22 PR write, T27 scheduling write, T29 worktree creation,
   T34 OAuth, T36 hooks-fire-on-prompt-submit) — those are out of
   scope. The exceptions are read-side anchors that just need
   user-account-scoped data to assert against.
2. **Smoke-test the candidate read-side** with various arg shapes.
3. **Ship a Tier 2 reframe** if the read-side resolves cleanly.
4. **Defer** if every candidate requires real account state to assert
   meaningfully.

**Needs debugger for smoke-test verification.**

#### Category C — Schema-rev for rejecting read-sides

The plan: resolve the validator schema for `listRemotePluginsPage` /
`listSkillFiles` via bundle grep, ship invocations if either unblocks
a case-doc claim.

1. **Grep on the rejection literal** in the bundled `index.js`.
   Validator block sits ~50-200 chars before the throw site (session
   9 finding). Read ~2KB around the hit to surface the full schema.
2. **Smoke-test the recovered schema** against the user's debugger-
   attached running Claude.
3. **Connect the resolved invocation to a case-doc claim.**
4. **Ship a Tier 2 invocation** if a case-doc claim is unblocked.

**Needs debugger to verify the recovered schema.**

#### Cross-compositor focus-shifter expansion (NOT recommended this session)

Building `lib/input-sway.ts` / `lib/input-hypr.ts` would mirror
`lib/input-niri.ts`'s shape but no consumer is asking for them.
Premature abstractions are wrong abstractions. Wait for a real
consumer.

#### Main-side `invokeEipcChannel` fallback (NOT recommended this session)

Same status as sessions 8-13 — wait for a real consumer.

#### Launch event-subscription primitive (NOT recommended this session)

Same status as sessions 11-13 — wait for a real consumer.

#### `waitForRenderedSurface` registry (NOT recommended this session)

Session 13's `lib/ax.ts` deliberately did NOT ship a named-surface
registry; promote when a third consumer crystallizes with a specific
surface name in mind.

#### CSS-querySelector primitive (NOT recommended this session)

Session 13's `lib/ax.ts` covers AX-tree consumers only. T07's CSS-
querySelector poll for the topbar is a different abstraction (DOM,
not AX). Wait for a second consumer before extracting.

### Constraints to respect (don't violate)

These are unchanged from sessions 1-13 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T07/T11_runtime/T16/T17/T19/T20/T21/T26/T22b/T27/T31b/T33b/T33c/T35b/T37b/T38b
  are the templates.
- **eipc handlers register on `webContents.ipc._invokeHandlers`,
  NOT global `ipcMain._invokeHandlers`.** Session 7 finding. Use
  `lib/eipc.ts` rather than rolling a new walker. The framing
  prefix `$eipc_message$_<UUID>_$_` should stay opaque to consumers
  (UUID has been stable but `lib/eipc.ts` doesn't pin it — match
  by case-doc-anchored suffix).
- **eipc invocation goes through the renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`.** Session 8 finding.
  Use `lib/eipc.ts`'s `invokeEipcChannel` rather than rolling
  main-side direct calls.
- **For arg validator schema-rev: try smoke-test first, then grep
  the rejection message literal.** Session 9 finding. Trivial
  validators (`typeof === 'string'` / similar) resolve in one
  round-trip. Elaborate validators get the bundle-grep treatment.
- **For session-scoped Tier 2 reframes: `LocalSessions/getAll` is
  the foundational read-side surrogate.** Session 10 finding.
- **For Tier 2 reframes with case-doc-anchored read-side handlers:
  invoke the case-doc-anchored handlers directly.** Session 11
  finding. Mixed-shape dual invocation is fine.
- **For Tier 2 reframes spanning two interfaces: invoke a read-side
  from each.** Session 12 finding (T11_runtime template).
- **For AX-tree consumers: use `lib/ax.ts`.** Session 13 finding.
  `snapshotAx` for one-shot reads, `waitForAxNode` /
  `waitForAxNodes` for predicate-based polling. Don't reach into
  `explore/walker.ts` directly — re-exports go through `lib/ax.ts`.
  Consumers in session 13: `lib/claudeai.ts` page-objects + T26.
- **`lib/input.ts` is X11-only.** Strict gate.
- **`lib/input-niri.ts` is Niri-only.** Strict gate.
- **Don't speculate on `lib/input-wayland.ts` dispatcher.**
- **Code-tab AX anchors stay in plan-doc until a consumer needs
  them.**
- **CDP auth gate is alive** — runtime SIGUSR1 attach via
  `app.attachInspector()`, never Playwright's `_electron.launch()`
  or `chromium.connectOverCDP()`.
- **BrowserWindow Proxy gotcha** — use
  `webContents.getAllWebContents()` not
  `BrowserWindow.getAllWindows()`. Constructor-level wraps don't
  work; use prototype-method hooks.
- **`skipUnlessRow()` always first.**
- **No fixed sleeps.** `retryUntil` from `lib/retry.ts`, or
  Playwright auto-wait, or `waitForAxNode` from `lib/ax.ts`.
  (Exception: short sleeps inside hand-rolled retry loops that
  catch typed errors and short-circuit; see S11 / S14.)
- **Diagnostics on every run.** `testInfo.attach()` the artefacts.
- **Tag with annotations.** `severity:` and `surface:` on every
  test so JUnit carries them through to matrix-regen.
- **Tabs in TS, ~80-char wrap as the existing files do.**
- **Don't break existing runners.** `npm run typecheck` must stay
  clean. H01-H05 are the canaries; `npm test` must still pass them
  after every commit. Note that T16/T17/T07/S25/S29-S31/S04 etc.
  are pre-existing-flaky on KDE-W per session 13's full-suite run
  — they're NOT canaries; baseline failures don't block work.
- **Always grep the installed asar** to verify a fingerprint
  string is present.
- **For mock-then-call: the helper goes in
  `lib/electron-mocks.ts`.**
- **Marker windows / sacrificial host processes always die in
  `finally`.**
- **Never log handler response BODIES into JUnit.**

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. **Check debugger:** `ss -tln 2>/dev/null | grep ':9229'` (or
   `curl --max-time 2 http://127.0.0.1:9229/json`). If port 9229 is
   open, A / B / C are tractable; if closed, pivot to D or
   documentation-only.
3. Read the plan doc's "Status (post-execution)" session 13 section,
   then read `lib/ax.ts`'s API + `T26` and `claudeai.ts`'s
   integration. Confirm you understand the `snapshotAx` /
   `waitForAxNode` / `waitForAxNodes` surface.
4. Pick ONE Category as the main bet:
   - **D** (PRIORITY when debugger is closed): pick 1-2 call-sites
     in `claudeai.ts` to migrate, list which.
   - **A**: bundle grep + per-URL navigation + registry re-probe.
   - **B**: pick a Tier 3 candidate, smoke-test the read-side, decide
     ship or defer.
   - **C**: bundle grep on rejection literals, schema-rev, smoke-test
     the resolved shape, decide ship or defer.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category D (call-site migration):
- Single subagent migrates 1-2 call-sites in `claudeai.ts` to use
  `waitForAxNode`. Verify by running T16 / T17 / T26 / H05.

For Category A (operon investigation):
- Single subagent does bundle-grep for operon URL routes + per-URL
  registry re-probe. Report findings; if a Tier 2 reframe is
  tractable, ship one spec.

For Category B (Tier 3 read-only reframes):
- Spawn ONE subagent for the candidate read-side investigation
  (smoke-test + bundle-grep if needed).

For Category C (schema-rev):
- Single subagent does bundle-grep on the rejection literals,
  surfaces the validator schemas, smoke-tests the recovered shapes
  against the user's debugger-attached running Claude.

Cap at ~1 spec OR ~1 primitive migration total — same scope as
sessions 9-13.

#### Per-subagent prompt shape

```
You're implementing ONE [test-harness runner | primitive migration |
investigation] for <TARGET>.

Read in order:
- docs/testing/cases/<FILE>.md (focus on <TARGET>'s Code anchors)
- tools/test-harness/README.md (conventions; status section names
  the most-recent-template that fits)
- tools/test-harness/src/runners/<closest-template>.spec.ts
- tools/test-harness/src/lib/ (the primitives you'll reuse —
  including session 13's `lib/ax.ts`)
- CLAUDE.md (project conventions)

Write tools/test-harness/src/runners/<TARGET>_short_name.spec.ts
[ AND/OR  tools/test-harness/src/lib/<NEW-PRIMITIVE>.ts ].

[per-task specifics: pattern (seedFromHost / mock-then-call /
asar fingerprint / shared isolation / new-primitive-build /
investigation / call-site migration), assertion shape, skip rules,
key constraint warnings]

Constraints:
- Tabs, ~80-char wrap.
- Use lib/* primitives; don't reinvent.
- testInfo.attach() the diagnostics from the spec's "Diagnostics
  on failure" block.
- Tag with severity + surface annotations.
- No fixed sleeps. retryUntil, Playwright auto-wait, or
  waitForAxNode.
- npm run typecheck must stay clean after your edits.
- Don't commit. The user reviews and commits.

If the target isn't reasonable to implement (anchors don't resolve
to anything assertable, the test depends on state you can't
construct, the existing primitives don't cover the surface), DO
NOT write a stub. Report under Open questions and stop. Sessions
1-13 had cumulative ~17 "stop and report" outcomes that were the
right call.

Report shape (~150 words):
## <TARGET> [runner | primitive | investigation | migration]

- File written: tools/test-harness/src/runners/<filename>.spec.ts
  [or lib/<newfile>.ts or modified lib/<existing>.ts]
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) |
  pgrep | new-primitive | investigation | migration
- Assertion shape (or migration shape): <one sentence>
- Skip rules: <which rows + why>
- Verification path: <typecheck + run result>
- Open questions: <caveats>
```

#### Phase 2 — synthesis

After fan-out returns:

1. `cd tools/test-harness && npm run typecheck` — must stay clean.
2. Run the new / migrated runners against KDE-W (the dev box) — but
   flag the user first if any are destructive (seedFromHost kills
   running Claude). Capture pass/skip/fail per spec for the matrix.
3. Update [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
   "Status (post-execution)" section to reflect newly-shipped
   specs / primitive migrations and any reclassifications.
4. Update [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
   inventory table.
5. Write a final report listing:
   - Specs landed / migrations completed (pass / skip / needs-tuning per row)
   - Primitives landed (with API shape)
   - Specs deferred (with the per-test rationale)
   - Specs reclassified (Tier 3 → Tier 2, Tier 2 → Tier 1, etc.)
   - Updated coverage stat (was 74/76 = 97%, now N/76 = M%)
6. Commit and push to `docs/compat-matrix` (the orchestration
   directive at the top of the followup supersedes "don't commit").
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-13:

1. Subagent typecheck failure → re-spawn with explicit fix
   instruction.
2. Subagent claims a runner / migration exists but `git status`
   shows no new file → re-spawn with explicit "use the Write tool"
   instruction.
3. Two subagents wrote runners that share a primitive but with
   different shapes → factor into `lib/<topic>.ts` BEFORE shipping.
4. Spec passes locally but the assertion is actually trivial → re-
   examine the assertion shape.
5. Migration breaks an existing spec → roll back the migration; the
   per-spec retry budget was load-bearing and the primitive
   defaults didn't match. Document the budget mismatch in plan-doc.
6. **Carry-over from session 5/6/7/8/9/10/11/12/13:** If the chosen
   Category's investigation doesn't resolve / requires schema-rev
   that exceeds budget after 2-3 approaches, STOP. Don't keep
   digging — pivot to a fallback Category. Document what was tried.
7. **Carry-over from session 10:** If a registration probe surfaces
   "registered but uninvocable", document and defer rather than
   building the main-side fallback speculatively.

Cap re-spawns at 2 per file. Past that, mark as needing human
review and move on.

### Termination conditions

Stop and write the final report when one of:

1. **Main-bet Category target landed and typecheck-clean.** Write
   coverage update, stop.
2. **Hit re-spawn cap on 2+ tasks.** Stop, write up which are
   blocked.
3. **Discovered a primitive gap that breaks 5+ Tier 2/Tier 3
   tests.** Stop, propose where the new primitive should live in
   `lib/`. Future session adds the primitive first, then resumes.
4. **Session budget hits ~1 new spec OR one new primitive
   landing OR one substantive call-site migration.** Stop,
   synthesize, leave the rest for the next session.
5. **All categories blocked after 2-3 attempts each.** Document the
   findings as plan-doc additions and stop — coverage is at 97%, a
   no-spec session that surfaces deferral notes is fine.

### What you should NOT do

- **Don't try to land Category D + A + B + C in one batch.** Pick
  ONE as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder.
- **Don't break existing runners.** H01-H05 are the canaries.
  T16 / T17 / T07 / S25 / S29-S31 are pre-existing-flaky on KDE-W
  per session 13's full-suite run — those are NOT canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling write, T29
  worktree creation, T34 OAuth, T36 hooks-fire-on-prompt-submit).
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Use `lib/eipc.ts`.
- **Don't call `invokeEipcChannel` for write-side handlers.**
- **Don't bolt other compositors into `lib/input-niri.ts`.**
- **Don't bolt Wayland into `lib/input.ts`.**
- **Don't speculate on a `lib/input-wayland.ts` dispatcher.**
- **Don't preemptively build `CodeTab.activateTopTab()` /
  `startNewSession()`.**
- **Don't add a main-side `invokeEipcChannel` fallback
  speculatively.**
- **Don't speculate on a Launch event-subscription primitive.**
- **Don't extract T07's CSS-querySelector poll into `lib/ax.ts`.**
  That's a different abstraction (DOM, not AX). Wait for a second
  CSS-poll consumer before extracting.
- **Don't add a `waitForRenderedSurface(client, surfaceKey)`
  registry to `lib/ax.ts`.** Session 13 deliberately deferred
  this — wait for a third consumer with a specific named surface.
- **Don't change the existing per-spec retry budgets when migrating
  to `waitForAxNode`.** The budgets are tuned. Migration is shape-
  only.
- **Don't reach into `explore/walker.ts` for AX types/helpers.**
  `lib/ax.ts` re-exports `RawElement` / `AxNode` /
  `axTreeToSnapshot` / `waitForAxTreeStable` — use those.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.

### Final report format

```markdown
## Runner implementation summary (session 14)

- Main-bet category: D | A | B | C
- Specs landed: N
- Migrations completed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 74/76 (97%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| D | <call-site> | <file>.ts | … | ✓ pass / skip / fail |
| ... |

## Notable findings
- ...

## Open questions
- ...

## Files touched
git status output.

## Diff summary
git diff --stat
```

### Operational notes

- Subagents are launched in parallel via a single message with
  multiple Agent tool calls. Don't serialise.
- Each subagent's Write calls land directly in the working tree.
- The grounding probe (`tools/test-harness/grounding-probe.ts`)
  can help when implementing a runner that asserts runtime API
  state.
- The eipc-registry probe (`tools/test-harness/eipc-registry-probe.ts`)
  is the dedicated tool for inspecting per-wc IPC handler state.
  Connects to a debugger-attached running Claude on port 9229.
- For seedFromHost specs, the host MUST have a signed-in Claude
  Desktop. The primitive throws with a clear message if not.
- For tests that touch the AX tree, **`lib/ax.ts`** is the new
  shared substrate. `claudeai.ts` page-objects are still the
  right substrate for renderer-UI domain operations (CodeTab,
  compact pills, menu items) — they consume `lib/ax.ts`
  internally. Don't query DOM by CSS selector unless `claudeai.ts`
  doesn't already cover the surface.
- For mock-then-call: helpers live in `lib/electron-mocks.ts`.
- For focus-shifting (X11 only): `lib/input.ts` exports
  `focusOtherWindow` + `spawnMarkerWindow`.
- For Wayland-native focus-shifting (Niri only): `lib/input-niri.ts`.
- For eipc registry walking: `lib/eipc.ts` exports
  `getEipcChannels` / `findEipcChannel` / `findEipcChannels` /
  `waitForEipcChannel` / `waitForEipcChannels`.
- For eipc invocation: `lib/eipc.ts` exports `invokeEipcChannel`.
  Only call read-side suffixes; the primitive doesn't enforce a
  read-only allowlist.
- **For arg validator schema-rev (sessions 9 / 11 / 12 findings):**
  smoke-test first, bundle-grep on rejection literal as fallback.
- **For session-scoped Tier 2 reframes (session 10 finding):**
  `LocalSessions/getAll` foundational read-side surrogate.
- **For Tier 2 reframes with case-doc-anchored read-side handlers
  (session 11 finding):** invoke directly. Mixed-shape OK.
- **For Tier 2 reframes spanning two interfaces (session 12
  finding):** invoke a read-side from each impl object.
- **For AX-tree polling (session 13 finding):** `lib/ax.ts`'s
  `waitForAxNode` / `waitForAxNodes` for predicate-based polling.
  `snapshotAx` for one-shot reads. Re-exports keep
  `explore/walker.ts` types accessible without crossing the
  lib/explore boundary.
- **For asar fingerprints: ALWAYS grep the installed asar
  first.** Build-reference is beautified; the bundle is
  minified.
  ```bash
  cd tools/test-harness && node -e "
    const {extractFile} = require('@electron/asar');
    const buf = extractFile(
      '/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar',
      '.vite/build/index.js'
    );
    const s = buf.toString('utf8');
    for (const k of ['<your-needle>', '<another>']) {
      console.log(k, '->', s.split(k).length - 1);
    }
  "
  ```

Begin with Phase 0. Don't fan out until calibration succeeds.
