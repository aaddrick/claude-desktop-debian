# test-harness runner implementation — session 17 prompt

This file is meant to be **copied verbatim into a fresh Claude Code
session** as the initial user message. Don't paraphrase it; the
orchestration depends on the exact directives below.

> **ORCHESTRATION STOPPED AFTER SESSION 16.** This prompt is rotated
> for completeness only. **Session 17 will NOT run automatically** —
> the autonomous orchestration was halted at the end of session 16
> after coverage stalled at 74/76 (97%) for four consecutive sessions
> (13, 14, 15, 16). To resume, the user must manually trigger another
> orchestration run AND meet at least one of these preconditions:
>
> 1. **Real signed-in Claude Desktop running with `--inspect=9229`**
>    on the dev box (debugger-attached, signed in, NOT a leaked test
>    isolation). This unblocks Categories A (operon-mode probe) and
>    B (Tier 3 read-only reframes that need auth-bearing renderer
>    state).
> 2. **A real claude.ai account fixture for write-side state.** The
>    remaining 2 specs (matrix coverage 74/76 → 76/76) need real
>    write-side state (e.g. an installed plugin to exercise
>    `LocalPlugins.listSkillFiles`, or a deep-linked deferred install
>    intent for T11). The Tier 3 destructive constraint
>    (`Don't run destructive Tier 3 write-side tests`) explicitly
>    forbids the harness constructing this state itself.
> 3. **Renderer-drift event** that requires re-anchoring page-objects
>    (e.g. claude.ai redesign breaks `findCompactPills`,
>    `clickMenuItem`, etc.). Triggers a defensive-migration session.
> 4. **New IPC surface** added by upstream that the harness should
>    cover (e.g. a new `claude.web` interface, a new eipc method
>    that's case-doc-anchored).
>
> If none of those preconditions hold, the orchestration should NOT
> resume — further sessions will produce documentation-only or
> marginal output. The structural ceiling of the harness without
> real-account fixtures is 74/76 (97%); we're already there.

You're picking up after session 16 of the test-harness runner
implementation work. Session 16 was the final session of the
sessions-13-to-16 orchestration run and produced: T17 verification
(session-15 structural fix VERIFIED — bare 60s timeout gone, new
failure mode at `openFolderPicker` post-`selectLocal` classified as
renderer-state-dependent and deferred), schema-rev for
`listRemotePluginsPage` / `listSkillFiles` (both schemas resolved by
bundle inspection — neither shipped as a Tier 2 invocation because
`listRemotePluginsPage` is not anchored in any case doc, and
`listSkillFiles` needs Tier 3 destructive setup). NO coverage gain.
Plan-doc updated. Followup-prompt rotated with the STOP flag (this
document).

The plan doc at
[`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
captures the tier classification and execution-time reclassifications.
Its "Status (post-execution)" section is the source of truth for
what's done and what's deferred — read **session 16** first, then
**session 15**, **session 14**, **session 13**, **session 12**,
**session 11**, **session 10**, **session 9**, **session 8**,
**session 7**, **session 6**, **session 5**, **session 4**, **session
3**, **session 2**, then **session 1** sub-sections.

This session is a continuation, not a restart. Start by reading the
plan doc's status sections AND verifying at least one of the
preconditions above holds. If none hold, STOP and report; don't try
to fan out.

### Session 16 final findings (key context for any session-17 attempt)

1. **T17's session-15 structural fix VERIFIED.** Bare 60s timeout is
   gone. `seedFromHost` clones the host's signed-in config,
   `waitForReady('userLoaded')` resolves to a post-login URL
   (`https://claude.ai/epitaxy` on the dev box), the dialog mock
   installs, and `CodeTab.activate({ timeout: 15_000 })` (session 14
   migration) succeeds first try.
2. **T17's NEW failure mode is renderer-state-dependent, not AX.**
   After `selectLocal()` clicks the Local menuitem, the Select-folder
   pill never appears within 4s. The URL during the run was
   `/epitaxy` — the user's workspace route. The folder-picker UI
   may only render on `/new` (or a fresh project), not on a workspace
   already containing files. To unblock: navigate to `/new`
   post-userLoaded BEFORE `openFolderPicker()`. NOT shipped session
   16 — needs a careful navigation primitive that doesn't break
   existing seedFromHost specs.
3. **`openPill` / `clickMenuItem` migration STILL parked.** Session
   16's T17 trace confirmed the env-pill open + Local click both
   succeeded, ruling out the AX-polling-loop hypothesis once and for
   all. Don't migrate those speculatively.
4. **Schema-rev resolved both deferred validators.**
   `CustomPlugins.listRemotePluginsPage(limit: number, offset:
   number)`. `LocalPlugins.listSkillFiles(pluginId: string,
   skillName: string, pluginContext?: opaque)`. Neither shipped as a
   Tier 2 invocation: `listRemotePluginsPage` is not anchored in any
   case doc; `listSkillFiles` needs Tier 3 destructive setup.
5. **Coverage stalled at 74/76 (97%) for 4 consecutive sessions.**
   Sessions 13-16 net deliverables: 1 primitive, 1 AX migration, 1
   structural fix, 1 verification + 1 schema-rev investigation.
   Without real-account fixtures, the harness's structural ceiling
   is 74/76. The remaining 2 specs need real-account write-side
   state.

### What a future session 17 might attempt (only if preconditions hold)

If precondition 1 (real signed-in debugger-attached Claude) holds:

- **Operon-mode probe** (Category A from sessions 13-16). Run
  `eipc-registry-probe.ts` against the user's Claude with operon mode
  toggled on/off, capture the diff in registered channels. May
  surface a new case-doc-coverable handler.
- **Schema-rev smoke-test** for the session-16-resolved schemas
  against the live debugger. `listRemotePluginsPage(limit: 10,
  offset: 0)` should return an array shape; `listSkillFiles('some-
  installed-plugin', 'some-skill')` would test the LocalPlugins
  handler's auth path.

If precondition 2 (real-account write-side fixture) holds:

- **T11 runtime invocation.** With an installed plugin in
  `~/.claude/plugins/`, the post-install state can be probed via
  `listSkillFiles` and the slash-menu skills would assert the
  case-doc claim "skills appear in the slash menu" (T11 step 3).
- **T17 navigation fix.** Add a `/new` navigation primitive to
  `claudeai.ts`'s `CodeTab` so `openFolderPicker` works on a fresh
  project route. Verify T17 reaches the dialog mock fired assertion.

If precondition 3 or 4 holds:

- **Defensive page-object refactor.** Re-snapshot the AX tree at the
  Customize panel and Plugin browser modal, refresh case-doc
  inventory anchors, migrate any decayed selectors.

### Termination signal interpretation

If session 17 is triggered without any precondition met, the right
move is the same as session 16's STOP recommendation: write a one-
paragraph "preconditions not met, no work shipped" plan-doc update
and terminate. Don't burn a session on documentation-only output.

### Constraints to respect (unchanged from sessions 1-16)

- Use `seedFromHost: true` for any auth-required spec — never
  `CLAUDE_TEST_USE_HOST_CONFIG=1` / `isolation: null` (legacy shape
  removed in session 15).
- eipc handlers register on `webContents.ipc._invokeHandlers`, NOT
  global `ipcMain._invokeHandlers`. Use `lib/eipc.ts`.
- For arg validator schema-rev: smoke-test first, fall back to
  bundle-grep on the rejection literal.
- For AX-tree consumers: use `lib/ax.ts` (`snapshotAx` /
  `waitForAxNode` / `waitForAxNodes`).
- For call-site migrations to `waitForAxNode`: keep per-spec retry
  budgets matching existing tuning.
- `lib/input.ts` is X11-only. `lib/input-niri.ts` is Niri-only. CDP
  auth gate is alive (runtime SIGUSR1 attach, never Playwright
  `_electron.launch()`). BrowserWindow Proxy gotcha — use
  `webContents.getAllWebContents()`. `skipUnlessRow()` always first.
- No fixed sleeps. `retryUntil` from `lib/retry.ts`, Playwright
  auto-wait, or `waitForAxNode` from `lib/ax.ts`.
- Diagnostics on every run via `testInfo.attach()`. Tag with
  `severity:` and `surface:` annotations.
- Tabs in TS, ~80-char wrap.
- Don't break existing runners. H01-H05 are the canaries.
- `npm run typecheck` must stay clean.
- Don't run destructive Tier 3 write-side tests.

### Authoritative reference

Read these in order before fanning out:

- [`docs/testing/runner-implementation-plan.md`](runner-implementation-plan.md)
  — tier classification + status sections.
- [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
  — runner conventions, the 74-spec inventory, primitives in
  `lib/`, isolation defaults.
- [`docs/testing/cases/README.md`](cases/README.md) — case-doc
  structure and the four anchor scopes.
- [`tools/test-harness/src/lib/`](../../tools/test-harness/src/lib/)
  — the existing primitives.
- [`tools/test-harness/src/runners/`](../../tools/test-harness/src/runners/)
  — every existing spec is a template.

### Phase 0 — calibration (mandatory before fanning out)

1. `cd tools/test-harness && npm run typecheck` — should pass.
2. Check debugger ATTACHMENT QUALITY (not just port). `ss -tln |
   grep ':9229'`. If port open, probe webContents via `evalInMain`:

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

   If every URL is `/login` / `find_in_page` / `main_window`, treat
   as soft-blocked for auth-required investigations.
3. Disambiguate running Claude processes. `pgrep -af
   "ozone-platform=x11.*app.asar"`; for each, inspect cmdline for
   `user-data-dir`. Real Claude has
   `~/.config/Claude` (or no user-data-dir flag); leaked test
   isolations have `/tmp/claude-test-*`.
4. **Verify at least one precondition for resuming the orchestration
   holds.** If none hold, write a "no preconditions met" plan-doc
   update and STOP. Don't fan out.

### Operational notes

- For the bundle-grep schema-rev pattern (sessions 9, 11, 12, 16
  precedents):

  ```bash
  cd tools/test-harness && node -e "
    const {extractFile} = require('@electron/asar');
    const buf = extractFile(
      '/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar',
      '.vite/build/index.js'
    );
    const s = buf.toString('utf8');
    const idx = s.indexOf('<rejection-literal>');
    console.log(s.slice(Math.max(0, idx - 1500), idx + 500));
  "
  ```

- For seedFromHost specs: host MUST have a signed-in Claude.
  `seedFromHost`'s host-claude-kill semantics will tear down any
  running Claude process — flag clearly in the report before
  invoking when the user's real Claude is running.

- For AX-tree polling: `lib/ax.ts`'s `waitForAxNode` /
  `waitForAxNodes` for predicate-based polling.

- The eipc-registry probe (`tools/test-harness/eipc-registry-probe.ts`)
  is the dedicated tool for inspecting per-wc IPC handler state.

Begin with Phase 0. Don't fan out until at least one of the
preconditions for resuming the orchestration is verified to hold.
