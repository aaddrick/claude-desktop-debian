# test-harness runner implementation — session 16 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
structural fix (T17 migrated from legacy `CLAUDE_TEST_USE_HOST_CONFIG=1`
auth path to `seedFromHost: true`, no new spec, no AX migration).
Session 15 was an investigation session: Phase 0 calibration found
port 9229 listening BUT the attached process was a leaked test
isolation at `claude.ai/login` rather than the user's auth-bearing
Claude — every webContents URL on that process was either `find_in_page`,
`/login`, or `main_window/index.html`, and the user-data-dir was
`/tmp/claude-test-*`. That made Categories A (operon-mode probe) / B
(Tier 3 read-only reframes) / C (schema-rev) all soft-blocked: the
debugger was technically attached, but to the wrong process for any
auth-required investigation. Session 15 pivoted to investigating T17's
pre-existing flake (the PRIORITY directive) and discovered the failure
was structural rather than AX-polling-related — the spec was using the
legacy `CLAUDE_TEST_USE_HOST_CONFIG=1` / `isolation: null` shape, and
when run without that env var fell through to a fresh isolation with no
auth, where `waitForUserLoaded`'s 90s default budget gets preempted by
Playwright's 60s spec timeout. Coverage unchanged at 74/76 (97%) —
structural fixes don't move the spec count, but T17 should now succeed
when host is signed in (rather than auto-failing with a bare 60s
timeout). Two commits on `docs/compat-matrix` expected (autonomous
orchestration commits + pushes — the user reviews after the session):

- TBD — `test(harness): session 15 migrate T17 to seedFromHost +
  prune unused RawElement import (no spec, coverage unchanged at 97%)`
  (T17 spec rewrite swapping the `CLAUDE_TEST_USE_HOST_CONFIG=1` +
  `isolation: null` branch for the canonical `seedFromHost: true`
  pattern; prunes unused `RawElement` re-export import in
  `lib/claudeai.ts` per session 14's leftover hint; typecheck clean;
  T17 not actually run this session — see below).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 15** first, then
**session 14**, then **session 13**, then **session 12**, then
**session 11**, then **session 10**, then **session 9**, then **session
8**, then **session 7**, then **session 6**, then **session 5**, then
**session 4**, then **session 3**, then **session 2**, then **session
1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 15

1. **T17 flake was structural, not AX-polling.** The trace showed
   bare 60s Playwright timeout with NO `renderer-url` attachment —
   meaning the test never reached line 49's attach call, which
   means it never resolved `waitForReady('userLoaded')` at line 40.
   Root cause: T17 was the last spec on the legacy
   `CLAUDE_TEST_USE_HOST_CONFIG=1` / `isolation: null` shape — every
   other auth-required spec (T07, T16, T19, T20, T21, T22b, T26,
   T27, T31b, T33b/c, T35b, T37b, T38b) had moved to `seedFromHost:
   true`. Without that env var (which CI / orchestration didn't
   set), T17 fell through to a fresh isolation with no auth, hit
   `/login`, and `waitForUserLoaded`'s 90s budget got preempted by
   the 60s spec timeout. **Session 14's hypothesis was wrong** —
   the AX click chain in `openPill` / `clickMenuItem` was never
   reached, so migrating those wouldn't have fixed anything.
2. **`openPill` / `clickMenuItem` migration parked.** With T17's
   actual flake explained by the auth-path mismatch, there's no
   remaining flake-evidence pulling for the AX migration that
   sessions 14-15 considered. `openPill`'s while-loop and
   `clickMenuItem`'s while-loop work fine when the auth path is
   correct. Don't migrate speculatively — wait for a third
   consumer to surface with budget-tuning evidence.
3. **Phase 0 must distinguish "port open" from "port attached to
   user's signed-in Claude".** Session 14 saw port 9229 closed and
   correctly classified as debugger-detached. Session 15 saw port
   9229 OPEN but attached to a leaked test isolation at /login —
   Categories A/B/C still soft-blocked. The right Phase 0 probe:
   `evalInMain` listing webContents and checking that AT LEAST one
   URL is `https://claude.ai/<not /login>`. If every webContents is
   `/login` or `find_in_page` or `main_window`, treat it the same
   as port-closed for auth-required investigations. Session 15's
   one-off probe shape (kept inline in the report, deleted after):

   ```ts
   const wcs = await client.evalInMain(`
     const { webContents } = process.mainModule.require('electron');
     return webContents.getAllWebContents().map((w) => ({
       id: w.id, url: w.getURL(), title: w.getTitle(),
     }));
   `);
   ```

