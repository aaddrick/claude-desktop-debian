# test-harness runner implementation — session 12 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new spec (T21) by way of registering the case-doc-anchored Launch
preview-pane suffixes plus invoking BOTH case-doc-anchored read-side
getters (`getConfiguredServices` returns array, `getAutoVerify` returns
boolean). No primitive change. Coverage 72/76 (95%) → 73/76 (96%). Two
commits on `docs/compat-matrix` expected (SHAs inserted after the
test-harness commit lands — the user reviews and commits at the end of
every session):

- TBD — `test(harness): session 11 T21 dev server preview runtime`
  (Tier 2 reframe; multi-suffix `waitForEipcChannels` over the
  case-doc-anchored Launch suffixes — `getConfiguredServices` /
  `startFromConfig` / `stopServer` / `getAutoVerify` /
  `capturePreviewScreenshot` — plus dual `invokeEipcChannel` on
  `Launch_$_getConfiguredServices` and `Launch_$_getAutoVerify` with
  `cwd = process.cwd()`; passes on KDE-W in 16.7s cold).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 11** first, then
**session 10**, then **session 9**, then **session 8**, then **session
7**, then **session 6**, then **session 5**, then **session 4**, then
**session 3**, then **session 2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 11

1. **`claude.web/Launch` cwd validator is `typeof cwd === 'string'`
   only.** No path-existence check, no absolute-path requirement,
   empty / relative / non-existent paths all pass. Only `null`,
   `undefined`, and object wraps reject. The handler tolerates
   missing `<cwd>/.claude/launch.json` — returns `[]` for
   `getConfiguredServices` and `false` for `getAutoVerify`. Smoke-
   test resolved the schema in one round-trip; bundle-grep on the
   rejection literal was not needed. Suggests a class of `claude.web`
   handlers may have similarly-trivial validators — when the
   rejection-message grep pattern from session 9 is the right tool,
   it's typically because the validator IS more elaborate (closed-
   over Zod schemas, optional-field unions). For simple `cwd`-only
   handlers, smoke-test first.
