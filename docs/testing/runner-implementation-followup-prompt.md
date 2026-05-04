# test-harness runner implementation — session 8 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 4
new specs (T22b, T31b, T33b, T38b) and 1 new primitive
(`lib/eipc.ts`). Coverage 62/76 (82%) → 66/76 (87%). One commit on
`docs/compat-matrix`:

- `XXX` — `test(harness): session 7 runner + eipc-registry primitive`
  (4 new Tier 2 runtime probes — T22b/T31b/T33b/T38b — paired with
  the existing T22/T31/T33/T38 Tier 1 fingerprints; new
  `lib/eipc.ts` primitive walks `webContents.ipc._invokeHandlers`
  per-WebContents, opaque on the framing UUID, suffix-matched against
  case-doc anchors).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 7** first, then
**session 6**, then **session 5**, then **session 4**, then **session
3**, then **session 2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 7

1. **eipc registry IS reachable from main — sessions 2-6 looked in
   the wrong place.** Handlers go through Electron's stdlib
   `IpcMainImpl`, just on the per-`webContents` IPC scope
   (`webContents.ipc._invokeHandlers`, Electron 17+) rather than the
   global `ipcMain._invokeHandlers`. Verified empirically: the
   claude.ai webContents holds 490 handlers including all 117
   `LocalSessions_$_*` and 16 `CustomPlugins_$_*` channels; the
   global `ipcMain` only has the 3 chat-tab MCP-bridge handlers
   session 3 reported. Registry is sticky across route changes
   (registers at webContents init, persists). See
   `tools/test-harness/eipc-registry-probe.ts` (kept in-tree as a
   re-runnable read-only probe).
2. **`lib/eipc.ts` is read-only by design — no `invokeEipcChannel`
   yet.** Session 7's API surface: `getEipcChannels` /
   `findEipcChannel` / `findEipcChannels` / `waitForEipcChannel` /
   `waitForEipcChannels`. All five are read-only — they walk
   `_invokeHandlers` keys but never call the underlying functions.
   Adding invocation would unlock T35 Phase 2 / T37 Phase 2 / T27
   Tier 2 reframe but the design decisions (event synthesis, args
   marshaling, side-effect gating per read vs write channel) need
   a real consumer to anchor against — same anti-speculation rule
   that kept `lib/electron-mocks.ts` (session 3) and `lib/input.ts`
   (session 4) and `lib/input-niri.ts` (session 6) threshold-driven.
3. **53 distinct interfaces fully mapped.** The probe's per-interface
   breakdown surfaced every `(scope, iface)` pair across the three
   webContents. Bonus interfaces with direct line-of-sight to
   deferred work:
   - `claude.web/CoworkMemory/readGlobalMemory` (read-only) → **T37
     Phase 2** unlock.
   - `claude.settings/MCP/getMcpServersConfig` (present on ALL three
     webContents, read-only) → **T35 Phase 2** unlock.
   - `claude.web/CoworkScheduledTasks/getAllScheduledTasks` /
     `claude.web/CCDScheduledTasks/getAllScheduledTasks` → **T27
     Tier 2 reframe** unlock.
   - `claude.web/ClaudeCode/{getStatus, prepare, checkGitAvailable,
     resolveLocalSettings}` → useful for the deferred T19/T20/T21
     Code-tab cluster (terminal / file pane / dev preview).

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 7**,
  **session 6**, **session 5**, **session 4**, **session 3**,
  **session 2**, then **session 1** "Status (post-execution)" sub-
  sections. The Tier-3 list (search for "## Tier 3") is the
  candidate pool for further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-66-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note (now updated to the per-wc finding).
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable session 7 addition: `eipc.ts`
  (suffix-matched, UUID-opaque registry walker; read-only).
- [`tools/test-harness/eipc-registry-probe.ts`](../../tools/test-harness/eipc-registry-probe.ts)
  — the read-only probe that surfaced the session 7 finding. Re-run
  against a debugger-attached Claude (`Developer → Enable Main
  Process Debugger` from the menu) to capture the current registry
  shape. Useful when designing new probes or auditing for upstream
  drift.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 7 templates:
  - `T22b_pr_monitoring_handler_runtime.spec.ts` — single-channel
    `waitForEipcChannel` shape. Pattern for any future Tier 2
    runtime probe asserting handler PRESENCE.
  - `T31b_side_chat_handlers_runtime.spec.ts` — multi-channel
    `waitForEipcChannels` shape with per-channel diagnostic
    attachment. Pattern for trios / pairs.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~3 new specs OR one new primitive landing.**
