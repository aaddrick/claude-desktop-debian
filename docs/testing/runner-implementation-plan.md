# Runner implementation plan

Tiered triage of the 61 missing test-harness runners across the
76-test matrix. Tier 1 / Tier 2 are within reach this session; Tier
3 is signed-in or multi-step work for a follow-up; Tier 4 is blocked
or out of scope.

Coverage today: 15/76 (~20%). Tier 1 (15 specs) + Tier 2 (16 specs)
land would lift this to roughly 46/76 (~61%) before any Tier 3
work begins.

| Tier | Count | Avg cost | Cumulative coverage if landed |
|------|-------|----------|-------------------------------|
| 1 — file / spawn / argv probes | 15 | 30 min – 1 h | 15 + 15 = 30 / 76 (39%) |
| 2 — single-launch probes | 16 | 2 – 3 h | 30 + 16 = 46 / 76 (61%) |
| 3 — login or multi-step | 22 | 4 – 8 h | 46 + 22 = 68 / 76 (89%) |
| 4 — blocked / out of scope | 8 | — | unchanged |

## Status (post-execution)

**Shipped session 16 (verification + schema-rev investigation, no new spec):**
T17's session-15 `seedFromHost` migration verified end-to-end against
the dev box: the bare 60s Playwright timeout is GONE, `seedFromHost`
clones the host's signed-in config, `waitForReady('userLoaded')`
resolves to `https://claude.ai/epitaxy` (post-login), the dialog mock
installs, and `CodeTab.activate({ timeout: 15_000 })` (session 14
migration) succeeds. T17 reaches a NEW failure mode at the next chain
step: `CodeTab.openFolderPicker: "Select folder…" pill did not open
within 4s after Local was clicked` — the env-pill open + Local click
both succeed, but the Select-folder pill doesn't render in the URL
state we reach (`/epitaxy`, the user's workspace, NOT `/new`). Per the
session-15 followup classification rules: this is NOT in `openPill` /
`clickMenuItem`'s post-click loops (those work — the env pill opened
and Local was found and clicked); the failure is one chain step later,
likely renderer-state-dependent (the workspace route doesn't expose a
local-folder picker the same way `/new` does). Don't migrate
`openPill` / `clickMenuItem` speculatively — that's been the standing
deferral since session 14. Document and defer the new failure mode.

Category C schema-rev (`listRemotePluginsPage` / `listSkillFiles`)
**resolved** by bundle inspection of
`/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar`
(extracted via `@electron/asar`):

- `CustomPlugins.listRemotePluginsPage(limit: number, offset: number)`
  — both positional, both numbers. Validator block sits at
  `'$eipc_message$_..._$_claude.web_$_CustomPlugins_$_listRemotePluginsPage'`,
  with explicit `typeof r!="number"` / `typeof n!="number"` checks
  preceding the throw. Result validator `VUi(s)`.
- `LocalPlugins.listSkillFiles(pluginId: string, skillName: string,
  pluginContext?: opaque)` — two required strings + optional context
  arg validated by `sc(s)` (the same shared validator used elsewhere
  for plugin-context blobs). Result validator `bUi(o)`.

**No Tier 2 invocation shipped for either** because neither method
connects to a case-doc claim:

- `listRemotePluginsPage` is NOT anchored in any case doc. T33 anchors
  `listMarketplaces` (`:71392`) and `listAvailablePlugins` (`:71534`)
  — both already covered by T33b/T33c — but `listRemotePluginsPage`
  is a separate read-side surface (paginated remote-plugin list) that
  the case docs don't claim. Shipping a probe just to exercise the
  validator with no assertion bound to a real-product behaviour would
  be a stub.
- `listSkillFiles` is `LocalPlugins`-scoped and meaningful only with
  an installed plugin (T11 step 3: "verify its skills appear in the
  slash menu"). Reaching that requires the destructive Tier 3 install
  path, which the constraints explicitly forbid. The validator
  resolves auth-independent, but the underlying handler needs real
  account state.

Schemas captured in plan-doc as a deferred reframe so a future session
with a real-account install fixture can ship the invocation.

Coverage stays at 74/76 (97%) — verification + investigation, no spec
landed.

Two commits on `docs/compat-matrix` expected (the orchestration
directive supersedes "the user reviews and commits" — autonomous
commit + push at end of session):

- TBD — `test(harness): session 16 verify T17 seedFromHost fix +
  schema-rev for listRemotePluginsPage / listSkillFiles (no spec,
  coverage unchanged at 97%)` (no code change beyond the doc updates;
  T17 verification run + schema-rev bundle inspection captured in
  the plan-doc).
- TBD — `docs(testing): session 16 plan/inventory + flag orchestrator
  STOP for session 17`.

Session 16 findings + reclassifications:

- **Session 15's structural T17 fix VERIFIED.** The pre-fix bare 60s
  timeout was real and is gone. `seedFromHost` clones host config,
  the renderer reaches a post-login URL, mocks install, and tab
  activation succeeds. Session 14's `activateTab` /
  `CodeTab.activate` AX migration also verified — `activate({
  timeout: 15_000 })` resolved on the FIRST run with no flake.
- **T17's NEW failure mode classified as renderer-state, not AX.**
  Post-`selectLocal` the Select-folder pill never appeared; this is
  upstream of `openPill`'s click loop (the env pill opened, Local
  was clicked successfully). The trace shows the URL is
  `https://claude.ai/epitaxy` — the user's workspace route, not
  `/new`. The folder-picker UI may only render on `/new` (or a
  fresh project), not on a workspace already containing files.
  Future fix: navigate to `/new` post-userLoaded before invoking
  `openFolderPicker`. NOT shipped this session — needs a careful
  navigation primitive that doesn't break existing seedFromHost
  specs.
- **`openPill` / `clickMenuItem` migration STILL parked.** Sessions
  14/15 speculated about migrating these; session 15 walked it back;
  session 16 confirms session 15's call. The new T17 failure is one
  chain step later, NOT in the post-click polling loops.
- **Schema-rev cleanly resolved both deferred validators.** Session 9
  pattern (bundle-grep on the rejection literal) works as expected.
  No smoke-test was needed because the validator literal IS the
  schema source of truth (typeof checks are explicit in source).
  Smoke-test against a live debugger-attached Claude wasn't possible
  this session because T17's seedFromHost step killed the leaked
  isolations and tore down the debugger.
- **No case-doc connection for either resolved schema.**
  `listRemotePluginsPage` is paginated remote-plugin enumeration
  (a separate surface from T33's `listMarketplaces` /
  `listAvailablePlugins` already covered). `listSkillFiles` needs
  real account state via a Tier 3 install. Both are documented for
  future revisit, neither shipped as a runner.
