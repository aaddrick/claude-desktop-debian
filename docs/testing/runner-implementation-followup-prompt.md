# test-harness runner implementation — session 4 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 7
new specs (T22, T24, T30, T31, T32, T33, T37) and reclassified one
session-2 carryover (T38), lifting harness coverage from 50/76 (66%)
to 57/76 (75%). Three commits on `docs/compat-matrix`:

- `XXX` — `test(harness): session 3 runners + eipc-registry finding`
  (7 new spec files; `lib/electron-mocks.ts` extracted from
  `lib/claudeai.ts` once T24 brought the third mock-then-call helper
  online — `installOpenDialogMock` / `installShowItemInFolderMock` /
  `installOpenExternalMock` plus their `getCalls` readers; T17, T24,
  T25 imports updated; T22/T31/T33/T38 reclassified to Tier 1
  fingerprints after the eipc-registry finding; README inventory +
  plan-doc status updated).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for what's
done and what's deferred — read **session 3** first, then **session 2**,
then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 3

1. **`ipcMain._invokeHandlers` does NOT see `claude.web` eipc
   channels.** This is load-bearing — corrects a session-2 assumption.
   The `LocalSessions_$_*` / `CustomPlugins_$_*` channels named in
   case-doc Code anchors use a **custom message-port protocol**
   (`$eipc_message$_<UUID>_$_claude.web_$_<name>` framing at
   `index.js:68816`) that's distinct from Electron stdlib IPC. KDE-W
   run revealed the standard registry holds only three chat-tab
   MCP-bridge handlers regardless of ready level
   (`mainVisible`/`claudeAi`/`userLoaded`) and regardless of whether
   the launch is hermetic or `seedFromHost: true` authenticated. The
   eipc registry itself is a closure-local — same gotcha as session
   2's `Sbn()` (S28) and `cE()`/`Tce()` (S19). Reverse-engineering the
   eipc bootstrap to expose the registry is a primitive gap that
   would unblock proper Tier 2 runtime probes for **T22, T31, T33,
   T38** and any future LocalSessions_/CustomPlugins_ tests.
   Reference: T22's leading comment, plan-doc session 3 status.

2. **For tests that depend on authenticated renderer state, ALWAYS
   use `createIsolation({ seedFromHost: true })`.** Session 3's first
   four launch-based specs (T22/T24/T31/T33 — all originally drafted
   as IPC handler probes) defaulted to hermetic isolation,
   i.e. unauthenticated. Even if the eipc registry HAD been at
   `ipcMain._invokeHandlers`, the LocalSessions/CustomPlugins
   handlers register only after the renderer's authenticated init
   path runs — default isolation never gets past `/login`. T16 and
   T26 are the canonical seedFromHost templates; copy that shape any
   time the assertion depends on claude.ai's renderer modules being
   loaded.

3. **`shell.openExternal` mock-then-call works identically to
   `shell.showItemInFolder` mock — but the mock returns
   `Promise<boolean>` not void.** T24 ships the mock pattern in
   `lib/electron-mocks.ts`. If a future spec needs to mock another
   `shell.*` method, mirror this shape: idempotency flag on
   `globalThis`, recorder pushes to a `__claudeAi*Calls` array, mock
   matches the documented return type. The mocks live in
   `lib/electron-mocks.ts` (extracted in session 3 — was in
   `lib/claudeai.ts` until the third helper landed).

4. **Asar fingerprint regex with multi-string proximity gates works
   well for cadence-style code.** T30 anchors three strings
   (`300*1e3`, `3600*1e3`, `AutoArchiveEngine`) in colocation with
   tuned distance windows (≤200 chars, ≤3000 chars), then runs an
   `.includes()` for a fourth string (`ccAutoArchiveOnPrClose`)
   inside the captured window. Single match globally. Pattern for
   any future "these constants are colocated with this class" test.

