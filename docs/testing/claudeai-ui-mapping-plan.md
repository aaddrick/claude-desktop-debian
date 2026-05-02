# claude.ai UI Mapping Plan

This is an executable plan for systematically mapping claude.ai's
renderer UI into reusable test-harness abstractions. It can be picked
up by a fresh session — start at "Phase 1" and walk down.

## Where we are

The harness already has one worked example: `tools/test-harness/src/lib/claudeai.ts`
exports a `CodeTab` class plus atom helpers (`activateTab`,
`installOpenDialogMock`, `findCompactPills`, `openPill`, `clickMenuItem`,
`pressEscape`). `T17_folder_picker.spec.ts` is its only consumer
today — drives the chain `Code df-pill → env pill → Local → Select
folder → Open folder` and asserts `dialog.showOpenDialog` fires.

Discovery evidence captured by `tools/test-harness/probe.ts` (run
against a live debugger on port 9229):

- df-pill is a stable atom — exactly 3 instances on Code-tab page
  (`Chat`, `Cowork`, `Code`), all with `class*="df-pill"` and
  matching `aria-label`.
- compact-pill is a stable atom — `button[aria-haspopup=menu]` with
  a `span.truncate.max-w-[Npx]` child. Env pill uses 200px,
  Select-folder pill uses 160px. Same Tailwind class signature; we
  anchor on structure, not classes.
- 80 `button[aria-haspopup=menu]` total on a Code-tab page; only the
  2 with the truncate fingerprint are pills, the other 78 are sidebar
  "More options" buttons.

Pattern proven: discovery-by-shape in the lib layer, page-object
classes per major UI surface, specs use the lib. This doc covers
how to extend that pattern across the rest of claude.ai.

## Strategy: three layers

**Layer 1 — atoms.** Generic helpers around stable structural
patterns. Live in `lib/claudeai.ts`. Built once, reused everywhere.
Examples already there: compact-pill, df-pill, menu, dialog mock.

**Layer 2 — page objects.** Domain classes per major UI surface
(CodeTab, ChatTab, Settings, etc.). Compose atoms. Built per test
demand — premature otherwise. CodeTab is the template.

**Layer 3 — discovery tooling.** Standalone scripts that connect to
a running debugger and let humans + agents explore the renderer.
`probe.ts` is the seed; this doc grows it into a small CLI.

The thing to avoid: comprehensively mapping the UI upfront. Even
with a recording tool, that burns time on surfaces no test will
exercise for months. Lazy + bookmark-the-shape wins.

## Phase 1 — Tooling foundation

**Goal:** turn `probe.ts` into a proper exploration CLI under
`tools/test-harness/explore/`, with snapshot + diff capability that
catches UI drift before tests do.

**Deliverables:**

- `tools/test-harness/explore/explore.ts` — entry point with
  subcommands.
- `tools/test-harness/explore/snapshot.ts` — capture renderer state.
- `tools/test-harness/explore/diff.ts` — compare two snapshots.
- `tools/test-harness/explore/find.ts` — search for elements.
- `docs/testing/ui-snapshots/` — directory for captured snapshots
  (gitignore the file contents but commit the directory + a README).
- `tools/test-harness/package.json` — add scripts:
  `npm run explore`, `npm run explore:snapshot <name>`, etc.

**Subcommand spec:**

```
npx tsx explore/explore.ts                  # full snapshot to stdout
npx tsx explore/explore.ts pills            # df-pills + compact-pills + state
npx tsx explore/explore.ts menu             # currently-open menu structure
npx tsx explore/explore.ts snapshot <name>  # write to docs/testing/ui-snapshots/<name>.json
npx tsx explore/explore.ts diff <a> <b>     # diff two snapshots — flags renamed/removed
npx tsx explore/explore.ts find <regex>     # search renderer for matching text/aria-label
```

Snapshot shape (per file):

```json
{
  "capturedAt": "2026-05-02T17:30:00Z",
  "claudeAiUrl": "https://claude.ai/epitaxy",
  "appVersion": "1.1.7714",
  "dfPills": [...],
  "compactPills": [...],
  "ariaLabeledButtons": [...],
  "openMenu": null,
  "modals": [...]
}
```

