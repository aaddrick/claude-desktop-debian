# test-harness runner implementation — session 7 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 1
new spec (S14) and 1 new primitive (`lib/input-niri.ts`). Coverage
61/76 (80%) → 62/76 (82%). One commit on `docs/compat-matrix`:

- `XXX` — `test(harness): session 6 runner + niri-native focus-shifter
  primitive` (S14 Tier 2 known-failing detector for the Niri portal
  `BindShortcuts` path, mirrored from S11's shape with imports swapped
  to the new `lib/input-niri.ts` primitive; primitive uses
  `niri msg --json windows` / `niri msg action focus-window` /
  `niri msg --json focused-window` chain plus `foot --title` for the
  marker window).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 6** first, then
**session 5**, then **session 4**, then **session 3**, then **session
2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 6

1. **`lib/input-niri.ts` shipped against session 5's recon — untested
   on real Niri.** The primitive landed against the recon notes
   without a live Niri row run. The first real Niri sweep will confirm:
   - The `Ok`-wrapper unwrap covers the niri version on the row. The
     primitive defensively handles both `{Ok: {FocusedWindow: ...}}`
     (older niri) and the bare-payload shape (newer niri); a third
     shape would fall through to `null` rather than crash.
   - Claude's `app_id` value on niri is literal `'Claude'`. The
     primitive's `app_id !== 'Claude'` guard becomes a no-op rather
     than wrong if the actual value differs (match still happens by
     title); tighten if needed.
   - `foot` is on the target row's PATH. Skip path is clean if not
     (`FootUnavailable` typed error → `testInfo.skip()` with install
     hint).
   Verified on KDE-W: the runner skips correctly via the row gate.
2. **S14 is a known-failing detector by design.** Case-doc S14
   currently records `Failed to call BindShortcuts (error code 5)` on
   Niri. Same shape as S12's GNOME-W
   `--enable-features=GlobalShortcutsPortal` detector — the spec
   encodes the contract and will start passing on Niri rows once the
   upstream / Chromium-side portal issue resolves, without any spec
   edit.
3. **Cross-compositor dispatcher deliberately not built.** Sway /
   Hyprland / River each have completely different IPCs (`swaymsg`,
   `hyprctl`, `riverctl`). Per-compositor files until a second
   consumer surfaces — a hypothetical `lib/input-wayland.ts` would
   just switch on `XDG_CURRENT_DESKTOP` and delegate. With only S14
   consuming `lib/input-niri.ts`, a dispatcher would be ceremony.
   Same anti-speculation rule that kept `lib/electron-mocks.ts`
   (session 3) and `lib/input.ts` (session 4) threshold-driven.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 6**,
  **session 5**, **session 4**, **session 3**, **session 2**, then
  **session 1** "Status (post-execution)" sub-sections. The Tier-3
  list (search for "## Tier 3") is the candidate pool for further
  reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-62-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc
  note.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable session 6 addition:
  `input-niri.ts` (Niri-only, `niri msg --json` IPC + `foot` marker;
  sibling of X11-only `input.ts`). DO NOT bolt other Wayland
  compositors into `input-niri.ts` — per-compositor files only.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 6 templates:
  - `S14_quick_entry_from_other_focus_niri.spec.ts` — first runner
    consuming `lib/input-niri.js`. Pattern for any future
    Niri-specific runner that needs Wayland-native focus injection.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~3 new specs OR one new primitive landing.** The
session 6 work (1 spec + 1 primitive) was at the lower end of the
ceiling because the primitive build was substantial. The obvious
focus-shifter / mock-then-call substrate work is now done — the next
session's main bets are narrower in shape.

**Category B (eipc-registry exposer) is now the cleanest single-
session win available.** Sessions 3-6 each kept punting Category B
because (a) other lower-risk work was on the table (focus-shifter,
mock-then-call extraction, Tier 1 fingerprints) and (b) session 3's
inspector walk came up empty. With the obvious work landed, Category
B is the only path forward to proper Tier 2 runtime probes for
T22/T31/T33/T38 (currently shipped as Tier 1 fingerprints) AND
unblocks T35 Phase 2 / T37 Phase 2.

Three categories — pick ONE as the main bet, treat the others as
fallback if the main bet hits an early blocker:

| # | Tests | Source | Notes |
|---|---|---|---|
| **A** eipc-registry exposer | unblocks T22/T31/T33/T38 Tier 2 reframes + T35 Phase 2 / T37 Phase 2 | new `lib/eipc.ts` (or extension to `lib/electron.ts`) | High-risk-high-reward closure-local reverse-engineering. Session 3's inspector walk via `globalThis` came up empty; sessions 4/5/6 each skipped for budget. **Now the cleanest single-session win** — needs a fresh approach. |
| **B** T35 Phase 2 / T37 Phase 2 (paired with eipc-registry exposer) | T35 Phase 2, T37 Phase 2 | depends on Category A | Only viable if Category A lands first. Don't attempt without it. |
| **C** Single-spec deferred items audit | various deferred items | — | Lower ceiling, higher confidence per spec. Best fallback if Category A turns up empty. |