4. **Leaked `/tmp/claude-test-*` dirs accumulating on dev box.**
   Multiple test isolations from prior sessions have leaked their
   tmpdirs and (in some cases) their Electron child processes.
   `ls /tmp/ | grep claude-test` showed several. The session 15
   T17 spec wasn't run because killing those leaked Electron
   processes might also kill the user's real running Claude (PID
   ambiguity from `ps`). A future session can either (a) verify
   no real Claude is running before invoking T17, or (b) just
   accept the seedFromHost kill side effect and let the user
   re-launch Claude after the session.
5. **Productivity signal is dimming.** Sessions 13-15 collectively
   produced one new primitive (`lib/ax.ts`), one substantive AX
   migration (`activateTab` + `CodeTab.activate`), and one
   structural fix (T17 seedFromHost). NO coverage gain in those
   three sessions. The remaining categories without an
   auth-bearing debugger-attached Claude are mostly exhausted.
   Next session should prioritise (a) running T17 to verify the
   seedFromHost fix actually resolves the timeout, and (b) checking
   whether a Category C schema-rev probe against the leaked /login
   isolation is tractable (validators don't need auth, only
   invocation does — worth a 15-min investigation). If both turn
   up empty, the orchestrator should seriously consider stopping —
   at 97% coverage with no clear high-leverage shapes left,
   further sessions are likely to produce documentation-only or
   marginal-improvement deliverables.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 15**, then
  **session 14**, **session 13**, **session 12**, **session 11**,
  **session 10**, **session 9**, **session 8**, **session 7**,
  **session 6**, **session 5**, **session 4**, **session 3**,
  **session 2**, then **session 1** "Status (post-execution)"
  sub-sections. The Tier-3 list (search for "## Tier 3") is the
  candidate pool for any further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-74-spec inventory, primitives in
  `lib/`, isolation defaults (T17 now seedFromHost per session 15),
  the CDP-gate workaround, the eipc note, and `lib/ax.ts` substrate.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. `lib/ax.ts` surface is `snapshotAx` /
  `waitForAxNode` / `waitForAxNodes` plus re-exports. The session 8
  eipc surface (`getEipcChannels` / `findEipcChannel` /
  `findEipcChannels` / `waitForEipcChannel` /
  `waitForEipcChannels` / `invokeEipcChannel` on `lib/eipc.ts`) is
  unchanged.
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the session 7 read-only registry probe. Re-run against an
  auth-bearing debugger-attached Claude (`Developer → Enable Main
  Process Debugger` from the menu, signed-in) to capture the
  current registry shape.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 15
  candidates for follow-up:
  - `T17_folder_picker.spec.ts` — newly migrated to seedFromHost.
    Run to verify the 60s timeout is gone. If T17 now passes, the
    structural fix shipped session 15 is verified.
  - Schema-rev for `listRemotePluginsPage` / `listSkillFiles` —
    rejection literals can be bundle-grepped without auth, and the
    validator runs auth-independent if /login state lets us
    invoke through the renderer-side wrapper. Session 12 found
    `listRemotePluginsPage` needs `limit: number` at position 0
    and `listSkillFiles` needs both `pluginId` and `skillName`.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~1 verification run OR ~1 schema-rev investigation
OR a "stop the orchestration" recommendation.** Sessions 9-12 each
landed 1-2 specs; session 13 landed only a primitive (debugger
blocked); session 14 landed only a migration (debugger blocked);
session 15 landed only a structural fix (debugger soft-blocked).
Coverage at 74/76 means the test budget naturally shifts toward
verification, low-stakes investigation, or the orchestration
termination decision.

**Phase 0 MUST check the debugger-attachment quality, not just port
status.** Run `ss -tln 2>/dev/null | grep ':9229'` for port. If open,
also run an `evalInMain` probe to enumerate webContents URLs — if no
URL is `https://claude.ai/<not /login>`, treat as soft-blocked for
auth-required categories. Probe shape (kept inline; delete after):

```ts
import { InspectorClient } from './src/lib/inspector.js';
const client = await InspectorClient.connect(9229);
const wcs = await client.evalInMain<unknown>(`
  const { webContents } = process.mainModule.require('electron');
  return webContents.getAllWebContents().map((w) => ({
    id: w.id, url: w.getURL(), title: w.getTitle(),
  }));
`);
console.log(wcs); client.close();
```

If every URL is `/login` or `find_in_page` or `main_window/index.html`,
the debugger is attached to a leaked test isolation, not the user's
Claude. Categories A and most of B are blocked. Category C may still
be tractable since validators run auth-independent — try the schema-
rev probe against the /login wrapper.

