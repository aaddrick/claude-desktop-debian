# Functional Test Cases

Test specifications grouped by feature surface. For live status, see [`../matrix.md`](../matrix.md). For sweep workflow, see [`../runbook.md`](../runbook.md).

## Files

| File | Surfaces covered | Tests |
|------|------------------|-------|
| [`launch.md`](./launch.md) | App startup, doctor, package detection, multi-instance | T01, T02, T13, T14 |
| [`tray-and-window-chrome.md`](./tray-and-window-chrome.md) | Tray icon, window decorations, hybrid topbar, hide-to-tray | T03, T04, T07, T08, S08, S13 |
| [`shortcuts-and-input.md`](./shortcuts-and-input.md) | URL handler, Quick Entry, global shortcuts | T05, T06, S06, S07, S09, S10, S11, S12, S14, S29, S30, S31, S32, S33, S34, S35, S36, S37 |
| [`code-tab-foundations.md`](./code-tab-foundations.md) | Sign-in, Code tab load, folder picker, drag-drop, terminal, file pane | T15, T16, T17, T18, T19, T20 |
| [`code-tab-workflow.md`](./code-tab-workflow.md) | Preview, PR monitor, worktrees, auto-archive, side chat, slash menu | T21, T22, T29, T30, T31, T32 |
| [`code-tab-handoff.md`](./code-tab-handoff.md) | Notifications, external editor, file manager, connector OAuth, IDE handoff | T23, T24, T25, T34, T38, T39 |
| [`routines.md`](./routines.md) | Scheduled tasks, catch-up runs, suspend inhibit, config dir | T26, T27, T28, S19, S20, S21 |
| [`extensibility.md`](./extensibility.md) | Plugins, MCP, hooks, CLAUDE.md memory, worktree storage | T11, T33, T35, T36, T37, S27, S28 |
| [`distribution.md`](./distribution.md) | DEB, RPM, AppImage, dependency pulls, auto-update | S01, S02, S03, S04, S05, S15, S16, S26 |
| [`platform-integration.md`](./platform-integration.md) | Autostart, Cowork, WebGL, PATH inheritance, Computer Use, Dispatch | T09, T10, T12, S17, S18, S22, S23, S24, S25 |

## Standard test body

Every test in this directory follows this structure:

```markdown
### T## — Title

**Severity:** Smoke | Critical | Should | Could
**Surface:** human-readable surface tag (e.g. "Code tab → Environment")
**Applies to:** All | <subset of rows>
**Issues:** linked issue/PR list, or `—`

**Steps:**
1. ...
2. ...

**Expected:** what should happen.

**Diagnostics on failure:** which captures to attach when filing. See [`../runbook.md#diagnostic-capture`](../runbook.md#diagnostic-capture).

**References:** docs links, learnings, related issues.

**Code anchors:** `<file>:<line>` pointers to the upstream code or
wrapper script that backs the load-bearing claim above. Added during
the grounding sweep — see "Anchor scope" for guidance on where
anchors can and can't land.

**Inventory anchor:** (optional) `<element-id>` from
[`../ui-inventory.json`](../ui-inventory.json) — only if the surface
shows up in the v7 walker's idle capture. For surfaces inside modals
or popups, append a sentence noting which click-chain opens them so
the next inventory regeneration can grab them.
```

The Steps and Diagnostics fields are written so they can later become
script entry points without a rewrite.

### Anchor scope

Where the load-bearing claim lives determines where the anchor goes:

- **Upstream code** — any file under
  `build-reference/app-extracted/.vite/build/` (most often `index.js`,
  the main process). Use `index.js:N` style anchors.
- **Our wrapper code** — `scripts/launcher-common.sh`, `scripts/doctor.sh`,
  `scripts/patches/*.sh`, `scripts/frame-fix-wrapper.js`,
  `scripts/wco-shim.js`. Use `<repo-relative-path>:N` style anchors.
- **Server-rendered (claude.ai SPA)** — anchorable only via the v7
  walker inventory (`docs/testing/ui-inventory.json`) or a runtime
  capture from `tools/test-harness/grounding-probe.ts`. Idle-state
  inventory misses contextual surfaces (modals, popups, slash menus,
  context menus, side panels) — note that explicitly.
- **Upstream `claude` CLI binary** — out of scope for this matrix
  (e.g. T39 `/desktop` is a CLI slash-command, not in the Electron
  asar). Mark as Ambiguous and link to a separate CLI matrix if one
  exists.

If a claim spans multiple scopes (a wrapper script triggering
upstream behavior, e.g. T01's launcher-log + main-window-opens),
list all the anchors. The whole point is making the next sweep
faster — over-anchoring is fine, missing anchors is not.

### Drift markers

When a sweep finds upstream behavior no longer matches the case:

- **Edited Steps/Expected** — fix the case in place, mention what
  changed in the commit message. The case is the spec.
- **Missing in build X.Y.Z** — prepend a blockquote under the test
  heading: `> **⚠ Missing in build 1.5354.0** — <one-line note>.
  Re-verify after next upstream bump.` Use when the feature isn't
  in the build at all (deprecated, behind unset flag, never shipped).
- **Ambiguous** — don't edit; flag in the sweep report. Use when
  the load-bearing claim could be one of several candidate code
  paths and static analysis can't disambiguate.
