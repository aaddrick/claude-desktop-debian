# test-harness runner implementation — session 13 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new spec (T11_runtime) by way of registering five install-flow
suffixes plus invoking BOTH case-doc-anchored read-side getters across
TWO distinct impl objects (CustomPlugins + LocalPlugins). First cross-
impl-object dual invocation. No primitive change. Coverage 73/76 (96%)
→ 74/76 (97%). Two commits on `docs/compat-matrix` expected (SHAs
inserted after the test-harness commit lands — the user reviews and
commits at the end of every session):

- TBD — `test(harness): session 12 T11 plugin install runtime`
  (Tier 2 reframe; multi-suffix `waitForEipcChannels` over the
  install-flow suffixes — `CustomPlugins/installPlugin` (case-doc
  :507181) / `uninstallPlugin` / `updatePlugin` /
  `listInstalledPlugins` / `LocalPlugins/getPlugins` — plus dual
  `invokeEipcChannel` across TWO impl objects:
  `CustomPlugins_$_listInstalledPlugins` with `args = [[]]` (empty
  `egressAllowedDomains`, T33c pattern) and `LocalPlugins_$_getPlugins`
  with `args = []`; passes on KDE-W in 28.8s cold).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 12** first, then
**session 11**, then **session 10**, then **session 9**, then **session
8**, then **session 7**, then **session 6**, then **session 5**, then
**session 4**, then **session 3**, then **session 2**, then **session
1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 12

1. **`LocalPlugins` registers 15 methods, `CustomPlugins` 16.**
   Smoke-test against the user's debugger-attached running Claude
   surfaced the full method list. Cleanly invocable read-sides:
   `LocalPlugins.getPlugins()` → array (length 0 on dev box),
   `LocalPlugins.getDownloadedRemotePlugins()` → array,
   `CustomPlugins.listInstalledPlugins([[]])` → array,
   `CustomPlugins.listMarketplaces([[]])` → array (also T33c),
   `CustomPlugins.listAvailablePlugins([[]])` → array (also T33c),
   `CustomPlugins.getCachedCommands()` → array,
   `CustomPlugins.getInstallCounts()` → null,
   `CustomPlugins.getAndClearMigrationIssues()` → null,
   `CustomPlugins.listLocalOrgPlugins()` → array. Three methods need
   pluginId at position 0 but accept any string (not just real plugin
   IDs): `getPluginOAuthStatus`, `getPluginCliStatus`,
   `getPluginShimOps`. **Two methods need extra args not derivable
   from a fresh isolation:** `LocalPlugins.listSkillFiles` (positional
   `pluginId` + `skillName` — `[]` rejects, `[cwd]` rejects too,
   needs both); `CustomPlugins.listRemotePluginsPage` (positional
   `limit: number` at 0 — every smoke-tested arg shape rejected;
   schema-rev would resolve this via grep on the `Argument "limit" at
   position 0` literal).
2. **Cross-impl-object dual invocation is the strongest Tier 2
   pattern** when the case-doc surface spans two interfaces. T11's
   install flow involves both `CustomPlugins.*` (the API/marketplace
   side that drives install) and `LocalPlugins.*` (the local-fs side
   where plugins land). T11_runtime invokes one read-side from each
   rather than picking one. Strictly stronger than single-interface
   coverage — proves the install plumbing crosses both impls intact.
   Mixed-arg-shape fine (one needs `[[]]`, another `[]`); same as
   T21's mixed-shape (one returns array, another returns boolean).