2. **`window['claude.web'].Launch` exposes 30 callable members,
   not 25.** The registry probe sees 25 `_invokeHandlers`; the
   wrapper additionally surfaces 5 `on*` event subscribers
   (`onDeployEvent` / `onElementSelected` /
   `onPreviewSelectionShortcut` / `onPreviewUrlChanged`) plus
   `isAvailable` and `activeServersStore`. Wrapper-only entries
   don't show up in `webContents.ipc._invokeHandlers` because
   they're event emitters and store proxies, bound via different
   bridge primitives. Worth noting: a future case-doc test that
   wants to probe event subscription paths (e.g. "preview pane
   reacts to deploy progress events") would need a different
   primitive than `invokeEipcChannel`. No consumer asks for it
   yet — anti-speculation rule applies.
3. **Dual case-doc-anchored read-side invocation pattern is
   distinct from foundational-surrogate.** T21 follows T33c's
   shape (invoke each case-doc-anchored read-side suffix, assert
   the documented shape per handler) rather than T19 / T20's
   foundational-surrogate shape (invoke `LocalSessions/getAll` as
   a stand-in because case-doc anchors were write-side). When the
   case-doc has read-side anchors with resolvable arg shapes,
   prefer invoking the case-doc-anchored handlers directly — it
   removes the surrogate hop, and the assertion is "the documented
   handler returns the documented shape" rather than "a
   foundational sibling is reachable through the wrapper".
4. **`getConfiguredServices` returns Array<…>, `getAutoVerify`
   returns boolean.** Mixed-shape dual invocation is fine — the
   spec does `Array.isArray(...)` and `typeof === 'boolean'`
   assertions independently. Diagnostic JSON captures both
   `responseShape` per invocation.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 11**, then
  **session 10**, **session 9**, **session 8**, **session 7**, **session
  6**, **session 5**, **session 4**, **session 3**, **session 2**, then
  **session 1** "Status (post-execution)" sub-sections. The Tier-3 list
  (search for "## Tier 3") is the candidate pool for further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-73-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note (covers registry walk, renderer-wrapper invocation, the
  schema-rev pattern from session 9, the foundational-getAll
  pattern from session 10, and the dual-case-doc-anchored-read-side
  pattern from session 11).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. No session 11 additions; surface remains
  the session 8 shape (`getEipcChannels` / `findEipcChannel` /
  `findEipcChannels` / `waitForEipcChannel` / `waitForEipcChannels` /
  `invokeEipcChannel` on `lib/eipc.ts`).
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against a
  debugger-attached Claude (`Developer → Enable Main Process
  Debugger` from the menu) to capture the current registry shape.
  Session 11 used a small one-off smoke-test in the test-harness
  dir (clones the InspectorClient connection pattern from
  eipc-registry-probe.ts, runs N cwd shapes via `evalInRenderer`,
  reports `[OK]` / `[REJ]` per shape; deleted after).
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 11 templates:
  - `T21_runtime.spec.ts` — multi-suffix `waitForEipcChannels` over
    case-doc-anchored Launch suffixes + dual `invokeEipcChannel` on
    case-doc-anchored read-side getters (`getConfiguredServices`
    returns array, `getAutoVerify` returns boolean). Pattern for any
    case-doc test whose anchors include read-side handlers with
    resolvable arg shapes — invoke the case-doc-anchored read-sides
    directly (no foundational surrogate needed). Mixed-shape dual
    invocation is fine.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~1-2 new specs OR one investigation + one new
spec landing.** Session 11 landed 1 spec; session 10 landed 2; session
9 landed 1. Session 12's main bet should aim for 1.

**Category A (T11 plugin install runtime upgrade) is the natural next
step.** It's currently a Tier 1 fingerprint only; promoting to a Tier
2 reframe follows the T21 shape — investigate `LocalPlugins`
read-side candidates, smoke-test, ship a single spec. Category B
(operon-mode navigation probe) is the smaller-scope investigation
fallback. There's no Category C this session — the deferral list
narrowed enough that two categories cover the budget.

Two categories — pick ONE as the main bet, treat the other as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** T11 plugin install runtime upgrade | T11 | T21 template + `lib/eipc.ts` invokeEipcChannel + bundle grep / smoke-test for any LocalPlugins arg validators | T11 currently is a Tier 1 fingerprint only. Session 7's registry probe surfaced 15 `LocalPlugins_*` handlers (sample names: `getPlugins`, `getDownloadedRemotePlugins`, `syncRemotePlugins`, `listSkillFiles`). Read-side candidates for invocation — likely return array of installed plugins / downloaded remotes / detected skills. Pattern: registration probe over the case-doc-anchored install-flow suffixes (which the T11 case-doc says — read it for the exact list) PLUS invocation of one or two read-side getters with whatever args the validators allow. Risk: getPlugins / similar may need a `cwd` arg or `pluginContext` object (mirrors T33c's `egressAllowedDomains` + `pluginContext` shape); smoke-test first. |
| **B** operon-mode navigation probe | n/a (investigation) + maybe small Tier 2 reframe | new probe + bundle grep for operon URL routes | Session 10 confirmed `OperonBootstrap.ensure` registers eagerly but the other 21 wrapper-exposed operon interfaces remain registry-unconfirmed. Outputs: either an operon-mode URL form recovered from the bundle (search for `operon`-keyed routes in `claude.ai/...` paths) plus a registry re-probe after navigation, OR a deferral note explaining why operon scope can't be reached without an operon-mode entry. Smaller scope than A. |

#### Category A — T11 plugin install runtime upgrade

The plan: confirm `LocalPlugins/*` is a tractable invocation surface,
then ship a Tier 2 reframe.

**Investigation phase first** — `LocalPlugins` arg shapes aren't yet
known:

1. **Re-run `eipc-registry-probe.ts`** filtering for
   `LocalPlugins_$_*`. Session 7 surfaced 15 handlers but only listed
   4 sample method names per interface. Dump the full method list to
   `/tmp/eipc-localplugins-methods.json` for grep. This is also a
   cheap re-probe of "is the registry shape unchanged from session
   7" — drift detection.
