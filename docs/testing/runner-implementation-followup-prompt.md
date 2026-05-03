# test-harness runner implementation — session 6 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new spec (T18) and a load-bearing reclassification finding (T36
Phase 2 is no longer a Tier 2 candidate). Coverage 60/76 (79%) →
61/76 (80%). One commit on `docs/compat-matrix`:

- `XXX` — `test(harness): session 5 runner + SessionStart-fires-on-
  prompt finding` (T18 Tier 1 fingerprint pinning the drag-drop
  preload bridge in `mainView.js`; plan-doc updated with the
  SessionStart-hook trace + Code-tab AX anchor capture + S14 niri
  msg recon verdict).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 5** first, then
**session 4**, then **session 3**, then **session 2**, then **session
1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 5

1. **SessionStart hook fires after first prompt submission, not on
   New-session click.** Trace through bundled `index.js`:
   `Ys.startSession` (`:454743` general, `:489371` CCD/Code-tab)
   requires `A.message`; the session record stores it as
   `initialMessage` (:489270); the agent SDK process is spawned via
   `DN({ prompt: k, options: v })` (`:489514`) only when there's a
   prompt stream to bind to. `createOrResumeSession` (`:489208`)
   creates the session record but doesn't spawn the agent. The
   SessionStart hook fires inside the agent SDK process once it
   boots — therefore only after a real prompt submission, which is
   a real-account write. **T36 Phase 2 reclassified Tier 2 →
   Tier 3/4**; unmockable without deep agent-SDK reverse-engineering.
2. **Code-tab session-opener AX surface verified — anchors saved in
   plan-doc.** A one-shot AX-tree probe against the user's
   debugger-enabled running Claude (deleted after capture) confirmed:
   - **Top-tab Code button**: `button[name="Code"]` under
     `group[Mode]` under `complementary`. Disambiguator from the
     prompt-mode `tab[name="Code"]` in
     `tablist[name="Prompt categories"]` (which is what T16's
     existing `CodeTab.activate()` clicks).
   - **Sidebar entries**: `button[name="New session ⌘N"]`,
     `button[name="Routines"]`, `button[name="Customize"]`,
     `button[name="More navigation items"]`,
     `button[name="Pinned"]` / `button[name="Recents"]`.
   - **Recents items**: `button[name="<status> <title>"]` where
     status ∈ {Idle, Ready, Needs input, Awaiting input}. Main-pane
     Welcome surface uses `button[name="Open session <title>"]`.
   - **URL of Code-tab landing**: `/epitaxy`.
   No primitive shipped — these anchors live in the plan-doc until a
   consumer needs them. Premature abstraction is wrong abstraction.
3. **niri msg IPC contract: `--json` shape is stable.** Wiki
   explicitly contracts the JSON output; plain text is unstable.
   `niri msg --json windows` returns `Vec<Window>` with `{id, title,
   app_id, pid, workspace_id, is_focused, ...}`; `niri msg action
   focus-window --id <u64>` injects focus; `niri msg --json
   focused-window` is the honest readback. `foot --title <T> -e
   sleep 600` is the Wayland-native marker (takes `--title` cleanly,
   ships in most niri setups). Niri 25.08+ has opt-in
   `xwayland-satellite` integration — existing X11 primitive *might*
   work on niri rows where it's running, but can't assume.
