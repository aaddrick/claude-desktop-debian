# test-harness runner implementation — session 5 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 3
new specs (T35, T36, S11) plus one new primitive (`lib/input.ts`
focus-shifter), lifting harness coverage from 57/76 (75%) to 60/76
(79%). Three commits on `docs/compat-matrix`:

- `XXX` — `test(harness): session 4 runners + focus-shifter primitive`
  (3 new spec files: T35 Phase 1 MCP separation fingerprint, T36
  Phase 1 hooks runtime fingerprint, S11 X11-only Quick Entry
  from-other-focus; new `lib/input.ts` exporting `focusOtherWindow` /
  `spawnMarkerWindow` / `getFocusedWindowId` / `isX11Session` /
  `WaylandFocusUnavailable` / `XdotoolUnavailable`; README inventory
  + plan-doc status updated; S14 explicitly NOT shipped — documented
  as primitive-gap because Niri row gate intersects with
  WaylandFocusUnavailable, would be a stub).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 4** first, then
**session 3**, then **session 2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 4

1. **`lib/input.ts` is X11-only by design — strict
   `XDG_SESSION_TYPE === 'x11'` gate.** The focus-shifter primitive
   throws `WaylandFocusUnavailable` on every other session type
   (including Wayland-with-XWayland like KDE-W and GNOME-W). The gate
   is intentionally strict because xdotool's `windowfocus` exits 0
   even when the compositor refuses activation — only on a real X11
   session can `_NET_ACTIVE_WINDOW` readback honestly verify the
   shift. Consumers (S11 today; future S14 / T18-X11 if ever shipped)
   row-gate to X11-only rows AND catch `WaylandFocusUnavailable` /
   `XdotoolUnavailable` defensively.
2. **S14 NOT shipped — primitive gap.** Niri (S14's only row gate) is
   wlroots Wayland with no XWayland; the focus-shifter primitive
   throws `WaylandFocusUnavailable` there, so an S14 runner would
   skip on every row in its gate. Per "don't ship stubs", S14 stays
   unshipped and is documented as needing Wayland-native focus
   injection (Niri's `niri msg` IPC, or libei when broadly
   available). The Tier 1 reframe (assert
   `--enable-features=GlobalShortcutsPortal` in argv) is already
   covered by S12 — S14's gap is on the delivery side.
3. **T35 / T36 Phase 2 deferred — same closure-local-minified-symbol
   blocker as T37b / S19 / S28.** Both Phase 2 forms need a
   reachable readback for parsed state (T35: parsed MCP server map;
   T36: hook-fire marker observation under Verbose-transcript mode).
   The parsed state lives in closure-local minified symbols not
   reachable from `globalThis` or stdlib IPC. Same gotcha as session
   2's `Sbn()` (S28), session 3's eipc-registry, and T37's parsed
   memory state. **Pattern**: when a Tier 2 reframe wants
   "fixture-then-readback", confirm a reachable readback target
   first; otherwise ship the Tier 1 fingerprint and defer the
   readback half.
4. **Case-doc strings vs minified bundle: `~/.claude.json` example.**
   T35 case-doc anchored on `~/.claude.json` (with tilde), but the
   minified bundle stores it as `.claude.json` (no tilde — minified
   strips path-prefix style and resolves home at use). Always grep
   the installed asar for the EXACT needle before settling on it;
   case-doc text is sometimes the user-facing form, not the bundle
   form.
5. **README inventory tidy: explicit `electron-mocks.ts` + `input.ts`
   entries.** The lib/ tree comment in README was missing those two;
   now it lists both with a one-line description. Future primitive
   extractions should add the entry at extraction time, not later.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 4**,
  **session 3**, **session 2**, then **session 1** "Status (post-
  execution)" sub-sections. The Tier-3 list (line ~342) is the
  candidate pool for further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-60-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable additions since session 4:
  - `input.ts` — focus-shifter (X11-only). If a future spec needs
    Wayland-native focus injection, the natural extension is a
    sibling `input-wayland.ts` per-compositor IPC layer (or libei
    once broadly available); don't try to bolt Wayland into the
    existing X11 file.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 4 templates:
  - `T35_mcp_config_separation.spec.ts` — four-needle asar
    fingerprint with per-needle case-doc anchor + rationale in the
    attached JSON. Pattern for any "this surface needs N strings
    co-present in the bundle" probe.
  - `T36_hooks_fingerprint.spec.ts` — five-needle fingerprint with
    per-needle occurrence counts in the attached JSON. The
    occurrence count gives drift signal even when the count
    doesn't drop to zero (N → N-1 is still load-bearing
    information). Pattern for any future fingerprint that wants
    drift detection beyond binary present/absent.
  - `S11_quick_entry_from_other_focus.spec.ts` — first consumer of
    `lib/input.ts`. Single-shot diagnostic record (S31 pattern)
    accumulating sessionEnv / markerTitle / active-WID before+after
    / popupState / openError / focusError / launcher-log tail.
    Marker xterm cleanup in `finally`. Pattern for any future spec
    that spawns a sacrificial host process the test must always
    tear down.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~3 new specs OR one major primitive landing.**