#### **PRIORITY: Verify T17's session 15 seedFromHost migration
actually resolves the 60s timeout.** Session 15 didn't run T17 because
the dev box had ambiguous Electron processes (some leaked test
isolations, possibly the user's real Claude — `ps` couldn't
disambiguate cleanly). Session 16's first action:

1. Check `pgrep -af "ozone-platform=x11.*app.asar"` and
   `ps -o pid,user-data-dir` to identify whether any real-Claude
   process is running (real Claude has a non-`/tmp/claude-test-*`
   user-data-dir, typically nothing or `~/.config/Claude`).
2. If only test cruft is running, run T17 (`npx playwright test
   T17 --reporter=list`). The test will kill those leaked
   processes via `seedFromHost`'s host-Claude-kill semantics —
   that's actually a desirable cleanup side effect.
3. If a real Claude IS running, **flag clearly in the report
   before running**, then run T17. The user accepted the
   `seedFromHost` kill side effect when authorising autonomous
   orchestration; just be transparent about it.
4. Capture pass/skip/fail. Update the matrix coverage doc if
   T17 now passes.
5. If T17 still fails, classify the new failure mode (is it now
   AX-polling? Folder picker chain? Mock not installing?) and
   decide whether to fix or defer.

This is **strictly higher-impact than session 14/15's
spec-implementation work** because it produces a concrete
pass/fail data point that resolves a 2-session-old hypothesis.
Doesn't need the debugger.

