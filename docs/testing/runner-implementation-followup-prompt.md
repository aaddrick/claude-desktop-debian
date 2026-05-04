# test-harness runner implementation — session 9 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 3
new specs (T35b, T37b, T27) and 1 primitive extension
(`invokeEipcChannel` on `lib/eipc.ts`). Coverage 66/76 (87%) → 69/76
(91%). One commit on `docs/compat-matrix`:

- `7ffd73a` — `test(harness): session 8 runners + invokeEipcChannel
  primitive` (3 new Tier 2 invocation probes — T35b / T37b paired with
  the existing T35 / T37 Tier 1 fingerprints, plus T27 as the case-doc
  Tier 2 reframe; new `invokeEipcChannel` API on `lib/eipc.ts` calls
  through the renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`, opaque on the framing
  UUID, suffix-matched against case-doc anchors).

(SHA inserted after the test-harness commit lands — the user reviews
and commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 8** first, then
**session 7**, then **session 6**, then **session 5**, then **session
4**, then **session 3**, then **session 2**, then **session 1** sub-
sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 8

1. **eipc invocation works through the renderer-side wrapper.** The
   per-handler origin gate (`le(e)` / `Vi(e)` / `mm(e)`) is a
   structural duck-type check on `event.senderFrame.url` and
   `event.senderFrame.parent === null`, not an `instanceof Frame`
   check. Two viable paths exist: (a) main-side direct call with a
   synthesized event whose `senderFrame.url = 'https://claude.ai/'`,
   and (b) renderer-side wrapper at
   `window['claude.<scope>'].<Iface>.<method>(...args)` exposed by
   `mainView.js` via `contextBridge.exposeInMainWorld` after the
   `Qc()` exposure gate. Session 8 chose (b) for the primitive — it
   honors the gate honestly (no senderFrame spoofing) and aligns test
   surface with real attack surface. Approach (a) stays available
   for future scopes whose renderer-side wrapper isn't exposed
   (e.g. find_in_page / main_window webContents host
   `claude.settings/*` handlers in their per-wc registry but their
   renderers are at `file://` so the wrapper isn't there); not
   implemented in this session — no current consumer.
2. **`mainView.js` exposes 9 wrapper namespaces, more than the
   registry-side count.** Session 7 catalogued
   `claude.settings`/`claude.web` plus `claude.app_internal` (small
   surface) on the per-wc registries. Session 8's renderer-side probe
   surfaced `claude.operon`, `claude.skills`, `claude.simulator`,
   `claude.officeAddin`, `claude.hybrid`, `claude.buddy`, plus
   `claudeAppBindings` / `claudeAppSettings`, totalling 9 distinct
   `window['claude.*']` namespaces. The operon scope is suspicious:
   wrapper exposes 22 interfaces but session 7's registry walk on
   `/epitaxy` and `/new` saw zero operon handlers registered on
   claude.ai. Either operon handlers register lazily on entering an
   operon-mode session, or the wrapper is exposed even when the
   handler isn't yet registered (in which case `invokeEipcChannel`
   would fail with "no handler registered with suffix"). Worth a
   one-liner probe before any operon-scope spec lands.
3. **`invokeEipcChannel(inspector, suffix, args?, opts?)` is the new
   surface.** Suffix is the same case-doc-anchored input that
   `findEipcChannel` accepts (e.g. `MCP_$_getMcpServersConfig` or
   the fully-qualified
   `claude.settings_$_MCP_$_getMcpServersConfig`). Internally
   resolves the full suffix through `findEipcChannel`, splits on
   `_$_` to recover `[scope, iface, method]`, then
   `evalInRenderer(urlFilter, "window[scope][iface][method](...args)")`.
   Default `urlFilter` is `'claude.ai'`. Args are JSON-marshaled in;
   return value is JSON-deserialized via `evalInRenderer`'s
   `executeJavaScript` path. Read-by-default but not allowlist-
   enforced — the safety property is that consumers pass case-doc-
   anchored suffixes verbatim.
4. **Renderer-eval errors are stringified.** When the underlying
   handler rejects (origin gate, arg validator, result validator),
   the error surface is `Error: Error invoking remote method
   '<framed-channel>': <inner-message>`. The framed channel name in
   the message lets consumers triage per-handler. Native exceptions
   get JSON-stringified through the inspector eval boundary; per-
   handler triage is intact but stack traces are lost on the renderer
   side.
5. **The session 8 prompt's `le(i)` reference at `:68820` was off.**
   Approach 3's investigator flagged that `le` is at `:5045138` in
   this build; offset 68820 hits OpenTelemetry SemRes constants.
   Doesn't change the outcome (the gate's behavior is the same
   regardless of offset) but worth noting if a future probe takes a
   followup-prompt offset literally — always confirm offsets against
   the current bundle before relying on them.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 8**,
  **session 7**, **session 6**, **session 5**, **session 4**,
  **session 3**, **session 2**, then **session 1** "Status (post-
  execution)" sub-sections. The Tier-3 list (search for "## Tier 3")
  is the candidate pool for further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-69-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note (now updated to cover both registry walk and renderer-wrapper
  invocation).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable session 8 addition: `eipc.ts`
  gained `invokeEipcChannel` (renderer-side wrapper invocation).
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against a
  debugger-attached Claude (`Developer → Enable Main Process
  Debugger` from the menu) to capture the current registry shape.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 8 templates:
  - `T35b_mcp_config_runtime.spec.ts` — single-channel
    `waitForEipcChannel` + `invokeEipcChannel` shape with shape-
    describing diagnostic. Pattern for any future Tier 2 invocation
    asserting response is a non-array object.
  - `T37b_global_memory_runtime.spec.ts` — `string | null` assertion
    shape. Pattern for invocation probes whose response can hold
    user content (T37b never logs the body — only type + length —
    because account memory may be sensitive).
  - `T27_scheduled_tasks_runtime.spec.ts` — multi-suffix
    `waitForEipcChannels` + per-suffix `invokeEipcChannel` loop with
    aggregated diagnostic attachment. Pattern for parallel-scope
    assertions (Cowork vs CCD).
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~2 new specs OR one investigation + one new
spec landing.** Session 8 was at the upper end (3 specs + 1 primitive
extension) because all three specs were near-identical shape and the
primitive extension was small. This session's main bet involves
reverse-engineering an arg schema (T33 Phase 2's
`egressAllowedDomains`), which is variable in cost.

**Category A (T33 Phase 2 invocation upgrade) is the cleanest
single-session win available.** T33 ships as a Tier 1 fingerprint and
T33b ships as a Tier 2 handler-registration probe (session 7); T33
Phase 2 invokes the same handlers and asserts the response shape —
the natural next rung. The blocker is arg validation:
`listMarketplaces` failed during session 8's smoke test on a missing
`egressAllowedDomains` arg, and the schema lives inside the main
handler's validator (not the renderer wrapper). Investigation phase
needs to either (a) reverse-engineer the schema from the bundle, or
(b) capture a real renderer call's args via DevTools network panel /
mainView.js inspection, or (c) drop to `listAvailablePlugins` if its
schema is simpler.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** T33 Phase 2 (plugin browser invocation) | T33 Phase 2 (`listMarketplaces` + `listAvailablePlugins` invocation) | `T33b` template + `lib/eipc.ts` invokeEipcChannel | Investigate `egressAllowedDomains` schema first. Risk: schema may be deeply structured (origin allow-list, fetch timeout, etc.) requiring trial-and-error against bundle. If both methods turn up empty after schema-rev, ship a documentation-only `H07_plugin_browser_args_finding.spec.ts` capturing the dead-end. |
| **B** T19/T20/T21 Code-tab cluster | T19, T20, T21 | invokeEipcChannel + AX-tree click chains | T19 (integrated terminal) needs `LocalSessions/startShellPty`; T20 (file pane) needs `LocalSessions/writeSessionFile`; T21 (dev server preview) needs `claude.web/Launch/*`. Each combines invocation + AX click — bigger work per spec. T19/T20 anchors verified session 5 (Code-tab AX surface); T21 anchors not yet verified. |
| **C** operon scope exposure-vs-registration probe | n/a (investigation) | new probe, possibly small Tier 1 reframe | Confirm whether operon handlers register on claude.ai webContents at any point, or only on operon-mode entry. Outputs: either a Tier 2 reframe of an operon case-doc test, OR a deferral note explaining why operon scope can't be reached without an operon-mode session. Smaller scope than A or B. |

#### Category A — T33 Phase 2 invocation upgrade

The plan: extend the existing T33 / T33b coverage with invocation
probes. T33 the Tier 1 fingerprint asserts the bundle contains the
two channel name strings; T33b the Tier 2 handler-registration probe
asserts both are registered on the claude.ai webContents at runtime;
T33 Phase 2 would invoke each and assert the response shape.

**Investigation phase first** — invocation has known unknowns:

1. **`egressAllowedDomains` schema.** Session 8's smoke test against
   `CustomPlugins/listMarketplaces` failed with `Argument
   "egressAllowedDomains" at position 0 ... failed to pass
   validation`. The schema lives inside the main handler's validator
   (probably a Zod-style schema that wraps the impl). Approaches:
   - Grep the bundled minified `index.js` for
     `egressAllowedDomains` — should resolve to a schema-construction
     site near the `listMarketplaces` handler. The schema usually has
     an enumerable shape (object with field validators).
   - Reverse-engineer the validator's `.toString()` at runtime via
     `evalInMain` — pull out the handler closure source and look for
     a `z.object({...})` or similar.
   - Capture a real renderer call's args via DevTools (open the
     plugin browser in claude.ai while DevTools network panel is open
     and the Main Process Debugger is attached; the `ipcRenderer.invoke`
     args show in the inspector).
   - Drop to `listAvailablePlugins` first if its schema is simpler;
     the case-doc anchors both, so either is a valid Phase 2 target.
2. **Response shape validation.** `listMarketplaces` returns a list of
   marketplace metadata objects. Case-doc anchor (`T33` in
   `docs/testing/cases/extensibility.md`) describes "browser populate
   flow" — should return a non-empty array on a configured-host run,
   or empty array on a fresh install. Either way, `Array.isArray` is
   the strongest assertion that doesn't depend on host state.
3. **Side-effect risk.** Both `list*` handlers should be read-only;
   confirm by reading the handler source (search for `listMarketplaces`
   in bundled `index.js`).

**Approaches to investigate (in order):**

1. **Bundle grep for the schema construction site.** Cheapest signal.
   The validator literal is usually inline near the handler.
2. **Runtime closure inspection** — pull the handler's `.toString()`
   via `evalInMain` and look for the schema declaration. May surface
   a closure-local schema we can't reach, but worth the 5-minute try.
3. **DevTools args capture** — last resort because it requires user
   interaction (open plugin browser in running Claude). Valuable if
   the schema is fully closure-local and not introspectable from main.

If Category A turns up empty after 2-3 distinct approaches, STOP AND
REPORT. Don't keep digging — document what was tried, ship a
"H07 documentation runner" if useful state surfaced, and pivot to
Category C (smaller scope) or pause for user review.

If `listMarketplaces` invocation lands cleanly, batch
`listAvailablePlugins` invocation as a sibling spec (or fold both
into a single `T33c` runner if the case-doc anchor structure makes
that natural). Cap at ~2 spec upgrades — don't try to land both if
the first one surfaces an unexpected issue.

#### Category B — T19/T20/T21 Code-tab cluster

Each needs both invocation against `claude.web/ClaudeCode/*` AND
AX-tree click chains against rendered Code-tab surfaces. Session 5
verified the Code-tab session-opener AX anchors (top-tab Code button,
sidebar entries, recents items) but didn't ship a primitive — the
anchors are in the plan-doc, ready for a consumer.

T19 (integrated terminal) needs `LocalSessions_$_startShellPty` shape;
T20 (file pane) needs `LocalSessions_$_writeSessionFile`; T21 (dev
server preview) needs `claude.web/Launch/*` (Launch interface
specifically).

Skip this category unless Category A's schema-rev turns up empty AND
the cluster's `claude.web/Launch/*` AX-tree anchors are pre-verified
(they aren't yet — T21 would need a debugger-on probe like session 5
used for Code-tab anchors). T19 and T20 are more reachable than T21
because their handlers are on `LocalSessions` (already-catalogued by
session 7's registry walk).

#### Category C — operon scope exposure-vs-registration probe

The plan: write a small read-only probe (mirror
`eipc-registry-probe.ts`'s shape) that asks two questions:

1. **At fresh launch + post-login**, are any operon handlers
   registered on the claude.ai webContents? Session 7's registry walk
   on `/epitaxy` and `/new` saw zero. Confirm — re-run the registry
   walker, filter by `scope === 'claude.operon'`, capture the count.
2. **After navigating to an operon-mode URL** (whatever the URL shape
   is — TBD; check `claude.ai/...` paths in the bundle for
   `operon`-keyed routes), do operon handlers appear?
3. **Independently**, does the renderer-side wrapper expose
   `window['claude.operon']` regardless of registration status? (Yes
   per session 8 — confirm this is stable across navigation.)

Outputs:

- If operon handlers register on claude.ai eagerly: write a one-liner
  Tier 2 reframe spec for the highest-priority operon case-doc target
  (search `docs/testing/cases/` for any test mentioning operon).
- If they register lazily on operon-mode entry: document the
  prerequisite in plan-doc Status section as a Tier 3 item ("requires
  operon-mode navigation primitive"), and don't ship a probe.
- If the wrapper is exposed without registered handlers: document as
  a known limitation of `invokeEipcChannel` (will fail with "no
  handler registered" even though `window['claude.operon']` is
  present).

This is a smaller-scope category — investigation + maybe one spec
landing. Best fallback if Category A's schema-rev turns up empty.

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

These are unchanged from sessions 1-8 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26/T22b/T27/T31b/T33b/T35b/T37b/T38b are the
  templates.
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
  whenever a future consumer surfaces. T19/T20 (Category B) would
  be that consumer.
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
  T22b, T27, T31b, T33b, T35b, T37b, T38b pattern) are cleaner
  than 5+ separate attachments.
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
  internal projects.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 8 section,
   then read `lib/eipc.ts`'s `invokeEipcChannel` API +
   `T35b_mcp_config_runtime.spec.ts` leading comments. Confirm you
   understand the renderer-wrapper path vs main-side fallback.
3. Pick ONE Category as the main bet. For Category A, plan the
   approach: (a) bundle grep for the schema, (b) runtime closure
   inspection, (c) DevTools args capture. List which approaches
   you'll try in what order, with the cap at 2-3 distinct approaches
   before STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category A (T33 Phase 2 invocation):
- Spawn ONE subagent per investigation approach — bundle grep,
  runtime closure inspection, DevTools args capture (if needed).
  Treat as exploratory; report findings before committing to a spec
  shape. The user's debugger-attached running Claude is a great
  target for verification probes (mirror session 7's
  `eipc-registry-probe.ts` shape).
- Cap re-spawns at 2-3 distinct approaches; if all empty, STOP AND
  REPORT. Ship an `H07_plugin_browser_args_finding.spec.ts`
  documentation runner if useful state surfaces during the
  investigation.
- If the schema is recoverable, second batch: ship `T33c` (or
  whatever the b-vs-c suffix convention dictates) invoking
  `listMarketplaces` and asserting array shape. Third batch (only
  if first lands clean): ship the `listAvailablePlugins` sibling.
- Cap at ~2 specs total upgrade — don't try to land both if the
  first one surfaces an unexpected issue.

For Category C (operon scope probe):
- Single subagent writes the registry-walk probe modeled on
  `eipc-registry-probe.ts`. User runs it (or you run via the
  debugger if attached). Report findings; if a Tier 2 reframe is
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
1-8 had cumulative ~15 "stop and report" outcomes that were the
right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral,
S14 primitive-gap then primitive-build, T35/T36 Phase 2 deferrals,
T18 Tier 1 reframe, T36 Phase 2 reclassification to Tier 3/4,
session-6 lib/input-niri.ts shipped untested-on-niri, session-7
per-wc IPC scope finding overturning the session-3 closure-local
conclusion, session-8 renderer-wrapper-vs-main-side decision).

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
   - Updated coverage stat (was 69/76 = 91%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-8:

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
   assertion shape. The lesson from sessions 3 and 7: verify the
   assertion is meaningful, not just that it passes.
5. **Carry-over from session 5/6/7/8:** If pursuing Category A and
   the schema-rev / closure-inspection / DevTools approaches turn
   up empty after 2-3 approaches, STOP. Don't keep digging —
   document what was tried, ship the H07 documentation runner if
   it surfaces useful state, move to Category C.
6. **NEW for session 9:** If Category A's invocation lands but
   the response shape doesn't match the case-doc claim (e.g.
   `listMarketplaces` returns something that isn't an array), re-
   examine the case-doc anchors before shipping the upgrade — the
   assertion shape might need adjustment, not the test target.

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
4. **Session budget hits ~2 new specs OR one new primitive
   landing.** Stop, synthesize, leave the rest for the next
   session.
5. **Category A approaches all turn up empty after 2-3 distinct
   attempts.** Document the dead-end as a finding, ship H07 if
   useful, pivot to Category C if budget remains.

### What you should NOT do

- **Don't try to land Category A + Category B in one batch.** Pick
  ONE as the main bet. Category C is small enough to pair as a
  fallback.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative fifteen "stop and
  report" outcomes from sessions 1-8 were the right call — every
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
  `cancel*`, `reset*`. The primitive doesn't enforce a read-only
  allowlist; the safety property is that case-doc-anchored
  suffixes are read-side. If a case-doc anchor mentions a write-
  side suffix, that's a Tier 3 (real-account-write) test, not a
  Tier 2 invocation reframe.
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
  T19/T20 (Category B) would be the legitimate consumer.
- **Don't add a main-side `invokeEipcChannel` fallback
  speculatively.** Build it only if a concrete consumer needs to
  invoke through a non-claude.ai webContents. Premature primitives
  leak design debt.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 9)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 69/76 (91%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | T33 Phase 2 | T33c_plugin_browser_invocation.spec.ts | … | ✓ pass / skip / fail |
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
  `webContents.ipc._invokeHandlers`. See T22b / T31b / T33b /
  T38b for end-to-end consumer patterns.
- For eipc invocation: `lib/eipc.ts` exports `invokeEipcChannel`
  (renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`). See T35b / T37b
  / T27 for end-to-end consumer patterns. Only call read-side
  suffixes; the primitive doesn't enforce a read-only allowlist.
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