5. **Build-reference is in BEAUTIFIED form; installed asar is
   MINIFIED. Numeric literals differ.** T30 case-doc named the
   constants as `300_000` / `3_600_000` (with underscores —
   beautified preserves them). The actual installed asar has
   `300*1e3` / `3600*1e3`. Always grep the installed asar before
   settling on a fingerprint string. The
   `/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar`
   path on KDE-W is the source of truth for fingerprints.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read **session 3**,
  **session 2**, then **session 1** "Status (post-execution)" sub-
  sections. The Tier-3 list (line ~342) is the candidate pool for
  further reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-57-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the eipc note.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable additions since session 3:
  - `electron-mocks.ts` — extracted from `claudeai.ts` once T24
    brought the third mock-then-call helper online. Three pairs
    today (`installOpenDialogMock`, `installShowItemInFolderMock`,
    `installOpenExternalMock` + their readers). If a future spec
    needs another `shell.*` / `dialog.*` / similar mock, add it
    here as a fourth sibling.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 3 templates:
  - `T22_pr_monitoring_handler.spec.ts` — multi-fingerprint Tier 1
    (eipc channel-name string + Linux-fallthrough throw site).
    Pattern for any "the IPC channel name is in the bundle" probe
    when the registry isn't introspectable.
  - `T24_open_in_editor_no_throw.spec.ts` — mock-then-call with a
    `Promise<boolean>` egress. Pattern for any future `shell.*`
    egress that returns a Promise (not void).
  - `T30_auto_archive_cadence_constants.spec.ts` — single-regex
    multi-string-proximity asar fingerprint with a tuned distance
    window. Pattern for any "these constants are colocated with
    this class" test.
  - `T31_side_chat_handlers_registered.spec.ts` —
    `T33_plugin_browser_handler_registered.spec.ts` — eipc channel-
    name fingerprints. Pattern for any "is this IPC channel name
    in the bundle" probe.
  - `T37_claude_md_memory_fingerprint.spec.ts` — multi-anchor Tier
    1 with a single-occurrence high-signal log line as the primary
    anchor + broader namespace tokens for context.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

**Realistic ceiling: ~5 new specs this session.** Session 3 hit ~7
because Tier 1 fingerprints are cheap. Session 4's candidates are
heavier — most need either a new primitive (focus-shifter, eipc-
registry exposer) or fixture-then-readback against state that may
not be reachable.

Three categories:

| # | Tests | Source files | Notes |
|---|---|---|---|
| **A** Focus-shifter primitive + S11/S14 | (lib/input.ts) + S11, S14 | `shortcuts-and-input.md` (S11, S14) | One PR builds the primitive (`focusOtherWindow()`), a second PR ships both runners |
| **B** T35 — MCP server config picked up | T35 | `extensibility.md` (T35) | Place fixture `~/.claude.json` + `<project>/.mcp.json` under isolation; assert on parsed-state readback. Risky — the parsed-state target may be a closure-local (same blocker as T37b/S19/S28) |
| **C** Deferred items audit | various | — | Re-walk session 1/2/3 deferrals; pick anything that's now tractable given the eipc finding + electron-mocks split |

#### Category A — focus-shifter primitive (3 specs)

- **`lib/input.ts:focusOtherWindow()`.** Build the primitive first.
  - **X11 path:** `xdotool search --name '<test-marker>' windowfocus`
    or similar. xdotool is available on most rows.
  - **Wayland path:** No portable focus injection. Skip cleanly per
    row gate. KDE-W might allow `kwin_x11`-class hacks but those are
    not portable.
  - Verify by spawning a marker window (e.g. a `xterm -title
    '<marker>'` background process), focusing it, then asserting
    `xprop -root _NET_ACTIVE_WINDOW` returns its WID.
- **S11** — Quick Entry shortcut fires from any focus.
  Launch app → focus marker window → fire `Ctrl+Alt+Space` via
  ydotool → assert popup appears (existing primitives).
  Row gate: GNOME-W, Ubu-W (mutter XWayland key-grab story is the
  load-bearing context). Currently broken on GNOME-W per #404; this
  runner is a regression detector.
- **S14** — Global shortcuts via XDG portal work on Niri.
  Same shape as S11. Row gate: Niri. Currently fails per case-doc.
  Reframe possible: assert `--enable-features=GlobalShortcutsPortal`
  is in argv (this is what S12 already does). The DELIVERY-side
  test needs the focus-shifter primitive.

