# test-harness runner implementation — session 10 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new spec (T33c) by way of reverse-engineering the
`CustomPlugins/listMarketplaces` arg validator. No primitive change.
Coverage 69/76 (91%) → 70/76 (92%). One commit on `docs/compat-matrix`
expected (SHA inserted after the test-harness commit lands — the user
reviews and commits at the end of every session):

- TBD — `test(harness): session 9 T33c plugin browser invocation`
  (Tier 2 invocation upgrade of T33b; schema-rev surfaced the
  byte-identical hand-rolled validator on both `listMarketplaces` and
  `listAvailablePlugins`; minimal valid arg is `[[]]` — empty
  egressAllowedDomains, omit pluginContext; passes on KDE-W in 39.2s
  with array shape on both invocations).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 9** first, then
**session 8**, then **session 7**, then **session 6**, then **session
5**, then **session 4**, then **session 3**, then **session 2**, then
**session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 9

1. **Hand-rolled positional arg validators.** Both
   `claude.web/CustomPlugins/listMarketplaces` and `listAvailablePlugins`
   use byte-identical inline `Array.isArray(...) && r.every(a => typeof
   a === "string")` checks for `egressAllowedDomains: string[]` (arg 0,
   required) plus an optional `pluginContext` checked by a closed-over
   `sc(...)` requiring `mode: string`. NOT Zod for args — the result
   validator IS Zod, runs after the impl returns. Validator blocks at
   bytes 5013601 / 5018821 in the bundled `index.js` (single-line
   minified bundle, ~15 MB, byte offsets not line numbers). Minimal
   valid arg: `args = [[]]`. The empty allow-list is the safety
   property — if the underlying impl is the CLI-shelling variant, it
   forwards as the spawned subprocess's permitted domains.