Session 7 was at the upper end (4 specs + 1 primitive) because the
primitive build was small (the registry was already in stdlib IPC,
just at a different scope) and the four specs were near-identical
shape. This session's work is more variable — the main bet involves
a primitive extension (`invokeEipcChannel`) that may or may not be
tractable depending on origin validation.

**Category A (eipc invocation extension + T35 Phase 2 canary) is
the cleanest single-session win available.** Sessions 2-6 each
flagged T35 Phase 2 / T37 Phase 2 as needing "a reachable readback
target". Session 7 confirmed the readback targets exist (per-wc
registry has the read-side handlers); what's missing is the
invocation primitive to call them.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** eipc invocation extension + T35 Phase 2 canary | T35 Phase 2 (and T37 Phase 2 / T27 reframe if budget) | `lib/eipc.ts` extension | Add `invokeEipcChannel(inspector, suffix, args?)` that synthesizes the IPC event. Risk: origin validation may reject synthesized events (case-doc T38 noted `le(i)` origin validation at `:68820`). Investigate first via probe; ship primitive if reachable. |
| **B** T19/T20/T21 Code-tab cluster (paired with Category A invocation) | T19, T20, T21 | depends on Category A invocation + AX-tree click chains | Each needs different combos of `claude.web/ClaudeCode/*` calls + AX surfaces. More work per spec. Skip unless Category A's invocation surface lands cleanly. |
| **C** Single-spec deferred items audit | various deferred items | — | Lower ceiling, higher confidence per spec. Best fallback if Category A turns up empty. |

#### Category A — eipc invocation extension + T35 Phase 2 canary

The plan: extend `lib/eipc.ts` with an invocation surface, then
ship T35 Phase 2 as the canary against the safest read-only handler
(`claude.settings/MCP/getMcpServersConfig` — present on ALL three
webContents, no side effects).

**Investigation phase first** — invocation has known unknowns:

1. **Origin validation gate.** Case-doc T38 noted `le(i)` origin
   validation at `index.js:68820` — the eipc layer rejects messages
   whose sender doesn't claim `claude.web` origin. Before writing
   `invokeEipcChannel`, probe whether `webContents.ipc.invokeHandler`
   (or whatever the invocation API is) bypasses the origin check
   when called from main. If it does → clean primitive. If it
   doesn't → the primitive needs to either (a) suppress the gate
   from main, (b) inject the call from inside the claude.ai
   webContents via `executeJavaScript`, or (c) install a hook on the
   gate's `setImplementation` site.
2. **Event synthesis.** `webContents.ipc._invokeHandlers.get(key)`
   returns the handler function but it expects an
   `IpcMainInvokeEvent` with a `sender` that has methods like
   `getURL()`. Need to construct or re-use a real event. Cleanest:
   call from inside `executeJavaScript('window.…')` against the
   claude.ai webContents — that goes through the normal eipc client
   wrapper and synthesizes the right event.
3. **Side-effect gating.** Read-only handlers (`getMcpServersConfig`,
   `readGlobalMemory`, `getStatus`, `getAllScheduledTasks`) are safe.
   Write handlers (`setMcpServerConfigs`, `writeGlobalMemory`,
   `startSideChat`, `openInEditor`) write to user state or shell
   out. The primitive should either (a) accept a "write" flag the
   caller has to opt into, or (b) maintain a hardcoded read-only
   allowlist and reject anything else. Pick whichever is closer to
   how `lib/electron-mocks.ts` gates side effects.

**Approaches to investigate (in order):**

1. **Renderer-side invocation via `evalInRenderer`** — find the eipc
   client wrapper in claude.ai's bundled JS (likely `window.claude_eipc.*`
   or similar). Call the handler through the wrapper from inside
   the claude.ai webContents — it handles event synthesis +
   origin validation natively. Probe via inspector to find the
   wrapper's surface.