#### Category B — T35 MCP server config (1 spec)

T35 case-doc anchors at `:215418` (Code-tab loads
`<project>/.mcp.json`), `:176766` (`~/.claude.json` reader), `:489098`
(Code-session passes `settingSources: ["user","project","local"]` to
agent SDK), `:130821` (`claude_desktop_config.json` is chat-tab path
constant — separate userData dir per `:130829` `kee()`).

**Phase 1 (cheap, ship today): asar separation fingerprint.** Assert:

1. `claude_desktop_config.json` string is in `index.js`. (Chat-tab
   MCP path constant — load-bearing for the per-tab separation.)
2. `kee()` resolution path: assert the userData-dir resolver is
   present.
3. The strings `~/.claude.json` and `.mcp.json` are in `index.js`.
   (Code-tab MCP loaders.)

This Tier 1 form pins the wiring without needing a launch. It does
NOT verify "the MCP server actually starts when a Code session
opens" — that's the full Tier 3 form, needs login + a Code-tab
session OPEN + an MCP server fixture.

**Phase 2 (risky, do only if Phase 1 lands and budget allows):
fixture-then-readback Tier 2.** Place a fixture
`<isolationDir>/Claude/claude_desktop_config.json` containing a
synthetic `mcpServers` entry. Launch with `seedFromHost: true` (so
the renderer is authenticated) + extraEnv override pointing the
chat-tab loader at the isolationDir. Try inspector-eval to read the
parsed MCP server list. **STOP AND REPORT** if the parsed-state
target is a closure-local (same blocker as T37b/S19/S28). Don't
ship a stub.

#### Category C — deferred items audit

Walk through session 1/2/3 deferrals and identify any that are now
tractable given session 3's findings. Specifically:

- **S20** — `powerSaveBlocker` Inhibit. Issue #569 still open; not
  this session.
- **T18** — drag-drop. X11 path is Tier 3 with xdotool drag. Wayland
  blocked until libei. Not this session.
- **T34** — OAuth round-trip. Hard to mock; not this session.
- **eipc-registry exposer (primitive gap)**. If you're feeling
  ambitious, reverse-engineer the eipc bootstrap and find a way to
  expose the channel→handler registry from main. Would unblock
  proper Tier 2 runtime probes for T22/T31/T33/T38. **High-risk,
  high-reward.** Likely involves walking the bundled `index.js`
  near `:68820` (`le(i)` origin validation) and `:68816` (channel
  framing) and identifying a stable handle. If the registry is
  truly closure-local with no exposed surface, abort and document.

### Constraints to respect (don't violate)

These are unchanged from sessions 1/2/3 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Use
  `seedFromHost: true` for any test that depends on authenticated
  renderer state — never assume default isolation gets past
  `/login`. T16/T26 are the templates.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  channels.** Session 3 confirmed those use a custom eipc protocol
  not in the standard registry. T22/T31/T33/T38 are now Tier 1
  fingerprints. If you build the eipc-registry exposer (Category
  C), update the plan-doc and this prompt accordingly.
- **CDP auth gate is alive** — runtime SIGUSR1 attach via
  `app.attachInspector()`, never Playwright's `_electron.launch()`
  or `chromium.connectOverCDP()`.
- **BrowserWindow Proxy gotcha** — use
  `webContents.getAllWebContents()` not `BrowserWindow.getAllWindows()`.
  Constructor-level wraps don't work; use prototype-method hooks.
- **`skipUnlessRow()` always first.** First line of every `test()`
  body when the test is row-gated.
- **No fixed sleeps.** `retryUntil` from `lib/retry.ts`, or
  Playwright auto-wait. Fixed `sleep(N)` is a smell.
- **Diagnostics on every run.** `testInfo.attach()` the artefacts
  (launcher log, --doctor output, frame extents, click attempts,
  AX-tree snapshot). Captured as JSON dumps for multi-state tests.
- **Tag with annotations.** `severity:` and `surface:` on every
  test so JUnit carries them through to matrix-regen.
