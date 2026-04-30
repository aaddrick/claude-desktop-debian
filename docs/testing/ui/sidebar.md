# UI — Code Tab Sidebar

The sidebar lists Code-tab sessions, lets you filter, group, archive, and rename. Related functional tests: [T29](../cases/code-tab-workflow.md#t29--worktree-isolation), [T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge), [S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification).

## Top controls

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| **+ New session** button | Top of sidebar | Click opens a new session against the currently selected env. `Ctrl+N` shortcut equivalent | — |
| **Routines** link | Top of sidebar | Click opens the Routines page ([T26](../cases/routines.md#t26--routines-page-renders)) | — |
| **Customize** link | Top of sidebar | Click opens connectors / skills / plugins manager | — |
| Filter: status | Top of session list | Dropdown / tabs filter by Active / Archived / All | — |
| Filter: project | Top of session list | Dropdown filters by project (multi-select) | — |
| Filter: environment | Top of session list | Dropdown filters by Local / Remote / SSH / All | — |
| Group-by control | Top of session list | Toggle between flat list and grouped-by-project | — |

## Session row

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Session title | Row content | Shows session name (auto-generated or user-renamed) | Click row → switches to that session |
| Session status indicator | Left of title or as colored dot | Reflects state: idle, running, awaiting-approval, errored, archived | — |
| Project / branch label | Below title | Shows project folder name + branch | — |
| Diff stats badge (e.g. `+12 -1`) | Right of title | Visible when session has uncommitted changes | Click → opens diff view |
| **Dispatch** badge | Top-right of row | Visible on Dispatch-spawned sessions ([S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification)) | — |
| **Scheduled** badge | Top-right of row | Visible on scheduled-task-spawned sessions ([T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies)) | Sessions group under "Scheduled" header |
| Hover archive icon | Right side, on row hover | Click archives the session and removes its worktree | — |
| Right-click context menu | Right-click on row | Standard menu: Rename, Archive, Open in Files, Copy path | — |
| Active session highlight | Selected row | Visually distinct from inactive rows | — |

## Sidebar layout

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Sidebar resize handle | Right edge of sidebar | Drag to resize; double-click to reset width | — |
| Sidebar collapse toggle | Top of sidebar (hamburger or arrow) | Collapse to icons-only or hide entirely | Crosses with topbar hamburger |
| Scrollbar | Right edge when content exceeds height | Renders, drags work | Theme-aware |

## Cycling shortcuts

| Shortcut | Expected | Notes |
|----------|----------|-------|
| `Ctrl+Tab` | Cycle to next session | Per upstream docs |
| `Ctrl+Shift+Tab` | Cycle to previous session | Per upstream docs |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Same as above on macOS | N/A on Linux unless rebound |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Sidebar doesn't render | Code tab failed to load ([T16](../cases/code-tab-foundations.md#t16--code-tab-loads)) | Check DevTools console |
| Sessions appear but clicking does nothing | IPC between sidebar and session pane broken | Launcher log, DevTools console |
| Hover archive icon never appears | CSS hover state mis-applied; touch device might be assumed | Inspect element; check pointer events |
| Dispatch / Scheduled badges missing | Feature flag or state not reaching the renderer | Check session metadata in launcher log |
| Auto-archive doesn't fire | Session-archive logic bug ([T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge)) | Confirm setting enabled; check PR state via `gh pr view` |