Three categories — pick the verification run as the main bet, treat
the others as fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **D-verify** T17 verification run (PRIORITY) | T17 | session 15 migration | Run T17 against the dev box. If pass, log it. If fail, classify the new failure mode. **Side effect: kills any running Claude (the user's, or leaked test cruft). Flag in the report.** Doesn't need the debugger. |
| **C** Schema-rev for `listRemotePluginsPage` / `listSkillFiles` | Bundle grep | session 9 schema-rev pattern | Both methods rejected every smoke-tested arg shape during session 12's investigation. `listRemotePluginsPage` needs `limit: number` at position 0 (rejection: `Argument "limit" at position 0 ...`); `listSkillFiles` needs both `pluginId` and `skillName` (rejection: `Argument "skillName" at position 1 ...`). Bundle-grep on the rejection literals → resolve the schema → ship a narrowly-scoped Tier 2 invocation if it unblocks a case-doc claim. **Tractable against a /login isolation since validators run auth-independent.** |
| **STOP** Orchestrator stop recommendation | n/a | session 15 productivity signal | Coverage at 97%, three consecutive non-coverage sessions, remaining categories soft- or hard-blocked. If D-verify and C both produce nothing tractable, formally recommend the orchestrator stop. Documentation-only sessions are still acceptable per the followup termination criteria, but consecutive ones with no improvement signal are noise. |

#### Category D-verify — T17 verification run

The plan: run the post-session-15 T17 against the dev box and capture
the result. Pass = the structural fix landed correctly. Fail = the
hypothesis was incomplete; classify and decide.

1. **Disambiguate running Claude processes.** `pgrep -af
   "ozone-platform=x11.*app.asar"`; for each, `cat
   /proc/<pid>/cmdline | tr '\0' '\n' | grep user-data-dir` (or
   inspect via `ps` cmdline). If only `/tmp/claude-test-*`
   user-data-dirs, no real Claude is running.
2. **Run T17.** `cd tools/test-harness && npx playwright test
   T17_folder_picker --reporter=list 2>&1 | tee
   /tmp/t17-session16.log`.
3. **Classify.**
   - Pass: structural fix verified. Update plan-doc / matrix.
   - Skip with "seedFromHost unavailable": means host has no
     `~/.config/Claude/Local State`. Should be rare on the dev
     box but possible if config was wiped between sessions.
   - Skip with "seeded auth did not reach post-login URL":
     auth was seeded but stale. User needs to re-sign-in
     manually. Don't try to reseed automatically.
   - Fail with NEW failure mode: classify the failure (AX
     click? openFolderPicker chain? dialog mock?). If it's
     now in `openPill` / `clickMenuItem`, sessions 14/15's
     speculation has finally hit; ship the AX migration.
     Otherwise document and defer.
4. **Don't restructure T17's body** unless step 3 surfaces a
   real new bug. Keep changes scoped to whatever the verification
   surfaces.

Doesn't need the debugger.

#### Category C — Schema-rev for rejecting read-sides

The plan: resolve the validator schema for `listRemotePluginsPage` /
`listSkillFiles` via bundle grep, ship invocations if either unblocks
a case-doc claim. Tractable against a /login isolation since
validators run auth-independent.

1. **Grep on the rejection literal** in the bundled `index.js`.
   Validator block sits ~50-200 chars before the throw site (session
   9 finding). Read ~2KB around the hit to surface the full schema.
2. **Smoke-test the recovered schema** against the user's debugger-
   attached running Claude (or, if auth-soft-blocked as in session 15,
   against the /login isolation — validators run regardless of auth).
3. **Connect the resolved invocation to a case-doc claim.**
4. **Ship a Tier 2 invocation** if a case-doc claim is unblocked.

Auth-independent for the validator; auth-bearing for any handler that
actually returns plugin / skill data. If the validator resolves but
the handler fails on auth, document the schema in plan-doc as a
deferred reframe and move on.

#### STOP recommendation

If D-verify resolves cleanly (pass or stable skip) and C produces no
shippable spec after the schema-rev investigation, the productivity
signal for further sessions is squarely "documentation-only with no
clear next-step deliverable." The orchestrator should stop. State
this plainly in the final report; don't keep cycling.

### Constraints to respect (don't violate)

These are unchanged from sessions 1-15 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T07/T11_runtime/T16/T17/T19/T20/T21/T26/T22b/T27/T31b/T33b/T33c/T35b/T37b/T38b
  are the templates. **T17 was migrated to this shape in session 15.**
- **eipc handlers register on `webContents.ipc._invokeHandlers`,
  NOT global `ipcMain._invokeHandlers`.** Session 7 finding. Use
  `lib/eipc.ts` rather than rolling a new walker.
- **eipc invocation goes through the renderer-side wrapper at
  `window['claude.<scope>'].<Iface>.<method>`.** Session 8 finding.
  Use `lib/eipc.ts`'s `invokeEipcChannel` rather than rolling
  main-side direct calls.
- **For arg validator schema-rev: try smoke-test first, then grep
  the rejection message literal.** Session 9 finding.
- **For AX-tree consumers: use `lib/ax.ts`.** Session 13 finding.
  `snapshotAx` for one-shot reads, `waitForAxNode` /
  `waitForAxNodes` for predicate-based polling.
- **For call-site migrations to `waitForAxNode`: keep the per-spec
  retry budgets matching the existing tuning.** Session 14
  finding. Migration is shape-only EXCEPT when the call-site has
  NO retry at all — adding a budget is the bug-fix the migration
  delivers.
- **For test specs that depend on host auth: use `seedFromHost:
  true`.** Session 15 finding. The legacy `CLAUDE_TEST_USE_HOST_CONFIG=1`
  / `isolation: null` shape collides with Playwright's 60s spec
  timeout when the env var isn't set; `seedFromHost` gives a clean
  skip-or-pass shape. T17 was the last spec on the legacy shape.
- **`lib/input.ts` is X11-only.** Strict gate.
- **`lib/input-niri.ts` is Niri-only.** Strict gate.
- **CDP auth gate is alive** — runtime SIGUSR1 attach via
  `app.attachInspector()`, never Playwright's `_electron.launch()`
  or `chromium.connectOverCDP()`.
- **BrowserWindow Proxy gotcha** — use
  `webContents.getAllWebContents()` not
  `BrowserWindow.getAllWindows()`.
- **`skipUnlessRow()` always first.**
- **No fixed sleeps.** `retryUntil` from `lib/retry.ts`, or
  Playwright auto-wait, or `waitForAxNode` from `lib/ax.ts`.
- **Diagnostics on every run.** `testInfo.attach()` the artefacts.
- **Tag with annotations.** `severity:` and `surface:` on every
  test so JUnit carries them through to matrix-regen.
- **Tabs in TS, ~80-char wrap as the existing files do.**
- **Don't break existing runners.** `npm run typecheck` must stay
  clean. H01-H05 are the canaries; `npm test` must still pass them
  after every commit. Note that T07 / S25 / S29-S31 / S04 etc.
  may be pre-existing-flaky on KDE-W — they're NOT canaries;
  baseline failures don't block work.
- **Always grep the installed asar** to verify a fingerprint
  string is present.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. **Check debugger ATTACHMENT QUALITY (not just port).** First
   `ss -tln 2>/dev/null | grep ':9229'`. If port open, also probe
   webContents via `evalInMain` (see "Big new findings" §3 for
   the probe shape). If every URL is `/login` /
   `find_in_page` / `main_window`, treat as soft-blocked.
3. **Disambiguate running Claude processes.** Required before any
   `seedFromHost` spec. `pgrep -af "ozone-platform=x11.*app.asar"`
   + cmdline inspection for user-data-dir.
4. Read the plan doc's "Status (post-execution)" session 15 section,
   then read T17's session-15 form and the seedFromHost convention.
5. Pick the main bet:
   - **D-verify** (PRIORITY): run T17, classify the result.
   - **C**: bundle grep on rejection literals, schema-rev,
     smoke-test the resolved shape against the /login isolation.
   - **STOP**: if both above produce nothing tractable, recommend
     stopping the orchestration.

If Phase 0 surfaces a problem (typecheck failing, primitives unclear,
the chosen Category's prerequisites don't hold), stop and report.
Don't fan out.

#### Phase 1 — fan-out batch

For Category D-verify (T17 run):
- Single subagent (or do directly — it's a single-command run +
  trace inspection) runs T17 and classifies. Verify by checking
  pass/skip/fail and any new failure-mode trace.

For Category C (schema-rev):
- Single subagent does bundle-grep on the rejection literals,
  surfaces the validator schemas, smoke-tests the recovered shapes
  against the user's debugger-attached running Claude (or /login
  isolation if soft-blocked).