2. **Smoke-test candidate read-sides** with `args = []` first (the
   cheapest signal). Mirror session 11's `launch-cwd-smoke.ts`
   pattern (clone the InspectorClient pattern from
   eipc-registry-probe.ts, iterate over candidate methods + arg
   shapes, report `[OK]` / `[REJ]` per probe):
   - `getPlugins`, `getDownloadedRemotePlugins`, `syncRemotePlugins`,
     `listSkillFiles` — and any other read-shaped names from the
     full method list dump.
   - Capture rejection messages. If `Argument "<name>" at position
     <N> ... failed to pass validation`, schema-rev via bundle grep
     on the literal (session 9 finding) — validator block sits
     ~50-200 chars before throw site.
   - Try the same shapes session 11 used for Launch: `[]` (empty),
     `['/tmp']` (string cwd), `[process.cwd()]` (real cwd),
     `[{}]` (empty object), `[[]]` (empty array — what T33c uses
     for `egressAllowedDomains`).
3. **Schema-rev any unresolved validator** via bundle grep on the
   rejection message literal. Session 9's pattern: the validator
   block sits ~50-200 chars before the throw site in the bundled
   `index.js`. Session 11's smoke-test path resolved Launch's
   trivial `cwd: string` validator without bundle-grep — try
   smoke-test first, fall back to grep only if rejection messages
   need more decoding.
4. **Read T11's case-doc anchors** — they'll name the install-flow
   suffixes (likely `installPlugin` / `enablePlugin` / similar
   write-sides). Build the `EXPECTED_SUFFIXES` registration list
   from those.
5. **Motivate the reframe** in the leading comment. T11's case-doc
   claim is "plugin install code path is wired"; the read-side
   reframe is e.g. "the plugin enumeration handler is wired and
   returns the documented array shape — the install button only
   activates when the listing populates". The connection to the
   case-doc surface needs to be plausible, not just "this handler
   returns an array".

**Approaches to investigate (in order):**

1. **Smoke-test LocalPlugins read-sides** with `args = []` and a few
   common shapes against the user's debugger-attached Claude.
   Cheapest signal — directly probes what each validator accepts.
2. **Bundle grep on any rejection-message literal** for any rejection
   not resolved by smoke-test alone.
3. **Draft Tier 2 spec** using T21 shape (multi-suffix
   `waitForEipcChannels` over the case-doc-anchored install-flow
   suffixes, plus `invokeEipcChannel` on the resolved read-side).

If Category A's read-side invocation doesn't resolve cleanly after 2-3
attempts (every candidate rejects with shape constraints not derivable
from the bundle, all candidate read-sides require user-account-scoped
args like a real `cwd` with installed plugins, the validator demands
a session/plugin-context that the harness can't construct), STOP AND
REPORT. Pivot to Category B.

#### Category B — operon-mode navigation probe

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
spec landing. Best fallback if Category A is blocked.

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

### Constraints to respect (don't violate)

These are unchanged from sessions 1-11 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T19/T20/T21/T26/T22b/T27/T31b/T33b/T33c/T35b/T37b/T38b
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
  overhead for simple validators.
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
  returns boolean) is fine — assert each shape independently. This
  pattern is strictly stronger than the foundational-surrogate
  pattern when applicable.
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
  T19, T20, T21, T22b, T27, T31b, T33b, T33c, T35b, T37b, T38b
  pattern) are cleaner than 5+ separate attachments.
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
  may surface internal-org marketplace pointers (T33c's defensive
  default). T19/T20's `getAll` and T21's `getConfiguredServices`
  defensive defaults extend the pattern: session metadata may
  include user-account-scoped paths and titles; configured dev
  service entries may include workspace paths from auto-detect.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 11 section,
   then read `lib/eipc.ts`'s `invokeEipcChannel` API +
   `T21_runtime.spec.ts` leading comments. Confirm you understand the
   multi-suffix registration + dual case-doc-anchored read-side
   invocation pattern.
3. Pick ONE Category as the main bet. For Category A, plan the
   approach: (a) re-run registry probe filtering for LocalPlugins,
   (b) smoke-test candidate read-sides with various arg shapes, (c)
   bundle-grep any unresolved validator, (d) draft the Tier 2 spec.
   List which approaches you'll try in what order, with the cap at
   2-3 distinct approaches before STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category A (T11 plugin install runtime upgrade):
