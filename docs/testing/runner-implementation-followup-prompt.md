# test-harness runner implementation — session 3 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

You're picking up after a runner-implementation session that landed 10
new specs (5 Tier 2 + 4 Tier 2-reframes + 1 Tier 1 reclass), lifting
harness coverage from 40/76 (53%) to 50/76 (66%). Three commits on
`docs/compat-matrix`:

- `XXX` — `test(harness): session 2 runners + lib/claudeai mock helper`
  (10 new spec files; `installShowItemInFolderMock` added to
  `lib/claudeai.ts` mirroring the `installOpenDialogMock` pattern;
  README inventory + plan-doc status section updated).

(Substitute the actual SHA after committing — the user reviews and
commits at the end of every session.)

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for what's
done and what's deferred — read **session 2** then **session 1**
sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections.

### Big new findings from session 2

1. **Mock-then-call beats invoke-then-cleanup for Tier 2 reframes of
   side-effecting Electron APIs.** T17's existing
   `installOpenDialogMock` pattern was extended to T25 via a new
   `installShowItemInFolderMock` in `lib/claudeai.ts`. Net: no host
   file-manager pop-up during the run, AND the assertion strengthens
   from "didn't throw" to "the egress was reached + the path arg
   flowed through verbatim". Apply this pattern to any future
   `shell.*` / `dialog.*` Tier 2 reframes (T24 `shell.openExternal`
   would mock cleanly the same way).

2. **`gdbus monitor --dest <name>` only sees signals OWNED BY that
   destination, not method calls TO it.** T23 had to switch from the
   plan's gdbus suggestion to `dbus-monitor` (eavesdrop match rule)
   to observe `org.freedesktop.Notifications.Notify` calls from
   Electron. If T27 / T22 / S24 ever ship Tier 2 reframes that need
   to observe method calls on a service, use `dbus-monitor`.

3. **`ipcMain._invokeHandlers` channel naming carries a build-stable
   UUID prefix:** `$eipc_message$_<UUID>_$_claude.web_$_<name>`. T38
   anchors on the `_$_<name>` suffix to survive UUID rotation; the
   prefix is captured as diagnostic. Useful precedent for any future
   IPC-introspection probes.

4. **Closure-local minified helpers are NOT reachable from
   globalThis.** S28's plan called for inspector-eval against
   `Sbn()`, but `Sbn` is a closure-local — couldn't be invoked. S28
   reclassified to Tier 1 (asar fingerprint of the classifier
   expression). For any future "Tier 2 reframe via inspector-eval
   against minified helper X" entry: confirm reachability before
   classifying.

5. **`safeStorage` on Linux uses random IVs.** Only decrypted
   plaintext is comparable across encrypt calls; ciphertext bytes
   are not deterministic. S25 compares plaintexts.

6. **`extraEnv` precedence.** `lib/electron.ts:317-323` spreads in
   order: `process.env`, `LAUNCHER_INJECTED_ENV`, `isolation?.env`,
   `waylandEnv`, then `opts.extraEnv`, then `CI: '1'`. Override
   wins. S19 leans on this; load-bearing for future tests that
   need to override isolation defaults.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status section. Read both **session 2**
  and **session 1** "Status (post-execution)" sub-sections. The
  Tier-3 list (line ~342) is the candidate pool for further
  reframes.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the now-50-spec inventory, primitives in
  `lib/`, isolation defaults, the CDP-gate workaround, the
  `seedFromHost` reference.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives. Notable additions since session 2:
  - `claudeai.ts` — `installShowItemInFolderMock` /
    `getShowItemInFolderCalls` (mirrors `installOpenDialogMock`).
    If 3+ tests start using mock-then-call, consider extracting to
    `lib/electron-mocks.ts` — but don't pre-extract.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template. Notable session 2 templates:
  - `T16_code_tab_loads.spec.ts` / `T26_routines_page_renders.spec.ts`
    — seedFromHost + post-login renderer-side AX nav. T16 uses the
    existing `CodeTab.activate()`; T26 inlines a similar AX walker
    for the sidebar. Pattern for any further "click an AX-tree
    button after login" test.
  - `T25_show_item_in_folder_no_throw.spec.ts` — mock-then-call
    pattern (mirrors T17). Use this shape for any future Tier 2
    reframe of a side-effecting Electron API.
  - `T38_open_in_editor_handler_registered.spec.ts` — IPC handler
    registry introspection via `ipcMain._invokeHandlers`. Pattern
    for any "is this handler wired up" check.
  - `T23_notification_reaches_dbus.spec.ts` — dbus-monitor
    subprocess + inspector-fired notification + buffer scan.
  - `T10_cowork_daemon_respawn.spec.ts` — H04 extension: spawn,
    SIGKILL, poll for new pid. Pattern for any "service auto-respawn
    contract" test.
  - `S25_safestorage_token_persists.spec.ts` — two-launch with
    shared isolation handle + safeStorage round-trip via tmpfile.
  - `S28_worktree_permission_classifier.spec.ts` — single-regex
    asar fingerprint for a multi-string-OR classifier expression.