3. **The Tier 2 reframe pool is essentially exhausted.** Every Tier 1
   fingerprint with a tractable runtime sibling has been promoted.
   The remaining deferred items are Tier 3 (login-required write-side
   flows), Tier 4 (out of scope), or schema-rev work to unblock the
   still-rejecting read-sides surfaced this session
   (`listRemotePluginsPage`, `listSkillFiles`).

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 12**, then
  **session 11**, **session 10**, **session 9**, **session 8**,
  **session 7**, **session 6**, **session 5**, **session 4**, **session
  3**, **session 2**, then **session 1** "Status (post-execution)"
  sub-sections. The Tier-3 list (search for "## Tier 3") is the
  candidate pool for any further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-74-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note (covers registry walk, renderer-wrapper invocation, the
  schema-rev pattern from session 9, the foundational-getAll
  pattern from session 10, the dual-case-doc-anchored-read-side
  pattern from session 11, and the cross-impl-object dual
  invocation pattern from session 12).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. No session 12 additions; surface remains
  the session 8 shape (`getEipcChannels` / `findEipcChannel` /
  `findEipcChannels` / `waitForEipcChannel` / `waitForEipcChannels` /
  `invokeEipcChannel` on `lib/eipc.ts`).
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against a
  debugger-attached Claude (`Developer → Enable Main Process
  Debugger` from the menu) to capture the current registry shape.
  Session 12 used a small one-off smoke-test in the test-harness
  dir (`localplugins-smoke.ts` — clones the InspectorClient
  connection pattern from eipc-registry-probe.ts, dumps full
  method lists for plugin-related interfaces, runs N candidate
  read-sides through M arg shapes, reports `[OK]` / `[REJ]` per
  probe; deleted after).
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 12 templates:
  - `T11_runtime.spec.ts` — multi-suffix `waitForEipcChannels` over
    install-flow suffixes + dual `invokeEipcChannel` across TWO impl
    objects (CustomPlugins + LocalPlugins). Pattern for any case-doc
    test whose surface spans two interfaces — invoke a read-side from
    each rather than picking one.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~1 new spec OR one investigation + maybe a
narrowly-scoped Tier 2 / schema-rev landing.** Sessions 9-12 each
landed 1-2 specs. With coverage at 74/76, the test budget naturally
shifts toward investigation, schema-rev for still-rejecting read-
sides, or operon-mode probing. Session 13's main bet should aim for
1 spec OR one substantive investigation deliverable.

#### **PRIORITY: Unify DOM loading + traversal primitives.** Take
this on first if budget allows — the user is reporting a real,
recurring flake: tests fail because they aren't waiting long enough
for the DOM to render, AX-tree queries fire before the relevant
subtree is mounted, and each spec picks its own `retryUntil` budget.
Existing wait primitives are scattered: `electron.ts:waitForReady('userLoaded')`
(post-login URL transition), `claudeai.ts` page-objects (each rolls
its own `retryUntil` for AX lookups), `eipc.ts:waitForEipcChannel`
(handler registration). No unified "wait for surface rendered"
primitive exists. Proposed shape is **`lib/dom-ready.ts`** with
`waitForAxNode` / `waitForAxTreeStable` / `waitForRenderedSurface`
helpers — see plan-doc "Primitive gaps to flag" → "Unified DOM/AX
loading + traversal primitive" for the full proposal. Pre-work:
audit per-spec `retryUntil` budgets and AX-query sites in
`claudeai.ts` + flaky test runners to identify the 3-5 most-flaky
callsites; build the primitive against those specifically (not
speculatively). Threshold-driven extraction, same way `eipc.ts` /
`input.ts` / `electron-mocks.ts` came out of consumer pressure
rather than design-up-front. **If this primitive is what session
13 ships, that's a strictly higher-impact outcome than another
Tier 2 / Tier 3 reframe — flake reduction touches every existing
AX-using spec (T07, T16, T17, T26, H05) and unblocks future
Code-tab AX work.**