- **Tabs in TS, ~80-char wrap as the existing files do.** Match
  surrounding style.
- **Don't break existing runners.** `npm run typecheck` must stay
  clean. H01-H05 are the canaries; `npm test` must still pass them
  after every commit.
- **Always grep the installed asar** to verify a fingerprint string
  is present (and how often) BEFORE shipping. Build-reference is
  beautified — strings differ from the minified bundle. Use
  `node -e "const {extractFile}=require('@electron/asar'); ..."`
  from inside `tools/test-harness` (where `@electron/asar` is on
  the require path).
- **For mock-then-call: the helper goes in `lib/electron-mocks.ts`,
  not `lib/claudeai.ts`.** Session 3 extracted them. The pattern is
  documented in T24/T25's leading comments.

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 3 section,
   then read T22's leading comment (the eipc-registry finding's
   worked-example doc) and T24's leading comment (the
   `Promise<boolean>` mock-then-call variant). Confirm you
   understand both.
3. Pick one Category candidate and sketch the runner shape mentally.
   Don't write it yet — confirm you can plan from the spec. Verify
   any fingerprint strings exist in the installed asar before
   committing to them.

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, patterns not understood), stop and report. Don't fan out.

#### Phase 1 — fan-out batch

Spawn parallel subagents (cap at 6 in flight) for the highest-
confidence candidates first.

**Suggested initial batch (~3-4 specs):**

- **A / `lib/input.ts:focusOtherWindow()` primitive.** Build the
  X11 path with xdotool, skip cleanly on Wayland. Verify with a
  marker-window round-trip.
- **B / T35 Phase 1 — MCP separation fingerprints.** Pure asar
  probe; load-bearing strings only.
- (Hold A/S11 + A/S14 for batch 2 — they depend on the primitive
  landing.)

If those land cleanly, dispatch batch 2:

- **A / S11** — Quick Entry shortcut from any focus.
- **A / S14** — Global shortcuts via XDG portal on Niri.
- **B / T35 Phase 2** — fixture-then-readback (only if Phase 1
  lands AND a reachable readback target is found; STOP AND REPORT
  otherwise).

#### Per-subagent prompt shape