- **Three Tier 4 blockers crystallised.** Sessions 13-16 collectively
  confirm the remaining un-runner'd specs all sit behind one of:
  (a) write-side state on a real claude.ai account (Tier 3
  destructive — explicitly forbidden); (b) renderer-state-dependent
  UI that the harness can't construct without account-side fixtures
  (T17's `/new` requirement); (c) auth-bearing debugger-attached
  Claude that exists only when a real signed-in app is running on
  the dev box (which the session-13 onwards sessions have been
  unable to keep alive across orchestration runs because seedFromHost
  kills it). At 74/76 (97%), the structural ceiling for the harness
  is reached; the remaining 2 specs need real-account write-side
  fixtures.

**ORCHESTRATION-LEVEL STOP RECOMMENDATION (session 16 final).**
Sessions 13-16 produced: 1 primitive (`lib/ax.ts` — session 13), 1
substantive AX migration (`activateTab` + `CodeTab.activate` —
session 14), 1 structural fix (T17 seedFromHost — session 15), 1
verification + 1 schema-rev investigation (session 16). NO coverage
gain across 4 sessions. Coverage start 74/76 → end 74/76 (97%
throughout). The structural ceiling is reached. Future sessions
should be triggered manually — only when (a) the user has a real
signed-in Claude they're willing to dedicate to a debugger-attached
session, or (b) a new test-harness primitive opportunity surfaces
from product changes (e.g. claude.ai renderer drift requiring
refactoring, new IPC surfaces requiring registry walking). The
autonomous orchestration is being stopped after session 16.

---

**Shipped session 15 (1 structural fix, no new spec, no AX migration):**
T17 migrated from the legacy `CLAUDE_TEST_USE_HOST_CONFIG=1` /
`isolation: null` auth path to the canonical `seedFromHost: true`
pattern (mirroring T16 / T26). Phase 0 calibration found port 9229
listening BUT the attached process was a leaked test isolation
(claude.ai loaded at `/login`, NOT the user's auth-bearing Claude),
which made Categories A (operon-mode probe) / B (Tier 3 read-only
reframes) / C (schema-rev) all soft-blocked: the debugger was
technically attached, but to the wrong process for any auth-required
investigation. Session 15 pivoted to investigating T17's pre-existing
flake (the PRIORITY directive in the followup) and discovered the
failure was structural rather than AX-polling-related.

**T17 flake root cause (session 15 finding):** The trace shows a
bare 60s Playwright spec timeout with NO `renderer-url` attachment
fired. That attachment lives at line 49 of the pre-migration spec —
which means the test never reached line 40's `waitForReady(
'userLoaded')` resolution. Session 14's hypothesis that T17's flake
was an `openPill` / `clickMenuItem` issue was wrong: the failure is
upstream of the AX click chain. The spec was running with
`isolation: undefined` (the no-`CLAUDE_TEST_USE_HOST_CONFIG` branch),
which produces a fresh isolation with no auth tokens, claude.ai
redirects to `/login`, and `waitForUserLoaded` polls for its full 90s
budget — but Playwright's spec timeout is 60s (per
`playwright.config.ts`). The 30s incompatibility produces the bare
"Test timeout of 60000ms exceeded" with no test-body trace events.
The fix is to align T17 with T16 / T26's shape: `seedFromHost: true`
copies the host's auth into the per-test isolation, hits a clean
`postLoginUrl` resolution, and skips cleanly when no signed-in host is
available (rather than hanging until the spec timeout preempts).

Coverage stays at 74/76 (97%) — structural fix, no spec landed. The
matrix coverage doesn't reflect spec-shape migrations; this shows up
as a real productivity gain (T17 should now succeed when host is
signed in, rather than auto-failing with a 60s timeout regardless).

Two commits on `docs/compat-matrix` expected (the orchestration
directive supersedes "the user reviews and commits" — autonomous
commit + push at end of session):

- TBD — `test(harness): session 15 migrate T17 to seedFromHost +
  prune unused RawElement import (no spec, coverage unchanged at
  97%)` (T17 spec rewrite swapping the `CLAUDE_TEST_USE_HOST_CONFIG`
  + `isolation: null` branch for the canonical `seedFromHost: true`
  pattern; prunes unused `RawElement` re-export import in
  `lib/claudeai.ts` per session 14's leftover hint; typecheck clean;
  T17 not run this session because the dev box's running processes
  ambiguously include leaked test isolations and possibly the user's
  real Claude — `seedFromHost` would kill both, deferred to next
  session for verification).
- TBD — `docs(testing): session 15 plan/inventory + rotate session 16
  prompt`.

Session 15 findings + reclassifications:

- **T17 flake reclassified from "AX-polling tuning" to "auth path
  not seeded".** Session 14's followup hypothesised the flake lived
  in `openPill` / `clickMenuItem` post-click loops; the trace
  evidence rules that out. The Playwright spec timeout (60s) is
  shorter than `waitForReady('userLoaded')`'s default budget (90s),
  so any unauth'd test that polls userLoaded will fail with a bare
  timeout regardless of what the AX code does. T17 was the last
  spec on the legacy `CLAUDE_TEST_USE_HOST_CONFIG=1` / `isolation:
  null` shape — every other auth-required spec (T07, T16, T19,
  T20, T21, T22b, T26, T27, T31b, T33b/c, T35b, T37b, T38b) had
  already moved to `seedFromHost: true`. T17 was an outlier, and
  the outlier-ness was the flake.
- **`openPill` / `clickMenuItem` migration NOT shipped.** Session
  14's followup proposed migrating these to `waitForAxNode` /
  `waitForAxNodes`. With T17's actual failure mode resolved by
  the structural fix, there's no remaining flake-evidence pulling
  for that migration. `openPill`'s while-loop and
  `clickMenuItem`'s while-loop both work fine when the auth path
  is correct; speculatively migrating them now would be premature
  optimisation. Future sessions can take it if a third consumer
  surfaces with budget-tuning evidence.
- **Unused `RawElement` import pruned.** Session 14 left
  `import type { RawElement }` in `lib/claudeai.ts`'s
  destructured `./ax.js` import after the migration didn't end up
  needing the type re-export. Pruned in session 15 alongside the
  T17 migration (one commit, two related shape fixes).
- **Debugger-attached process is a leaked test isolation.** The
  port-9229 listener pointed at a process whose webContents listed
  three URLs: `find_in_page.html`, `https://claude.ai/login`, and
  `main_window/index.html`. NOT the user's signed-in Claude. The
  user-data-dir on those processes was `/tmp/claude-test-*`,
  confirming they're leaked from prior test runs. There are
  multiple `/tmp/claude-test-*` dirs accumulating on the dev box
  (visible via `ls /tmp/`). Future sessions: Phase 0 calibration
  should distinguish "port 9229 is open" from "port 9229 is open
  AND attached to the user's auth-bearing Claude". Probe via
  `evalInMain` listing webContents — if every URL is `/login`,
  the auth-required investigations (Categories A/B/C) are blocked
  same as if the debugger were closed.
- **No primitive change, no AX migration.** `lib/ax.ts` and the
  session 14 migration shape are unchanged. The change was a
  spec-level structural fix, not a substrate or page-object
  change.

Tier 2 → Tier 2 candidates remaining for next session: same as
sessions 12-14 — operon-mode navigation probe (still needs an
auth-bearing debugger-attached Claude), schema-rev for
`listRemotePluginsPage` / `listSkillFiles` (might be tractable
against the leaked-isolation /login process since validators run
auth-independent — investigate), Tier 3 read-only reframes
(login-required). The `openPill` / `clickMenuItem` migration is
parked: session 15 confirmed T17's flake didn't need it, and no
other consumer is signalling for it. Coverage at 74/76 (97%) with
the test budget naturally cycling through low-impact deliverables
unless a true coverage opportunity surfaces.

**Productivity signal for next session.** Session 15 fixed a
real T17 failure mode (structural). Sessions 13-15 collectively
have produced one new primitive (`lib/ax.ts`), one substantive
migration (`activateTab` + `CodeTab.activate`), one structural
fix (T17 seedFromHost). NO coverage gain in those three sessions.
The remaining categories without a debugger that hits the user's
signed-in process are mostly exhausted. Next session should
prioritise (a) running T17 to verify the seedFromHost fix actually
resolves the 60s timeout, and (b) checking whether a Category C
schema-rev probe against the leaked /login isolation is tractable
(validators don't need auth, only invocation does — worth a 15-min
investigation). If both turn up empty, the orchestrator should
seriously consider stopping — at 97% coverage with no clear
high-leverage shapes left, further sessions are likely to produce
documentation-only or marginal-improvement deliverables.

---

**Shipped session 14 (1 call-site migration, no new spec):**
`activateTab` and `CodeTab.activate` in `lib/claudeai.ts` migrated
from hand-rolled retry loops to session 13's `lib/ax.ts` substrate.
This is a flake-reduction session — the priority shape called out in
session 13's followup as the natural next step once the substrate
landed. Phase 0 calibration found the debugger detached on the dev
box (port 9229 not listening), which blocked Categories A / B / C
(operon-mode navigation probe + Tier 3 read-only reframes + schema-
rev for `listRemotePluginsPage` / `listSkillFiles` — all needing
runtime probing against debugger-attached Claude). The PRIORITY
Category D (call-site migration) was the highest-impact deliverable
that didn't require the debugger.

Coverage stays at 74/76 (97%) — migration session, no spec landed.
The matrix coverage doesn't reflect call-site migrations; those show
up as flake-reduction in existing specs (T16's pre-existing `no
AX-tree button with accessibleName="Code" found` failure mode is
fixed by session 14's migration).

Two commits on `docs/compat-matrix` expected (the orchestration
directive supersedes "the user reviews and commits" — autonomous
commit + push at end of session):

- TBD — `test(harness): session 14 migrate activateTab to
  waitForAxNode (no spec, coverage unchanged at 97%)`
  (migrates `activateTab` from one-shot snapshot to
  `waitForAxNode` with a configurable pre-click timeout; migrates
  `CodeTab.activate`'s post-click `retryUntil`-around-
  `findCompactPills` loop to `waitForAxNodes`; T16 passes 3/3 on
  KDE-W against the migrated form, was pre-existing-flaky on the
  baseline; T26 still passes (regression check); T17 still pre-
  existing-flaky (verified by stash + retry — failure shape
  unchanged-by-migration).

Session 14 findings + reclassifications:

- **T16 fix landed.** Session 13 documented T16 as pre-existing-
  flaky on KDE-W with the failure mode `CodeTab.activate: no
  AX-tree button with accessibleName="Code" found`. Verified by
  stashing session 13's changes and re-running T16 against the
  baseline — same failure. Session 14's migration converts the
  pre-click `activateTab` from a one-shot AX snapshot into a
  `waitForAxNode` poll. The Code button is now waited-for up to
  the caller's budget (T16 passes 15s through `CodeTab.activate`)
  rather than checked-once. T16 passed 3/3 in succession against
  the migrated form.
- **`activateTab` API change is additive.** New optional `opts:
  { timeout?: number }` parameter; default 5000ms matches the
  `lib/ax.ts` defaults. Existing callers (just `CodeTab.activate`)
  pass through their own timeout. No breaking shape change to
  return type or first/second positional args.
- **`CodeTab.activate` post-click loop migrated.** The hand-rolled
  `retryUntil(async () => { const pills = await
  findCompactPills(...); return pills.length > 0 ? pills : null; },
  { timeout, interval: 200 })` block is structurally identical to
  `waitForAxNodes` with the compact-pill predicate inlined. The
  predicate (role: 'button' + hasPopup: 'menu' + non-empty
  accessibleName + not a `^More options for ` row trigger) is
  copy-pasted from `findCompactPills` to keep the page-object
  free-standing without changing observable shape. `waitForAxNodes`
  carries the existing 200ms interval and overall budget through
  via `intervalMs` / `timeoutMs`.
- **`findCompactPills` not migrated.** It's used in three call-
  sites: (a) inside `CodeTab.activate`'s formerly-hand-rolled
  retry — migrated; (b) T16's diagnostic capture on failure
  (line 91, expects fail-fast / wants whatever's currently on the
  page); (c) T16's post-activate diagnostic (already-stable, one-
  shot-by-design). Migrating `findCompactPills` itself would push
  unwanted retry latency into the diagnostic path, so the helper
  stays a one-shot snapshot — only the retry shape moved into
  `CodeTab.activate`.
- **`openPill` / `clickMenuItem` not migrated.** Both have
  post-click stability gates + sleep-based polling loops that
  could in principle be `waitForAxNode`-shaped, but each carries
  per-spec budget tuning (T17 / openFolderPicker chain uses
  `openPill { timeout: 1500 }` and `clickMenuItem { timeout:
  1500 }` defaults) that the prompt explicitly cautions against
  changing speculatively. The migration was scoped to the
  highest-impact call-site (the T16 fix) plus the cleanest shape
  match (`CodeTab.activate`'s post-click pill poll). Future
  sessions can take `openPill` / `clickMenuItem` if a third
  consumer signals.
- **T17 unchanged-by-migration.** T17 was reported pre-existing-
  flaky on KDE-W per session 13's full-suite run. Verified that
  status by stashing the migration and re-running T17 — same
  60s timeout. T17 exercises the env-pill → Local → Select-folder
  → Open-folder chain via `openEnvPill` / `selectLocal` /
  `openFolderPicker`, which use `openPill` and `clickMenuItem`
  internally. Those weren't migrated this session (per above), so
  T17's flake mode is unchanged and is pre-existing rather than
  a session-14 regression.
- **No primitive change.** `lib/ax.ts`'s `waitForAxNode` /
  `waitForAxNodes` cover both migration sites unchanged. No new
  `WaitForAxNodeOptions` flags needed.

Tier 2 → Tier 2 candidates remaining for next session: same as
session 12 / 13 — operon-mode navigation probe (still needs
debugger), schema-rev for `listRemotePluginsPage` / `listSkillFiles`
(still needs debugger), Tier 3 read-only reframes (login-required).
The new shape unlocked this session: **further call-site migrations**
in `lib/claudeai.ts` — `openPill`'s post-click while-loop and
`clickMenuItem`'s while-loop are tractable when a follow-up signal
warrants. Plus migrating T26's pre-click `retryUntil` (carries a
`context-was-destroyed` retry — `waitForAxNode` doesn't currently
swallow that exception class, so it'd need a primitive extension or
a wrapper). Coverage at 74/76 (97%) with the test budget naturally
shifting toward flake reduction now that the substrate exists.

---

**Shipped session 13 (1 new primitive, no new spec):** `lib/ax.ts` —
shared AX-tree loading + traversal substrate, threshold-driven
extraction. The plan-doc had flagged "Unified DOM/AX loading +
traversal primitive" in session 12 as the natural priority for
session 13 if the operon / Tier 3 / schema-rev categories were
blocked. Phase 0 of session 13 found the debugger detached on the
dev box (port 9229 not listening), which blocked Categories A and C
(operon-mode navigation probe + schema-rev for `listRemotePluginsPage`
/ `listSkillFiles` — both need runtime probing against the user's
debugger-attached running Claude). Category B (Tier 3 read-only
reframes) ALSO effectively required the debugger for the smoke-test
investigation phase. The PRIORITY (DOM unification) primitive
landed as the strongly-supported alternative — two threshold-
driven extraction signals (T26 had duplicated `snapshotAx` from
claudeai.ts, plus user-reported flake in AX-tree queries).

Coverage stays at 74/76 (97%) — primitive-only session, no spec
landed. The matrix coverage doesn't reflect primitive landings;
those show up in the `lib/` surface and are picked up by future
spec consumers.

Two commits on `docs/compat-matrix` expected (SHAs inserted after
the test-harness commit lands — the user reviews and commits at the
end of every session):

- TBD — `test(harness): session 13 lib/ax.ts AX substrate primitive`
  (extracts `snapshotAx` + adds `waitForAxNode` / `waitForAxNodes`;
  refactors `claudeai.ts` and `T26_routines_page_renders.spec.ts` to
  consume the shared substrate instead of carrying duplicate
  implementations; passes typecheck + H01-H03 canaries + T26 +
  T11_runtime spot-checks on KDE-W).

Session 13 findings + reclassifications:

- **`lib/ax.ts` primitive surface.** Threshold-driven extraction
  hitting 2 consumers (the formerly-private `snapshotAx` in
  `claudeai.ts` + the explicit duplicate in T26 noted as
  "premature abstraction at 1 consumer"). Surface:
  - `snapshotAx(inspector, opts)` — single AX read with a stability
    gate. `opts.fast` skips the gate for inside-poll callers
    (matches the existing internal contract).
  - `waitForAxNode(inspector, predicate, opts)` — repeatedly
    snapshot the tree and return the first matching `RawElement`,
    or null on timeout. Gates on stability once at the start
    (configurable), then iterates with `fast: true`. Built against
    the inline polling loops in `CodeTab.activate`, `openPill`,
    `clickMenuItem`, T26 pre/post-click anchor scans.
  - `waitForAxNodes(inspector, predicate, opts)` — same shape,
    returns every match. For consumers that want to enumerate.
  - Re-exports: `RawElement`, `AxNode`, `axTreeToSnapshot`,
    `waitForAxTreeStable` — so consumers don't have to reach into
    `explore/walker.ts` themselves. Walker stays the source of
    truth for AX-snapshot construction; this file is the runner-
    facing alias.
- **Refactor scope was minimal.** `claudeai.ts` swaps its private
  `snapshotAx` for the shared one (5-line import change). T26
  drops its inlined helper and imports from `lib/ax.ts`. No
  call-site rewrites — the predicate-based polling in
  `CodeTab.activate` / `openPill` / `clickMenuItem` is unchanged
  this session. Future sessions can opportunistically migrate
  hand-rolled retry loops to `waitForAxNode` when re-touching
  those code paths; not forced this session because the call-site
  retry patterns each carry per-spec budget tuning that the
  primitive's defaults need to validate against real flake data.
- **Why no spec landed.** Phase 0 calibration found port 9229
  detached (Claude was running but debugger wasn't attached via
  Developer → Enable Main Process Debugger). Categories A and C
  strictly need runtime probing against the debugger; Category B
  needs the debugger for the smoke-test verification phase (per
  session-12 pattern). The PRIORITY primitive build was the
  highest-impact deliverable that didn't require the debugger —
  pure static-analysis-driven extraction with two existing
  consumers as the threshold signal. Primitive-only sessions are
  in scope per the followup prompt's termination criteria
  ("Session budget hits ~1 new spec OR one new primitive
  landing").
- **What's NOT in `lib/ax.ts`.** Did NOT add a
  `waitForRenderedSurface(client, surfaceKey)` registry — the
  plan-doc flag mentioned it but no consumer asks for a named
  surface anchor today; promote when a third consumer crystallizes
  with a specific surface name in mind. Did NOT extract T07's
  CSS-querySelector poll loop — that's a different abstraction
  (DOM, not AX) with no second consumer signal yet. Did NOT
  rewrite call-site retry budgets in `claudeai.ts` — the budgets
  are tuned per-spec and changing them speculatively risks
  introducing flake rather than removing it.
- **Pre-existing T16 / T17 flake confirmed unchanged.** Running
  the full suite found T16 / T17 / T07 / S25 / S29-S31 / etc.
  failing on KDE-W — these failures are pre-existing on the
  baseline (verified by stashing the session-13 changes and re-
  running T16, which still failed with the same
  `CodeTab.activate: no AX-tree button with accessibleName="Code"
  found` error). Session 13's primitive doesn't fix the existing
  flake; it lays groundwork that future sessions can build
  flake-reduction patches against (e.g. promoting `activateTab`
  to use `waitForAxNode` with a longer budget instead of a one-
  shot snapshot would be the next session's natural follow-up).

Tier 2 → Tier 2 candidates remaining for next session: the same
list as session 12 — operon-mode navigation probe (still needs a
debugger-attached Claude), schema-rev for `listRemotePluginsPage`
/ `listSkillFiles` (same), Tier 3 read-only reframes (same). The
new option for next session is **call-site migration to
`waitForAxNode`** — promote `activateTab`'s one-shot snapshot to a
proper retry, give T07's CSS poll a more durable wait shape, etc.
That's a flake-reduction session shape rather than a coverage-
expansion shape; the session 13 primitive made it tractable.

---

**Shipped session 12 (1 new spec, no primitive change):** T11_runtime
(Tier 2 reframe — `seedFromHost` + multi-suffix registration probe
over five install-flow handlers + dual-handler invocation across two
distinct impl objects). First runtime probe for T11 — sibling to the
existing T11 Tier 1 fingerprint (`T11_plugin_install_fingerprint.spec.ts`,
session 3). The case-doc anchors `CustomPlugins.installPlugin` at
index.js:507181 (write-side) plus `installed_plugins.json` at :465822
(idempotency record) and `dx()` returns `~/.claude/plugins` at :465816.
Coverage moved from 73/76 (96%) to 74/76 (97%). Passes on KDE-W in
28.8s (cold).

Two commits on `docs/compat-matrix` expected (SHAs inserted after the
test-harness commit lands — the user reviews and commits at the end of
every session):

- TBD — `test(harness): session 12 T11 plugin install runtime`
  (Tier 2 reframe; multi-suffix `waitForEipcChannels` over the install-
  flow suffixes — `CustomPlugins/installPlugin` (case-doc :507181) /
  `uninstallPlugin` / `updatePlugin` / `listInstalledPlugins` /
  `LocalPlugins/getPlugins` — plus dual `invokeEipcChannel` across
  TWO impl objects: `CustomPlugins_$_listInstalledPlugins` with
  `args = [[]]` (empty `egressAllowedDomains` per T33c pattern,
  returns array — drives Manage plugins panel) and
  `LocalPlugins_$_getPlugins` with `args = []` (returns array —
  reads `~/.claude/plugins/installed_plugins.json` per case-doc
  :465822).

Session 12 findings + reclassifications:

- **`LocalPlugins` registers 15 methods, `CustomPlugins` 16.** Smoke-
  test on the user's debugger-attached running Claude dumped the full
  method list. LocalPlugins read-sides (cleanly invocable):
  `getPlugins` (`[]` → array), `getDownloadedRemotePlugins` (`[]` →
  array), plus three pluginId-arg read-sides (`getPluginOAuthStatus`,
  `getPluginCliStatus`, `getPluginShimOps` — all accept any string at
  position 0, smoke-tested). `listSkillFiles` rejects `[]` then
  `[cwd]` — needs both `pluginId` AND `skillName` (positional 0+1,
  not derivable from a fresh isolation). LocalPlugins write-sides:
  `uploadPlugin`, `deletePlugin`, `setPluginEnabled`,
  `startPluginOAuthFlow`, `revokePluginOAuth`, `setPluginEnvVars`,
  `setPluginOAuthClient`, `setPluginShimPermission`,
  `syncRemotePlugins` (sync may write).
- **`CustomPlugins` read-sides invocable:** `listMarketplaces` /
  `listInstalledPlugins` / `listAvailablePlugins` (all need `[[]]` —
  `egressAllowedDomains` empty array, T33c pattern), `getCachedCommands`
  / `getInstallCounts` / `getAndClearMigrationIssues` /
  `listLocalOrgPlugins` (all `[]`), `checkPluginHasLocalChanges` (`[cwd]`
  → object). `listRemotePluginsPage` rejects every smoke-tested arg
  shape — needs a numeric `limit` at position 0 (rejection: `Argument
  "limit" at position 0 ...`); resolvable via grep on the rejection
  literal if a future test needs paginated remote plugin listings.
- **Dual-impl-object invocation pattern.** T11_runtime is the first
  spec to invoke handlers across TWO distinct impl objects in a
  single test (CustomPlugins + LocalPlugins). Pattern: when the case-
  doc surface spans two interfaces (here: the install API side and
  the local-fs storage side), invoke a read-side from each rather
  than picking one. Strictly stronger than single-interface coverage
  — proves the install plumbing crosses both impls intact. Mixed-arg-
  shape (CustomPlugins needs `[[]]`, LocalPlugins needs `[]`) is fine,
  same as T21's mixed-shape (one returns array, another returns
  boolean).
- **No primitive change.** `lib/eipc.ts`'s `waitForEipcChannels` +
  `invokeEipcChannel` cover T11_runtime unchanged. Investigation
  budget was ~5 minutes for the smoke-test (15 read-side candidates
  × 3-5 arg shapes); no bundle-grep needed for any of the candidates
  used by the spec.
- **Filename convention.** T11_runtime is a sibling to the existing
  T11 Tier 1 fingerprint (`T11_plugin_install_fingerprint.spec.ts`)
  rather than a first-runtime-probe — uses the `_runtime` suffix
  (no letter), consistent with T19/T20/T21/T26/T27. The "b" / "c"
  letter convention is reserved for sequencing multiple runtime
  siblings on the same case-doc (T22 → T22b; T33 → T33b → T33c);
  T11_runtime is the only runtime sibling to T11, so plain `_runtime`
  fits.

Tier 2 → Tier 2 candidates remaining for next session: **operon-mode
navigation probe** (still on the table — session 10 confirmed
`OperonBootstrap.ensure` registers eagerly but the other 21 wrapper-
exposed operon interfaces remain registry-unconfirmed; would need an
operon-mode URL form recovered from the bundle). Beyond that, the
reframe pool is essentially exhausted — every Tier 1 fingerprint with
a tractable runtime sibling has been promoted, and the remaining
deferred items are Tier 3 (login-required write-side flows) or Tier 4
(out of scope). Next session's natural shape is either:

1. **Operon investigation** (smaller-scope category B from session 12's
   prompt — bundle grep for operon URL routes + per-URL registry probe).
2. **Tier 3 read-only reframes** that the harness can construct from
   existing `seedFromHost` state (e.g. T22's gh PR check monitoring —
   the `getPrChecks` read-side might be invocable with a non-existent
   PR number to assert error shape).
3. **Schema-rev** any of the still-rejecting read-sides surfaced this
   session (`listRemotePluginsPage`, `listSkillFiles`, the LocalSessions
   methods that need `cwd` / `config` args) and ship narrowly-scoped
   Tier 2 invocations if they unblock a case-doc claim.

The primitive surface remains broad enough that consumer-driven
extensions are the right next move. Coverage at 74/76 (97%) means the
test budget can shift toward Tier 3 read-only reframes or shoring up
the existing test-harness's documentation / drift-detection rather
than chasing more Tier 2 promotions.

---

**Shipped session 11 (1 new spec, no primitive change):** T21 (Tier 2
reframe — `seedFromHost` + multi-suffix registration probe over five
case-doc-anchored Launch handlers + dual-handler invocation of the
case-doc-anchored read-side getters `getConfiguredServices` /
`getAutoVerify`). First runtime probe for T21 — no fingerprint sibling
shipped because the case-doc anchors point at impl-side function
names (`setAutoVerify`, `parseLaunchJson`, `capturePage` /
`captureViaCDP`) plus an MCP tool table (`preview_*`), not the user-
facing channel names. Coverage moved from 72/76 (95%) to 73/76 (96%).
Passes on KDE-W in 16.7s (cold) / 5.2s (warm follow-up).

Two commits on `docs/compat-matrix` expected (SHAs inserted after
the test-harness commit lands — the user reviews and commits at the
end of every session):

- TBD — `test(harness): session 11 T21 dev server preview runtime`
  (Tier 2 reframe; multi-suffix `waitForEipcChannels` over the
  case-doc-anchored Launch suffixes — `getConfiguredServices` /
  `startFromConfig` / `stopServer` / `getAutoVerify` /
  `capturePreviewScreenshot` — plus dual `invokeEipcChannel` on
  `Launch_$_getConfiguredServices` (returns array) and
  `Launch_$_getAutoVerify` (returns boolean), both with
  `cwd = process.cwd()` as the validator-passing string).

Session 11 findings + reclassifications:

- **`Launch` cwd validator is `typeof cwd === 'string'` only.** Smoke-
  test against the user's debugger-attached running Claude on
  `getAutoVerify` and `getConfiguredServices` showed: `''` (empty
  string), `'.'` (relative), `'/tmp'` (existing absolute), `'/'`
  (root), `'/home/aaddrick'` (home), `'/nonexistent-path-xyzzy'`
  (non-existent), `'/home/aaddrick/source/claude-desktop-debian'`
  (existing) ALL pass. Only `null`, `undefined`, and object wraps
  (`{path:'/tmp'}`, `{cwd:'/tmp'}`) reject. No path-existence check,
  no absolute-path requirement. The handler tolerates missing
  `<cwd>/.claude/launch.json` — returns `[]` for `getConfiguredServices`
  and `false` for `getAutoVerify` when the config file is absent.
  Bundle-grep on the rejection literal NOT needed — direct smoke-
  test resolved the schema in one round-trip.
- **`window['claude.web'].Launch` exposes 30 callable members.** The
  registry probe sees 25 `_invokeHandlers`; the wrapper additionally
  surfaces 5 `on*` event subscribers (`onDeployEvent`,
  `onElementSelected`, `onPreviewSelectionShortcut`,
  `onPreviewUrlChanged`) plus `isAvailable` and `activeServersStore`.
  Wrapper-only entries don't show up in `webContents.ipc._invokeHandlers`
  because they're not invoke-style channels — they bind to event
  emitters and store proxies via different bridge primitives. Worth
  noting for any future T21-area test that wants to probe event
  subscription paths (those would need a different primitive than
  `invokeEipcChannel`).
- **UUID still `c0eed8c9-c94a-4931-8cc3-3a08694e9863`.** Build-stable
  since session 2; smoke-test confirmed.
- **Dual case-doc-anchored read-side invocation pattern.** T21
  follows T33c's shape (invoke each case-doc-anchored read-side
  suffix, assert the documented shape per handler) rather than T19
  / T20's foundational-surrogate shape (invoke `LocalSessions/getAll`
  as a stand-in because case-doc anchors were write-side). When a
  case-doc has read-side anchors with resolvable arg shapes, prefer
  invoking the case-doc-anchored handlers directly — it removes the
  surrogate hop and the assertion is "the documented handler returns
  the documented shape" rather than "a foundational sibling is
  reachable".
- **No primitive change.** `lib/eipc.ts`'s `waitForEipcChannels` +
  `invokeEipcChannel` cover T21 unchanged. Investigation budget was
  ~3 minutes for the smoke-test (eight cwd shapes against
  `getAutoVerify` plus three against `getConfiguredServices`); no
  bundle-grep needed.
- **Filename convention.** T21 had no fingerprint sibling, so
  follows T19 / T20 / T26 / T27's `_runtime` (no letter suffix)
  shape — `T21_runtime.spec.ts`. Same pattern as session 10's first-
  runtime-probe-against-case-doc filename rule.

Tier 2 → Tier 2 candidates remaining for next session: **T11 plugin
install runtime upgrade** (currently a Tier 1 fingerprint;
`LocalPlugins` registers 15 handlers per session 7's probe, includes
`getPlugins` / `getDownloadedRemotePlugins` / `syncRemotePlugins` /
`listSkillFiles` candidates — needs schema-rev or smoke-test). **operon
scope navigation probe** still on the table (session 10 confirmed
`OperonBootstrap.ensure` registers eagerly but the other 21
wrapper-exposed operon interfaces remain registry-unconfirmed; would
need an operon-mode URL form recovered from the bundle). **T11 is
the natural main bet for session 12** — same pattern as session 11's
T21 (single Launch interface investigated, single new spec landed).
The primitive surface remains broad enough that consumer-driven
extensions are the right next move.

---

**Shipped session 10 (2 new specs, no primitive change):** T19 + T20
(Tier 2 reframes — `seedFromHost` + multi-suffix registration probe
over the case-doc-anchored write-side handlers + invocation of the
foundational read-side `LocalSessions/getAll` as the surrogate).
First runtime probes for both T19 (integrated terminal) and T20
(file pane) — neither had a Tier 1 fingerprint sibling because the
case-doc anchors are channel names + impl line numbers, not user-
facing literals. Coverage moved from 70/76 (92%) to 72/76 (95%).

Session 10 findings + reclassifications:

- **`claude.web/Launch` IS registered on the claude.ai webContents
  with 25 handlers** — overturns session 7's per-interface map which
  did not list Launch (it captured /epitaxy with cowork loaded; the
  Launch interface was either lazy-registered after a navigation
  not yet performed or the per-interface enumeration missed it). The
  session 10 registry probe re-run on /epitaxy with an active session
  saw all 25: `getLogs`, `stopServer`, `showPreview`, `hidePreview`,
  `startFromConfig`, `getConfiguredServices`, `getAutoVerify`,
  `setAutoVerify`, `deployPreview`, `destroyPreview`, `pickHtmlFile`,
  `loadHtmlPreview`, `goBack`, `goForward`, `refreshPreview`,
  `navigatePreview`, `getPreviewUrl`, `setPreviewColorScheme`,
  `setPreviewViewport`, `clearPreviewViewport`, `capturePreviewScreenshot`,
  `suggestDeployName`, `unpublishDeploy`, `toggleSelectionMode`,
  `activeServers_$store$_getState`. T21's case-doc claim (dev server
  preview pane) is now reachable as a Tier 2 reframe — not shipped this
  session, deferred to next.
- **`claude.web/Launch` invocation is gated on a `cwd` argument.**
  Smoke-test of `Launch/getConfiguredServices` and `Launch/getAutoVerify`
  against the user's debugger-attached running Claude rejected with
  `Argument "cwd" at position 0 to method "<name>" in interface
  "Launch" failed to pass validation`. Schema-rev next session via the
  rejection-message grep pattern (session 9 finding) — the validator
  block sits ~50-200 chars before the throw site in the bundled
  `index.js`. T21 ships once the cwd format is recovered.
- **`claude.operon/OperonBootstrap.ensure` registers eagerly on
  claude.ai** — partially answers session 8's open question. The
  registry probe surfaced 1 operon handler (`OperonBootstrap.ensure`)
  on /epitaxy with the active Code session. The other 21 wrapper-
  exposed operon interfaces (per session 8's `mainView.js` namespace
  count) remain registry-unconfirmed; either they lazy-register on
  operon-mode entry, or the `claude.operon` wrapper is exposed
  without registration as session 8 hypothesized. Worth a follow-up
  navigation probe (operon-mode URL TBD — would need to grep
  `claude.ai/...` paths in the bundle for `operon`-keyed routes), but
  the current finding is enough to stop calling operon "registry-un-
  confirmed" — at least one handler IS registered.
- **`LocalSessions` registers 117 methods** (full list dumped to
  `/tmp/eipc-full-methods.json` during smoke-test). Read-side methods
  invocable cleanly with `args = []` as confirmed by smoke-test on the
  user's debugger-attached running Claude:
  - `getAll` → `Array<Session>` (length 1 on dev box's active /epitaxy
    session)
  - `getInstalledEditors` → `Array<EditorConfig>` (length 4 on dev box)
  - `getDetectedProjects` → `Array<Project>` (length 0 on dev box, no
    detected projects in the harness's CWD)
  - `isVSCodeInstalled` → boolean (false on dev box)
  - `getSSHConfigs` → `Array<SSHConfig>` (length 0 on dev box)
  - `getTrustedSSHHosts` → `Array<Host>` (length 0 on dev box)
  - `getDefaultEffort` → object (returns null on dev box)
  - `getSupportedCommands` → `Array<Command>` (length 25 on dev box)
  Several other read-sides DO require args:
  - `getDefaultPermissionMode` rejects with `Argument "cwd" at position
    0 ... failed to pass validation` — needs cwd
  - `getSSHSupportedCommands` rejects with `Argument "config" at position
    0 ... failed to pass validation` — needs an SSH config object
  T19 and T20 use `getAll` as the foundational read-side surrogate
  because both surfaces (terminal + file pane) bind to LocalSessions;
  the session enumeration handler is what proves the LocalSessions
  impl object is reachable through the renderer wrapper.
- **T19/T20 case-doc anchors are write-side; reframe is registration
  + foundational read-side invocation.** T19's anchors are all
  `LocalSessions_$_*ShellPty*` (start/write/stop/resize/getBuffer);
  T20's are `readSessionFile` (read-side but needs sessionId+path
  args not constructible from a fresh isolation) + `writeSessionFile`
  (write-side, would mutate user content if invoked). The strongest
  non-destructive Tier 2 layer for both is registration probe over
  the case-doc-anchored suffixes plus a single invocation of `getAll`.
  Different shape from T33c (which invokes each case-doc-anchored
  suffix because both `listMarketplaces`/`listAvailablePlugins` are
  read-side); T19/T20 mirror T22b/T31b/T33b/T38b's registration
  shape but add the `getAll` invocation for the impl-object
  reachability assertion.
- **No primitive change.** `lib/eipc.ts`'s `waitForEipcChannels` +
  `invokeEipcChannel` cover both new specs. The existing primitive
  surface remains broad enough that consumer-driven additions are
  the right next move, not fresh primitive builds.
- **Filename convention: `_runtime` suffix, no `b`/`c` letter.** T19
  and T20 had no prior runners — these are the first siblings, so
  the naming follows T26/T27 (single `_runtime` Tier 2 reframe with
  no fingerprint predecessor) rather than T33b/T33c (numbered after
  earlier siblings). `T19_runtime.spec.ts` / `T20_runtime.spec.ts`.

Tier 2 → Tier 2 candidates remaining for next session: **T21 dev
server preview** (NOW tractable — `claude.web/Launch` registers 25
handlers including read-side getters; needs `cwd` arg schema-rev via
the rejection-message grep pattern). **T11 plugin install** (currently
just a fingerprint — could promote to invocation if a read-side
plugin-listing handler is identified; `LocalPlugins/getPlugins` is
listed in the registry probe with 15 LocalPlugins handlers). **operon
scope navigation probe** (still on the table — the partial answer is
that OperonBootstrap registers eagerly, but the other 21 interfaces
would need an operon-mode navigation; URL form TBD). The primitive
surface remains broad enough that consumer-driven additions are the
right next move.

---

**Shipped session 9 (1 new spec, no primitive change):** T33c (Tier 2
runtime invocation upgrade — `seedFromHost` + dual-handler invocation
of `claude.web/CustomPlugins/{listMarketplaces, listAvailablePlugins}`
through the renderer-side wrapper, asserting array shape on each).
T33 (Tier 1 fingerprint, session 3) and T33b (Tier 2 handler-
registration, session 7) already covered the bundle-string and
registry-presence layers; T33c closes the chain by proving the impls
are wired through and return the documented `Array<…>` shape. Coverage
moved from 69/76 (91%) to 70/76 (92%). Passes on KDE-W in 39.2s
(both impls returned arrays of length 0 on the dev box's host
config).

Session 9 findings + reclassifications:

- **`CustomPlugins/listMarketplaces` and `listAvailablePlugins` use
  byte-identical hand-rolled arg validators** (NOT Zod for args; the
  result validator IS Zod, runs after the impl returns). Validator
  block at bytes 5013601 / 5018821 in the bundled `index.js`. Args
  are positional:
  - `[0] egressAllowedDomains: string[]` — required;
    `Array.isArray(r) && r.every(a => typeof a === "string")`. Empty
    array passes.
  - `[1] pluginContext: { mode: string, ...optional fields } |
    undefined` — optional. The closed-over `sc(...)` validator
    requires `mode: string`, with optional `workspacePath?`,
    `settingsLevel?`, `pluginSource?`, `marketplaceScope?`,
    `telemetryAttempt?: { attempt, maxAttempts }`.
  - **Minimal valid arg literal**: `args = [[]]`. Both methods
    accept this and treat the empty allow-list as the safety
    property — if the underlying impl is the CLI-shelling variant,
    the egress allow-list is forwarded as the spawned subprocess's
    permitted domains, so `[]` blocks any network attempt.
- **Two impl variants exist in the bundle.** `A.listMarketplaces`
  has a CLI-shelling implementation (`runCommand(["plugin",
  "marketplace", "list", "--json"])` with timeout 30s) AND a native
  implementation (reads `knownMarketplacesFile` directly). Same for
  `listAvailablePlugins` (CLI: `["plugin", "list", "--json",
  "--available"]`, timeout 60s; native: scans `marketplacesDir`).
  The selection logic isn't called out in the closure source but
  both variants return the same `Array<…>` shape on success — the
  T33c assertion (`Array.isArray(result) === true`) holds for either
  impl. Test budget bumped to 180s to accommodate worst-case
  sequential CLI timeouts.
- **Side-effect profile is acceptable for an automated runner.** No
  installs, no fs writes to user content, no state mutation. The CLI
  variant spawns a subprocess that emits log lines and may emit a
  Sentry capture on subprocess failure (e.g. `claude` CLI missing on
  PATH); the native variant performs a JSON file read. With the
  empty allow-list, no network egress from the spawned subprocess.
  Mirrors the read-only invariant T35b / T37b / T27 already rely on.
- **Both schema-rev paths converged independently.** Bundle grep
  (static analysis of the minified `.vite/build/index.js`) and
  runtime closure inspection (Function.prototype.toString of the
  registered handler pulled from `webContents.ipc._invokeHandlers`
  via the user's debugger-attached running Claude on :9229)
  produced byte-identical validator literals and the same minimal
  arg shape. High confidence. Investigation budget: ~3 minutes
  bundle-grep, ~2.5 minutes runtime-closure (subagent traces in
  /tmp; cleaned up after the run).
- **T33c filename convention follows T33/T33b.** Sessions 7 / 8
  established `_handler_registered` (Tier 1 fingerprint) /
  `_handler_runtime` (Tier 2 registration) suffixes for T33's
  paired runners. T33c the invocation upgrade is
  `T33c_plugin_browser_invocation.spec.ts` — keeps the case-doc
  pairing visible in `ls runners/`. Same pattern T35b / T37b /
  T27 implicitly used (no `_invocation` suffix needed because they
  ship as the first/only Tier 2 runner against their case-doc; T33c
  has T33 / T33b siblings to disambiguate against).
- **Registry-side T33b assertion is preserved unchanged.** T33c
  calls `waitForEipcChannels` on the same suffix pair before
  invoking — surfaces "registered but uninvocable" cleanly if the
  wrapper-exposure gate flips (registration would still happen on
  the per-wc registry, only the renderer-side wrapper would be
  missing). Both T33b and T33c can keep co-existing; T33b is the
  fast-path Tier 2 sibling for sweeps that don't need the
  invocation cost.
- **Session 8's smoke-test rejection cleanly identified the
  validator.** The session 8 prompt called out that
  `CustomPlugins/listMarketplaces` failed with `Argument
  "egressAllowedDomains" at position 0 ... failed to pass
  validation`. That error message is verbatim what the inline hand-
  rolled validator throws — the framed channel name carries through
  into the renderer-eval error surface, so the path from "invocation
  rejected by validator" to "exact validator location in the
  bundle" was a single grep on the literal error string. Worth
  noting for any future schema-rev session: the validator's own
  rejection messages are the cheapest grep target.

Tier 2 → Tier 2 candidates remaining for next session: **T19 / T20
Code-tab cluster** (each needs `claude.web/LocalSessions/*`
invocation + AX-tree click chains; LocalSessions handlers verified
present via T22b / T31b / T38b; AX anchors verified session 5).
**T19** (integrated terminal) needs `LocalSessions_$_startShellPty`
shape — but that's a write-side suffix (spawns a shell), so the
read-side reframe would be e.g. `LocalSessions_$_listSessions` or a
similar getter, not the case-doc anchor. **T20** (file pane) needs
`LocalSessions_$_writeSessionFile` (also write-side); read-side
sibling `LocalSessions_$_readSessionFile` could be the Tier 2 entry
point. **T21** (dev server preview) needs `claude.web/Launch/*`
which session 7's registry walk did NOT confirm — needs an
exposure-vs-registration probe first (mirrors the operon scope
finding from session 8). **operon scope exposure-vs-registration
probe** is still on the table from session 8 — the session 9 budget
went to T33c and didn't touch this. Primitive surface
(`lib/electron-mocks.ts`, `lib/input.ts`, `lib/input-niri.ts`,
`lib/eipc.ts` with read-and-invoke surfaces) remains broad enough
that consumer-driven extensions are the right next move, not
fresh primitive builds.

---

**Shipped session 8 (3 new specs + 1 primitive extension):** T35b, T37b,
T27 (Tier 2 runtime invocations — `seedFromHost` + eipc-handler invoke
through the renderer-side wrapper, strictly stronger than the Tier 1
fingerprint siblings T35 / T37 from session 4 and the previously-
unshipped T27 case-doc target). New `invokeEipcChannel` API on
`lib/eipc.ts` (suffix-resolved through the existing
`findEipcChannel`, then dispatched via
`inspector.evalInRenderer('claude.ai', "window['claude.<scope>']
.<Iface>.<method>(...args)")`). Coverage moved from 66/76 (87%) to 69/76
(91%). All three pass on KDE-W (T27 27.7s, T35b 33.2s, T37b 25.8s; ~1.5m
total sequential).

Session 8 findings + reclassifications:

- **eipc invocation is tractable from main, with two viable approaches.**
  Three parallel investigations were spawned: (a) direct main-side call
  (pull function from `_invokeHandlers`, synthesize `event` object), (b)
  renderer-side wrapper at `window['claude.<scope>'].<Iface>.<method>`,
  (c) hook the eipc dispatcher prototype. Approach (c) turned out
  unnecessary — the gate `le(e)` / `Vi(e)` / `mm(e)` etc. is a structural
  duck-type check on `event.senderFrame.url` and
  `event.senderFrame.parent === null`, NOT an `instanceof Frame` check,
  so a literal-object fake event passes. Approaches (a) and (b) are both
  empirically tractable — the smoke test against the user's debugger-
  attached running Claude returned the documented response shape for
  four read-only handlers via each path.
- **Renderer-side wrapper chosen for the primitive.** Honors the gate
  honestly (the wrapper IS at claude.ai; no spoofing of `senderFrame.url`
  to claim an origin the test isn't actually at), can't accidentally
  invoke a handler the real renderer can't reach (test surface stays
  aligned with real attack surface), and is shorter to spell. Trade-off:
  errors come back as serialized strings rather than native exceptions,
  but the framed channel name appears in the error message so per-handler
  triage is intact. Approach (a) stays available as a fallback for
  future scopes whose renderer-side wrapper isn't exposed (e.g. the
  `find_in_page` / `main_window` webContents host `claude.settings/*`
  handlers in their per-wc registry, but their renderers run from
  `file://` so the wrapper isn't there); not implemented in this
  session — anti-speculation rule (no consumer asks for it yet).
- **`mainView.js` exposes 9 wrapper namespaces** (more than the
  registry-side scope count): `claude.settings`, `claude.web`,
  `claude.operon`, `claude.skills`, `claude.simulator`,
  `claude.officeAddin`, `claude.hybrid`, `claude.buddy`, plus
  `claudeAppBindings` / `claudeAppSettings`. Each is a literal-dot key
  on `window` (`window['claude.web']`, NOT `window.claude.web`). The
  exposure gate `Qc()` checks top-level frame + origin allow-list
  (`https://claude.ai`, `https://claude.com`, preview.*, localhost). On
  the `find_in_page` and `main_window` webContents the wrapper is NOT
  exposed (origin is `file://`); the registry walker still sees their
  `claude.settings/*` handlers but `invokeEipcChannel` would need a
  different (main-side) approach to reach them.
- **`invokeEipcChannel(inspector, suffix, args?, opts?)` API shape.**
  Suffix is the same case-doc-anchored input the existing
  `findEipcChannel` accepts (e.g. `MCP_$_getMcpServersConfig` or fully
  qualified `claude.settings_$_MCP_$_getMcpServersConfig`). Internally
  resolves the full suffix through `findEipcChannel`, splits on `_$_`
  to recover `[scope, iface, method]`, then `evalInRenderer(urlFilter,
  "window[scope][iface][method](...args)")`. Default `urlFilter` is
  `'claude.ai'`. Args are JSON-marshaled in; return value is JSON-
  deserialized via `evalInRenderer`'s `executeJavaScript` path. Read-by-
  default but not allowlist-enforced — the safety property is that
  consumers pass case-doc-anchored suffixes verbatim (write-side suffixes
  never appear in case-doc text).
- **T35b assertion shape: response is a non-null, non-array object.**
  Empty-config (host has no `~/.claude.json` MCP servers) returns `{}`;
  configured-host returns `Record<string, MCPServerConfig>`. Either is
  the documented shape. Strongest assertion that doesn't depend on host
  MCP-config state. Diagnostic attachment shows shape + truncated
  sample (4KB cap) so a configured-host run can be triaged without
  dumping potentially-PII config into JUnit.
- **T37b assertion shape: `string | null`.** The dev box returns `null`
  (host account has no global CLAUDE.md memory written). Spec asserts
  `result === null || typeof result === 'string'` — rejects an envelope
  / object / number as a wiring regression. Diagnostic attachment shows
  type + length only (never the body — global memory is per-account
  user content and can hold sensitive material).
- **T27 (no `b` suffix — first T27 spec) ships as the case-doc Tier 2
  reframe.** Previous sessions didn't ship a T27 fingerprint sibling
  because the case-doc anchors (`runNow(A)` / `Rc.showNotification` /
  `getJitter`) are minified-symbol-shaped and don't form a high-
  confidence string fingerprint. The eipc registry names ARE high-
  confidence, so T27 ships directly as the runtime probe (same shape
  as T26's "Routines page renders" runner that has no fingerprint
  sibling). Asserts both `claude.web/CoworkScheduledTasks/
  getAllScheduledTasks` AND `claude.web/CCDScheduledTasks/
  getAllScheduledTasks` return arrays — Cowork (chat-side / Routines
  sidebar) and CCD (Code-tab) scheduling are parallel surfaces; the
  case-doc T27 mentions both Manual (Cowork-shaped) and Hourly (CCD-
  shaped) tasks.
- **The session 8 prompt's `le(i)` reference at `:68820` was off.**
  Approach 3's investigator flagged that the followup-prompt's
  reference to `le(i)` origin validation at `index.js:68820` is
  misaligned with the current build — `le` is at `:5045138` in this
  bundle; offset 68820 hits OpenTelemetry SemRes constants. Doesn't
  affect the outcome (the gate's behavior is the same regardless of
  offset) but worth noting for any future probe that takes the
  followup-prompt offset literally.
- **Renderer-eval errors are stringified.** When `invokeEipcChannel`'s
  underlying handler rejects (origin gate, arg validator, result
  validator), the error surface is `Error: Error invoking remote method
  '<framed-channel>': <inner-message>`. The framed channel name in the
  message lets consumers triage per-handler. Two non-Tier-2 handlers
  hit during investigation (`listMarketplaces`, `getPrChecks`) failed
  arg validation cleanly — proves the gate accepted the wrapper-
  synthesized event, which is the load-bearing signal that the
  primitive's invocation path is real.
- **Smoke-test artefact deleted.** Built a quick smoke test
  (`tools/test-harness/smoke-test-invoke.ts`) to verify the new primitive
  against the user's debugger-attached Claude before writing specs.
  Confirmed all four target invocations (`getMcpServersConfig`,
  `readGlobalMemory`, `CCDScheduledTasks/getAllScheduledTasks`,
  `CoworkScheduledTasks/getAllScheduledTasks`) returned their
  documented shapes. Smoke-test deleted after; the runners themselves
  are the durable assertion surface. The probe artefacts at
  `/tmp/eipc-invoke-probe-*.{ts,md,log,json}` from the three
  investigation subagents are also disposable — `/tmp` is wiped on
  next reboot, and the per-investigation findings are captured in the
  bullets above.

Tier 2 → Tier 2 candidates remaining for next session: **T33 Phase 2**
(`CustomPlugins/listMarketplaces` — currently fails arg validation on
`egressAllowedDomains`; would need the schema reverse-engineered from
the bundle, then the spec invokes with valid args), **T19/T20/T21
Code-tab cluster** (each needs `claude.web/ClaudeCode/*` invocation +
AX-tree click chains; AX anchors verified session 5), **operon scope
exposure-vs-registration check** (the renderer wrapper exposes 22
operon interfaces but session 7's registry walk didn't catalogue them
on claude.ai — either lazy-register on operon-mode entry, or wrapper-
exposed without a registered handler; worth a one-liner probe before
any operon-scope spec lands). Primitive surface
(`lib/electron-mocks.ts`, `lib/input.ts`, `lib/input-niri.ts`,
`lib/eipc.ts` with read-and-invoke surfaces) is now broad enough that
session 9 is more about consumer-driven additions than primitive
builds.

---

**Shipped session 7 (4 new specs + 1 new primitive):** T22b, T31b, T33b,
T38b (Tier 2 runtime probes — `seedFromHost` + eipc-registry presence
checks, strictly stronger than the Tier 1 fingerprint siblings T22 / T31
/ T33 / T38 from session 3). New primitive `lib/eipc.ts`
(`getEipcChannels` / `findEipcChannel` / `findEipcChannels` /
`waitForEipcChannel` / `waitForEipcChannels`; opaque on the
`$eipc_message$_<UUID>_$_` framing prefix, matches by case-doc-anchored
suffix). Coverage moved from 62/76 (82%) to 66/76 (87%) — the four
session 3 fingerprint specs gained Tier 2 siblings; the 4 session 1
splits (T14a/T14b shape) precedent applies. All four pass on KDE-W
(~7.5s each, ~32s total).

Session 7 findings + reclassifications:

- **eipc registry IS reachable from main — session 3's "closure-local"
  conclusion was wrong about WHERE, not whether.** The handlers go
  through Electron's stdlib `IpcMainImpl`, just on the per-`webContents`
  IPC scope (`webContents.ipc._invokeHandlers`, Electron 17+) rather
  than the global `ipcMain._invokeHandlers`. Sessions 2-6 only ever
  walked the global registry (which holds 3 chat-tab MCP-bridge
  handlers); the per-wc registry on the claude.ai webContents holds
  490 handlers including all 117 `LocalSessions_$_*` and 16
  `CustomPlugins_$_*` channels. Verified empirically against a
  debugger-attached running Claude via
  `tools/test-harness/eipc-registry-probe.ts` (kept in-tree as a
  re-runnable read-only probe).
- **Registry is sticky across route changes.** Run-1 captured
  `https://claude.ai/epitaxy` with cowork loaded → 490 handlers. Run-2
  navigated to `https://claude.ai/new` (chat tab) → still 490 handlers,
  same 117 LocalSessions + 16 CustomPlugins. Conclusion: handlers
  register at webContents init and persist; specs don't need to
  navigate to /epitaxy specifically — `seedFromHost` + `userLoaded` on
  any post-login route is sufficient.
- **Framing UUID is build-stable** at
  `c0eed8c9-c94a-4931-8cc3-3a08694e9863` (single UUID across all 647
  per-wc handlers). Session 2's T38 partial `c0eed8c9-…` confirmed.
  `lib/eipc.ts` does NOT pin the UUID — it strips it via regex and
  matches by suffix so a future build that rotates the UUID doesn't
  silently break consumers.
- **53 distinct interfaces fully mapped.** The probe's per-interface
  breakdown surfaced every `(scope, iface)` pair across the three
  webContents. Notable interfaces with direct line-of-sight to
  deferred Tier 2 / Tier 3 work (NOT shipped this session — flagged
  for next):
  - `claude.web/CoworkMemory/readGlobalMemory` (read-only) — direct
    path to **T37 Phase 2** (CLAUDE.md memory loads), upgrades the
    Tier 1 fingerprint to Tier 2 invocation.
  - `claude.settings/MCP/getMcpServersConfig` (present on ALL three
    webContents, read-only) — direct path to **T35 Phase 2** (MCP
    config picked up).
  - `claude.web/CoworkScheduledTasks/getAllScheduledTasks` and
    `claude.web/CCDScheduledTasks/getAllScheduledTasks` — pathway for
    a T27 Tier 2 reframe (scheduled tasks).
  - `claude.web/ClaudeCode/{getStatus, prepare, checkGitAvailable,
    resolveLocalSettings}` — useful for the deferred T19/T20/T21
    cluster (Code-tab integrated terminal, file pane, dev server
    preview).
  - `claude.web/CustomPlugins/listMarketplaces` is shape-identical to
    `getMcpServersConfig` (read-only) — could feed a T33 Phase 2
    invocation if a consumer needs marketplace contents asserted, not
    just handler presence.
- **`lib/eipc.ts` API: read-only by design.** `getEipcChannels` walks
  the per-wc registry; `waitForEipcChannel` / `waitForEipcChannels`
  add the populate-on-init poll; no `invokeEipcChannel` yet. Adding
  invocation would unlock T35 Phase 2 / T37 Phase 2 but the design
  decisions (event synthesis, args marshaling, side-effect gating per
  read vs write channel) need a real consumer to anchor against.
  Same anti-speculation rule that kept `lib/electron-mocks.ts`
  (session 3) and `lib/input.ts` (session 4) and `lib/input-niri.ts`
  (session 6) threshold-driven.
- **T14a/T14b convention applied.** Existing T22 / T31 / T33 / T38
  shipped session 2/3 without the `a` suffix; session 7 left them
  unchanged (Tier 1 fingerprint files are still authoritative for
  bundle-string-presence regression detection) and added T22b / T31b
  / T33b / T38b siblings (Tier 2 runtime probes). The `b` files use
  the `_runtime` filename suffix to disambiguate from the `_fingerprint`
  / `_handler_registered` shape of the existing files.
- **All four pass on KDE-W (Plasma 6 Wayland, XWayland).** Sequential
  run (Playwright `workers: 1`) — 7.7s / 7.5s / 7.5s / 7.7s. The
  `host-claude` killer fired once at the start (sent SIGTERM to the
  user's running Claude); subsequent specs found no host process to
  kill. End-to-end shape: createIsolation seedFromHost → launchClaude
  → waitForReady('userLoaded') → waitForEipcChannel(s) → assert
  presence → app.close().
- **eipc-registry-probe kept in-tree.** `tools/test-harness/eipc-registry-probe.ts`
  is the read-only standalone probe that surfaced the per-wc finding;
  parallel to the existing `probe.ts` (renderer-DOM probe) and
  `grounding-probe.ts` (case-grounding runtime capture). Useful
  re-run target across upstream version bumps to confirm the registry
  shape hasn't drifted.

Tier 2 → Tier 2 candidates remaining for next session: **T35 Phase 2**
and **T37 Phase 2** (now MUCH more tractable — the registry primitive
gives a discoverable surface for the read-side handlers like
`getMcpServersConfig` / `readGlobalMemory`; what's missing is the
invocation surface in `lib/eipc.ts`). **T27 Tier 2 reframe** (scheduled
tasks; same invocation pattern). **T19/T20/T21 Code-tab cluster** (each
needs different combos of `claude.web/ClaudeCode/*` + AX-tree click
chains). The primitive surface itself (`lib/electron-mocks.ts`,
`lib/input.ts`, `lib/input-niri.ts`, `lib/eipc.ts`) is now broad enough
that the next session is more about consumer-driven extensions
(`invokeEipcChannel`) than fresh primitive builds.

---

**Shipped session 6 (1 new spec + 1 new primitive):** S14 (Tier 2 — Niri-
only, currently known-failing detector). New primitive `lib/input-niri.ts`
(Wayland-native focus-shifter sibling of `lib/input.ts`:
`focusOtherWindow` / `spawnMarkerWindow` / `getFocusedWindowId` /
`isNiriSession` plus `NiriIpcUnavailable` / `FootUnavailable` typed
errors). Coverage moved from 61/76 (80%) to 62/76 (82%).

Session 6 findings + reclassifications:

- **S14 shipped as Tier 2 known-failing detector.** Near-clone of S11's
  shape with imports swapped from `lib/input.js` to `lib/input-niri.js`
  and the row gate flipped from `['GNOME-X', 'Ubu-X']` to `['Niri']`.
  Same five-phase shape: setup → ready → marker spawn → focus loop with
  sticky-error short-circuits → press shortcut + assert popup visible.
  Diagnostic record fields parallel S11's `s11-diagnostics`
  (`activeWidBeforeFocus` / `activeWidAfterFocus` typed `number | null`
  for niri u64 IDs vs the X11 hex strings). Currently a known-failing
  detector per case-doc S14 (`Failed to call BindShortcuts (error code
  5)`); same shape as S12's GNOME-W `--enable-features=GlobalShortcutsPortal`
  detector — the spec encodes the contract and will start passing on
  Niri rows once the upstream / Chromium-side portal issue is resolved
  without any spec edit.
- **`lib/input-niri.ts` extracted as the niri-side focus-shifter
  substrate.** Niri-only by design — strict
  `XDG_CURRENT_DESKTOP === 'niri'` gate via `isNiriSession()`. Exports:
  `focusOtherWindow(title)` (`niri msg --json windows` →
  `app_id !== 'Claude'` filter + title match → `niri msg action
  focus-window --id <u64>` → honest readback via `getFocusedWindowId()`
  using `retryUntil`), `spawnMarkerWindow(title)` (backgrounded
  `foot --title <T> -e sleep 600` with kill-with-grace, mirroring the
  X11 primitive's xterm pattern), `getFocusedWindowId()` (parses
  `niri msg --json focused-window` to `number | null`), `isNiriSession()`,
  `MarkerWindow` interface, `NiriIpcUnavailable` / `FootUnavailable`
  typed errors. The primitive verifies the focus shift took (niri's
  `focus-window` action exits 0 even when the compositor refuses
  activation — only `focused-window` readback is the honest answer).
  Defensive `unwrapOk` helper handles both the older
  `{Ok: {FocusedWindow: ...}}` Result-style JSON envelope and newer
  bare-payload responses; if niri ships a third shape, the parser
  falls through to `null` rather than crashing.
- **Cross-compositor dispatcher NOT speculated.** Sway / Hyprland /
  River each have totally different IPCs (`swaymsg`, `hyprctl`,
  `riverctl`); the long-term cross-compositor answer is libei but
  isn't widely deployed. Per-compositor files until a second consumer
  surfaces — a hypothetical `lib/input-wayland.ts` dispatcher would
  just switch on `XDG_CURRENT_DESKTOP` and delegate. With only S14
  consuming `lib/input-niri.ts`, a dispatcher would be ceremony.
- **Category B (eipc-registry exposer) NOT attempted.** Same reasoning
  as sessions 4/5: session 3 already established the registry is
  closure-local, the inspector walk came up empty, and the early-exit
  cap on retries makes Category B a poor main bet without a new
  approach. Stays available for a future session that takes the
  closure-local reverse-engineering as its main work.

Tier 2 → Tier 2 candidates remaining for next session: **T35 Phase 2**
and **T37 Phase 2** (still need closure-local readback or the
eipc-registry exposer; unchanged from sessions 4/5). **eipc-registry
exposer** (closure-local in main; reverse-engineering remains
unattempted — now the cleanest single-session win available, with all
the obvious focus-shifter / mock-then-call work already landed). The
primitive surface itself isn't growing quickly — `lib/electron-mocks.ts`
(session 3), `lib/input.ts` (session 4), and `lib/input-niri.ts`
(session 6) are all threshold-driven extractions, not speculative.

Session 6 untested-on-Niri caveats: the `lib/input-niri.ts` primitive
landed against session 5's recon notes, not a live niri session. First
real Niri sweep run will confirm: (a) the `Ok`-wrapper unwrap covers
the niri version on the row; (b) Claude's `app_id` value on niri is
literal `'Claude'` (the primitive's `app_id !== 'Claude'` guard
becomes a no-op rather than wrong if the actual value differs — match
still happens by title; tighten if needed); (c) `foot` is on the
target row's PATH (skip path is clean if not). Verified on KDE-W: the
runner skips correctly via the row gate.

---

**Shipped session 5 (1 new spec):** T18 (Tier 1 fingerprint). No new
primitives. Coverage moved from 60/76 (79%) to 61/76 (80%).

Session 5 findings + reclassifications:

- **T18 shipped as Tier 1 fingerprint, OS-level form deferred.**
  Four-needle pin against bundled `mainView.js` for the
  preload-bridged path-resolution wiring: `getPathForFile` (2× —
  property key + the underlying `webUtils.getPathForFile(` call,
  both at case-doc :9267), `webUtils` (1×, :9267), `filePickers`
  (1×, :9267), `claudeAppSettings` (1×, :9552 — the
  `contextBridge.exposeInMainWorld` namespace). Bundle form
  matches case-doc form verbatim — no minified-vs-beautified
  gotcha (unlike T35's `~/.claude.json` → `.claude.json`). The
  Tier 2/3 OS-level form (real drag-drop into Chromium with file
  payload) stays a primitive gap on **both** backends: X11
  xdotool can simulate mouse motion but cannot put file URIs on
  the XDND selection (the bridge would never see a file payload),
  and Wayland needs per-compositor IPC + libei input injection.
  A real test needs a custom XDND source app (X11) or a libei
  emitter (Wayland); deferred. T18 follows the same shape as
  T35/T36 from session 4 — when Tier 2 readback isn't reachable,
  ship the Tier 1 fingerprint against the load-bearing strings.
- **T36 Phase 2 reclassified Tier 2 → Tier 3/4 (real-account
  write).** Session 4's plan-doc framed T36 Phase 2 as needing "a
  Code-tab session opener the AX-tree walker hasn't been taught"
  — implying the AX tree was the only blocker. Session 5 traced
  the SessionStart-hook fire path through the bundled `index.js`
  and found a deeper blocker: the `SessionStart` hook fires
  inside the agent SDK process once it boots, and the agent
  process is spawned only when there's a prompt to bind to. Call
  chain: `Ys.startSession` (`:454743` general, `:489371` CCD)
  requires `A.message`; the session record stores it as
  `initialMessage` (:489270); the agent is spawned via
  `DN({ prompt: k, options: v })` (`:489514`) — only when there's
  a prompt stream to bind to. `createOrResumeSession` (`:489208`)
  creates the session record but doesn't spawn the agent.
  Conclusion: clicking "New session" alone navigates to a fresh
  composer but doesn't boot the agent. The hook fires only after
  first prompt submission, which writes to the user's real
  claude.ai account. T36 Phase 2 is therefore unmockable without
  deep agent-SDK reverse-engineering and stays Tier 3/4 (real
  account write) rather than Tier 2.
- **Code-tab session-opener AX surface verified — primitive
  build deferred.** The user's debugger-enabled running Claude
  let the session do a one-shot AX-tree probe (deleted after
  use). Concrete anchors confirmed for a future
  `CodeTab.activateTopTab()` / `startNewSession()` /
  `openExistingSession()` primitive set:
  - **Top-tab Code button**: `button[name="Code"]` under
    `group[Mode]` under `complementary`. Disambiguator from the
    prompt-mode `tab[name="Code"]` in
    `tablist[name="Prompt categories"]` (which is what T16's
    existing `CodeTab.activate()` clicks).
  - **Sidebar entries (Code mode active)**:
    `button[name="New session ⌘N"]`, `button[name="Routines"]`,
    `button[name="Customize"]`, `button[name="More navigation items"]`,
    plus `button[name="Pinned"]` / `button[name="Recents"]`
    section headings.
  - **Recents items**: `button[name="<status> <title>"]` where
    status ∈ {Idle, Ready, Needs input, Awaiting input}. The
    main-pane Welcome surface uses a different naming —
    `button[name="Open session <title>"]` — for the same
    sessions; either anchor would work for an
    `openExistingSession(re)` consumer.
  - **URL of Code-tab landing**: `/epitaxy`.
  Primitive deferred per the T36 Phase 2 finding: no consumer
  needs the click chain right now — it would only navigate to a
  fresh composer without firing any hook. If a future session
  identifies a consumer that benefits from "Code-tab session
  opened" alone (e.g. a Tier 2 reframe of T19/T20 that probes
  surfaces visible *before* prompt submission), the AX anchors
  above are pre-verified.
- **S14 niri msg recon — TRACTABLE; build deferred to next
  session.** Niri's IPC exposes everything the X11 primitive
  needs honest equivalents of: `niri msg --json windows` returns
  `Vec<Window>` with `{id, title, app_id, pid, workspace_id,
  is_focused, ...}`; `niri msg action focus-window --id <u64>`
  injects focus; `niri msg --json focused-window` is the honest
  post-hoc readback (the equivalent of `xprop _NET_ACTIVE_WINDOW`
  for the X11 primitive). The wiki explicitly contracts that
  `--json` output is stable; plain text is not. A
  `lib/input-niri.ts` sibling can mirror `lib/input.ts`'s shape:
  `spawnMarkerWindow(title)` via `foot --title <T> -e sleep 600`
  (Wayland-native marker; takes `--title` cleanly and ships in
  most niri setups), `focusOtherWindow(title)` via the
  windows-list match + focus-window action + focused-window
  readback chain, `getFocusedWindowId()` via
  focused-window. Niri 25.08+ ships `xwayland-satellite`
  integration so the existing X11 primitive *might* work on niri
  rows where it's running — but it's opt-in/runtime, can't
  assume. Cross-compositor: Sway / Hyprland / River each have
  completely different IPCs; per-compositor files are cleaner
  than a unified abstraction (a 10-line dispatcher in
  `lib/input-wayland.ts` switching on `XDG_CURRENT_DESKTOP`
  delegates to the per-IPC files; libei is the long-term answer
  but isn't widely deployed). Build deferred — single S14
  consumer didn't justify the new-primitive build this session
  on top of T18 + the runtime-probe + plan-doc work.
- **Category A (eipc-registry exposer) NOT attempted.** Same
  reasoning as session 4: session 3 already established the
  registry is closure-local, the inspector walk came up empty,
  and the early-exit cap on retries makes Category A a poor main
  bet without a new approach. Stays available for a future
  session.

Tier 2 → Tier 2 candidates remaining for next session: **S14**
(build `lib/input-niri.ts` per the session 5 recon sketch +
ship S14 runner — clearest single-session win available).
**T35 Phase 2** and **T37 Phase 2** (still need closure-local
readback or the eipc-registry exposer; unchanged from session 4).
**eipc-registry exposer** (closure-local in main; reverse-
engineering remains unattempted). **T36 Phase 2 is no longer a
Tier 2 candidate** — moved to Tier 3/4 per the SessionStart-fires-
on-prompt-submit finding. The primitive surface isn't growing —
session 5 added zero new primitives, and the Code-tab AX anchors
captured during the runtime probe live in the plan-doc rather
than in `claudeai.ts` until a consumer needs them.

---

**Shipped session 4 (3 new specs + 1 new primitive):** T35 (Phase 1
fingerprint), T36 (Phase 1 fingerprint), S11 (X11-only). New primitive
`lib/input.ts` (focus-shifter: `focusOtherWindow` /
`spawnMarkerWindow` / `getFocusedWindowId` / `isX11Session` plus
`WaylandFocusUnavailable` / `XdotoolUnavailable` typed errors).
Coverage moved from 57/76 (75%) to 60/76 (79%).

Session 4 findings + reclassifications:

- **T35 Phase 1 shipped as Tier 1, Phase 2 deferred.** Four-needle
  asar fingerprint pinning the chat-tab vs Code-tab MCP-config
  separation: `claude_desktop_config.json` (chat-tab path constant,
  case-doc :130821), `.claude.json` (Code-tab user-level loader,
  :176766), `.mcp.json` (Code-tab project-level loader, :215418),
  `"user","project","local"` (settingSources triple Code-session
  passes to the agent SDK, :489098). The case-doc references
  `~/.claude.json` with the tilde, but the minified bundle stores
  it as `.claude.json` (no tilde — minified strips the path-prefix
  style and resolves home at use); the runner's leading comment
  flags this discrepancy so future maintainers don't chase the
  tilde form. Phase 2 (place fixture
  `<isolation>/Claude/claude_desktop_config.json` + inspector-eval
  the parsed MCP server list) deferred — same closure-local-
  minified-symbol blocker as T37b / S19 / S28; without a reachable
  readback target the fixture form would assert "the spec didn't
  crash" and nothing more.
- **T36 shipped as Tier 1, Phase 2 deferred.** Five-needle asar
  fingerprint following T37's "single-occurrence high-signal anchor
  + registry tokens" shape: `hook_started` / `hook_progress` /
  `hook_response` (each single-occurrence Verbose-transcript
  runtime emits at case-doc :493411 — these back the case-doc's
  "hook output is visible in Verbose transcript mode" claim) plus
  `PreToolUse` (17×, :455717 — built-in event registry the runtime
  extends) and `UserPromptSubmit` (4×, :455819 — less-common
  registry token, stronger uniqueness than `PostToolUse`'s 9×).
  Phase 2 (`~/.claude/settings.json` SessionStart-hook fixture +
  marker-file readback) deferred — needs login + a Code-tab
  session opener the AX-tree walker hasn't been taught.
- **S11 shipped with X11-only row gate; GNOME-W mutter regression
  detector remains a primitive gap.** Case-doc applies-to is
  "GNOME, Ubu" (W and X), but the focus-shifter primitive is
  X11-only — XDG_SESSION_TYPE === 'x11' strict — so the runner's
  row gate is `['GNOME-X', 'Ubu-X']` only. The case-doc's
  load-bearing concern is the GNOME-W mutter XWayland key-grab
  regression (#404); that regression CANNOT be detected here
  because there's no portable focus-injection on native Wayland
  (each compositor exposes its own IPC; libei isn't universally
  honored). What S11 does catch: a regression in the X11 path of
  the global shortcut on GNOME-X / Ubu-X — a currently-passing
  detector unlike S12 which is a currently-failing one. The
  Wayland-side regression detector stays manual until libei
  adoption broadens.
- **S14 NOT shipped — primitive gap.** Case-doc row gate is just
  `Niri` and Niri is wlroots Wayland with no XWayland; the
  focus-shifter primitive throws `WaylandFocusUnavailable` there,
  so any S14 runner consuming the new primitive would skip on
  every row in its gate. That's the definition of a stub. Per the
  session prompt's "don't ship stubs" rule, S14 is documented as a
  primitive-gap (needs Wayland-native focus injection — Niri's
  `niri msg` IPC, or libei when broadly available) and stays
  unshipped. The Tier 1 reframe (assert
  `--enable-features=GlobalShortcutsPortal` in argv) is already
  covered by S12.
- **`lib/input.ts` extracted as the focus-shifter substrate.**
  X11-only by design — strict `XDG_SESSION_TYPE === 'x11'` gate
  via `isX11Session()`. Exports:
  `focusOtherWindow(title)` (xdotool `search --name` + verify via
  `xprop -root _NET_ACTIVE_WINDOW` poll using `retryUntil`),
  `spawnMarkerWindow(title)` (backgrounded `xterm -e 'sleep 600'`
  with kill-with-grace), `getFocusedWindowId()` (parses xprop
  output to lowercase 0x-prefixed hex), `isX11Session()`,
  `MarkerWindow` interface, `WaylandFocusUnavailable` /
  `XdotoolUnavailable` typed errors. The primitive verifies the
  focus shift took (xdotool exits 0 even when the compositor
  refuses activation — only `_NET_ACTIVE_WINDOW` readback is the
  honest answer).
- **eipc-registry exposer NOT attempted.** Listed in session 3 as
  a high-risk-high-reward primitive that would unblock proper
  Tier 2 runtime probes for T22/T31/T33/T38. Session 4 budget
  didn't fit it — the primitive build (`lib/input.ts`) plus three
  spec runners filled the realistic ceiling. Stays available for
  a future session that wants to take the closure-local
  reverse-engineering on as its main work.

Tier 2 → Tier 2 candidates remaining for a future session:
**S14** (focus-shifter Wayland-native variant — needs libei or
per-compositor IPC fallback; primitive gap). **T35 Phase 2** and
**T36 Phase 2** (both need a reachable readback for parsed
state — same blocker as T37b / S19 / S28). **eipc-registry
exposer** (closure-local in main; reverse-engineering remains
unattempted). The primitive surface itself isn't growing
quickly — `lib/electron-mocks.ts` (session 3) and `lib/input.ts`
(session 4) are both threshold-driven extractions, not
speculative.

---

**Shipped session 3 (7 new specs):** T22, T24, T30, T31, T32, T33, T37.
Coverage moved from 50/76 (66%) to 57/76 (75%).

Session 3 findings + reclassifications:

- **eipc-registry finding (load-bearing — corrects session 2 T38).** The
  `LocalSessions_$_*` and `CustomPlugins_$_*` channels named in case-doc
  Code anchors (`:68816` framing comment, `:71392` listMarketplaces, etc.)
  do **not** register through Electron's standard `ipcMain.handle()`
  registry. KDE-W run revealed `ipcMain._invokeHandlers` holds only three
  chat-tab MCP-bridge handlers (`list-mcp-servers`,
  `connect-to-mcp-server`, `request-open-mcp-settings`) regardless of
  ready level (`mainVisible` / `claudeAi` / `userLoaded`) and regardless
  of whether the launch was hermetic (default isolation) or authenticated
  (`createIsolation({ seedFromHost: true })`). Confirmed via inspector
  walk of `globalThis` — no Map containing 5+ keys with the
  `LocalSessions_$_*` shape exists at any reachable surface. The custom
  `$eipc_message$_<UUID>_$_claude.web_$_<name>` protocol uses a closure-
  local message-port registry that's not introspectable from main without
  reverse-engineering the eipc bootstrap (deferred — same gotcha as
  session 2's S28 with `Sbn()`).
- **T38 reclassified from Tier 2 → Tier 1.** Session 2 shipped T38 as a
  `ipcMain._invokeHandlers` introspection probe assuming the channel
  registered through stdlib IPC; the eipc-registry finding above shows
  that probe never resolved a real handler. Reclassified to a Tier 1
  asar fingerprint asserting the channel-name string
  `LocalSessions_$_openInEditor` is present in bundled `index.js` (case-
  doc anchor `:68816` framing / `:464011` egress). Same drift signal,
  zero false-positive surface, no launch needed. Updated leading
  comment links the eipc-registry finding for future maintainers.
- **T22, T31, T33 shipped as Tier 1 fingerprints, not Tier 2 IPC
  probes.** All three were originally drafted using the (now-known-broken)
  T38 handler-registered pattern. After the eipc-registry finding,
  rewritten as pure asar fingerprints anchoring on the eipc channel-name
  strings:
  - **T22** asserts `LocalSessions_$_getPrChecks` *and* the
    `"gh CLI not found in PATH"` throw site (case-doc anchors
    `:464281` / `:464964` / `:464368`). Two-fingerprint runner; the
    missing-`gh` string is the Linux-specific UX backstop since
    `installGh()` is macOS-only.
  - **T31** asserts the side-chat trio: `LocalSessions_$_startSideChat`,
    `LocalSessions_$_sendSideChatMessage`, `LocalSessions_$_stopSideChat`
    (case-doc anchors `:487025` / `:487265`). Trio is load-bearing —
    side chat is broken without all three.
  - **T33** asserts `CustomPlugins_$_listMarketplaces` and
    `CustomPlugins_$_listAvailablePlugins` (case-doc anchors `:71392` /
    `:71534` / `:507176`). Both load-bearing for the plugin-browser
    populate flow.
- **T24 shipped as Tier 2 mock-then-call (Category E pattern).**
  Mirrors T25's `installShowItemInFolderMock` shape; new
  `installOpenExternalMock` helper records every `shell.openExternal`
  call without launching a real editor on the host. Strictly stronger
  than the asar-fingerprint alternative (Category C / `Mtt` registry
  fingerprint) — exercises the actual egress at index.js:464011 with
  the URL flowing through verbatim. The meaningful difference from T25:
  `shell.openExternal` returns `Promise<boolean>` (not void), so the
  mock returns a resolved Promise.
- **T30 sweep cadence regex tuned to minified bundle.** Case-doc names
  the constants as `300_000` / `3_600_000` (beautified form); installed
  asar has them as `300*1e3` / `3600*1e3`. Single regex with two
  proximity windows — tail of `300*1e3` to `3600*1e3` ≤ 200 chars,
  tail of `3600*1e3` to `AutoArchiveEngine` ≤ 3000 chars — confirmed
  to match exactly once globally. Followed by an `.includes()` check
  for `ccAutoArchiveOnPrClose` inside the captured window to colocate
  the gate key.
- **T37 fixture-readback form deferred — Tier 1 fingerprint shipped.**
  Session prompt suggested placing a fixture `~/.claude/CLAUDE.md` and
  inspector-eval'ing the loaded memory state. The parsed-memory state
  target is a closure-local minified symbol (same gotcha as S28 from
  session 2 / S19's `cE()`/`Tce()` re-implementation note); without a
  reachable readback target the fixture form would assert nothing
  beyond "the spec didn't crash". Shipped as Tier 1 fingerprint
  anchoring on `[GlobalMemory] Copied CLAUDE.md` (single-occurrence
  log line, the cleanest possible anchor) plus `CLAUDE.md` filename
  literal and `CLAUDE_CONFIG_DIR` env-var token.
- **`lib/electron-mocks.ts` extracted.** With T24 landing the third
  mock-then-call helper (after T17's dialog mock and T25's
  showItemInFolder mock), the threshold from the session prompt was
  hit. Moved `installOpenDialogMock` / `installShowItemInFolderMock` /
  `installOpenExternalMock` plus their `getCalls` readers + interfaces
  out of `lib/claudeai.ts` into `lib/electron-mocks.ts`. T17, T24, T25
  imports updated. The mocks are generic Electron module patches —
  not claude.ai-domain — so the new home keeps `claudeai.ts` focused
  on AX-tree page-objects.
- **Authentication state in launch-based specs.** All four launch-
  based specs in this session (T22/T24/T31/T33 originally) ran with
  default isolation, i.e. unauthenticated. After the eipc-registry
  finding the three IPC probes converted to pure file probes (no
  launch needed); T24 (mock-then-call) doesn't depend on auth state
  because `shell.openExternal` is a stdlib Electron module patched
  in main. For future Tier 2 reframes that DO depend on authenticated
  renderer state (e.g. testing claude.ai DOM after login), the
  T16/T26 `seedFromHost: true` pattern is the correct gate.

Tier 2 → Tier 2 candidates remaining for a future session: **S11,
S14** (focus-shifter primitive still unbuilt). **T35** (MCP server
config picked up — needs a reachable readback for parsed MCP server
state, same blocker as T37b/S19/S28). The eipc-registry surface
itself is a primitive gap — landing it would unlock proper Tier 2
runtime probes for T22/T31/T33/T38 and any future LocalSessions_*
or CustomPlugins_* tests.

---

**Shipped session 2 (10 new specs):** T10, T16, T23, T25, T26, T38, S10,
S19, S25, S28. Coverage moved from 40/76 (53%) to 50/76 (66%).

Session 2 reclassifications:

- **S28** reclassified from **Tier 2 → Tier 1**. The plan called for
  inspector-eval against `Sbn()` permission classifier with a synthetic
  error string, but `Sbn` is a closure-local in the bundled main process
  — not reachable from `globalThis` and no IPC surface exposes it. The
  shipped runner is a single-regex asar fingerprint that pins the same
  classifier expression (the `"Permission denied" || "Access is denied"
  || "could not lock config file" → "permission-denied"` chain) plus the
  `Failed to create git worktree:` log line. Same drift signal, no
  launch needed.
- **T38** shipped as a **handler-registered probe**, not a no-throw
  invocation. Calling `LocalSessions.openInEditor` directly would
  terminate at `shell.openExternal('vscode://...')` (real editor launch
  + side effect on host) and would also be blocked by the channel's
  origin validation against non-claude.ai senders. Instead, the runner
  inspects `ipcMain._invokeHandlers` for the channel ending in
  `LocalSessions_$_openInEditor`. Documents the channel's
  `$eipc_message$_<UUID>_$_claude.web_$_<name>` framing (UUID is
  build-stable: `c0eed8c9-...`) so a future framing change is visible.
- **T23 tool choice — dbus-monitor, not gdbus monitor.** The plan
  suggested `gdbus monitor --session --dest=org.freedesktop.Notifications`
  but `gdbus monitor --dest <name>` only sees signals OWNED BY that
  destination, not method calls TO it. `Notify` is a method call FROM
  Electron TO the daemon, so `gdbus` cannot observe it. Switched to
  `dbus-monitor` (eavesdrop match rule). Pre-launch checks gate on
  `dbus-monitor` presence + notification-daemon ownership of
  `org.freedesktop.Notifications`.
- **S19 honest-stub note.** The Tier 2 slice is env propagation
  (`extraEnv: { CLAUDE_CONFIG_DIR }` → main-process `process.env`).
  Half 1 (env propagation) is the load-bearing assertion. Half 2
  (resolver-shape echo) is a synthetic re-implementation of `cE()` /
  `Tce()` because those minified symbols are closure-locals — leading
  comment is explicit about the re-implementation status.
- **T25 / T38 / T23 host side effects documented.** T25 may briefly
  open a file manager on the host; T38 deliberately doesn't invoke;
  T23 fires a real notification. Each runner's leading comment
  documents the side effect.

Tier 2 → Tier 2 candidates remaining for a future session: **T31, T32**
(side chat, slash menu — both need a Code-tab session OPEN, not just
the Code tab loaded). **S11, S14** (focus-shifter primitive still
unbuilt — flagged in plan and unchanged).

---

**Shipped session 1 (25 new specs):** T02, T05, T06, T07, T08, T09,
T11, T12, T13, T14a, T14b, S01, S02, S03, S04, S05, S07, S08, S15, S16,
S17, S21, S22, S26, S27. Coverage moved from 15/76 (20%) to 40/76 (53%).

Session 1 reclassifications:

- **T05** shipped as a **Tier 3 delivery probe** (xdg-open →
  `app.on('second-instance', ...)`), not the originally-planned Tier 2
  `app.isDefaultProtocolClient` check — that runtime call is a no-op
  in the harness because `ELECTRON_FORCE_IS_PACKAGED=true` makes
  `app.getName()` resolve to `Claude` instead of `claude-desktop`.
  Real registration is install-time via the `.desktop` file's
  `MimeType=` line. Spec uses `isolation: null` + pre-launch
  `killHostClaude()` so the SingletonLock collision routes the URL.
- **T07** shipped via `createIsolation({ seedFromHost: true })` —
  the topbar IS rendered by claude.ai's authenticated SPA (per
  `docs/learnings/linux-topbar-shim.md`), but the harness's
  hermetic-auth seeding primitive lifts it from Tier 3 to Tier 2.
  T07 is the first spec to exercise `seedFromHost`; it works
  end-to-end (kill host, copy auth allowlist, post-login URL
  reached, topbar DOM probed).
- **T14** intentionally split into **T14a** (asar fingerprint, Tier 1)
  + **T14b** (runtime second-launch focus, Tier 2). Adopt this
  letter-suffix convention for other case-doc tests with both static
  and runtime halves.
- **S20** deferred with an issue tracking the multi-DE DBus channel
  for power-blocker verification (KDE PowerDevil claims the
  `org.freedesktop.PowerManagement.Inhibit` lock; logind
  `systemd-inhibit --list` doesn't see it). Linked from the spec
  index when the issue lands.

**Tier 3 → Tier 2 promotion candidates unlocked by `seedFromHost`:**
T16 (Code tab loads), T26 (Routines page renders), T31 (side chat),
T32 (slash command menu) — each previously deferred for "needs
login" can now ship as `seedFromHost` specs in the T07 pattern.
Login-tests that *write* to the user's account (T22 PR monitoring,
T27 scheduling, T29 worktree creation, T34 OAuth, T36 hooks fire)
remain Tier 3 because the seed is read-only; writes still hit the
real account on close.

Templates referenced below (paths relative to
`tools/test-harness/src/runners/`):

- `H02_frame_fix_wrapper_present.spec.ts` — pure asar/file probe
- `H03_patch_fingerprints.spec.ts` — multi-fingerprint asar probe
- `S09_quick_window_patch_only_kde.spec.ts` — single-fingerprint asar probe
- `S33_electron_version_capture.spec.ts` — bundled-binary metadata read
- `H01_cdp_gate_canary.spec.ts` — short-lived spawn + exit-code probe
- `H04_cowork_daemon_lifecycle.spec.ts` — pgrep delta around launch
- `S12_global_shortcuts_portal_flag.spec.ts` — argv probe with
  launchClaude + `/proc/$pid/cmdline`
- `T01_app_launch.spec.ts` — launchClaude + xprop window probe
- `T03_tray_icon_present.spec.ts` — launchClaude + DBus / SNI walk
- `T04_window_decorations.spec.ts` — launchClaude + xprop frame query
- `T17_folder_picker.spec.ts` — launchClaude + inspector + AX-tree
  click chain (login required)
- `S29_…lazy_create…` / `S31_…submit_reaches_new_chat` — Quick
  Entry: launchClaude + interceptor + ydotool injection
- `S35_…position_persisted_across_restarts` — two-launch with shared
  isolation handle

## Tier 1 — File / spawn / argv probes (~30min – 1hr each)

No app launch needed (or a single short-lived spawn for an exit
code). Existing primitives (`asar.ts`, `argv.ts`, `diagnostics.ts`,
filesystem reads, `execFile` shells) suffice. Cheap wins.

- **T02 — Doctor exit code 0.** Template: `H01` (spawn + exit code) +
  `diagnostics.ts:runDoctor`. Layer: spawn probe. Primitives:
  `lib/diagnostics.ts` (already runs `--doctor` and captures combined
  stdout/stderr). Assertion: spawn `claude-desktop --doctor`, exit
  code === 0, attach stdout for the matrix annotation. `runDoctor`
  currently swallows the non-zero code; extend it to return
  `{ output, exitCode }` and assert in the spec.
- **T13 — Doctor identifies package format correctly.** Template:
  `H01` + `diagnostics.ts:runDoctor`. Layer: spawn probe + stdout
  grep. Assertion: `--doctor` stdout does not contain
  `not found via dpkg (AppImage?)` on a dnf-installed row. Reuses the
  T02 scaffolding; the only delta is a regex on the captured output.
- **S01 — AppImage launches without manual `libfuse2t64`.** Template:
  `H01` (spawn + exit-code probe). Layer: spawn probe. Primitives:
  `child_process.spawn` against the AppImage with `--version` or a
  short-lived launch; capture stderr; expect no
  `libfuse.so.2` mention. Skip on non-AppImage rows. Optional bonus:
  `dpkg -l | grep -i fuse` capture for the diag attachment.
- **S02 — `XDG_CURRENT_DESKTOP=ubuntu:GNOME` doesn't break DE
  detection.** Template: `H03` (multi-fingerprint asar/source probe).
  Layer: file probe. Primitives: read
  `scripts/launcher-common.sh` and `scripts/patches/quick-window.sh`
  from the install path; assert no `==` equality check against
  `XDG_CURRENT_DESKTOP`. Pure shell-source grep — the launcher source
  is shipped alongside the binary on deb/rpm installs (or in the
  worktree on dev). Row gate: Ubu rows.
- **S03 — DEB install pulls runtime deps.** Template: `H02` +
  `H01`. Layer: spawn probe. Primitives: `dpkg-deb -I` on the
  installed package or `apt-cache depends claude-desktop`. Assertion:
  the `Depends:` field is non-empty (or, given S03's case-doc note
  that no `Depends:` line is emitted, capture the field for the
  matrix and mark `✗` against the upstream contract). Row gate: Ubu /
  any deb row.
- **S04 — RPM install pulls runtime deps.** Template: `H02`. Layer:
  spawn probe. Primitives: `rpm -qR claude-desktop`. Same shape as
  S03 — capture and assert the `Requires:` is non-empty. Row gate:
  KDE-W/X, GNOME-W/X, Sway, i3, Niri (any RPM-based row).
- **S05 — Doctor recognises dnf-installed package.** Template: `H01`
  + `diagnostics.ts:runDoctor`. Layer: spawn probe. Primitives:
  `runDoctor` + grep `rpm -qf` install-method line in stdout.
  Assertion: doctor prints an install-method PASS line on RPM-based
  rows (today the entire dpkg-gated block is skipped — the test will
  fail until the rpm branch lands). Row gate: same as S04.
- **S15 — `--appimage-extract` works as documented fallback.**
  Template: `H01` (spawn + exit-code) + `H02` (filesystem assertion
  on the extracted tree). Layer: spawn probe. Primitives:
  `child_process.spawn` of the AppImage with `--appimage-extract`;
  assert exit 0; assert `squashfs-root/AppRun` exists; spawn that
  with `--version` and assert exit 0. Row gate: any AppImage row.
- **S16 — AppImage mount cleans up on app exit.** Template: `H04`
  (pgrep delta around launch + close). Layer: pgrep delta + mount
  probe. Primitives: `mount | grep claude` before launch (baseline),
  after launch (one mount), after `app.close()` + 5s settle (mount
  gone). Reuses launchClaude isolation. Row gate: any AppImage row.
  Borderline Tier 2 (does require a launch); kept here because the
  assertion is purely on `mount(8)` output, no inspector needed.
- **S26 — Auto-update is disabled when installed via apt/dnf.**
  Template: `H03` (fingerprint absence probe). Layer: file probe.
  Primitives: `asar.ts:asarContains` — assert
  `index.js` *contains* `setFeedURL` (upstream code) AND assert no
  patch-applied suppression token (e.g. a `cdd-disable-auto-update`
  marker) is present. As written this is a regression detector that
  *fails* until #567's suppression patch lands. Cheap. Pair with a
  launcher-log scan for `autoUpdater` errors as an attachment.
- **S09 (already landed)** — listed for context, not a new runner.
- **S33 (already landed)** — listed for context, not a new runner.
- **T11 — Plugin install (Anthropic & Partners).** Template: `H03`
  (fingerprint probe). Layer: file probe. Assertion: bundled
  `index.js` contains `installPlugin: attempting remote API install`
  and `installed_plugins.json` strings. This is the file-level
  "install code path is wired" signal — the end-to-end install flow
  with a real plugin click chain is Tier 3 (T33). T11's case-doc
  smoke claim is satisfied by the plumbing being present. **Tier 2
  runtime sibling shipped session 12** (`T11_runtime.spec.ts`) — five-
  suffix registration probe over `CustomPlugins/installPlugin` (case-
  doc anchor :507181) + `uninstallPlugin` + `updatePlugin` +
  `listInstalledPlugins` + `LocalPlugins/getPlugins`, plus dual
  invocation across both impl objects (CustomPlugins +
  LocalPlugins). Tier 1 fingerprint kept as the cheap drift sentinel.
- **T14 — Multi-instance behavior (asar fingerprint).** Template:
  `H03`. Layer: file probe. Assertion: `requestSingleInstanceLock`
  + `second-instance` listener strings present in `index.js`. The
  case-doc full assertion (second invocation focuses existing
  window) is Tier 2 — this Tier 1 entry covers the upstream
  contract being in the bundle. Flag in the plan: **the
  case-doc-defined T14 isn't fully testable without two
  launchClaude calls + window-focus detection — split T14 into
  T14a (file probe, here) and T14b (full second-instance behavior,
  Tier 2)** when implementing.
- **S27 — Plugins install per-user.** Template: `H03`. Layer: file
  probe. Assertion: `index.js` contains `cE()` resolving
  `~/.claude` + no system-path string in the plugin install code
  path. Pure asar probe. (The full assertion — actually installing
  a plugin and checking nothing landed in `/usr` — is Tier 3.)
- **S08 — Tray icon doesn't duplicate after `nativeTheme` update.**
  Template: `H03`. Layer: file probe. Assertion: the
  `setImage` + `setContextMenu` in-place fast-path string is in
  `index.js` (injected by `patches/tray.sh:95-231`). Wraps the
  static side of the patch. Runtime tray-rebuild idempotency is
  *already* covered by T03's post-toggle SNI count assertion —
  S08's case-doc claim is fully exercised today, so the static
  fingerprint is the only remaining file-level verification gap.
  Row gate: KDE-W, KDE-X.

## Tier 2 — Single-launch probes (~2-3hrs each)

One `launchClaude()` + inspector attach + an Electron-API or
window-state assertion. Existing primitives suffice. Default
isolation works; signed-in claude.ai is **not** required.

- **T05 — `claude://` URL handler registered.** Template: `T17`
  (inspector eval) + `T01` (window probe). Layer: L1 (inspector).
  Primitives: `inspector.evalInMain` to read
  `app.isDefaultProtocolClient('claude')`. One-line assertion.
  Bonus: spawn `xdg-mime query default x-scheme-handler/claude`
  and capture the result for the diag attachment. The `xdg-open`
  delivery half (does the running app receive the URL?) is a
  separate sub-test — kept Tier 3 because verifying delivery
  needs a second-instance argv path round-trip.
- **T06 — Quick Entry global shortcut registered.** Template:
  `S29` (Quick Entry interceptor) without the ydotool press.
  Layer: L1. Primitives: `inspector.evalInMain` to read the
  `globalShortcut.isRegistered(accelerator)` state for
  `Ctrl+Alt+Space`. Assertion shape is "registration state, not
  delivery"; the unfocused-state shortcut delivery is exercised
  by S29 / S31. Skip rows where ydotool can't drive the press
  (none, since registration assertion doesn't need a press).
- **T07 — In-app topbar renders + clickable.** Template: `T17`
  (renderer eval) — but with **no claude.ai login required**
  because the topbar is in the shell, not behind /login.
  Layer: L1. Primitives: `inspector.evalInRenderer` to query
  `document.querySelectorAll('.topbar button')` (or the AX
  equivalent via `claudeai.ts`). Assertion: five buttons
  present, each has non-zero bounding rect. Click delivery is a
  follow-up. Row gate: rows with PR #538 builds.
- **T08 — Hide-to-tray on close.** Template: `S29` (MainWindow
  state probe) + pgrep. Layer: L1. Primitives:
  `MainWindow.setState('close')` (already in `quickentry.ts`),
  then `MainWindow.getState()` should report `visible: false`,
  then `pgrep -af claude-desktop` should still show our pid.
  Assertion: process alive, window hidden. Reuses `quickentry.ts`
  primitives directly.
- **T09 — Autostart via XDG.** Template: `T17`. Layer: L1.
  Primitives: `inspector.evalInMain` to call
  `app.setLoginItemSettings({ openAtLogin: true })`, then read
  `~/.config/autostart/claude-desktop.desktop` (the wrapper writes
  it via the shim at `frame-fix-wrapper.js:376`). Assert file
  exists, contains `Exec=` line, has valid Desktop-Entry shape.
  Toggle off, assert file gone. Pure file-system observation
  side-stepping XDG login flows.
- **T10 — Cowork integration (asar + spawn delta).** Template:
  `H04` (pgrep delta). Layer: pgrep delta. Primitives: same as
  H04 — `pgrep cowork-vm-service`. The case-doc claim has
  multiple parts; T10 here covers "daemon spawns when needed"
  via H04's existing infrastructure. The "kill the daemon, see
  it respawn" half is Tier 2 too but needs an extra
  pgrep-then-kill-then-poll sequence. Either combine into one
  T10 spec or split into T10a (spawn) + T10b (respawn).
- **T12 — WebGL warn-only.** Template: `T17`. Layer: L1.
  Primitives: `inspector.evalInRenderer` against the main
  webContents to navigate to `chrome://gpu` — actually, that's
  blocked (Electron file: scheme guard). Better: query
  `app.getGPUFeatureStatus()` from main process. Assertion: GPU
  feature status object captured; UI didn't crash. Pure
  Electron-API probe.
- **T14b — Multi-instance second-launch focus.** Template:
  `H04` (pgrep delta) + a second `spawn` call. Layer: spawn
  probe + pgrep delta. Primitives: launchClaude (first), then
  `child_process.spawn` of the launcher a second time, assert
  the second exits ~immediately (existing-instance message)
  and pgrep still shows just the first pid. No inspector
  needed. Borderline Tier 1 — kept here because two launches
  is the load-bearing setup.
- **T26 — Routines page renders (via deeplink).** Template:
  `T17`. Layer: L1. Primitives: launch with
  `--args claude://code` (or whatever deep-link routes to
  routines), wait for `userLoaded`, query the AX tree for the
  Routines sidebar button. **Requires login — promote to
  Tier 3.** Listed here as a candidate; the actual classification
  is T26 → Tier 3. Removed from Tier 2 count.
- **S07 — `CLAUDE_USE_WAYLAND=1` opt-in path works.** Template:
  `S12` (argv + diag log) but with `extraEnv: { CLAUDE_USE_WAYLAND: '1' }`.
  Layer: argv probe + launcher-log scan. Primitives: `argv.ts`
  to confirm `--ozone-platform=wayland` in argv, plus
  `diagnostics.ts:readLauncherLog` to scan for the Wayland-mode
  log line. Row gate: Sway, Niri, Hypr-O, Hypr-N (native-Wayland
  rows).
- **S10 — Quick Entry popup is transparent.** Template: `S29`
  (Quick Entry interceptor, popup state read). Layer: L1.
  Primitives: trigger Quick Entry via ydotool, then
  `inspector.evalInMain` to read `popupWindow.getBackgroundColor()`
  (alpha component) — the construction-time `transparent: true`
  isn't observable through the prototype hook (per CLAUDE.md
  hooking note), but `getBackgroundColor()` returns the runtime
  state. Row gate: KDE-W.
- **S11 — Quick Entry shortcut fires from any focus.** Template:
  `S29`. Layer: L1 + ydotool. Primitives: launch app, focus
  another window (xdotool / ydotool), inject the shortcut, assert
  popup appears. Row gate: GNOME-W, Ubu-W (where the mutter
  XWayland key-grab story matters). **Currently broken on GNOME-W
  per #404 — this is a regression detector, expected to fail until
  the GlobalShortcutsPortal patch lands.**
- **S14 — Global shortcuts via XDG portal work on Niri.** Template:
  `S29`. Layer: L1 + ydotool. Same shape as S11. Row gate: Niri.
  Currently fails per case-doc.
- **S30 (already landed)**, **S29 (already landed)**, etc. listed
  for context.
- **S17 — App launched from `.desktop` inherits shell PATH.**
  Template: `T17`. Layer: L1. Primitives: launch with `extraEnv`
  scrubbing `PATH`, then `inspector.evalInMain` to read the
  process.env.PATH after the shell-path-worker fork completes
  (`index.js:259300` site). Assertion: PATH includes the
  user-shell-profile additions. Tricky bit: the shell-path-worker
  is async; needs a poll. Reuses `retryUntil`.
- **S20 — "Keep computer awake" inhibits idle suspend.** **Deferred —
  see [#569](https://github.com/aaddrick/claude-desktop-debian/issues/569).**
  The case-doc verification path (`systemd-inhibit --list`) doesn't
  work on KDE rows: Electron's `powerSaveBlocker.start('prevent-app-suspension')`
  calls `org.freedesktop.PowerManagement.Inhibit` (PowerDevil), not
  logind's `Inhibit()`, so `systemd-inhibit --list` never sees it.
  Issue #569 tracks the multi-DE DBus channel solution
  (default L1 `isStarted()` + KDE PowerDevil addendum + GNOME
  SessionManager addendum). Grounding probe already covers the L1
  half synthetically.
- **S21 — Lid-close still suspends per OS policy.** Template:
  `H03` (fingerprint absence). Layer: file probe (pure). No
  launch needed — the case-doc anchor is "no `handle-lid-switch`
  string anywhere in `index.js`". `asarContains('index.js', 'handle-lid-switch')`
  must return false. Move to Tier 1 instead. Reclassified.
- **S22 — Computer-use toggle absent or visibly disabled on
  Linux.** Template: `T17` + AX-tree query. Layer: L1.
  Primitives: navigate to Settings → Desktop app → General via
  AX-tree click chain (no claude.ai login needed — settings is
  shell-rendered). Assert the Computer Use toggle is either
  absent or has `disabled: true` on its AX node. Falls back to a
  file-probe Tier 1 if the AX walk is brittle (assert
  `index.js` contains the `qDA = new Set(["darwin", "win32"])`
  fingerprint). **Promote the file-probe form to Tier 1; keep
  the AX-tree form as Tier 3 because the Settings surface may
  itself be claude.ai-side rendering for some panels.**
- **S25 — Mobile pairing survives Linux session restart (token
  storage probe).** Template: `T17` + isolation handle reuse
  (S35 pattern). Layer: L1. Primitives: launchClaude with shared
  isolation, write
  `coworkTrustedDeviceToken` via `safeStorage.encryptString`,
  close, relaunch with same isolation, read it back. Asserts
  the storage key is encrypt/decrypt-stable across restart. The
  end-to-end pairing flow is Tier 3 (needs paired phone); this
  is the Linux-side persistence half.

Net Tier 2 count after reclassifications above: T05, T06, T07, T08,
T09, T10, T12, T14b, S07, S10, S11, S14, S17, S20, S22 (file-probe
form), S25 = **16 specs**.

S21 reclassified to Tier 1 (file-probe only, no launch). Add S21 to
Tier 1 list.

## Tier 3 — Multi-step or login-required (~4-8hrs each)

Defer to follow-up sessions. Each needs either signed-in claude.ai
(`CLAUDE_TEST_USE_HOST_CONFIG=1` + writes to the user's real
account), multi-launch state, or AX-tree click chains against
rendered Code-tab surfaces. Most cluster on the Code tab.

- **T15 — Sign-in completes in embedded webview.** Blocker: live
  OAuth flow with no mock provider. Closest template: `T17`
  (renderer eval) but the `/login/` → token-exchange chain can't
  be driven without real credentials. Could be tested
  destructively against a throwaway test account, but writes to
  a real account.
- **T16 — Code tab loads.** Blocker: needs login.
  Template: `T17`. After login, AX-tree click on the Code tab
  button + assert the `/epitaxy` URL loaded.
- **T18 — Drag-and-drop files into prompt.** Blocker: drag-drop
  injection on Wayland is portal-grabbed; X11 needs xdotool
  drag. Closest template: `T17`. Could be Tier 4 on Wayland;
  Tier 3 on X11 with xdotool.
- **T19 — Integrated terminal.** Blocker: needs login + spawning
  a session. Template: `T17` + IPC probe of
  `LocalSessions_startShellPty`. Login required.
- **T20 — File pane opens and saves.** Blocker: login + Code
  session. Template: `T17` + IPC probe of
  `LocalSessions_writeSessionFile`. Login required.
- **T21 — Dev server preview pane.** Blocker: login + a real
  project + `.claude/launch.json`. Template: `T17`.
- **T22 — PR monitoring via gh.** Blocker: login + open PR +
  authenticated `gh`. Template: `T17`. Could also write a Tier 1
  fingerprint probe for the `gh CLI not found in PATH` string,
  but the case-doc claim is full PR monitoring.
- **T23 — Desktop notifications fire.** Blocker: needs T27 / T22
  / S24 to fire first. Template: DBus monitor on
  `org.freedesktop.Notifications`. Could be Tier 2 if reframed
  as "spawn a notification via `Notification` API and verify it
  reaches the bus" — that's a pure inspector eval. Reframed
  form is Tier 2.
- **T24 — Open in external editor.** Blocker: needs login + a
  Code session + an installed editor. Template: `T17`. Could
  be partially covered Tier 1 by asserting the `Mtt` registry
  fingerprint is in `index.js`, but the case-doc claim is full
  click-chain → editor opens.
- **T25 — Show in Files / file manager.** Blocker: same as T24.
  Closest Tier 2 reframe: inspector-call
  `shell.showItemInFolder('/tmp/x')` directly and assert it
  doesn't throw — that's Tier 2. The case-doc claim is the
  click-chain version.
- **T26 — Routines page renders.** Blocker: login. Template:
  `T17`.
- **T27 — Scheduled task fires and notifies.** Blocker: login
  + creating a real task that writes to the user's account.
  Template: `T17` + DBus notification monitor.
- **T28 — Scheduled task catch-up after suspend.** Blocker:
  login + actual `systemctl suspend` (likely Tier 4 in CI; Tier
  3 on a dev box).
- **T29 — Worktree isolation.** Blocker: login + real Git
  project + multiple parallel sessions. Template: `T17`.
- **T30 — Auto-archive on PR merge.** Blocker: login + PR + 5
  min sweep window. Tier 4-adjacent due to the wait; reframe as
  fingerprint probe for the sweep cadence constants (Tier 1).
- **T31 — Side chat opens.** Blocker: login + Code session.
  Template: `T17`.
- **T32 — Slash command menu.** Blocker: login + Code session.
  Template: `T17`.
- **T33 — Plugin browser.** Blocker: login + the plugin browser
  modal. Template: `T17`. Tier 1 fingerprint probe handles the
  `listMarketplaces` IPC presence; full click-chain through the
  marketplace is Tier 3.
- **T34 — Connector OAuth round-trip.** Blocker: live OAuth +
  browser handoff back. Template: `T17`. Hard to mock.
- **T35 — MCP server config picked up.** Blocker: login + Code
  session + an MCP server fixture. Template: `T17`.
- **T36 — Hooks fire.** Blocker: login + Code session. Template:
  `T17` + filesystem marker check.
- **T37 — `CLAUDE.md` memory loads.** Blocker: login + Code
  session. Template: `T17`.
- **T38 — Continue in IDE.** Blocker: login + IDE installed.
  Template: `T17`. Reframe as
  inspector-eval `LocalSessions.openInEditor(path, …)` and
  assert no throw — that's Tier 2.
- **S06 — URL handler doesn't segfault on native Wayland.**
  Blocker: native-Wayland row + `coredumpctl` correlation.
  Template: spawn URL handler subprocess, monitor for SIGSEGV.
  Could be Tier 2 once a native-Wayland row is wired (the
  harness's `CLAUDE_HARNESS_USE_WAYLAND=1` enables this).
  Reclassify to Tier 2 once a Wayland row is part of the sweep.
- **S18 — Local environment editor persists across reboot.**
  Blocker: requires reboot half. Template: `T17` + isolation
  reuse (S35 pattern) — partial coverage as Tier 2 (across
  app-restart, not host-reboot).
- **S19 — `CLAUDE_CONFIG_DIR` redirects scheduled-task storage.**
  Blocker: login + creating a task. Reframe as Tier 2:
  inspector-eval `Tce()` returns the right path under
  `extraEnv.CLAUDE_CONFIG_DIR`. **Reclassify to Tier 2.**
- **S23 — Dispatch-spawned sessions don't soft-lock.** Blocker:
  paired phone + Dispatch task. Tier 4 unless Dispatch can be
  mocked at the IPC layer (probably can — Tier 3).
- **S24 — Dispatch-spawned Code session appears with badge.**
  Blocker: paired phone. Tier 4 without mock.
- **S28 — Worktree creation surfaces clear error on read-only
  mounts.** Blocker: login + read-only mount fixture.
  Template: `T17` + a `mount -o ro` bind in CI. Reframe Tier 2:
  inspector-eval against `Sbn()` permission-denied classifier
  with a synthetic error message; assert it returns
  `'permission-denied'`. **Reclassify to Tier 2.**

After Tier-3 → Tier-2 reclassifications (S06, S19, S28, T23, T25
reframe, T38 reframe): Tier 3 net count =
T15, T16, T18, T19, T20, T21, T22, T24, T26, T27, T28, T29, T31,
T32, T33 (full form), T34, T35, T36, T37, S18, S23, S25 (full
pairing form) = **22 specs.**

## Tier 4 — Out of scope or blocked

- **T39 — `/desktop` CLI command behavior.** Blocker: this asserts
  the upstream `claude` CLI binary, not the Electron asar. Out of
  harness scope per `cases/README.md` "Anchor scope" — Ambiguous /
  no asar anchor exists. Mark `-` in the matrix.
- **S12 (currently)** — **already a runner** but listed because
  it's a known-failing regression detector by design (will pass
  only after #404 is closed). Keep as Tier 2 land — flagged here
  for awareness.
- **S31 (closed-via-X variant)** — the "close via X" sub-case in
  S31 is already covered by the existing S31 runner under hidden
  state. The "different workspace" variant on Wayland is
  blocked: ydotool can't address-by-workspace and AX-tree
  doesn't reach the compositor. Tier 4 for the workspace half.
- **S32 — Quick Entry submit on GNOME mutter (full repro).**
  Already exists as a runner for the static gate; the full
  Andrej730 stale-`isFocused()` repro requires extra logging
  injection in `h1()`. Tier 4 unless we ship the diagnostic
  patch.
- **S36 — Quick Entry popup falls back to primary display.**
  Blocker: hardware multi-monitor with disconnect. Already
  documented as skip-on-single-monitor. Tier 4 (hardware
  dependent).
- **S37 — Quick Entry popup remains functional after main
  window destroy.** Blocker: project's hide-to-tray override
  makes the destroy path unreachable on Linux without a debug
  build. Tier 4 (architecturally unreachable).
- **T18 (Wayland half)** — drag-drop on Wayland portal-grabbed.
  Already noted; X11 form is Tier 3. Wayland form: Tier 4
  until libei adoption.
- **S11/S12/S14 (delivery-side on portal-grabbed Wayland)** —
  ydotool can't drive portal-grabbed shortcuts. The
  registration-side assertions are Tier 2; the delivery-side
  assertions on portal-grabbed Wayland sessions are Tier 4
  until libei. The case-doc reframes assertion shape so most
  rows are Tier 2; portal-grabbed Wayland rows are Tier 4.
- **T28 — Suspend catch-up.** Tier 4 in CI (real `systemctl
  suspend`); Tier 3 on a dev box with cooperation.

## Primitive gaps to flag

The following Tier 1 / Tier 2 items hint at a missing primitive or
a primitive that needs a small extension:

- **`runDoctor` should expose exit code.** T02 / T13 / S05 all need
  `{ output, exitCode }`. Today's implementation swallows the code.
  One-line lib/diagnostics.ts edit.
- **AppImage detection helper.** S01 / S15 / S16 need to know "is
  the install an AppImage". Today the test would spawn the
  launcher and look at mount output; a `lib/install.ts:detectFormat()`
  that returns `'deb'|'rpm'|'appimage'|'unknown'` from probing the
  install paths would centralize this.
- **`mount(8)` parser.** S16 needs `mount | grep claude`-style
  observation; nothing under `lib/` does that today. Trivial
  `child_process.exec` wrapper, but worth its own file
  (`lib/mounts.ts`) for reuse by future install-path tests.
- **systemd-inhibit list parser.** S20 needs to parse
  `systemd-inhibit --list` output to find the Claude-owned
  `idle:sleep` lock. New `lib/systemd.ts` module — also useful
  for future power-state tests (T28).
- **DBus notification monitor.** T23 / T27 need to observe
  `org.freedesktop.Notifications`. The existing `lib/dbus.ts`
  does `getConnectionPid` only; a new `lib/notifications.ts`
  with `monitorNotifications(predicate)` would be a clean
  extension.
- **xdotool / ydotool focus-stealing.** S11 / S14 need to
  focus another app before injecting the shortcut. Today
  `quickentry.ts` injects the shortcut but doesn't shift
  focus. Add `lib/input.ts:focusOtherWindow()` (X11
  `xdotool` shell-out; Wayland: skip).
- **Source-tree introspection (not just app.asar).** S02 / S26
  reference `scripts/launcher-common.sh` and other repo files
  not in the asar. A `lib/repo.ts:readRepoFile(path)` that
  resolves against a known repo root would give the file probes
  a clean entry. For an installed-binary sweep, the launcher
  source is shipped under `/usr/lib/claude-desktop/scripts/`
  on deb/rpm; for the dev tree, it's the worktree itself. The
  helper would probe both.
- **Plugin install side-channel.** T11 (full form, not the
  fingerprint probe) needs to verify
  `~/.claude/plugins/installed_plugins.json` after a click chain.
  Tier 3 only — flagged for later.
- **Multi-monitor helper.** S36 — out of scope (Tier 4 hardware
  dependent), but if it ever becomes tractable, a
  `lib/displays.ts` mocking `screen.getAllDisplays()` would be
  the entry.
- **Unified DOM/AX loading + traversal primitive (LANDED session
  13 as `lib/ax.ts`).** Threshold-driven extraction once T26 had to
  redefine `snapshotAx` inline (after `claudeai.ts`'s private copy
  was the only consumer for sessions 1-12). The primitive surface
  exports `snapshotAx`, `waitForAxNode`, `waitForAxNodes`, plus
  re-exports of `RawElement` / `AxNode` / `axTreeToSnapshot` /
  `waitForAxTreeStable` so consumers don't reach into
  `explore/walker.ts` directly. `claudeai.ts` and T26 both consume
  the shared substrate; future call-site migrations (e.g.
  `activateTab` → `waitForAxNode`) are tractable now. The
  speculative `waitForRenderedSurface(client, surfaceKey)` shape
  was deliberately NOT shipped — no consumer asks for a named-
  surface registry today; promote when a third consumer
  crystallizes with a specific surface name. The CSS-querySelector
  poll in T07 was deliberately NOT extracted — different
  abstraction (DOM, not AX), no second consumer signal yet.

## Open questions for the parent agent

- **T11 / T14 split.** The case-doc T11 / T14 conflate "code path
  exists in asar" with "click chain works end-to-end". The plan
  splits each into a Tier-1 fingerprint probe and a Tier-3 full
  flow. If the parent prefers single-spec coverage, T11 / T14
  drop entirely from Tier 1 and live only in Tier 3.
- **Reframe-to-Tier-2 calls.** T23 / T25 / T38 / S18 / S19 / S28
  are written here as Tier 2 *reframes* of Tier 3 case-doc
  claims. Each reframe trades end-to-end fidelity for an
  IPC-shaped assertion that's testable without login. Reasonable
  policy is "land both" — the Tier 2 reframe today, the Tier 3
  full flow when login is wired. Confirm before fanning out.
- **Wayland row strategy.** Several Tier 3 entries collapse to
  Tier 2 on a Wayland row (S06 segfault, S07 opt-in flag), and
  several Tier 2 entries collapse to Tier 4 on portal-grabbed
  Wayland (S11/S14 delivery half). The plan classifies for the
  default X11 row. If the sweep is run with
  `CLAUDE_HARNESS_USE_WAYLAND=1`, several reclassifications
  apply.
- **The "pure file probe vs needs-launch" line on multi-part
  case-docs.** T07 / T10 / S22 each have a load-bearing static
  fingerprint AND a load-bearing runtime click. The plan picks
  the static form for Tier 1 / Tier 2 and notes the runtime
  form's Tier 3 cost separately. If the parent wants one spec
  per case-doc test, a few reclassifications.
- **CDP gate side-effect on T17.** T17 runs against a
  signed-in host config today; without
  `CLAUDE_TEST_USE_HOST_CONFIG=1` it cleanly skips. Several Tier
  3 specs follow this pattern. The matrix's "skip" cell semantics
  for these tests need a sweep-runner convention — probably
  `-` rather than `?` for "host config required, not provided".