Session 4's three Tier 1 fingerprints were cheap; session 5's
candidates are heavier — most need either a new primitive that takes
most of the budget, or fixture-then-readback against state that
isn't reachable today.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** eipc-registry exposer (primitive gap) | unblocks T22/T31/T33/T38 Tier 2 reframes | `lib/electron.ts` or new `lib/eipc.ts` | High-risk-high-reward closure-local reverse-engineering. One big primitive landing. |
| **B** Code-tab session opener primitive + Phase 2 reframes | T36 Phase 2 (hooks fire), T11 full form (plugin install), maybe T19/T20 (terminal/file pane) | new `lib/codetab.ts` AX-tree page-object | Unblocks 4+ Tier 3 specs. AX-tree work is fragile against minified UIs. |
| **C** Single-spec deferred items audit | various | — | Re-walk session 1/2/3/4 deferrals; pick anything tractable. Lower ceiling, higher confidence per spec. |

#### Category A — eipc-registry exposer (primitive gap)

Listed in session 3/4 as the high-risk-high-reward primitive that
would unblock proper Tier 2 runtime probes for T22 / T31 / T33 / T38
(currently Tier 1 fingerprints because the eipc registry is
closure-local). The work is reverse-engineering the bundled
`index.js` near `:68820` (`le(i)` origin validation) and `:68816`
(channel framing) to find a stable handle to the registry.

**Phase 1 (cheap, ship first):** confirm by grep what session 3's
KDE-W run claimed — the standard `ipcMain._invokeHandlers` registry
holds only three chat-tab MCP-bridge handlers
(`list-mcp-servers` / `connect-to-mcp-server` /
`request-open-mcp-settings`) regardless of ready level. Confirm the
custom `$eipc_message$_<UUID>_$_claude.web_$_<name>` framing is
distinct from stdlib IPC. Ship a Tier 0 documentation runner
(NEW SPEC: `H06_eipc_registry_finding.spec.ts`?) that snapshots
the registry contents and surfaces them as a JUnit attachment for
historical comparison. Doesn't fix the gap but cements the finding.

**Phase 2 (the actual reverse-engineering):** walk the bundled
`index.js` near `:68816`-`:68820` looking for:
- A module-level Map / object that the eipc bootstrap mutates as
  channels register.
- A function that the framing layer calls to dispatch — its `this`
  binding might be the registry.
- A `globalThis` write the bootstrap does (unlikely; if it existed
  session 3 would have found it).

If you find a stable handle, expose it via a new `lib/eipc.ts`
helper (`getEipcChannels(inspector): Promise<string[]>`,
`invokeEipcChannel(inspector, name, args): Promise<unknown>`).

Then upgrade T22 / T31 / T33 / T38 from Tier 1 fingerprints to
Tier 2 runtime probes:
- **T22**: invoke `LocalSessions_$_getPrChecks` with a synthetic
  arg, assert handler runs without throwing (or returns a
  documented error shape — `installGh()` is macOS-only so a
  Linux/Windows invocation should hit the `gh CLI not found in
  PATH` throw site).