`diff` should flag: removed elements (selector → no match), changed
text/aria-label, new elements (informational, not a failure). Output
human-readable + a `--json` flag for machine consumption.

**How to dispatch this work:**

Single agent, `general-purpose`. Brief:

> Build the explore CLI under `tools/test-harness/explore/`. Read
> `tools/test-harness/probe.ts` as the seed implementation. Match the
> existing project style (tabs, multi-line `//` why-blocks, terse).
> Reuse `src/lib/inspector.ts` (`InspectorClient.connect(9229)`) for
> the debugger connection. Subcommands as specified in
> `docs/testing/claudeai-ui-mapping-plan.md` Phase 1. Do not delete
> probe.ts — leave it as a one-off; it can be removed in a follow-up.
> Typecheck with `npx tsc --noEmit` (no test runs). Add npm scripts
> to `package.json`. Add a thin README in
> `docs/testing/ui-snapshots/README.md` explaining how to capture +
> compare snapshots.

**Exit criteria:**

- `npx tsx explore/explore.ts pills` against a running debugger lists
  the 3 df-pills and 2 compact-pills (or whatever's on screen).
- `explore/explore.ts snapshot baseline-code-tab` writes a JSON file.
- `explore/explore.ts diff baseline-code-tab baseline-code-tab`
  reports zero diffs.
- Typecheck green.

## Phase 2 — UI map document

**Goal:** maintain a living markdown index of every reachable UI
surface, the navigation path to reach it, and which Layer-2 class
covers it (or `TODO` if none yet).

**Deliverable:** `docs/testing/claudeai-ui-map.md`.

**Initial content** (populate from what's known today, leave gaps
marked TODO):

```markdown
# claude.ai UI Map

Source of truth for "where does each UI surface live, and which
test-harness abstraction covers it." Update as new abstractions are
added.

## Top-level routes

- `/new` — chat composer page (default landing for signed-in users)
- `/chat/<uuid>` — open chat session
- `/epitaxy` — Code tab landing
- `/projects/<id>` — project view
- `/login`, `/auth/*` — pre-login routes (test harness skips here)

## Surfaces by tab

### Chat (df-pill "Chat", route /new)
- Composer textarea — TODO `ChatTab.composer()`
- "+" submenu (Add files / Add to project / Skills / Connectors / ...)
  — TODO `ChatTab.openAttachMenu()`
- Model selector — TODO
- Stop / regenerate — TODO

### Cowork (df-pill "Cowork")
- Workspace list — TODO
- Environment switcher — TODO

### Code (df-pill "Code", route /epitaxy)
- Env pill (Local / Cloud / SSH) — `lib/claudeai.ts:CodeTab.openEnvPill()` ✓
- Select folder pill — `lib/claudeai.ts:CodeTab` (used internally by
  `openFolderPicker`) ✓
- Folder picker dialog — `lib/claudeai.ts:installOpenDialogMock` ✓
- File tree (left panel) — TODO
- Editor pane — TODO

## Surfaces independent of tab

### Sidebar
- Search — TODO `SidebarNav.search()`
- Recent conversations — TODO `SidebarNav.openRecent(idx | uuid)`
- "More options" per row — TODO
- New session button — TODO

### Native dialogs
- File / folder picker — `lib/claudeai.ts:installOpenDialogMock` ✓
- Message box / confirm — TODO `installShowMessageBoxMock`
- Save dialog — TODO `installShowSaveDialogMock`

### Menus / popovers
- Generic menu open + click — `lib/claudeai.ts:openPill` /
  `clickMenuItem` ✓
- Modal — TODO `Modal.dismiss() / Modal.confirm()`
- Toast / status — TODO `waitForToast(regex)`

### Settings
- Hotkey rebind — TODO
- Theme toggle — TODO
- Account / sign-out — TODO

## Atoms inventory

Stable structural patterns the lib already anchors on:

| Atom | Fingerprint | Helper |
|---|---|---|
| df-pill | `button[aria-label][class*="df-pill"]` | `activateTab(name)` |
| compact-pill | `button[aria-haspopup=menu] > span.truncate.max-w-[*]` | `findCompactPills`, `openPill` |
| menu / menuitem | `[role=menu] [role=menuitem*]` | `clickMenuItem(regex)` |

Atoms not yet abstracted (when a third test needs the same shape,
promote to a top-level helper):

| Atom | Probable fingerprint | Status |
|---|---|---|
| modal | `[role=dialog]` | not seen yet |
| toast | `[role=status][aria-live]` | not seen yet |
| sidebar nav row | `[class*="df-row"] [aria-label]` | seen, not abstracted |
| chat composer | textarea/contenteditable in composer container | not abstracted |
```

**How to dispatch this work:**

A claude-code-guide or general-purpose agent can write the initial
file. Single message:

> Create `docs/testing/claudeai-ui-map.md` matching the structure in
> `docs/testing/claudeai-ui-mapping-plan.md` Phase 2. Pull TODO
> entries from the planned ChatTab/Settings/etc. surfaces. Mark
> existing helpers from `tools/test-harness/src/lib/claudeai.ts`
> with ✓ and the file:line. Don't run any tests.

**Exit criteria:**

- File exists with all top-level routes documented.
- Every existing `lib/claudeai.ts` export is referenced ✓.
- Every planned surface from this plan has a TODO entry.

## Phase 3 — Page objects per test demand

**Goal:** add new Layer-2 classes (ChatTab, Settings, etc.) when the
first test needs them. Don't speculate.

**Template:** `tools/test-harness/src/lib/claudeai.ts:CodeTab`. Match
its shape:

- Instance class taking `inspector: InspectorClient` in constructor.
- Public methods are either single-step (`openEnvPill`,
  `selectLocal`) or multi-step convenience (`openFolderPicker`).
- Discovery by shape, not Tailwind classes.
- Multi-line `//` why-block at top of class explaining what UI
  surface it covers and the discovery strategy.
- Failures throw with enough context for the spec to attach to
  `testInfo.attach()`.

**Workflow per new page object:**

1. Identify which test motivates the new class. Don't build
   speculatively.
2. Run `explore.ts snapshot <name>` against a live debugger on the
   target UI surface. Commit the snapshot under
   `docs/testing/ui-snapshots/`.
3. Inspect the snapshot — pick stable structural fingerprints, not
   Tailwind classes.
4. Write the class in `lib/claudeai.ts`. If the file gets large
   (>1500 lines), split per-tab into separate files
   (`lib/claudeai/code-tab.ts`, `lib/claudeai/chat-tab.ts`, with
   `lib/claudeai.ts` as the barrel).
5. Update `docs/testing/claudeai-ui-map.md` — replace the TODO with
   the class name + ✓.
6. Add the spec that uses it.
7. Run typecheck. Don't run tests until everything's wired.

**Don't pull out yet:**

- Single-consumer methods. If only one spec calls
  `Settings.toggleDarkMode()`, the inline implementation is fine.
  Promote to its own method when a second consumer arrives.
- Generic primitives that haven't repeated three times. Three is
  the threshold for "this is an atom" — two could still be
  coincidence.

## Phase 4 — Atom promotion

**Goal:** keep the atom layer (Layer 1) growing in step with the
page-object layer (Layer 2).

**Rule:** when a discovery pattern (CSS selector + JS predicate)
appears in 3 different page objects, promote it to a top-level
helper in `lib/claudeai.ts`.

**Examples of likely promotions in the next 6 months:**

- `findModal()` / `dismissModal()` — every page object that opens a
  confirmation modal will need this.
- `waitForToast(regex, timeout)` — error and success toasts are
  pervasive.
- `installShowMessageBoxMock(inspector, response)` — for native
  confirm dialogs.
- `clickNavRow(label)` — sidebar interactions.

**Process:**

1. Notice the third occurrence of the same pattern.
2. Move the inline implementation up to a top-level export.
3. Replace the three call sites with calls to the new export.
4. Add an entry to the atoms inventory in `claudeai-ui-map.md`.

## Phase 5 — Drift detection

**Goal:** catch UI changes that break selectors *before* a sweep
fails — fast, automatic, runs on every harness invocation.

**Deliverable:** `tools/test-harness/src/runners/H05_ui_drift_check.spec.ts`.

**Design:**

- Loads each `*.json` file from `docs/testing/ui-snapshots/`.
- Connects to a running app via the existing `launchClaude` +
  `attachInspector` flow (NOT against an externally-running app —
  the harness must be self-contained).
- For each snapshot, navigates to the captured URL (if not already
  there), then asserts each captured selector still resolves to an
  element with the same text/aria-label.
- Failures are *attachments*, not full failures — the spec passes
  if ≥80% of snapshots match, surfaces the diffs as warnings. Hard
  threshold can be tightened later. Goal is "tell me what drifted,"
  not "block CI on every minor renderer change."

**How to dispatch:**

Single agent, after Phases 1–2 are done. Brief:

> Create `tools/test-harness/src/runners/H05_ui_drift_check.spec.ts`
> per the design in `docs/testing/claudeai-ui-mapping-plan.md`
> Phase 5. Read each `*.json` under `docs/testing/ui-snapshots/`,
> drive the renderer to the captured URL, assert each captured
> element selector still matches. Surface diffs via
> `testInfo.attach`. Pass if ≥80% match. Severity Should, surface
> "claude.ai UI drift detection". Typecheck only.

**Exit criteria:**

- Runs cleanly against current renderer state (all snapshots match).
- Returns ≤200ms per snapshot.
- Skip with a clear message when no signed-in host config available
  (most snapshots will be of post-login surfaces).

## Recommended order

1. **Phase 1 (tooling)** — ~2 hours, single agent. Foundation for
   everything else.
2. **Phase 2 (UI map doc)** — ~30 min, single agent. Cheap,
   self-documenting.
3. **Phase 3 (page objects)** — incremental, per test need.
4. **Phase 4 (atom promotion)** — opportunistic, no scheduled work.
5. **Phase 5 (drift detection)** — once Phase 1 is done and a few
   snapshots exist.

Phases 1 and 2 are independent and can run in parallel.

## Today's starting state (reference)

What's already in place as of session-end:

```
tools/test-harness/
├── probe.ts                              # one-off probe (Phase 1 seed)
├── src/
│   ├── lib/
│   │   ├── claudeai.ts                   # CodeTab + atoms (NEW today)
│   │   ├── electron.ts                   # SIGINT cleanup, lastExitInfo
│   │   ├── inspector.ts                  # idempotent close()
│   │   ├── quickentry.ts                 # disk-read getStoredPosition
│   │   └── ... (unchanged)
│   └── runners/
│       ├── H01_cdp_gate_canary.spec.ts          # NEW
│       ├── H02_frame_fix_wrapper_present.spec.ts # NEW
│       ├── H03_patch_fingerprints.spec.ts        # NEW
│       ├── H04_cowork_daemon_lifecycle.spec.ts   # NEW
│       ├── T17_folder_picker.spec.ts             # refactored to lib/claudeai.ts
│       ├── _investigate_t17_urls.spec.ts         # one-off, can be deleted
│       └── ... (T01/T03/T04, S09/S12, S29-S37)
├── orchestrator/sweep.sh                  # multi-suite JUnit parser
└── playwright.config.ts                   # CI-gated retries + forbidOnly
```

**Pending cleanup** (covered in a final commit, not part of this plan):

- Delete `_investigate_t17_urls.spec.ts` — investigation served.
- Delete `probe.ts` once `explore/` lands and supersedes it.
- Update `tools/test-harness/README.md` Status table — T17 from
  "selector-tuning pending" to passing on KDE-W.

**Useful commands for a fresh session:**

```sh
cd /home/aaddrick/source/claude-desktop-debian/tools/test-harness

# Typecheck (must pass after every edit)
npx tsc --noEmit

# Run a single spec
ROW=KDE-W CLAUDE_TEST_USE_HOST_CONFIG=1 npx playwright test \
  src/runners/T17_folder_picker.spec.ts --reporter=list

# Full sweep
ROW=KDE-W CLAUDE_TEST_USE_HOST_CONFIG=1 ./orchestrator/sweep.sh

# Probe a running app (requires main process debugger enabled)
npx tsx probe.ts

# Kill stale instances before launch
pkill -9 -f claude-desktop; pkill -9 -f mount_claude
```

**Before starting Phase 1:** open Claude Desktop, enable
`Developer → Enable Main Process Debugger` from the menu, navigate
to a known UI state. Then run `npx tsx probe.ts` to confirm the
inspector is reachable on port 9229.