- Spawn ONE subagent for the LocalPlugins read-side schema
  investigation (registry re-probe + smoke-test + any needed
  bundle-grep). Treat as exploratory; report findings before
  committing to a spec shape. The user's debugger-attached running
  Claude is a great target for verification probes.
- Cap re-spawns at 2-3 distinct approaches; if no read-side resolves
  cleanly, STOP AND REPORT. Pivot to Category B if budget remains.
- If a read-side lands cleanly with valid args, second batch: ship
  `T11_runtime.spec.ts`.
- Cap at ~1 spec total — same scope as session 11's T21.

For Category B (operon-mode navigation probe):
- Single subagent does bundle-grep for operon URL routes + per-URL
  registry re-probe. Report findings; if a Tier 2 reframe is
  tractable, ship one spec.

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
1-11 had cumulative ~17 "stop and report" outcomes that were the
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
   - Updated coverage stat (was 73/76 = 96%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-11:

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
5. **Carry-over from session 5/6/7/8/9/10/11:** If pursuing Category A
   and the LocalPlugins read-side schema doesn't resolve / requires
   schema-rev that exceeds budget after 2-3 approaches, STOP. Don't
   keep digging — pivot to Category B. Document what was tried.
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
5. **Category A read-side schema doesn't resolve after 2-3 distinct
   attempts.** Document the dead-end as a finding, pivot to
   Category B if budget remains.

### What you should NOT do

- **Don't try to land Category A + Category B in one batch.** Pick
  ONE as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative seventeen "stop and
  report" outcomes from sessions 1-11 were the right call — every
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
  `cancel*`, `reset*`, `installPlugin`, `enablePlugin`. The
  primitive doesn't enforce a read-only allowlist; the safety
  property is that case-doc-anchored suffixes are read-side OR
  case-doc-anchored write-side suffixes are tested via REGISTRATION
  ONLY (`waitForEipcChannels`), never invoked. T19/T20/T21 ship
  registration probes over write-side suffixes — that's the safe
  pattern.
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
## Runner implementation summary (session 12)

- Main-bet category: A | B
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 73/76 (96%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | T11_runtime | T11_runtime.spec.ts | … | ✓ pass / skip / fail |
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
  `webContents.ipc._invokeHandlers`. See T19 / T20 / T21 / T22b /
  T31b / T33b / T38b for end-to-end consumer patterns.
- For eipc invocation: `lib/eipc.ts` exports `invokeEipcChannel`
  (renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`). See T19 / T20 /
  T21 / T27 / T33c / T35b / T37b for end-to-end consumer patterns.
  Only call read-side suffixes; the primitive doesn't enforce a
  read-only allowlist.
- **For arg validator schema-rev (sessions 9 / 11 findings):** when
  invocation rejects with `Argument "<name>" at position N ...
  failed to pass validation`, FIRST try smoke-testing common arg
  shapes against the user's debugger-attached Claude (session 11's
  `launch-cwd-smoke.ts` pattern — clone the InspectorClient
  connection, iterate over arg shape candidates, report `[OK]` /
  `[REJ]` per shape). For trivial validators (`typeof === 'string'`
  / similar), this resolves the schema in one round-trip and avoids
  needing bundle-grep. For more elaborate validators, fall back to
  grep on the bundled `index.js` for the literal rejection string;
  validator block sits ~50-200 chars before the throw site. See
  plan-doc session 9 status section for the byte offsets of the
  two CustomPlugins validators (5013601 / 5018821) as worked
  examples.
- **For session-scoped Tier 2 reframes (session 10 finding):**
  `LocalSessions/getAll` is the foundational read-side surrogate
  when case-doc anchors are write-side. Pattern: `args = []`,
  returns `Array<Session>`. T19 and T20 are the templates.
- **For Tier 2 reframes with case-doc-anchored read-side handlers
  (session 11 finding):** invoke the case-doc-anchored handlers
  directly rather than using a foundational surrogate. Mixed-shape
  dual invocation is fine. T21 is the template (one returns array,
  another returns boolean — assert each shape independently).
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