- **T31**: invoke each side-chat channel with synthetic args.
- **T33**: invoke `CustomPlugins_$_listMarketplaces`, assert the
  marketplace list shape comes back.
- **T38**: invoke `LocalSessions_$_openInEditor` against the
  shell.openExternal mock from `lib/electron-mocks.ts` (mock first,
  then invoke — same shape as T24).

**STOP AND REPORT** if the registry is truly closure-local with no
exposed surface. A clean "I tried, here's what I found, here's why
it's unreachable" report is itself useful — it converts the
"primitive gap" annotation in the plan-doc from "TODO" to "tried,
unfixable without an upstream change". Don't ship a stub.

#### Category B — Code-tab session opener primitive

Many Tier 3 specs blocked on "needs login + a Code-tab session
OPEN": T11 full form (plugin install end-to-end), T19 (terminal),
T20 (file pane), T31 / T32 full form, T36 Phase 2 (hooks fire), T37
Phase 2 (CLAUDE.md memory parsed-state readback), partially T35
Phase 2.

The blocker isn't login itself (`createIsolation({ seedFromHost:
true })` solves that — see T16/T26) — it's the multi-step AX-tree
click chain to navigate Code tab → select-or-create project →
start session. T16 currently asserts "Code body mounted" via a
compact-pill probe; the next step is "session OPEN against a
project" which needs:

1. Click the Code tab (existing in T16).
2. Select an existing project from the sidebar OR click "New
   session" / "Add project".
3. For a hermetic test, project selection needs a fixture — write
   a directory under `<isolation>/Documents/` (or wherever the
   Code tab's project list reads from) and hope it shows up.
4. Click into the session — wait for the session UI to mount.

**Phase 1 (cheap):** read T16 / T26 / T17 (the AX-tree click-chain
templates) and the `claudeai.ts` page-object. Sketch the
click-chain for "Code tab → first project → start session" without
writing it. If the existing primitives don't have the AX-node
selectors needed (e.g. project-list rows aren't in the inventory
anchors yet), this is a multi-week project — STOP AND REPORT,
suggest a separate session for the AX-tree teaching work.

**Phase 2 (the actual primitive):** add a `CodeSession` class to
`claudeai.ts` (or split into `lib/codetab.ts` if `claudeai.ts` is
getting crowded). Methods: `openExistingProject(path)`,
`startNewSession()`, `waitForSessionReady()`. Each step is a
retry-until-AX-node-appears.

**Phase 3 (consumers):** ship T36 Phase 2 first — it's the
smallest. `~/.claude/settings.json` SessionStart-hook that touches
a marker file + assertion that the marker file exists after
`CodeSession.startNewSession()` resolves. Then T37 Phase 2 (memory
state readback via session prompt inspection) if Phase 2 found a
readback path.

#### Category C — single-spec deferred items audit

Walk through session 1/2/3/4 deferrals and identify any that are
now tractable. Specifically:

- **S20** — `powerSaveBlocker` Inhibit. Issue #569 still open; not
  this session.
- **T18** — drag-drop. X11 path is Tier 3 with xdotool drag (the
  new `lib/input.ts` could add a `dragFile()` helper using
  `xdotool mousemove + mousedown + mouseup` against the marker-
  window pattern; X11-only). Wayland blocked until libei. Could
  be a one-spec session if Category A/B don't fit.
- **T34** — OAuth round-trip. Hard to mock; not this session
  unless you have a clever idea.
- **S14** Wayland variant — needs Wayland-native focus injection.
  Could be exploratory: try `niri msg` on the Niri row, document
  whether it's stable enough to bake into a primitive.
- **T35 Phase 2** — fixture-readback. Same closure-local target as
  T37b. Would need either the eipc-registry exposer (Category A)
  to land first, or a different readback path.

### Constraints to respect (don't violate)

These are unchanged from sessions 1/2/3/4 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26 are the templates.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  channels.** Session 3 confirmed those use a custom eipc protocol
  not in the standard registry. T22/T31/T33/T38 are Tier 1
  fingerprints. If you build the eipc-registry exposer (Category
  A), update the plan-doc and this prompt accordingly.
- **`lib/input.ts` is X11-only.** Strict `XDG_SESSION_TYPE ===
  'x11'` gate. Wayland consumers must skip — don't try to bolt
  Wayland into the file. If session 5 attempts Wayland-native
  focus injection (S14 variant or Category C), put it in a
  sibling file (`lib/input-wayland.ts` or `lib/input-niri.ts`).
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
  errors and short-circuit; see S11 for the pattern.)
- **Diagnostics on every run.** `testInfo.attach()` the artefacts.
  Single-shot JSON dumps for multi-state tests (S11, S31 pattern)
  are cleaner than 5+ separate attachments.
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
  bundle. The case-doc text is sometimes the user-facing form
  (e.g. `~/.claude.json`) not the bundle form (`.claude.json`).
- **For mock-then-call: the helper goes in
  `lib/electron-mocks.ts`,** not `lib/claudeai.ts`. Documented in
  T24/T25's leading comments.
- **Marker windows / sacrificial host processes always die in
  `finally`.** S11 is the template — `marker.kill()` runs before
  `app.close()` so the kill happens even if the spec throws.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 4 section,
   then read S11's leading comment (the X11-only-row-gate
   reasoning) and `lib/input.ts`'s leading comment (the X11-only
   gate-strictness reasoning). Confirm you understand both.
3. Pick ONE Category as the main bet. Don't write it yet — confirm
   you can plan from the spec. Verify any fingerprint strings
   exist in the installed asar before committing to them. For
   Category A/B, confirm the closure-local landscape hasn't shifted
   (re-run the session 3 inspector walk or its equivalent).

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, the chosen Category's prerequisites don't hold), stop and
report. Don't fan out.

#### Phase 1 — fan-out batch

For Category A (eipc-registry exposer):
- Spawn ONE subagent doing the inspector walk — looking for
  module-level Maps / dispatch functions / `globalThis` writes
  near `:68816`-`:68820`. Treat as exploratory; report findings
  before committing to a primitive shape.
- If a stable handle is found, second batch: build `lib/eipc.ts`
  + ship `H06_eipc_registry_finding.spec.ts`. Third batch:
  upgrade T22 / T31 / T33 / T38.
- Cap at ~3 specs total upgrade — don't try to land all four if
  the first one surfaces an unexpected issue.

For Category B (Code-tab session opener):
- Spawn ONE subagent surveying the existing AX-tree primitives
  and inventory anchors for the Code tab. Sketch the click chain.
  If the AX-tree gaps are large (no project-list anchors, no
  session-OPEN anchor), STOP AND REPORT — this becomes a
  multi-session AX-tree teaching project.
- If the gaps are manageable, second batch: ship `CodeSession`
  primitive in `claudeai.ts` + T36 Phase 2 spec.
- Hold T11 / T19 / T20 / T37 Phase 2 for batch 3.

For Category C (single-spec audit):
- Pick 2-3 deferred items per the table above. Standard fan-out
  per `runners/<closest-template>.spec.ts`.

#### Per-subagent prompt shape

```
You're implementing ONE [test-harness runner | primitive] for
<TARGET>.

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
asar fingerprint / shared isolation / new-primitive-build),
assertion shape, skip rules, key constraint warnings]

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
1, 2, 3, and 4 had cumulative ~10 "stop and report" outcomes that
were the right call (S20 deferral, T05 reshape, T07 needs
seedFromHost, T08 needs setState('close'), S28 reclassification,
T38 framing, session-3 eipc-registry finding, T37 fixture-readback
deferral, S14 primitive-gap, T35/T36 Phase 2 deferrals).