4. **T18 Tier 1 fingerprint shipped against `mainView.js`, not
   `index.js`.** First runner to read a non-`index.js` source from
   the asar. `lib/asar.ts` already supports this via the existing
   `readAsarFile(filename, asarPath)` shape — no helper extraction
   needed. The case-doc anchor strings (`getPathForFile`, `webUtils`,
   `filePickers`, `claudeAppSettings`) are property names that
   survive minification verbatim — no minified-vs-beautified gotcha
   (unlike T35's `~/.claude.json` → `.claude.json`).
5. **Tier 2/3 OS-level drag-drop is a primitive gap on BOTH
   backends.** X11 xdotool can simulate mouse motion but cannot put
   file URIs on the XDND selection (Chromium's drop handler would
   never see a file payload). Wayland needs per-compositor IPC +
   libei input injection. A real test needs either a custom XDND
   source app (X11) or a libei emitter (Wayland). The xdotool form
   the session-5 prompt suggested for T18 was a stub by this lens —
   pivot to Tier 1 was the right call.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 5**,
  **session 4**, **session 3**, **session 2**, then **session 1**
  "Status (post-execution)" sub-sections. The Tier-3 list (around
  line 690 — search for "## Tier 3") is the candidate pool for
  further reframes; T18 has now landed (was Tier 3, shipped Tier 1)
  and T36 Phase 2 reclassified to Tier 3/4.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-61-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. No new primitives in session 5.
  Notable: `input.ts` remains strict X11-only by design; do NOT bolt
  Wayland into it. If session 6 builds the niri-native sibling, put
  it in `lib/input-niri.ts` (per-compositor file, NOT a Wayland
  catch-all — sway/hyprland/river have totally different IPCs).
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 5 templates:
  - `T18_drag_drop_files_into_prompt.spec.ts` — first runner to
    read a non-`index.js` source (`mainView.js`). Pattern for any
    future fingerprint that anchors on the preload bundle (e.g.
    bridge wiring, contextBridge exposes).
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~3 new specs OR one new primitive landing.**
Session 5 ran light (1 spec + 1 doc finding) because the runtime
probe + bundled-source trace consumed half the budget. Session 6's
clearest single-session win is **Category A — `lib/input-niri.ts`
+ S14 runner** because:

- The recon already sketched the primitive API (mirrors
  `lib/input.ts`'s shape, swaps xdotool/xprop for `niri msg`).
- The niri IPC contract is stable in `--json` mode per the wiki.
- S14 is the single consumer waiting on it.
- The `lib/input.ts` extraction in session 4 is a direct template.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** `lib/input-niri.ts` + S14 runner | S14 | new `lib/input-niri.ts` + S14 runner | Recon-sketched; niri IPC contract is stable in `--json` mode. Cleanest single-session win. |
| **B** eipc-registry exposer | unblocks T22/T31/T33/T38 Tier 2 reframes | `lib/electron.ts` or new `lib/eipc.ts` | High-risk-high-reward closure-local reverse-engineering. Same warning as sessions 4 / 5: session 3's inspector walk came up empty; needs a fresh approach. |
| **C** Single-spec deferred items audit | various (T35 Phase 2 / T37 Phase 2 still blocked on closure-local readback; T36 Phase 2 NO LONGER A CANDIDATE) | — | Lower ceiling, higher confidence per spec. |

#### Category A — `lib/input-niri.ts` + S14 runner

The session 5 recon's TRACTABLE verdict gives the API sketch
verbatim:

- `spawnMarkerWindow(title)` → `child_process.spawn('foot',
  ['--title', title, '-e', 'sleep', '600'], {detached:true})`;
  teardown via PID + SIGTERM. Mirrors the X11 primitive's xterm
  pattern.
- `focusOtherWindow(title)` → `niri msg --json windows`,
  `JSON.parse`, find row where `title === wantedTitle && app_id !==
  'Claude'`, then `niri msg action focus-window --id <id>`, then
  re-read `niri msg --json focused-window` and assert `id` matches.
  This gives the honest readback that S11's primitive needs.
- `getFocusedWindowId()` → `niri msg --json focused-window` →
  `.Ok.FocusedWindow?.id ?? null`.
- `isNiriSession()` → check `XDG_CURRENT_DESKTOP === 'niri'` OR
  `niri msg version` exits 0 (the latter is more honest because
  XDG_CURRENT_DESKTOP can be overridden — but adds a process-spawn
  cost on every call; cache the result).

S14 runner shape: near-clone of `S11_quick_entry_from_other_focus.spec.ts`
with the import swapped from `lib/input.js` to `lib/input-niri.js`
and the row gate flipped from `['GNOME-X', 'Ubu-X']` to `['Niri']`.
The X11-side "what this catches vs what it doesn't" leading
comment from S11 has a Niri-side equivalent: this catches a
regression in the Wayland path of the global shortcut on Niri (the
load-bearing concern the case-doc carries forward from the S11
mutter regression discussion).

**Cross-compositor consideration (do NOT bolt in this session):**
Sway / Hyprland / River each have totally different IPCs.
Per-compositor files (`lib/input-sway.ts`, `lib/input-hypr.ts`,
…) are cleaner than a unified abstraction. A `lib/input-wayland.ts`
dispatcher would just be a switch on `XDG_CURRENT_DESKTOP` that
delegates. Don't speculate on it this session — let the second
consumer drive the dispatcher.

**STOP AND REPORT** if: (a) `niri msg` output shape doesn't match
the recon (the wiki contract is `--json` only, but the output
schema may shift between niri versions even within the contract);
(b) `foot` isn't on the target row's PATH (the primitive should
fall back to `alacritty` / `kitty` / fail with a clear typed
error matching `lib/input.ts`'s `XdotoolUnavailable` shape).

#### Category B — eipc-registry exposer

Same framing as session 4/5: closure-local reverse-engineering of
the eipc bootstrap near `:68820` (`le(i)` origin validation) and
`:68816` (channel framing). Session 3's inspector walk found
nothing reachable via `globalThis`; the walk was repeated approach
in sessions 4/5 implicitly (and skipped for budget reasons).

If you take this as the main bet, treat as exploratory — Phase 1
is the inspector walk only. STOP AND REPORT if 2-3 distinct
approaches turn up empty. The cleanest "tried, here's what was
unreachable" report converts the primitive-gap annotation in the
plan-doc from "TODO" to "tried, unfixable without an upstream
change." Don't ship a stub.

If a stable handle is found, expose it via `lib/eipc.ts`
(`getEipcChannels`, `invokeEipcChannel`); upgrade T22 / T31 /
T33 / T38 from Tier 1 fingerprints to Tier 2 runtime probes.

#### Category C — single-spec deferred items audit

Walk through session 1/2/3/4/5 deferrals and identify any that are
now tractable. Specifically:

- **S20** — `powerSaveBlocker` Inhibit. Issue #569 still open;
  not this session.
- **T18** — drag-drop OS-level form. Tier 1 fingerprint shipped
  session 5; OS-level (Tier 2/3) requires a custom XDND source
  (X11) or libei emitter (Wayland) — both are heavy primitive
  builds that don't fit this session's ceiling.
- **T34** — OAuth round-trip. Hard to mock; not this session
  unless you have a clever idea.
- **T35 Phase 2 / T37 Phase 2** — fixture-readback. Same
  closure-local target as T37b. Need either Category B
  (eipc-registry exposer) to land first, or a different readback
  path. Skip unless paired with Category B.
- **T36 Phase 2** — NO LONGER A CANDIDATE. Session 5's
  SessionStart-hook trace showed the hook fires only after first
  prompt submission, which is a real-account write. Reclassified
  Tier 2 → Tier 3/4. Don't try to ship it.
- **S14 Wayland variant** — see Category A. Session 5 recon says
  TRACTABLE.

#### Code-tab session-opener primitive (NOT recommended this session)

Session 5 verified the AX surface (anchors in plan-doc), but the
single biggest consumer (T36 Phase 2) was just reclassified out of
Tier 2. Without a load-bearing consumer, building
`CodeTab.activateTopTab()` / `startNewSession()` would be a
speculative primitive. Wait until a real consumer surfaces.

### Constraints to respect (don't violate)

These are unchanged from sessions 1/2/3/4/5 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26 are the templates.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  channels.** Session 3 confirmed those use a custom eipc protocol
  not in the standard registry. T22/T31/T33/T38 are Tier 1
  fingerprints. If you build the eipc-registry exposer (Category
  B), update the plan-doc and this prompt accordingly.
- **`lib/input.ts` is X11-only.** Strict `XDG_SESSION_TYPE ===
  'x11'` gate. Wayland consumers must skip — don't try to bolt
  Wayland into the file. Session 6's Category A puts the niri
  variant in `lib/input-niri.ts` (sibling), NOT `lib/input.ts`.
- **Don't speculate on `lib/input-wayland.ts` dispatcher.**
  Per-compositor files until a second consumer (Sway / Hyprland /
  River row) lands. Premature abstractions are wrong abstractions.
- **Code-tab AX anchors stay in plan-doc until a consumer needs
  them.** Don't preemptively add `CodeTab.activateTopTab()` to
  `claudeai.ts` — T36 Phase 2 was the only consumer and it's now
  Tier 3/4. Session 5's anchors block out the work for whenever
  a future consumer surfaces.
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
  T18 happened to have no minified-vs-beautified gotcha; T35 did.
- **For mock-then-call: the helper goes in
  `lib/electron-mocks.ts`,** not `lib/claudeai.ts`. Documented in
  T24/T25's leading comments.
- **Marker windows / sacrificial host processes always die in
  `finally`.** S11 is the template — `marker.kill()` runs before
  `app.close()` so the kill happens even if the spec throws. The
  niri sibling's `foot` marker should follow the same pattern.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 5 section,
   then read S11's leading comment + `lib/input.ts`'s leading
   comment (the X11-only-row-gate reasoning still applies; the
   niri sibling will mirror its shape but with niri-specific
   honest-readback discussion). Confirm you understand both.
3. Pick ONE Category as the main bet. Don't write it yet — confirm
   you can plan from the spec. For Category A, verify niri's IPC
   doc is still consistent with the session 5 recon (the wiki
   page may have changed; re-fetch). For Category B, confirm the
   closure-local landscape hasn't shifted (re-run the session 3
   inspector walk's premise).

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, the chosen Category's prerequisites don't hold), stop and
report. Don't fan out.

#### Phase 1 — fan-out batch

For Category A (`lib/input-niri.ts` + S14):
- Spawn ONE subagent for `lib/input-niri.ts` against the
  recon-sketched API (mirror `lib/input.ts` style — leading
  comment with the `--json`-stability rationale and the
  honest-readback reasoning, sibling typed errors
  `NiriIpcUnavailable` / `FootUnavailable`, exports matching
  `focusOtherWindow` / `spawnMarkerWindow` / `getFocusedWindowId`
  / `isNiriSession` / `MarkerWindow` interface).
- Spawn ONE subagent in parallel for the S14 runner (near-clone
  of S11 with imports swapped + row gate `['Niri']`).
- After both return: typecheck, ensure the two files agree on the
  primitive's exported shape.

For Category B (eipc-registry exposer):
- Spawn ONE subagent doing the inspector walk — looking for
  module-level Maps / dispatch functions / `globalThis` writes
  near `:68816`-`:68820`. Treat as exploratory; report findings
  before committing to a primitive shape.
- Cap re-spawns at 2-3 distinct approaches; if all empty, STOP
  AND REPORT.
- If a stable handle is found, second batch: build `lib/eipc.ts`
  + ship `H06_eipc_registry_finding.spec.ts`. Third batch:
  upgrade T22 / T31 / T33 / T38.
- Cap at ~3 specs total upgrade — don't try to land all four if
  the first one surfaces an unexpected issue.

For Category C (single-spec audit):
- Pick 1-2 deferred items per the table above. Standard fan-out
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
1-5 had cumulative ~12 "stop and report" outcomes that were the
right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral,
S14 primitive-gap, T35/T36 Phase 2 deferrals, T18 Tier 1 reframe,
T36 Phase 2 reclassification to Tier 3/4).

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
   Claude). For Category A, S14 will skip on KDE-W (row gate is
   Niri-only); the typecheck pass is the verification on KDE-W,
   and a real Niri-row run is for the next sweep. Capture
   pass/skip/fail per spec for the matrix.
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
   - Updated coverage stat (was 61/76 = 80%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-5:

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
5. **Carry-over from session 5:** If pursuing Category B and the
   inspector walk turns up empty after 2-3 approaches, STOP.
   Don't keep digging — document what was tried, ship the H06
   "documentation runner" if it surfaces useful state, move to
   Category A or C.
6. **NEW for session 6:** If pursuing Category A and the niri
   IPC `--json` output has shifted from the session 5 recon
   (e.g. the Window struct shape changed; an action got renamed),
   STOP and re-fetch the wiki / probe a live niri instance if
   available. Don't ship against a stale schema.

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
5. **Category B inspector walk turns up empty after 2-3 distinct
   approaches.** Document the dead-end as a finding, ship H06
   if useful, pivot to Category A or C if budget remains.

### What you should NOT do

- **Don't try to land Category A + B + C in one batch.** Pick ONE
  as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative twelve "stop and
  report" outcomes from sessions 1-5 were the right call — every
  one revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
  `electron-mocks.ts` (session 3) and `input.ts` (session 4) were
  threshold-driven extractions, not speculative. `input-niri.ts`
  for Category A is the same shape — a single-consumer extraction
  with the API mirroring its X11 sibling.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks-fire-on-prompt-submit).
  Only the *read-only reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Confirmed broken in session 3. Category B is
  the ONLY appropriate path to runtime IPC verification for those
  channels.
- **Don't bolt Wayland into `lib/input.ts`.** Sibling file or new
  primitive only; the X11-strict gate is load-bearing. Session 6
  Category A puts niri in `lib/input-niri.ts`.
- **Don't speculate on a `lib/input-wayland.ts` dispatcher.**
  Per-compositor files until a second consumer lands.
- **Don't preemptively build `CodeTab.activateTopTab()` /
  `startNewSession()`.** Session 5 captured the AX anchors but
  T36 Phase 2 (the only known consumer) was reclassified out.
  Wait for a real consumer.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 6)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 61/76 (80%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | S14 | S14_quick_entry_from_other_focus_niri.spec.ts | … | ✓ pass / skip (Niri-only) |
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
  end-to-end consumer pattern (single-shot diagnostic record,
  marker-window cleanup in `finally`, defensive
  `WaylandFocusUnavailable` / `XdotoolUnavailable` skip catches).
- **For Wayland-native focus-shifting (Niri only, if Category A
  ships):** the recon's API sketch is in plan-doc session 5.
  Mirror `lib/input.ts`'s shape. Use `niri msg --json` (the
  contracted-stable surface; plain text is unstable per the
  wiki). `foot --title <T> -e sleep 600` is the marker process.
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