- [`docs/testing/cases/*.md`](cases/) — the spec each runner
  asserts. The **Code anchors:** field tells you exactly where
  upstream implements the feature.

### Tests in scope this session

Five categories, in priority order:

| # | Tests | Source files | Notes |
|---|---|---|---|
| **A** Deferred from session 2 | T31, T32, S06, S11, S14 | `code-tab-workflow.md` (T31, T32), `shortcuts-and-input.md` (S06, S11, S14) | T31/T32 need a Code-tab session OPEN; S06 needs Wayland row; S11/S14 need a new focus-shifter primitive |
| **B** Tier 3 → Tier 2 reframes (read-only) | T22, T35, T37 | `code-tab-workflow.md` (T22), `extensibility.md` (T35, T37) | Each can ship as a *reads-from-disk-or-IPC-registry* probe without writing to the user's account |
| **C** Asar fingerprint cleanups | T24, T30, T33 | `code-tab-handoff.md` (T24), `code-tab-workflow.md` (T30), `extensibility.md` (T33) | Each has a load-bearing string set in `index.js` that pins the wiring without needing a launch |
| **D** New primitive — focus-shifter | (unblocks A's S11/S14) | `lib/input.ts` | xdotool / ydotool focus-stealing helper. Build only if S11/S14 worth shipping this session |
| **E** Mock-then-call extension | T24 (mock form) | `code-tab-handoff.md` (T24) | Mirror of T25's pattern but for `shell.openExternal` — handler reaches the egress with the right URL |

Realistic ceiling: **~6-8 new specs** this session. Don't try all
13 — Categories A and B are heavier than session 2's mix because
they need either a Code-tab session opened OR a new primitive built
first.

### Detailed scope per category

#### Category A — deferred items (5)

- **T31 — Side chat opens.** Needs: `seedFromHost` + Code-tab
  session OPEN (env pill → Local → choose folder → wait for session
  load). After session loads, send `Ctrl+;` via ydotool OR find the
  IPC handler `startSideChat` in `ipcMain._invokeHandlers` (T38
  pattern) and assert it's registered + invokable. The lighter form
  is the IPC-registry probe; the heavier form is full
  click-chain-into-side-chat.
- **T32 — Slash command menu.** Needs: same Code-tab session OPEN
  preamble as T31. Then trigger `/` in the prompt textarea and
  assert the slash menu renders (AX-tree query for menuitem* nodes
  in the prompt area). Heavier than T31 because the slash menu is
  rendered server-side by claude.ai's bundle.
- **S06 — URL handler segfault on native Wayland.** Needs:
  `CLAUDE_HARNESS_USE_WAYLAND=1` row + `coredumpctl info
  claude-desktop` observation after firing
  `xdg-open 'claude://chat/new'`. Skip cleanly if not on a
  Wayland row.
- **S11 / S14 — focus-shifter delivery.** Needs: `lib/input.ts`
  with `focusOtherWindow()` (xdotool on X11; skip on Wayland or
  use compositor-specific). Then S11 / S14 launch app, focus
  another window, fire shortcut, assert popup appears. Build the
  primitive in one PR (Category D), then both runners in a second
  PR.

#### Category B — Tier 3 → Tier 2 reframes (3)

These each have a slice that doesn't write to the user's real
account:

- **T22 — PR monitoring (read-only half).** The Tier 3 form opens a
  PR; the Tier 2 reframe is "after `seedFromHost`, IPC handler
  `getPrChecks` is registered + the `gh CLI not found in PATH`
  string is in the bundle". The handler-registered probe is the
  shippable form; the missing-`gh` warning string is a static
  fingerprint. Both ship as one runner.
- **T35 — MCP server config picked up.** Reframe: place a fixture
  `claude_desktop_config.json` under the isolation's configDir
  (no host config touch needed — fresh isolation), then via
  inspector eval, read whatever main-process state holds the
  parsed MCP server list. Anchor on a known path under
  `${configDir}/Claude/`.
- **T37 — `CLAUDE.md` memory loads.** Reframe: place a fixture
  `~/.claude/CLAUDE.md` (or under `CLAUDE_CONFIG_DIR/CLAUDE.md`
  with extraEnv override — see S19's pattern), then via inspector
  eval read the loaded memory state. Anchor needs to come from
  case-doc Code anchors.

#### Category C — asar fingerprint cleanups (3)

Each is Tier 1 / no launch:

- **T24 — Open in external editor (asar fingerprint).** The full
  click-chain T24 is Tier 3. The fingerprint half: assert `Mtt`
  registry is in `index.js` with the editor scheme strings
  (`vscode://`, `cursor://`, `zed://`, `windsurf://`).
- **T30 — Auto-archive on PR merge (cadence constants).** Static
  fingerprint of the sweep cadence — assert `300_000` (5 min)
  and `3_600_000` (1 h) appear near the auto-archive code.
- **T33 — Plugin browser (IPC handler registered).** Same shape
  as T38 — assert `listMarketplaces` IPC handler is registered.

#### Category D — primitive build

- **`lib/input.ts:focusOtherWindow()`.** xdotool on X11
  (`xdotool search --name '<test-marker>' windowfocus`); on
  Wayland skip cleanly (no portable focus injection). Used by
  S11 / S14. Don't build unless those are in scope this session.

#### Category E — mock-then-call extension

- **T24 (mock form, alternative to Category C).** Mock
  `shell.openExternal` via a new `installOpenExternalMock` in
  `lib/claudeai.ts` (mirror of `installShowItemInFolderMock`),
  then `inspector.evalInMain` calls
  `shell.openExternal('vscode://file/tmp/test')` and assert
  the recorded call list contains the URL. Strictly stronger
  than the Category C fingerprint form. **Pick C OR E for T24
  — not both.**

### Why this iteration

The harness is at 50/76 coverage and every release tag now
exercises the smoke-set + a chunk of critical surfaces
automatically. Remaining work clusters in three pockets:

- **Code-tab cluster (T15-T39, mostly login-walled).** Session 2
  unblocked the *render-only* half via `seedFromHost`; session 3
  should push into the *open-a-session* half (T31, T32) and the
  read-only-Tier-3-reframes (T22, T35, T37).
- **Wayland-specific tests (S06).** Need a Wayland row + the
  harness's `CLAUDE_HARNESS_USE_WAYLAND=1` switch.
- **Focus-shift-dependent tests (S11, S14).** Need
  `lib/input.ts:focusOtherWindow()` built first.

After this session, future sessions can focus on the genuinely
heavy Tier 3 work (destructive-write login tests; multi-launch
state) with a clearer cost model.

### Known mechanism-recipe table (session 1 + session 2)

| Pattern | Use when | Worked example |
|---|---|---|
| `createIsolation({ seedFromHost: true })` | spec needs a signed-in renderer; read-only | T07, T16, T26 |
| `isolation: null` + pre-launch `killHostClaude()` | spec needs SingletonLock collision (delivery probes) | T05 |
| Default isolation | most other tests | T01, T03, T04, S29 |
| `isolation: <handle>` (shared across launches) | multi-launch persistent state | S35, S25 |
| `MainWindow.setState('close')` | exercise the wrapper close-interceptor | T08 |
| Mock-then-call for `shell.*` / `dialog.*` | Tier 2 reframe of side-effecting API | T17, T25 |
| `ipcMain._invokeHandlers` registry probe | "is this IPC handler wired up" | T38 |
| `dbus-monitor` subprocess | observe DBus method calls TO a destination | T23 |
| Asar single-regex multi-string-OR fingerprint | classifier-style code that combines several strings | S28 |

### Constraints to respect (don't violate)

These are unchanged from sessions 1 and 2 and still load-bearing:

- **Default isolation** unless the spec needs otherwise. Never
  write to `~/.config/Claude` without explicit gating
  (`CLAUDE_TEST_USE_HOST_CONFIG=1` opt-out, OR `seedFromHost: true`
  with read-only-then-discard semantics, OR an explicit comment
  documenting why).
- **CDP auth gate is alive** — runtime SIGUSR1 attach via
  `app.attachInspector()`, never Playwright's `_electron.launch()`
  or `chromium.connectOverCDP()`.
- **BrowserWindow Proxy gotcha** — use `webContents.getAllWebContents()`
  not `BrowserWindow.getAllWindows()`. Constructor-level wraps
  don't work; use prototype-method hooks.
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
- **For mock-then-call: leading comment must document why mock
  beats invoke** (T25's leading comment is the worked example —
  three short paragraphs).

### Phases

#### Phase 0 — calibration

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Read the plan doc's "Status (post-execution)" session 2 section,
   then read T25's leading comment (the mock-then-call pattern's
   worked-example doc) and T16/T26 (the seedFromHost-then-AX-nav
   pattern). Confirm you understand both.
3. Pick one Category B candidate (suggest T22 — read-only half) and
   sketch the runner shape mentally. Don't write it yet — confirm
   you can plan from the spec.

If Phase 0 surfaces a problem (typecheck failing, primitives
unclear, patterns not understood), stop and report. Don't fan out.

#### Phase 1 — fan-out batch

Spawn parallel subagents (cap at 6 in flight) for the highest-
confidence candidates first.

**Suggested initial batch (4-5 specs):**

- **B / T22 — PR monitoring read-only half.** seedFromHost +
  `ipcMain._invokeHandlers` for `getPrChecks` + asar fingerprint
  for the missing-`gh` warning string.
- **C / T24 (asar fingerprint OR mock form, pick one).** If you
  want stronger coverage, go mock form (Category E shape — mirror
  of T25's `installOpenExternalMock` helper). If you want a quick
  Tier 1, go asar fingerprint (`Mtt` registry + scheme strings).
- **C / T30 — Auto-archive cadence constants.** Pure asar probe.
- **C / T33 — Plugin browser handler registered.** T38 pattern.
- **B / T35 — MCP server config picked up.** Fixture under
  isolation configDir + inspector eval.

If those land cleanly, dispatch a second batch:

- **A / T31 — Side chat opens (handler-registered shape).**
  seedFromHost + `ipcMain._invokeHandlers` for `startSideChat`
  / `sendSideChatMessage` / `stopSideChat`. The lighter probe.
- **A / T32 — Slash command menu (asar fingerprint).** The full
  AX-tree form needs a Code-tab session open AND server-side
  rendered menu — heavy. The fingerprint form: `getSupportedCommands`
  + `slashCommands` schema present in `index.js`.
- **A / S11 / S14 (only if Category D primitive is built first).**
  Build `lib/input.ts:focusOtherWindow()` in PR 1; ship S11/S14
  in PR 2.
- **B / T37 — CLAUDE.md memory loads.** Fixture file + inspector
  eval against the loaded memory state.

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
ipcMain._invokeHandlers / asar fingerprint / shared isolation),
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

If the test isn't reasonable to implement (anchors don't resolve
to anything assertable, the test depends on state you can't
construct, the existing primitives don't cover the surface), DO
NOT write a stub. Report under Open questions and stop. Sessions
1 and 2 had cumulative ~6 "stop and report" outcomes that were
the right call (S20 deferral, T05 reshape, T07 needs seedFromHost,
T08 needs setState('close'), S28 reclassification, T38 framing).

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
   Claude; T31/T32 require an open Code-tab session that may
   accumulate state). Capture pass/skip/fail per spec for the
   matrix.