```
You're implementing ONE test-harness runner for <TEST-ID> in
docs/testing/cases/<FILE>.md.

Read in order:
- docs/testing/cases/<FILE>.md (focus on <TEST-ID>'s Code anchors)
- tools/test-harness/README.md (conventions; status section names
  the most-recent-template that fits)
- tools/test-harness/src/runners/<closest-template>.spec.ts
- tools/test-harness/src/lib/ (the primitives you'll reuse)
- CLAUDE.md (project conventions)

Write tools/test-harness/src/runners/<TEST-ID>_short_name.spec.ts.

[per-test specifics: pattern (seedFromHost / mock-then-call /
asar fingerprint / shared isolation), assertion shape, skip rules,
key constraint warnings]

Constraints:
- Tabs, ~80-char wrap.
- Use lib/* primitives; don't reinvent.
- testInfo.attach() the diagnostics from the spec's "Diagnostics
  on failure" block.
- Tag with severity + surface annotations.
- No fixed sleeps. retryUntil or Playwright auto-wait.
- npm run typecheck must stay clean after your edits.
- Don't commit. The user reviews and commits.

If the test isn't reasonable to implement (anchors don't resolve
to anything assertable, the test depends on state you can't
construct, the existing primitives don't cover the surface), DO
NOT write a stub. Report under Open questions and stop. Sessions
1, 2, and 3 had cumulative ~8 "stop and report" outcomes that were
the right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing,
session-3 eipc-registry finding, T37 fixture-readback deferral).

Report shape (~150 words):
## <TEST-ID> runner

- File written: tools/test-harness/src/runners/<filename>.spec.ts
- Layer: file probe | argv probe | L1 | L2 (xprop) | L2 (DBus) | pgrep
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
   authenticated state actually uses `seedFromHost: true` — session
   3 shipped specs with default isolation that needed
   authentication, masking the eipc-registry finding for several
   iterations. Capture pass/skip/fail per spec for the matrix.
3. Update [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
   "Status (post-execution)" section to reflect newly-shipped
   specs and any reclassifications discovered mid-flight.
4. Update [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
   inventory table.
5. Write a final report listing:
   - Specs landed (pass / skip / needs-tuning per row)
   - Specs deferred (with the per-test rationale)
   - Specs reclassified (Tier 3 → Tier 2, Tier 2 → Tier 1, etc.)
   - Updated coverage stat (was 57/76 = 75%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for the
   NEXT session's deferred items.

### Self-correction loop

Same as sessions 1, 2, and 3:

1. Subagent typecheck failure → re-spawn with explicit fix
   instruction.
2. Subagent claims a runner exists but `git status` shows no new
   file → re-spawn with explicit "use the Write tool" instruction.
3. Two subagents wrote runners that share a primitive but with
   different shapes → factor into `lib/<topic>.ts` BEFORE shipping.
4. **NEW for session 4:** Spec passes locally but the assertion is
   actually trivial (e.g. an unauthenticated launch where the
   handler check vacuously passes because no handlers are
   registered) → re-examine the assertion shape. Session 3's eipc-
   registry finding came from running the specs and finding only
   3 handlers in the registry; the lesson is to verify the
   assertion is meaningful, not just that it passes.

Cap re-spawns at 2 per file. Past that, mark as needing human
review and move on.

### Termination conditions

Stop and write the final report when one of:

1. **All Category A + B target specs landed and typecheck-clean.**
   Write coverage update, stop.
2. **Hit re-spawn cap on 3+ runners.** Stop, write up which are
   blocked.
3. **Discovered a primitive gap that breaks 5+ Tier 2/Tier 3
   tests.** Stop, propose where the new primitive should live in
   `lib/`. Future session adds the primitive first, then resumes.
4. **Session budget hits ~5 new specs.** Stop, synthesize, leave
   the rest for the next session.

### What you should NOT do

- **Don't try to land Category A + B + C in one batch.** Pick the
  highest-confidence subset for the first batch.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and don't
  write a placeholder. The cumulative eight "stop and report"
  outcomes from sessions 1/2/3 were the right call — every one
  revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions. `electron-mocks.ts`
  was extracted in session 3 once the third helper landed —
  threshold-driven, not speculative.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks). Only the *read-only
  reframes* of those are in scope.
- **Don't introspect `ipcMain._invokeHandlers` for `claude.web`
  eipc channels.** Confirmed broken in session 3. If you need
  runtime IPC verification for those channels, the eipc-registry
  exposer is the primitive gap to land first.
- **Don't implement the #569 power-inhibit patch in this session.**
  That's a separate workstream.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 4)

- Category A landed: N / 3 (focus-shifter primitive + S11 + S14)
- Category B landed: N / 1-2 (T35 Phase 1 + maybe Phase 2)
- Reclassified mid-flight: N (with reasons)
- Coverage: was 57/76 (75%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| A | S11 | S11_quick_entry_from_other_focus.spec.ts | … | ✓ pass |
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
- The grounding probe (`tools/test-harness/grounding-probe.ts`) can
  help when implementing a runner that asserts runtime API state —
  capture once with `npm run grounding-probe -- --launch
  --include-synthetic`, grep the output for the IPC channel /
  accelerator / API your runner needs to assert against.
- For seedFromHost specs, the host MUST have a signed-in Claude
  Desktop. The primitive throws with a clear message if not.
  Document the prerequisite in your runner's leading comment if
  it's the first one to add seedFromHost coverage to a new surface.
- For tests that touch the AX tree, `claudeai.ts` page-objects are
  the right substrate — see `T17_folder_picker.spec.ts` for the
  end-to-end example. Don't query DOM by CSS selector unless
  `claudeai.ts` doesn't already cover the surface.
- For mock-then-call: helpers live in `lib/electron-mocks.ts` (not
  `claudeai.ts` anymore — extracted in session 3). See T24's
  leading comment for the `Promise<boolean>` variant + T25's for
  the void variant.
- **For asar fingerprints: ALWAYS grep the installed asar first.**
  Build-reference is beautified; the bundle is minified.
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