2. **Direct main-side handler invocation** — pull the function
   out of `_invokeHandlers`, synthesize a minimal `IpcMainInvokeEvent`
   `{ sender: webContents }`, call it. Test against
   `claude.settings/MCP/getMcpServersConfig` first — if it works
   without throwing an origin error, the primitive is straightforward.
3. **Hook the eipc dispatcher** — install a prototype-method hook
   on the dispatcher's `invoke`-side method (sibling of session 7's
   `handle`-side hook approach). More invasive but bypasses any
   origin gate.

If Category A turns up empty after 2-3 distinct approaches, STOP
AND REPORT. Don't keep digging — document what was tried, ship a
"H07 documentation runner" that captures the dead-end as a finding
in JUnit, and pivot to Category C.

If a clean invocation primitive lands, ship `invokeEipcChannel` +
T35 Phase 2 (canary, single-channel against `getMcpServersConfig`).
If T35 Phase 2 lands cleanly, batch T37 Phase 2 (CoworkMemory /
readGlobalMemory) and the T27 Tier 2 reframe (CoworkScheduledTasks
/ getAllScheduledTasks). Cap at ~3 spec upgrades — don't try to
land all four if the first one surfaces an unexpected issue.

#### Category B — T19/T20/T21 Code-tab cluster (paired with Category A)

Each needs both invocation against `claude.web/ClaudeCode/*` AND
AX-tree click chains against rendered Code-tab surfaces. T19
(integrated terminal) needs `LocalSessions_$_startShellPty` shape;
T20 (file pane) needs `LocalSessions_$_writeSessionFile`; T21
(dev server preview) needs `claude.web/Launch/*`.

Skip this category unless Category A's invocation surface lands
cleanly AND the cluster's AX-tree anchors are pre-verified (none
have been; would need a debugger-on probe like session 5 used for
Code-tab anchors).

#### Category C — single-spec deferred items audit

Walk through session 1-7 deferrals and identify any that are now
tractable. Specifically:

- **S20** — `powerSaveBlocker` Inhibit. Issue #569 still open;
  separate workstream.
- **T18** — drag-drop OS-level form. Tier 1 fingerprint shipped
  session 5; OS-level (Tier 2/3) requires a custom XDND source
  (X11) or libei emitter (Wayland) — both heavy primitive builds.
- **T34** — OAuth round-trip. Hard to mock; not this session
  unless you have a clever idea.
- **T36 Phase 2** — NOT a candidate. Session 5's SessionStart-
  hook trace showed it requires a real-account write.
- **S14 cross-compositor variants (Sway / Hyprland / River)** —
  no current case-doc consumer demands them.

If Category A turns up empty, Category C's most-reachable target
is **investigate Tier 3 reframes for issues opened against the
project since session 7.** Check `gh issue list --state open
--label test-coverage-gap` (if the label exists) or just walk
recent open issues for ones that suggest a Tier 1 fingerprint or
Tier 2 runtime probe is now possible.

#### Cross-compositor focus-shifter expansion (NOT recommended this session)

Building `lib/input-sway.ts` / `lib/input-hypr.ts` would mirror
`lib/input-niri.ts`'s shape but no consumer is asking for them.
Premature abstractions are wrong abstractions. Wait for a real
consumer.

### Constraints to respect (don't violate)

These are unchanged from sessions 1-7 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26/T22b/T31b/T33b/T38b are the templates.
- **eipc handlers register on `webContents.ipc._invokeHandlers`,
  NOT global `ipcMain._invokeHandlers`.** Session 7 finding. Use
  `lib/eipc.ts` rather than rolling a new walker. The framing
  prefix `$eipc_message$_<UUID>_$_` should stay opaque to consumers
  (UUID has been stable but `lib/eipc.ts` doesn't pin it — match
  by case-doc-anchored suffix).
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
  T22b, T31b, T33b, T38b pattern) are cleaner than 5+ separate
  attachments.
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

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 7 section,
   then read `lib/eipc.ts` + `T22b_pr_monitoring_handler_runtime.spec.ts`
   leading comments. Confirm you understand the per-wc registry vs
   global ipcMain distinction.