Cap at ~1 spec OR ~1 verification + 1 schema-rev — same scope as
sessions 9-15.

#### Per-subagent prompt shape

```
You're implementing ONE [verification run | primitive migration |
investigation] for <TARGET>.

Read in order:
- docs/testing/cases/<FILE>.md (focus on <TARGET>'s Code anchors)
- tools/test-harness/README.md (conventions; status section names
  the most-recent-template that fits)
- tools/test-harness/src/runners/<closest-template>.spec.ts
- tools/test-harness/src/lib/ (the primitives you'll reuse —
  including session 13's `lib/ax.ts` and session 15's seedFromHost
  T17 migration)
- CLAUDE.md (project conventions)

[per-task specifics: pattern (verification run / mock-then-call /
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
NOT write a stub. Report under Open questions and stop.

Report shape (~150 words):
## <TARGET> [verification | primitive | investigation | migration]

- File written: tools/test-harness/src/runners/<filename>.spec.ts
  [or lib/<newfile>.ts or modified lib/<existing>.ts]
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) |
  pgrep | new-primitive | investigation | migration | verification
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

Same as sessions 1-15:

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
   defaults didn't match.
6. **Carry-over from sessions 5-15:** If the chosen Category's
   investigation doesn't resolve / requires schema-rev that exceeds
   budget after 2-3 approaches, STOP. Don't keep digging — pivot
   to a fallback Category. Document what was tried.
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
4. **Session budget hits ~1 verification + 1 schema-rev landing.**
   Stop, synthesize, leave the rest for the next session.
5. **All categories blocked / unproductive after 2-3 attempts
   each.** Document the findings as plan-doc additions, **and
   recommend the orchestrator stop the campaign** — coverage at
   97%, three+ consecutive non-coverage sessions, dimming
   productivity signal.

### What you should NOT do

- **Don't try to land D-verify + C in one batch.** Pick D-verify
  first; if that resolves cleanly, take C as a stretch goal.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account.
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
- **Don't migrate `openPill` / `clickMenuItem` to `waitForAxNode`
  speculatively.** Session 15 confirmed T17's flake didn't need
  it; without a third consumer signal, it's premature optimisation.
- **Don't reach into `explore/walker.ts` for AX types/helpers.**
  `lib/ax.ts` re-exports — use those.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't keep cycling on documentation-only sessions.** If
  D-verify and C both turn up empty, formally recommend the
  orchestrator stop the campaign rather than burning another
  session of compute on marginal output.

### Final report format

```markdown
## Runner implementation summary (session 16)

- Main-bet category: D-verify | C | STOP
- Specs landed: N
- Migrations completed: N
- Primitives landed: N
- Verifications run: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 74/76 (97%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| D-verify | T17 | T17_folder_picker.spec.ts | … | ✓ pass / skip / fail |
| ... |

## Notable findings
- ...

## Open questions
- ...

## Stop recommendation
- Yes / no, with rationale.

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
- For tests that touch the AX tree, **`lib/ax.ts`** is the shared
  substrate.
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
- **For call-site migrations to `waitForAxNode` (session 14
  finding):** keep per-spec retry budgets matching the existing
  tuning.
- **For auth-required spec migrations (session 15 finding):**
  use `seedFromHost: true`, NOT `CLAUDE_TEST_USE_HOST_CONFIG=1` /
  `isolation: null`. The legacy shape collides with Playwright's
  60s spec timeout.
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