2. **Two impl variants exist.** Both methods have a CLI-shelling impl
   (`runCommand(["plugin", ...], { timeout: 30s/60s, allowedDomains: A
   })`) AND a native impl (reads `knownMarketplacesFile` /
   `marketplacesDir` directly). Selection logic isn't called out in
   the registered handler's closure source; both variants return the
   same `Array<…>` shape on success. T33c's `Array.isArray(result) ===
   true` assertion holds regardless of which is active. Test budget
   bumped to 180s to accommodate worst-case sequential CLI timeouts.
3. **Validator rejection messages are the cheapest grep target.** When
   `invokeEipcChannel` rejects with `Argument "<name>" at position N
   ... failed to pass validation`, the verbatim rejection string in
   the inline validator block is the entry point — single grep on the
   literal error message resolves to the exact validator location in
   the bundle. Save this pattern for any future schema-rev session
   where invocation fails with a structured rejection.
4. **Bundle grep + runtime closure inspection converged independently.**
   Two parallel investigations (subagents read the bundle vs. read
   `Function.prototype.toString` of the registered handler via the
   debugger-attached running Claude on :9229) produced byte-identical
   validator literals and the same minimal arg shape. High confidence
   on the schema. Worth using the dual-approach pattern again when a
   future schema-rev needs cross-checking — both paths are cheap and
   the false-positive rate goes to zero when they agree.
5. **`mainView.js` exposes 9 wrapper namespaces but only 5 currently
   have registry-confirmed handlers** on the claude.ai webContents.
   Carryover from session 8: `claude.operon` exposes 22 interfaces in
   the renderer wrapper but session 7's registry walk on `/epitaxy`
   and `/new` saw zero operon handlers registered. Either operon
   handlers register lazily on operon-mode entry, or the wrapper is
   exposed even when the handler isn't yet registered (in which case
   `invokeEipcChannel` would fail with "no handler registered with
   suffix"). Same uncertainty applies to `claude.web/Launch/*`
   (relevant for T21 dev server preview): wrapper present, registry
   un-confirmed. Worth a one-liner probe before any operon-scope or
   Launch-scope spec lands.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 9**,
  **session 8**, **session 7**, **session 6**, **session 5**,
  **session 4**, **session 3**, **session 2**, then **session 1**
  "Status (post-execution)" sub-sections. The Tier-3 list (search for
  "## Tier 3") is the candidate pool for further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-70-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note (now updated to cover registry walk, renderer-wrapper
  invocation, AND the schema-rev pattern from session 9).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. No session 9 additions; surface remains
  the session 8 shape (`getEipcChannels` / `findEipcChannel` /
  `findEipcChannels` / `waitForEipcChannel` / `waitForEipcChannels` /
  `invokeEipcChannel` on `lib/eipc.ts`).
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against a
  debugger-attached Claude (`Developer → Enable Main Process
  Debugger` from the menu) to capture the current registry shape.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 9 template:
  - `T33c_plugin_browser_invocation.spec.ts` — multi-suffix
    `waitForEipcChannels` + per-suffix `invokeEipcChannel` loop with
    `args = [[]]` for both methods, `Array.isArray` shape assertion,
    180s budget for CLI-spawn worst case. Pattern for any Tier 2
    invocation upgrade where the validator requires a positional arg
    AND the impl may shell out to a subprocess.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~2 new specs OR one investigation + one new
spec landing.** Session 9 was at the lower end (1 spec + 0 primitives)
because the schema-rev was the work; now that the validator pattern
is documented, follow-on Tier 2 invocation upgrades that need similar
schema work are cheaper. Session 8's upper end (3 specs + 1 primitive
extension) was a near-identical-shape batch; session 10's main bet
should aim for the lower-middle (2 specs OR 1 investigation + 1 spec).

**Category B remains the natural next step** but its case-doc anchors
point at write-side handlers — needs read-side reframes before
shipping. Category C (operon / Launch exposure-vs-registration) is
still on the table from session 8 and is the smallest-scope option.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** T19/T20 read-side reframes | T19, T20 (read-side) | T33c template + `lib/eipc.ts` invokeEipcChannel | Case-doc anchors are write-side (`startShellPty`, `writeSessionFile`). Investigate read-side equivalents in the registry first — `LocalSessions_$_listSessions`, `LocalSessions_$_getSessionInfo`, `LocalSessions_$_readSessionFile` are candidates per session 7's per-interface map (117 LocalSessions handlers total). Schema-rev each before invocation — the validator-rejection-grep pattern from session 9 applies. Risk: read-side handlers may not have one-to-one case-doc anchor mapping; the spec body has to motivate why the read-side reframe asserts the same surface as the write-side case-doc claim. |
| **B** Launch scope + T21 | T21 (dev server preview) | exposure-vs-registration probe + new spec | Confirm `claude.web/Launch/*` handlers register on the claude.ai webContents at all (session 7 mapped 53 distinct interfaces; Launch wasn't in the surfaced list — could be lazy-register on `.claude/launch.json` presence, or exposed-but-not-registered). If registered, ship a Tier 2 reframe similar to T33c. If wrapper-only, document and pivot. |
| **C** operon scope exposure-vs-registration probe | n/a (investigation) | new probe, possibly small Tier 1 reframe | Confirm whether operon handlers register on claude.ai webContents at any point, or only on operon-mode entry. Outputs: either a Tier 2 reframe of an operon case-doc test, OR a deferral note explaining why operon scope can't be reached without an operon-mode session. Smaller scope than A or B. |

#### Category A — T19/T20 read-side reframes

The plan: pick read-side `LocalSessions_$_*` getters that map to the
write-side case-doc claims for T19 (integrated terminal) and T20
(file pane), then ship Tier 2 invocation runners against each.

**Investigation phase first** — case-doc anchors are write-side,
need read-side equivalents:

1. **Re-run `eipc-registry-probe.ts`** against a debugger-attached
   Claude. Filter for `LocalSessions_$_*` and look for `list*` /
   `get*` / `read*` patterns. Session 7 catalogued 117 LocalSessions
   handlers but only listed sample method names (4 per interface).
   The full list lives in `/tmp/eipc-registry-probe.json` from a
   re-run. Candidate read-sides:
   - For T19 (terminal): `LocalSessions_$_listSessions`,
     `LocalSessions_$_getSessionInfo`, `LocalSessions_$_readPty`?
   - For T20 (file pane): `LocalSessions_$_readSessionFile`,
     `LocalSessions_$_listSessionFiles`?
2. **Schema-rev each candidate** using the session 9 pattern:
   - First call: smoke test against the user's debugger-attached
     Claude with `args = []`. Capture the rejection error.
   - If rejection error includes `Argument "<name>" at position N
     ... failed to pass validation`, grep the bundle for the literal
     rejection string to find the validator block.
   - If the call succeeds with `[]`, you don't need schema-rev — go
     straight to runner shape.
   - If the call succeeds but returns a non-array shape, decide
     whether the assertion shape is `Array.isArray` (T33c, T27) or
     `non-array object` (T35b) or `string | null` (T37b) based on
     what the read-side returns.
3. **Motivate the reframe** in the leading comment. T19's case-doc
   claim is "integrated terminal opens"; the read-side reframe is
   e.g. "the per-session listing handler is wired and returns an
   array — the terminal-spawn path consumes this list to attach to
   an existing PTY". The connection to the case-doc surface needs
   to be plausible, not just "this handler returns an array".

**Approaches to investigate (in order):**

1. **Re-run the registry probe against the user's running
   debugger-attached Claude.** Cheapest signal — captures the full
   `LocalSessions_$_*` method list as seen from main. Mirror the
   existing probe; don't rewrite.
2. **Smoke-test candidate read-side suffixes** with `args = []`.
   Capture rejections. The validator-rejection grep pattern from
   session 9 resolves the schema cheaply.
3. **If a candidate's invocation succeeds**, draft a Tier 2 spec
   using T33c's shape (multi-suffix if both T19 and T20 read-sides
   land, single-suffix otherwise).

If Category A turns up empty after 2-3 distinct read-side candidates
(none invoke cleanly with `args = []`, all require schema-rev that
exceeds the session budget, OR the registry walk doesn't surface a
plausible read-side equivalent), STOP AND REPORT. Don't keep
digging — pivot to Category B or C.

#### Category B — Launch scope + T21

The plan: confirm `claude.web/Launch/*` handlers register on the
claude.ai webContents (session 7's per-interface map didn't list
them; either lazy-register on `.claude/launch.json` presence, or
exposed-but-not-registered).

1. **Re-run `eipc-registry-probe.ts`** filtering for
   `claude.web_$_Launch_$_*`. If non-empty, treat similarly to
   T33c: pick a read-side getter, schema-rev with the rejection-
   grep pattern, ship a Tier 2 invocation runner.
2. **If empty**, navigate the running Claude to a project with
   `.claude/launch.json` and re-run. If still empty, document
   "Launch scope handlers register lazily on a path we can't
   construct from the harness" and defer.
3. **If wrapper-exposed without registry-side handlers**,
   document as a known limitation alongside the operon finding.

T21's case-doc claim is "dev server preview pane" — needs
`.claude/launch.json` AND a real project to fully exercise. The
Tier 2 reframe is "the Launch dispatch handler is registered AND
returns the documented shape on a known fixture path"; needs more
investigation than T19/T20.

Skip this category unless Category A's read-side candidates turn
up empty AND Category C is also unappealing.

#### Category C — operon / Launch exposure-vs-registration probe

The plan: write a small read-only probe (mirror
`eipc-registry-probe.ts`'s shape) that asks two questions for each
of operon and Launch:

1. **At fresh launch + post-login**, are any operon / Launch handlers
   registered on the claude.ai webContents? Session 7's registry walk
   on `/epitaxy` and `/new` didn't surface them in the per-interface
   summary (which lists every `(scope, iface)` pair). Confirm — re-
   run the registry walker, filter by `scope === 'claude.operon'` and
   `scope === 'claude.web' && iface.startsWith('Launch')`, capture
   the count.
2. **After navigating to operon-mode URL or a launch-config'd
   project**, do the missing handlers appear? Operon-mode URLs are
   TBD — search `claude.ai/...` paths in the bundle for `operon`-
   keyed routes. Launch-config navigation needs `.claude/launch.json`
   in the working folder.
3. **Independently**, does the renderer-side wrapper expose
   `window['claude.operon']` / `window['claude.web'].Launch`
   regardless of registration status? (Yes per session 8 for
   operon; un-confirmed for Launch.)

Outputs:

- If operon / Launch handlers register on claude.ai eagerly: write a
  one-liner Tier 2 reframe spec for the highest-priority case-doc
  target.
- If they register lazily on a navigation we can't easily construct:
  document the prerequisite in plan-doc Status section as a Tier 3
  item ("requires operon-mode navigation primitive" /
  "requires .claude/launch.json fixture"), and don't ship a probe.
- If the wrapper is exposed without registered handlers: document as
  a known limitation of `invokeEipcChannel` (will fail with "no
  handler registered" even though `window['claude.<scope>']` is
  present).

This is a smaller-scope category — investigation + maybe one spec
landing. Best fallback if Category A's read-side candidates turn up
empty.

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

These are unchanged from sessions 1-9 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26/T22b/T27/T31b/T33b/T33c/T35b/T37b/T38b are the
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
- **For arg validator schema-rev: grep the rejection message
  literal first.** Session 9 finding. When `invokeEipcChannel`
  rejects with `Argument "<name>" at position N ... failed to pass
  validation`, that exact string lives inline in the validator
  block. One grep on the literal resolves the location; reading
  ~2KB around it surfaces the full schema. Cheaper than runtime
  closure inspection in most cases (closure inspection is a good
  cross-check).
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
  whenever a future consumer surfaces. T19/T20 read-side reframes
  may need them; pre-flight check before adding to `claudeai.ts`
  whether the read-side path actually exercises the AX surface or
  only the IPC.
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
  T22b, T27, T31b, T33b, T33c, T35b, T37b, T38b pattern) are
  cleaner than 5+ separate attachments.
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
  default).

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 9 section,
   then read `lib/eipc.ts`'s `invokeEipcChannel` API +
   `T33c_plugin_browser_invocation.spec.ts` leading comments.
   Confirm you understand the multi-suffix invocation pattern, the
   schema-rev approach (rejection-message grep), and the 180s
   timeout budget.
3. Pick ONE Category as the main bet. For Category A, plan the
   approach: (a) re-run the registry probe to enumerate
   LocalSessions read-sides, (b) smoke-test candidates with `args =
   []`, (c) schema-rev any rejections via bundle grep. List which
   approaches you'll try in what order, with the cap at 2-3
   distinct approaches before STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category A (T19/T20 read-side reframes):
- Spawn ONE subagent per read-side candidate (or one per
  investigation approach if candidates aren't yet identified):
  registry-probe re-run, smoke-test of candidate suffixes, schema-
  rev of any rejections. Treat as exploratory; report findings
  before committing to a spec shape. The user's debugger-attached
  running Claude is a great target for verification probes (mirror
  session 7's `eipc-registry-probe.ts` shape and session 9's
  bundle-grep pattern).
- Cap re-spawns at 2-3 distinct approaches; if all empty, STOP AND
  REPORT. Pivot to Category B or C if budget remains.
- If a candidate's schema is recoverable AND invocation lands
  cleanly with valid args, second batch: ship `T19c` /
  `T20c` (or whatever the file-naming convention dictates given
  the existing T19/T20 files don't exist yet — use `_runtime`
  suffix as session 7 did for T22b / T31b / T33b / T38b, OR
  `_invocation` suffix as session 9 did for T33c, depending on
  whether registration siblings T19b / T20b are also being
  shipped).
- Cap at ~2 specs total — don't try to land both if the first one
  surfaces an unexpected issue.

For Category C (operon / Launch scope probe):
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
1-9 had cumulative ~16 "stop and report" outcomes that were the
right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral,
S14 primitive-gap then primitive-build, T35/T36 Phase 2 deferrals,
T18 Tier 1 reframe, T36 Phase 2 reclassification to Tier 3/4,
session-6 lib/input-niri.ts shipped untested-on-niri, session-7
per-wc IPC scope finding overturning the session-3 closure-local
conclusion, session-8 renderer-wrapper-vs-main-side decision,
session-9 schema-rev cross-check via dual investigation).

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
   - Updated coverage stat (was 70/76 = 92%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-9:

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
5. **Carry-over from session 5/6/7/8/9:** If pursuing Category A
   and the read-side candidates turn up empty / require schema-rev
   that exceeds budget after 2-3 approaches, STOP. Don't keep
   digging — pivot to Category B or C. Document what was tried.
6. **NEW for session 10:** If a Category A read-side reframe
   surfaces a "registered but uninvocable" pattern (handler is on
   the registry but the renderer-side wrapper isn't exposed for
   the relevant scope), that's the same shape as session 8's
   find_in_page / main_window observation — document it and
   defer rather than building the main-side fallback
   speculatively.

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
5. **Category A read-side candidates all turn up empty after 2-3
   distinct attempts.** Document the dead-end as a finding, pivot
   to Category B or C if budget remains.

### What you should NOT do

- **Don't try to land Category A + Category B in one batch.** Pick
  ONE as the main bet. Category C is small enough to pair as a
  fallback.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative sixteen "stop and
  report" outcomes from sessions 1-9 were the right call — every
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
  property is that case-doc-anchored suffixes are read-side.
  Session 9 reframed T33's invocation through the read-side
  `list*` methods specifically because of this. T19/T20 (Category
  A) need the same treatment — case-doc anchors at write-side
  handlers must be reframed through read-side equivalents.
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
  T19/T20 read-side reframes may not even need them if the
  read-side path is purely IPC-driven.
- **Don't add a main-side `invokeEipcChannel` fallback
  speculatively.** Build it only if a concrete consumer needs to
  invoke through a non-claude.ai webContents. Premature primitives
  leak design debt.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 10)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 70/76 (92%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | T19c | T19c_*.spec.ts | … | ✓ pass / skip / fail |
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
  `window['claude.<scope>'].<Iface>.<method>`). See T27 / T33c /
  T35b / T37b for end-to-end consumer patterns. Only call read-
  side suffixes; the primitive doesn't enforce a read-only
  allowlist.
- **For arg validator schema-rev (session 9 finding):** when
  invocation rejects with `Argument "<name>" at position N ...
  failed to pass validation`, grep the bundled `index.js` for the
  literal rejection string. The validator block sits ~50-200 chars
  before that throw. Read ~2KB around it to capture the full
  schema. See plan-doc session 9 status section for the byte
  offsets of the two CustomPlugins validators (5013601 / 5018821)
  as worked examples.
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