Report shape (~150 words):
## <TARGET> [runner | primitive]

- File written: tools/test-harness/src/runners/<filename>.spec.ts
  [or lib/<newfile>.ts]
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) |
  pgrep | new-primitive
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
   Claude). **CRITICAL:** Test that any spec depending on
   authenticated state actually uses `seedFromHost: true`. Test
   that any spec depending on X11 focus is row-gated to X11 rows
   only. Capture pass/skip/fail per spec for the matrix.
3. Update [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
   "Status (post-execution)" section to reflect newly-shipped
   specs and any reclassifications discovered mid-flight.
4. Update [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
   inventory table.
5. Write a final report listing:
   - Specs landed (pass / skip / needs-tuning per row)
   - Specs deferred (with the per-test rationale)
   - Specs reclassified (Tier 3 → Tier 2, Tier 2 → Tier 1, etc.)
   - Updated coverage stat (was 60/76 = 79%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1, 2, 3, and 4:

1. Subagent typecheck failure → re-spawn with explicit fix
   instruction.
2. Subagent claims a runner exists but `git status` shows no new
   file → re-spawn with explicit "use the Write tool" instruction.
3. Two subagents wrote runners that share a primitive but with
   different shapes → factor into `lib/<topic>.ts` BEFORE
   shipping.
4. Spec passes locally but the assertion is actually trivial
   (e.g. an unauthenticated launch where the handler check
   vacuously passes because no handlers are registered) →
   re-examine the assertion shape. The session-3 eipc-registry
   finding came from finding only 3 handlers in the registry —
   the lesson is to verify the assertion is meaningful, not just
   that it passes.
5. **NEW for session 5:** If pursuing Category A (eipc-registry
   exposer) and the inspector walk turns up empty after 2-3
   approaches, STOP. Don't keep digging — the time-budget
   tradeoff is brutal. Document what was tried, ship the H06
   "documentation runner" if it surfaces useful state, move to
   Category B or C.

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
4. **Session budget hits ~3 new specs OR one major primitive
   landing.** Stop, synthesize, leave the rest for the next
   session.
5. **Category A inspector walk turns up empty after 2-3 distinct
   approaches.** Document the dead-end as a finding, ship H06,
   pivot to Category B or C if budget remains.

### What you should NOT do

- **Don't try to land Category A + B + C in one batch.** Pick ONE
  as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative ten "stop and report"
  outcomes from sessions 1/2/3/4 were the right call — every one
  revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
  `electron-mocks.ts` (session 3) and `input.ts` (session 4) were
  threshold-driven extractions, not speculative.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks-with-real-marker-side-
  effect). Only the *read-only reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Confirmed broken in session 3. Category A is
  the ONLY appropriate path to runtime IPC verification for those
  channels.
- **Don't bolt Wayland into `lib/input.ts`.** Sibling file or new
  primitive only; the X11-strict gate is load-bearing.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 5)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 60/76 (79%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | H06 | H06_eipc_registry_finding.spec.ts | … | ✓ pass |
| ... |

## Notable findings
- ...

## Open questions
- ...

## Files touched
git status output (only tools/test-harness/src/runners/*.spec.ts +
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
- For seedFromHost specs, the host MUST have a signed-in Claude
  Desktop. The primitive throws with a clear message if not.
  Document the prerequisite in your runner's leading comment if
  it's the first one to add seedFromHost coverage to a new
  surface.
- For tests that touch the AX tree, `claudeai.ts` page-objects
  are the right substrate — see `T17_folder_picker.spec.ts` for
  the end-to-end example. Don't query DOM by CSS selector unless
  `claudeai.ts` doesn't already cover the surface.
- For mock-then-call: helpers live in `lib/electron-mocks.ts`
  (extracted in session 3). See T24's leading comment for the
  `Promise<boolean>` variant + T25's for the void variant.
- For focus-shifting (X11 only): `lib/input.ts` exports
  `focusOtherWindow` + `spawnMarkerWindow`. See S11 for the
  end-to-end consumer pattern (single-shot diagnostic record,
  marker-window cleanup in `finally`, defensive
  `WaylandFocusUnavailable` / `XdotoolUnavailable` skip catches).
- **For asar fingerprints: ALWAYS grep the installed asar
  first.** Build-reference is beautified; the bundle is
  minified. Case-doc text may be the user-facing form, not the
  bundle form (e.g. `~/.claude.json` vs `.claude.json`).
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