#### Category A — eipc-registry exposer

The closure-local IPC registry near `:68820` (`le(i)` origin
validation) and `:68816` (channel framing) is what T22/T31/T33/T38
should be probing at runtime — instead they all ship as Tier 1
asar fingerprints because session 3 confirmed the standard
`ipcMain._invokeHandlers` map only carries three chat-tab MCP-bridge
handlers, not the `LocalSessions_$_*` / `CustomPlugins_$_*` channels.
The custom `$eipc_message$_<UUID>_$_claude.web_$_<name>` protocol
uses a closure-local message-port registry that's not introspectable
from main without reverse-engineering the eipc bootstrap.

**Approaches that have NOT been tried (good starting points):**

1. **Module-level grep for symbol references** — search the bundled
   `index.js` near `:68816` and `:68820` for any
   `Object.defineProperty` / `globalThis[`...`]` / `module.exports`
   call that exposes the registry to a reachable surface.
2. **Hook the eipc message-port creation site** — instead of looking
   for a registry to inspect post-hoc, hook the registration site
   itself. If the channel-name string flows through a single
   function call, install a prototype-method hook at that site (see
   the hook pattern in
   [`docs/learnings/test-harness-electron-hooks.md`](../../learnings/test-harness-electron-hooks.md))
   and accumulate names into a side-channel map the test can read.