**Category A (operon-mode navigation probe)** is the natural next
step. The other 21 wrapper-exposed operon interfaces remain registry-
unconfirmed; if any URL form recovered from the bundle surfaces
additional handlers, that's a tractable Tier 2 reframe. **Category B
(Tier 3 read-only reframes)** picks the lowest-hanging Tier 3 spec
where a non-destructive read-side might be invocable from a fresh
isolation. **Category C (schema-rev for the rejecting read-sides)**
unblocks `listRemotePluginsPage` or `listSkillFiles` via grep on
the rejection literal — small-scope, useful as a fallback.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** operon-mode navigation probe | n/a (investigation) + maybe small Tier 2 reframe | new probe + bundle grep for operon URL routes | Session 10 confirmed `OperonBootstrap.ensure` registers eagerly but the other 21 wrapper-exposed operon interfaces remain registry-unconfirmed. Outputs: either an operon-mode URL form recovered from the bundle (search for `operon`-keyed routes in `claude.ai/...` paths) plus a registry re-probe after navigation, OR a deferral note explaining why operon scope can't be reached without an operon-mode entry. |
| **B** Tier 3 read-only reframes | Pick from the Tier 3 list | T33c / T35b / T37b template + bundle grep | The Tier 3 list is full of login-required flows; some have read-only entry points that the harness CAN construct. Candidates: T22's `getPrChecks` read-side might accept a non-existent PR number / dry-run mode; T15's OAuth surface has read-only state queries. Most need the user-account-scoped state to fail-fast with a clean error rather than a real network roundtrip — investigate first. |
| **C** Schema-rev for `listRemotePluginsPage` / `listSkillFiles` | Bundle grep | session 9 schema-rev pattern | Both methods rejected every smoke-tested arg shape during session 12's investigation. `listRemotePluginsPage` needs `limit: number` at position 0 (rejection: `Argument "limit" at position 0 ...`); `listSkillFiles` needs both `pluginId` and `skillName` (rejection: `Argument "skillName" at position 1 ...`). Bundle-grep on the rejection literals → resolve the schema → ship a narrowly-scoped Tier 2 invocation if it unblocks a case-doc claim. Smaller scope than A or B; useful as a fallback. |

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
   Tier 2 reframe spec (e.g. probe `OperonBootstrap.ensure` invocation
   shape, or assert the lazy-registration count).
4. **If none of the candidate URLs surface additional handlers**,
   document as "operon scope handlers register lazily on a navigation
   we can't easily construct from the harness" and defer.

This is the smaller-scope category — investigation + maybe one
spec landing.

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
   For example, T22's `LocalSessions.getPrChecks(prUrl)` might accept
   a fake URL string and return an empty/error array shape that
   asserts the impl is wired without making a real GitHub call —
   investigate.
3. **Ship a Tier 2 reframe** if the read-side resolves cleanly.
4. **Defer** if every candidate requires real account state to assert
   meaningfully.

#### Category C — Schema-rev for rejecting read-sides

The plan: resolve the validator schema for `listRemotePluginsPage` /
`listSkillFiles` via bundle grep, ship invocations if either unblocks
a case-doc claim.

1. **Grep on the rejection literal** in the bundled `index.js`.
   Validator block sits ~50-200 chars before the throw site (session
   9 finding). Read ~2KB around the hit to surface the full schema.
2. **Smoke-test the recovered schema** against the user's debugger-
   attached running Claude.
3. **Connect the resolved invocation to a case-doc claim.** If
   neither method connects to an existing case-doc test, the schema
   knowledge is a finding for the plan-doc but not a spec to ship.
4. **Ship a Tier 2 invocation** if a case-doc claim is unblocked.
   `listRemotePluginsPage` could potentially extend T33's plugin
   browser coverage with a paginated listing assertion.

This is the smallest-scope category — best fallback if A and B are
blocked.

#### Cross-compositor focus-shifter expansion (NOT recommended this session)

Building `lib/input-sway.ts` / `lib/input-hypr.ts` would mirror
`lib/input-niri.ts`'s shape but no consumer is asking for them.
Premature abstractions are wrong abstractions. Wait for a real
consumer.

#### Main-side `invokeEipcChannel` fallback (NOT recommended this session)