3. Pick ONE Category as the main bet. For Category A, plan the
   approach: (a) renderer-side invocation via evalInRenderer, (b)
   direct main-side handler invocation, (c) hook the eipc
   dispatcher's invoke side. List which approaches you'll try in
   what order, with the cap at 2-3 distinct approaches before
   STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, the chosen Category's prerequisites don't hold), stop and
report. Don't fan out.

#### Phase 1 — fan-out batch

For Category A (eipc invocation extension):
- Spawn ONE subagent per approach — renderer-side, main-side,
  hook-the-dispatcher. Treat as exploratory; report findings before
  committing to a primitive shape. The user's debugger-attached
  running Claude is a great target for verification probes (mirror
  session 7's `eipc-registry-probe.ts` shape).
- Cap re-spawns at 2-3 distinct approaches; if all empty, STOP
  AND REPORT. Ship an `H07_eipc_invocation_finding.spec.ts`
  documentation runner if useful state surfaces during the
  investigation.
- If a clean invocation surface lands, second batch: extend
  `lib/eipc.ts` with `invokeEipcChannel` + ship T35 Phase 2 as
  canary. Third batch: T37 Phase 2 + T27 reframe.
- Cap at ~3 specs total upgrade — don't try to land all three if
  the first one surfaces an unexpected issue.

For Category C (single-spec audit):
- Walk recent open issues + the deferred-items list. Pick 1-2
  that are now tractable. Standard fan-out per
  `runners/<closest-template>.spec.ts`.

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
1-7 had cumulative ~14 "stop and report" outcomes that were the
right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral,
S14 primitive-gap then primitive-build, T35/T36 Phase 2 deferrals,
T18 Tier 1 reframe, T36 Phase 2 reclassification to Tier 3/4,
session-6 lib/input-niri.ts shipped untested-on-niri, session-7
per-wc IPC scope finding overturning the session-3 closure-local
conclusion).

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
   - Updated coverage stat (was 66/76 = 87%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-7:

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
   assertion shape. Session 3's eipc-registry finding came from
   noticing only 3 handlers in the registry; session 7's correction
   came from noticing the per-wc scope holds the rest. The lesson:
   verify the assertion is meaningful, not just that it passes.
5. **Carry-over from session 5/6/7:** If pursuing Category A and
   the renderer-side / main-side / hook approaches turn up empty
   after 2-3 approaches, STOP. Don't keep digging — document what
   was tried, ship the H07 documentation runner if it surfaces
   useful state, move to Category C.
6. **NEW for session 8:** If Category A's invocation primitive
   lands but T35 Phase 2 surfaces an unexpected response shape
   (e.g. `getMcpServersConfig` returns something that doesn't
   match the case-doc claim), re-examine the case-doc anchors
   before shipping the upgrade — the assertion shape might need
   adjustment, not the test target.

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
4. **Session budget hits ~3 new specs OR one new primitive
   landing.** Stop, synthesize, leave the rest for the next
   session.
5. **Category A approaches all turn up empty after 2-3 distinct
   attempts.** Document the dead-end as a finding, ship H07 if
   useful, pivot to Category C if budget remains.

### What you should NOT do

- **Don't try to land Category A + Category C in one batch.** Pick
  ONE as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative fourteen "stop and
  report" outcomes from sessions 1-7 were the right call — every
  one revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
  `electron-mocks.ts` (session 3), `input.ts` (session 4),
  `input-niri.ts` (session 6), and `eipc.ts` (session 7) were
  threshold-driven extractions, not speculative.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks-fire-on-prompt-submit).
  Only the *read-only reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Session 7 confirmed those use the per-wc IPC
  scope. Use `lib/eipc.ts`'s primitive (which targets the per-wc
  scope) instead.
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
  Wait for a real consumer.
- **Don't add `invokeEipcChannel` speculatively.** Build it only
  if T35 Phase 2 (or another concrete consumer) needs it AND the
  Phase 0 investigation confirms a tractable approach. Premature
  primitives leak design debt.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 8)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 66/76 (87%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | T35 Phase 2 | T35b_mcp_config_runtime.spec.ts | … | ✓ pass / skip / fail |
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
  T38b for end-to-end consumer patterns. Read-only by design;
  invocation surface is session 8's main bet.
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