3. **Patch in a dev-only registry exposer** — pre-launch, modify
   `index.js` (via the harness's `lib/asar.ts` write path) to add
   `globalThis.__eipcChannels = ...` near the registration site.
   Idempotent + reversible; the patched asar is per-test isolation
   so it doesn't leak.

If Category A turns up empty after 2-3 distinct approaches, STOP
AND REPORT. Don't keep digging — document what was tried, ship a
"H06 documentation runner" that captures the dead-end as a finding
in JUnit, and pivot to Category C. The cleanest "tried, here's
what was unreachable" report converts the primitive-gap annotation
in the plan-doc from "TODO" to "tried, unfixable without an
upstream change."

If a stable handle is found, expose it via `lib/eipc.ts`
(`getEipcChannels`, `invokeEipcChannel`); upgrade T22 / T31 /
T33 / T38 from Tier 1 fingerprints to Tier 2 runtime probes. Cap
at ~3 spec upgrades — don't try to land all four if the first one
surfaces an unexpected issue.

#### Category B — T35 / T37 Phase 2 (paired with Category A)

Both currently ship as Tier 1 fingerprints because the parsed-state
readback target is a closure-local minified symbol — the same
gotcha as S28 from session 2 and S19's `cE()`/`Tce()`
re-implementation note. Without Category A landing first, the
fixture form of these specs would assert "the spec didn't crash"
and nothing more.

Skip this category unless Category A lands a stable handle.

#### Category C — single-spec deferred items audit

Walk through session 1-6 deferrals and identify any that are now
tractable. Specifically:

- **S20** — `powerSaveBlocker` Inhibit. Issue #569 still open;
  this is a separate workstream, not for this session.
- **T18** — drag-drop OS-level form. Tier 1 fingerprint shipped
  session 5; OS-level (Tier 2/3) requires a custom XDND source
  (X11) or libei emitter (Wayland) — both are heavy primitive
  builds that don't fit this session's ceiling.
- **T34** — OAuth round-trip. Hard to mock; not this session
  unless you have a clever idea.
- **T35 Phase 2 / T37 Phase 2** — see Category B above. Need
  Category A first.
- **T36 Phase 2** — NOT a candidate. Session 5's SessionStart-
  hook trace showed the hook fires only after first prompt
  submission, which is a real-account write. Reclassified
  Tier 2 → Tier 3/4. Don't try to ship it.
- **S14 cross-compositor variants (Sway / Hyprland / River)** —
  no current case-doc consumer demands them. Don't speculate.

If Category A turns up empty, Category C's most-reachable target
is **investigate Tier 3 reframes for issues opened against the
project since session 6.** Check `gh issue list --state open
--label test-coverage-gap` (if the label exists) or just walk
recent open issues for ones that suggest a Tier 1 fingerprint is
now possible (a regression that produces a stable string in the
bundle, etc.).

#### Cross-compositor focus-shifter expansion (NOT recommended this session)

Building `lib/input-sway.ts` / `lib/input-hypr.ts` would mirror
`lib/input-niri.ts`'s shape but no consumer is asking for them.
Sway / Hyprland / River specs aren't on the case-doc radar.
Premature abstractions are wrong abstractions. Wait for a real
consumer.

### Constraints to respect (don't violate)

These are unchanged from sessions 1/2/3/4/5/6 and still load-bearing:

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
  Single-shot JSON dumps for multi-state tests (S11, S14, S31
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
  bundle. The case-doc text is sometimes the user-facing form
  (e.g. `~/.claude.json`) not the bundle form (`.claude.json`).
  T18 happened to have no minified-vs-beautified gotcha; T35 did.
- **For mock-then-call: the helper goes in
  `lib/electron-mocks.ts`,** not `lib/claudeai.ts`. Documented in
  T24/T25's leading comments.
- **Marker windows / sacrificial host processes always die in
  `finally`.** S11 / S14 are the templates — `marker.kill()` runs
  before `app.close()` so the kill happens even if the spec throws.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 6 section,
   then read S14's leading comment + `lib/input-niri.ts`'s leading
   comment. Confirm you understand the niri-only gate reasoning.
3. Pick ONE Category as the main bet. For Category A, plan the
   approach: (a) module-level grep for registry exposers, (b) hook
   the eipc registration site, (c) patch in a dev-only exposer.
   List which approaches you'll try in what order, with the cap at
   2-3 distinct approaches before STOP AND REPORT.

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, the chosen Category's prerequisites don't hold), stop and
report. Don't fan out.

#### Phase 1 — fan-out batch

For Category A (eipc-registry exposer):
- Spawn ONE subagent per approach — module-level grep, hook-at-
  registration-site, dev-only patch-in. Treat as exploratory;
  report findings before committing to a primitive shape.
- Cap re-spawns at 2-3 distinct approaches; if all empty, STOP
  AND REPORT. Ship an `H06_eipc_registry_finding.spec.ts`
  documentation runner if useful state surfaces during the
  investigation.
- If a stable handle is found, second batch: build `lib/eipc.ts`
  + ship the H06 finding runner. Third batch: upgrade T22 / T31 /
  T33 / T38.
- Cap at ~3 specs total upgrade — don't try to land all four if
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
1-6 had cumulative ~13 "stop and report" outcomes that were the
right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral,
S14 primitive-gap then primitive-build, T35/T36 Phase 2 deferrals,
T18 Tier 1 reframe, T36 Phase 2 reclassification to Tier 3/4,
session-6 lib/input-niri.ts shipped untested-on-niri).

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
   - Updated coverage stat (was 62/76 = 82%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for
   the NEXT session's deferred items.

### Self-correction loop

Same as sessions 1-6:

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
5. **Carry-over from session 5/6:** If pursuing Category A and the
   inspector / hook / patch approaches turn up empty after 2-3
   approaches, STOP. Don't keep digging — document what was
   tried, ship the H06 documentation runner if it surfaces
   useful state, move to Category C.
6. **NEW for session 7:** If Category A's hook approach lands a
   handle but T22 / T31 / T33 / T38 upgrades reveal the channels
   route through different code paths than the bundle strings
   suggest (i.e. the runtime registry's contents don't match the
   case-doc Code anchors), re-examine the case-doc anchors before
   shipping the upgrade — the assertion shape might need
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
   attempts.** Document the dead-end as a finding, ship H06 if
   useful, pivot to Category C if budget remains.

### What you should NOT do

- **Don't try to land Category A + Category C in one batch.** Pick
  ONE as the main bet.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and
  don't write a placeholder. The cumulative thirteen "stop and
  report" outcomes from sessions 1-6 were the right call — every
  one revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
  `electron-mocks.ts` (session 3), `input.ts` (session 4), and
  `input-niri.ts` (session 6) were threshold-driven extractions,
  not speculative.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks-fire-on-prompt-submit).
  Only the *read-only reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Confirmed broken in session 3. Category A is
  the ONLY appropriate path to runtime IPC verification for those
  channels.
- **Don't bolt other compositors into `lib/input-niri.ts`.**
  Sway / Hyprland / River each get their own per-compositor file
  if a consumer surfaces. With S14 the only consumer, no
  expansion is justified yet.
- **Don't bolt Wayland into `lib/input.ts`.** X11-strict gate is
  load-bearing.
- **Don't speculate on a `lib/input-wayland.ts` dispatcher.**
  Per-compositor files until a second Wayland consumer lands.
- **Don't preemptively build `CodeTab.activateTopTab()` /
  `startNewSession()`.** Session 5 captured the AX anchors but
  T36 Phase 2 (the only known consumer) was reclassified out.
  Wait for a real consumer.
- **Don't implement the #569 power-inhibit patch in this
  session.** That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 7)

- Main-bet category: A | B | C
- Specs landed: N
- Primitives landed: N
- Reclassified mid-flight: N (with reasons)
- Coverage: was 62/76 (82%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | T22 | T22_pr_monitoring_handler.spec.ts | … | ✓ pass / skip / fail |
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
  end-to-end consumer pattern.
- For Wayland-native focus-shifting (Niri only): `lib/input-niri.ts`
  exports the same shape with `niri msg --json` IPC + `foot`
  marker. See S14 for the end-to-end consumer pattern. The
  primitive is untested-on-real-Niri as of session 6 — the
  first real Niri sweep run will confirm the schema assumptions
  documented in its leading comment.
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