If a future spec needs to invoke a `claude.settings/*` handler that
only registers on the find_in_page or main_window webContents (where
the renderer is at `file://` and the wrapper isn't exposed), the
main-side direct-call path is documented in session 8's Status
section. Don't add it speculatively — wait for a real consumer.

#### Launch event-subscription primitive (NOT recommended this session)

Session 11 noted that `window['claude.web'].Launch` exposes 5 `on*`
event subscribers + `activeServersStore` not visible in
`_invokeHandlers`. No consumer asks for an event-probe primitive
yet — wait for one.

### Constraints to respect (don't violate)

These are unchanged from sessions 1-12 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T11_runtime/T16/T19/T20/T21/T26/T22b/T27/T31b/T33b/T33c/T35b/T37b/T38b
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
  main-side direct calls — the wrapper honors the per-handler origin
  gate honestly. Main-side direct calls work but require spoofing
  `senderFrame.url`; reserved as a fallback for non-claude.ai
  webContents (no current consumer).
- **For arg validator schema-rev: try smoke-test first, then grep
  the rejection message literal.** Session 9 finding. When
  `invokeEipcChannel` rejects with `Argument "<name>" at position N
  ... failed to pass validation`, that exact string lives inline in
  the validator block. One grep on the literal resolves the
  location; reading ~2KB around it surfaces the full schema. Cheaper
  than runtime closure inspection in most cases. Session 11 finding:
  for trivial `typeof === 'string'` validators, the smoke-test
  resolves the shape in one round-trip — bundle-grep is unnecessary
  overhead for simple validators. Session 12: most plugin-side
  validators were resolvable by smoke-test alone (15-method
  enumeration with 3-5 arg shapes per method costs ~5 minutes).
- **For session-scoped Tier 2 reframes: `LocalSessions/getAll` is
  the foundational read-side surrogate.** Session 10 finding. When
  a case-doc test's anchors are write-side LocalSessions handlers
  with no read-side equivalent, ship a registration probe over the
  case-doc-anchored suffixes PLUS a single
  `invokeEipcChannel('LocalSessions_$_getAll', [])` array-shape
  assertion as the read-side surrogate.
- **For Tier 2 reframes with case-doc-anchored read-side handlers:
  invoke the case-doc-anchored handlers directly.** Session 11
  finding. When the case-doc has read-side anchors with resolvable
  arg shapes (like T21's `getConfiguredServices(cwd)` /
  `getAutoVerify(cwd)`), prefer invoking those over a foundational
  surrogate. Mixed-shape dual invocation (one returns array, another
  returns boolean) is fine — assert each shape independently.
- **For Tier 2 reframes spanning two interfaces: invoke a read-side
  from each.** Session 12 finding. When the case-doc surface spans
  two impl objects (T11's CustomPlugins + LocalPlugins), invoke one
  read-side from each rather than picking one. Cross-impl-object
  dual invocation proves the plumbing crosses both impls intact —
  strictly stronger than single-interface coverage. Mixed-arg-shape
  fine (one needs `[[]]`, another `[]`).
- **`lib/input.ts` is X11-only.** Strict `XDG_SESSION_TYPE ===
  'x11'` gate. Wayland consumers must skip — don't try to bolt
  Wayland into the file.
- **`lib/input-niri.ts` is Niri-only.** Strict
  `XDG_CURRENT_DESKTOP === 'niri'` gate. Sway / Hyprland / River
  consumers must skip or live in their own per-compositor files.
- **Don't speculate on `lib/input-wayland.ts` dispatcher.**
  Per-compositor files until a second Wayland consumer (Sway /
  Hyprland / River) lands. With only S14 on Niri, a dispatcher
  is ceremony.
- **Code-tab AX anchors stay in plan-doc until a consumer needs
  them.** Don't preemptively add `CodeTab.activateTopTab()` to
  `claudeai.ts` — session 5's anchors block out the work for
  whenever a future consumer surfaces.
- **CDP auth gate is alive** — runtime SIGUSR1 attach via
  `app.attachInspector()`, never Playwright's `_electron.launch()`
  or `chromium.connectOverCDP()`.
- **BrowserWindow Proxy gotcha** — use
  `webContents.getAllWebContents()` not
  `BrowserWindow.getAllWindows()`. Constructor-level wraps don't
  work; use prototype-method hooks.
- **`skipUnlessRow()` always first.** First line of every `test()`
  body when the test is row-gated.
- **No fixed sleeps.** `retryUntil` from `lib/retry.ts`, or
  Playwright auto-wait. Fixed `sleep(N)` is a smell. (Exception:
  short sleeps inside hand-rolled retry loops that catch typed
  errors and short-circuit; see S11 / S14 for the pattern.)
- **Diagnostics on every run.** `testInfo.attach()` the artefacts.
  Single-shot JSON dumps for multi-state tests (S11, S14, S31,
  T11_runtime, T19, T20, T21, T22b, T27, T31b, T33b, T33c, T35b,
  T37b, T38b pattern) are cleaner than 5+ separate attachments.
- **Tag with annotations.** `severity:` and `surface:` on every
  test so JUnit carries them through to matrix-regen.
- **Tabs in TS, ~80-char wrap as the existing files do.** Match
  surrounding style.
- **Don't break existing runners.** `npm run typecheck` must stay
  clean. H01-H05 are the canaries; `npm test` must still pass them
  after every commit.
- **Always grep the installed asar** to verify a fingerprint
  string is present (and how often) BEFORE shipping. Build-
  reference is beautified — strings differ from the minified
  bundle.
- **For mock-then-call: the helper goes in
  `lib/electron-mocks.ts`,** not `lib/claudeai.ts`.
- **Marker windows / sacrificial host processes always die in
  `finally`.** S11 / S14 are the templates — `marker.kill()` runs
  before `app.close()` so the kill happens even if the spec throws.
- **Never log handler response BODIES into JUnit.** T37b's pattern
  (response type + length only, never the body) is correct for any
  invocation that returns user-account-scoped content. Memory bodies
  may contain personal or sensitive content; MCP server tokens may
  contain credentials; scheduled-task instructions may reference
  internal projects; marketplace `pluginContext`-filtered listings
  may surface internal-org marketplace pointers. T11_runtime's
  defensive default extends the pattern: installed-plugin entries may
  include workspace paths and plugin IDs that reveal org-internal
  marketplace pointers when the user is in an org; configured dev
  service entries (T21) may include workspace paths from auto-detect.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 12 section,
   then read `lib/eipc.ts`'s `invokeEipcChannel` API +
   `T11_runtime.spec.ts` leading comments. Confirm you understand the
   cross-impl-object dual invocation pattern.
3. Pick ONE Category as the main bet. Each has a different shape:
   - **A**: bundle grep + per-URL navigation + registry re-probe.
   - **B**: pick a Tier 3 candidate, smoke-test the read-side, decide
     ship or defer.
   - **C**: bundle grep on rejection literals, schema-rev, smoke-test
     the resolved shape, decide ship or defer.
   List which approaches you'll try in what order, with the cap at
   2-3 distinct approaches before STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category A (operon investigation):
- Single subagent does bundle-grep for operon URL routes + per-URL
  registry re-probe. Report findings; if a Tier 2 reframe is
  tractable, ship one spec.

For Category B (Tier 3 read-only reframes):
- Spawn ONE subagent for the candidate read-side investigation
  (smoke-test + bundle-grep if needed). Treat as exploratory; report
  findings before committing to a spec shape.
- Cap re-spawns at 2-3 distinct approaches; if no read-side resolves
  cleanly, STOP AND REPORT.

For Category C (schema-rev):
- Single subagent does bundle-grep on the rejection literals, surfaces
  the validator schemas, smoke-tests the recovered shapes against the
  user's debugger-attached running Claude. If a recovered schema
  unblocks a case-doc claim, ship; otherwise document and defer.

Cap at ~1 spec total — same scope as session 12's T11_runtime.

#### Per-subagent prompt shape

```
You're implementing ONE [test-harness runner | primitive |
investigation] for <TARGET>.

Read in order:
- docs/testing/cases/<FILE>.md (focus on <TARGET>'s Code anchors)
- tools/test-harness/README.md (conventions; status section names
  the most-recent-template that fits)
- tools/test-harness/src/runners/<closest-template>.spec.ts
- tools/test-harness/src/lib/ (the primitives you'll reuse)
- CLAUDE.md (project conventions)

Write tools/test-harness/src/runners/<TARGET>_short_name.spec.ts
[ AND/OR  tools/test-harness/src/lib/<NEW-PRIMITIVE>.ts ].

[per-task specifics: pattern (seedFromHost / mock-then-call /
asar fingerprint / shared isolation / new-primitive-build /
investigation), assertion shape, skip rules, key constraint
warnings]

Constraints:
- Tabs, ~80-char wrap.
- Use lib/* primitives; don't reinvent.
- testInfo.attach() the diagnostics from the spec's "Diagnostics
  on failure" block.
- Tag with severity + surface annotations.
- No fixed sleeps. retryUntil or Playwright auto-wait.
- npm run typecheck must stay clean after your edits.
- Don't commit. The user reviews and commits.

If the target isn't reasonable to implement (anchors don't resolve
to anything assertable, the test depends on state you can't
construct, the existing primitives don't cover the surface), DO
NOT write a stub. Report under Open questions and stop. Sessions
1-12 had cumulative ~17 "stop and report" outcomes that were the
right call.

Report shape (~150 words):
## <TARGET> [runner | primitive | investigation]

- File written: tools/test-harness/src/runners/<filename>.spec.ts
  [or lib/<newfile>.ts]
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) |
  pgrep | new-primitive | investigation
- Assertion shape: <one sentence>
- Skip rules: <which rows + why>
- Verification path: <typecheck + run result>
- Open questions: <caveats>
```

#### Phase 2 — synthesis

After fan-out returns:

1. `cd tools/test-harness && npm run typecheck` — must stay clean.
2. Run the new runners against KDE-W (the dev box) — but flag the
   user first if any are destructive (seedFromHost kills running
   Claude). Capture pass/skip/fail per spec for the matrix.
3. Update [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
   "Status (post-execution)" section to reflect newly-shipped
   specs and any reclassifications discovered mid-flight.
4. Update [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
   inventory table.
5. Write a final report listing:
   - Specs landed (pass / skip / needs-tuning per row)
   - Primitives landed (with API shape)
   - Specs deferred (with the per-test rationale)
   - Specs reclassified (Tier 3 → Tier 2, Tier 2 → Tier 1, etc.)
   - Updated coverage stat (was 74/76 = 97%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-12:

1. Subagent typecheck failure → re-spawn with explicit fix
   instruction.
2. Subagent claims a runner exists but `git status` shows no new
   file → re-spawn with explicit "use the Write tool" instruction.
3. Two subagents wrote runners that share a primitive but with
   different shapes → factor into `lib/<topic>.ts` BEFORE
   shipping.
4. Spec passes locally but the assertion is actually trivial (e.g.
   an unauthenticated launch where the handler check vacuously
   passes because no handlers are registered) → re-examine the
   assertion shape.
5. **Carry-over from session 5/6/7/8/9/10/11/12:** If the chosen
   Category's investigation doesn't resolve / requires schema-rev
   that exceeds budget after 2-3 approaches, STOP. Don't keep
   digging — pivot to a fallback Category. Document what was tried.
6. **Carry-over from session 10:** If a registration probe surfaces
   "registered but uninvocable" (handler is on the registry but the
   renderer-side wrapper isn't exposed for the relevant scope or the
   validator rejects every smoke-test arg shape), document and
   defer rather than building the main-side fallback speculatively.

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
   landing.** Stop, synthesize, leave the rest for the next
   session.
5. **All categories blocked after 2-3 attempts each.** Document the
   findings as plan-doc additions and stop — coverage is at 97%, a
   no-spec session that surfaces deferral notes is fine.

### What you should NOT do

- **Don't try to land Category A + B + C in one batch.** Pick
  ONE as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative seventeen "stop and
  report" outcomes from sessions 1-12 were the right call — every
  one revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
  `electron-mocks.ts` (session 3), `input.ts` (session 4),
  `input-niri.ts` (session 6), and `eipc.ts` registry walker
  (session 7) + invocation surface (session 8) were threshold-
  driven extractions, not speculative.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling write, T29
  worktree creation, T34 OAuth, T36 hooks-fire-on-prompt-submit).
  Only the *read-only reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Session 7 confirmed those use the per-wc IPC
  scope. Use `lib/eipc.ts`'s primitive (which targets the per-wc
  scope) instead.
- **Don't call `invokeEipcChannel` for write-side handlers** —
  `start*`, `set*`, `write*`, `run*`, `openIn*`, `delete*`,
  `cancel*`, `reset*`, `installPlugin`, `uninstallPlugin`,
  `updatePlugin`, `enablePlugin`, `uploadPlugin`, `syncRemotePlugins`.
  The primitive doesn't enforce a read-only allowlist; the safety
  property is that case-doc-anchored suffixes are read-side OR
  case-doc-anchored write-side suffixes are tested via REGISTRATION
  ONLY (`waitForEipcChannels`), never invoked. T11_runtime / T19 /
  T20 / T21 ship registration probes over write-side suffixes — that's
  the safe pattern.
- **Don't bolt other compositors into `lib/input-niri.ts`.**
  Sway / Hyprland / River each get their own per-compositor file
  if a consumer surfaces.
- **Don't bolt Wayland into `lib/input.ts`.** X11-strict gate is
  load-bearing.
- **Don't speculate on a `lib/input-wayland.ts` dispatcher.**
  Per-compositor files until a second Wayland consumer lands.
- **Don't preemptively build `CodeTab.activateTopTab()` /
  `startNewSession()`.** Session 5 captured the AX anchors but
  T36 Phase 2 (the only known consumer) was reclassified out.
- **Don't add a main-side `invokeEipcChannel` fallback
  speculatively.** Build it only if a concrete consumer needs to
  invoke through a non-claude.ai webContents. Premature primitives
  leak design debt.
- **Don't speculate on a Launch event-subscription primitive.**
  Session 11 noted that `window['claude.web'].Launch` exposes 5
  `on*` event subscribers + `activeServersStore` not visible in
  `_invokeHandlers`. No consumer asks for an event-probe primitive
  yet. Wait for one.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 13)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 74/76 (97%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | <test_id> | <file>.spec.ts | … | ✓ pass / skip / fail |
| ... |

## Notable findings
- ...

## Open questions
- ...

## Files touched
git status output (tools/test-harness/src/runners/*.spec.ts +
maybe lib/* primitives if extraction was needed; possibly plan-doc /
README updates).

## Diff summary
git diff --stat
```

### Operational notes

- Subagents are launched in parallel via a single message with
  multiple Agent tool calls. Don't serialise.
- Each subagent's Write calls land directly in the working tree.
- The grounding probe (`tools/test-harness/grounding-probe.ts`)
  can help when implementing a runner that asserts runtime API
  state — capture once with `npm run grounding-probe -- --launch
  --include-synthetic`, grep the output for the IPC channel /
  accelerator / API your runner needs to assert against.
- The eipc-registry probe (`tools/test-harness/eipc-registry-probe.ts`)
  is the dedicated tool for inspecting per-wc IPC handler state.
  Useful when designing new probes or auditing for upstream drift.
  Connects to a debugger-attached running Claude on port 9229.
- For seedFromHost specs, the host MUST have a signed-in Claude
  Desktop. The primitive throws with a clear message if not.
  Document the prerequisite in your runner's leading comment if
  it's the first one to add seedFromHost coverage to a new
  surface.
- For tests that touch the AX tree, `claudeai.ts` page-objects
  are the right substrate — see `T17_folder_picker.spec.ts` for
  the end-to-end example. Don't query DOM by CSS selector unless
  `claudeai.ts` doesn't already cover the surface. Code-tab
  session-opener anchors are documented in plan-doc session 5;
  don't add them to `claudeai.ts` unless a consumer surfaces.
- For mock-then-call: helpers live in `lib/electron-mocks.ts`
  (extracted in session 3). See T24's leading comment for the
  `Promise<boolean>` variant + T25's for the void variant.
- For focus-shifting (X11 only): `lib/input.ts` exports
  `focusOtherWindow` + `spawnMarkerWindow`. See S11 for the
  end-to-end consumer pattern.
- For Wayland-native focus-shifting (Niri only): `lib/input-niri.ts`
  exports the same shape with `niri msg --json` IPC + `foot`
  marker. See S14 for the end-to-end consumer pattern.
- For eipc registry walking: `lib/eipc.ts` exports
  `getEipcChannels` / `findEipcChannel` / `findEipcChannels` /
  `waitForEipcChannel` / `waitForEipcChannels` against
  `webContents.ipc._invokeHandlers`. See T11_runtime / T19 / T20 /
  T21 / T22b / T31b / T33b / T38b for end-to-end consumer patterns.
- For eipc invocation: `lib/eipc.ts` exports `invokeEipcChannel`
  (renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`). See T11_runtime / T19 /
  T20 / T21 / T27 / T33c / T35b / T37b for end-to-end consumer patterns.
  Only call read-side suffixes; the primitive doesn't enforce a
  read-only allowlist. Cross-impl-object dual invocation pattern is
  T11_runtime; single-interface dual is T21 / T33c.
- **For arg validator schema-rev (sessions 9 / 11 / 12 findings):**
  when invocation rejects with `Argument "<name>" at position N ...
  failed to pass validation`, FIRST try smoke-testing common arg
  shapes against the user's debugger-attached Claude (session 11's
  `launch-cwd-smoke.ts` / session 12's `localplugins-smoke.ts`
  pattern — clone the InspectorClient connection, iterate over arg
  shape candidates, report `[OK]` / `[REJ]` per shape). For trivial
  validators (`typeof === 'string'` / similar), this resolves the
  schema in one round-trip and avoids needing bundle-grep. For more
  elaborate validators, fall back to grep on the bundled `index.js`
  for the literal rejection string; validator block sits ~50-200
  chars before the throw site. See plan-doc session 9 status section
  for the byte offsets of the two CustomPlugins validators (5013601
  / 5018821) as worked examples.
- **For session-scoped Tier 2 reframes (session 10 finding):**
  `LocalSessions/getAll` is the foundational read-side surrogate
  when case-doc anchors are write-side. Pattern: `args = []`,
  returns `Array<Session>`. T19 and T20 are the templates.
- **For Tier 2 reframes with case-doc-anchored read-side handlers
  (session 11 finding):** invoke the case-doc-anchored handlers
  directly rather than using a foundational surrogate. Mixed-shape
  dual invocation is fine. T21 is the template (one returns array,
  another returns boolean — assert each shape independently).
- **For Tier 2 reframes spanning two interfaces (session 12
  finding):** invoke a read-side from each impl object. T11_runtime
  is the template (CustomPlugins/listInstalledPlugins array +
  LocalPlugins/getPlugins array — proves the install plumbing
  crosses both impls intact). Mixed-arg-shape fine.
- **For asar fingerprints: ALWAYS grep the installed asar
  first.** Build-reference is beautified; the bundle is
  minified. Case-doc text may be the user-facing form, not the
  bundle form (e.g. `~/.claude.json` vs `.claude.json`). T18
  reads `mainView.js`, not `index.js` — `lib/asar.ts`'s
  `readAsarFile(filename, asarPath)` already handles this.
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