3. Update [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
   "Status (post-execution)" section to reflect newly-shipped
   specs and any reclassifications discovered mid-flight.
4. Update [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
   inventory table.
5. Write a final report listing:
   - Specs landed (pass / skip / needs-tuning per row)
   - Specs deferred (with the per-test rationale)
   - Specs reclassified (Tier 3 → Tier 2, Tier 2 → blocked, etc.)
   - Updated coverage stat (was 50/76 = 66%, now N/76 = M%)
6. Don't commit. The user reviews and commits.
7. Rotate this prompt: rewrite
   `docs/testing/runner-implementation-followup-prompt.md` for the
   NEXT session's deferred items.

### Self-correction loop

Same as sessions 1 and 2:

1. Subagent typecheck failure → re-spawn with explicit fix
   instruction.
2. Subagent claims a runner exists but `git status` shows no new
   file → re-spawn with explicit "use the Write tool" instruction.
3. Two subagents wrote runners that share a primitive but with
   different shapes → factor into `lib/<topic>.ts` BEFORE shipping.

Cap re-spawns at 2 per file. Past that, mark as needing human
review and move on.

### Termination conditions

Stop and write the final report when one of:

1. **All Category A + B + C target specs landed and typecheck-clean.**
   Write coverage update, stop.
2. **Hit re-spawn cap on 3+ runners.** Stop, write up which are
   blocked.
3. **Discovered a primitive gap that breaks 5+ Tier 2/Tier 3
   tests.** Stop, propose where the new primitive should live in
   `lib/`. Future session adds the primitive first, then resumes.
4. **Session budget hits ~7 new specs.** Stop, synthesize, leave
   the rest for the next session.

### What you should NOT do

- **Don't try to land Category A + B + C in one batch.** That's
  ~9-11 specs. Pick the highest-confidence subset for the first
  batch and decide whether to do more based on what came back.
- **Don't ship stubs.** If a runner can't actually assert what the
  spec says, mark it as Tier 3 / blocked / primitive-gap and don't
  write a placeholder. The cumulative six "stop and report"
  outcomes from sessions 1+2 were the right call — every one
  revealed a real constraint.
- **Don't break existing runners.** H01-H05 are the canaries.
- **Don't pre-extract `lib/electron-mocks.ts`.** The
  `installShowItemInFolderMock` + `installOpenDialogMock` pair
  doesn't yet justify a new file; if T24 ships as Category E
  (mock form), THAT's the third — extract then.
- **Don't restructure `lib/`** beyond targeted additions.
  Premature abstractions are wrong abstractions.
- **Don't run destructive Tier 3 tests** that write to the user's
  real claude.ai account (T22 PR write, T27 scheduling, T29
  worktree creation, T34 OAuth, T36 hooks). Only the *read-only
  reframes* of those are in scope this session.
- **Don't implement the #569 power-inhibit patch in this session.**
  That's a separate workstream. The S20 spec follows the patch,
  not the other way around.
- **Don't commit.** The user reviews and commits.

### Final report format

```markdown
## Runner implementation summary (session 3)

- Category A landed: N / 5
- Category B landed: N / 3
- Category C landed: N / 3
- Reclassified mid-flight: N (with reasons)
- Coverage: was 50/76 (66%), now <NEW>/76 (<PCT>%)
- Typecheck: clean | <errors>
- KDE-W test run: <pass/skip/fail counts>

## Per-spec breakdown

| Cat | Test ID | File | Assertion shape | Status |
|---|---|---|---|---|
| B | T22 | T22_pr_monitoring_handler.spec.ts | seedFromHost + IPC handler probe + asar fingerprint | ✓ pass |
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
- For mock-then-call: see T25 for the canonical pattern. Mock
  installation is in `lib/claudeai.ts` alongside the dialog-mock;
  add a sibling export, don't pre-extract a new file.

Begin with Phase 0. Don't fan out until calibration succeeds.
