# Functional Test Cases

Test specifications grouped by feature surface. For live status, see [`../matrix.md`](../matrix.md). For sweep workflow, see [`../runbook.md`](../runbook.md). For the UI element inventory, see [`../ui/`](../ui/).

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
```

The Steps and Diagnostics fields are written so they can later become script entry points without a rewrite.
