# UI Element Inventory

This directory holds per-surface UI checklists. Where [`../cases/`](../cases/) tests verify *behavior end-to-end*, files here verify *every UI element renders and responds* on Linux.

## Why a separate directory

A functional test like [T17 — Folder picker opens](../cases/code-tab-foundations.md#t17--folder-picker-opens) verifies the folder picker works. A UI checklist asks the smaller, more granular questions:

- Is the **Select folder** button visually present?
- Does its hover state render?
- Is the icon next to it the correct shape on a HiDPI screen?
- Does it tab-focus correctly?
- Does it have an accessible name (a11y)?

Functional tests catch "the feature broke." UI checklists catch "the feature works but looks wrong." Both matter on Linux because Electron under different DEs / display servers / GTK theme combinations produces visual artifacts that aren't behavioral failures.

## Layout

| File | Surface | Notes |
|------|---------|-------|
| [`window-chrome-and-tabs.md`](./window-chrome-and-tabs.md) | OS window frame + hybrid in-app topbar + Chat/Cowork/Code tabs | Crosses with [T04](../cases/tray-and-window-chrome.md#t04--window-decorations-draw), [T07](../cases/tray-and-window-chrome.md#t07--in-app-topbar-renders--clickable) |
| [`tray.md`](./tray.md) | System tray icon + menu + theme variants | Crosses with [T03](../cases/tray-and-window-chrome.md#t03--tray-icon-present), [S08](../cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update) |
| [`sidebar.md`](./sidebar.md) | Session sidebar in Code tab | Crosses with [T29](../cases/code-tab-workflow.md#t29--worktree-isolation), [T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge), [S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification) |
| [`prompt-area.md`](./prompt-area.md) | Code-tab prompt input area | Crosses with [T18](../cases/code-tab-foundations.md#t18--drag-and-drop-files-into-prompt), [T32](../cases/code-tab-workflow.md#t32--slash-command-menu) |
| [`code-tab-panes.md`](./code-tab-panes.md) | Diff, preview, terminal, file, tasks, subagent, plan, side-chat | Crosses with [T19](../cases/code-tab-foundations.md#t19--integrated-terminal), [T20](../cases/code-tab-foundations.md#t20--file-pane-opens-and-saves), [T21](../cases/code-tab-workflow.md#t21--dev-server-preview-pane), [T22](../cases/code-tab-workflow.md#t22--pr-monitoring-via-gh), [T31](../cases/code-tab-workflow.md#t31--side-chat-opens) |
| [`settings.md`](./settings.md) | All Settings pages | Crosses with [S20](../cases/routines.md#s20--keep-computer-awake-inhibits-idle-suspend), [S22](../cases/platform-integration.md#s22--computer-use-toggle-is-absent-or-visibly-disabled-on-linux), [T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge) |
| [`routines-page.md`](./routines-page.md) | Routines list + new-routine form + detail page | Crosses with [T26](../cases/routines.md#t26--routines-page-renders), [T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies) |
| [`connectors-and-plugins.md`](./connectors-and-plugins.md) | Connector picker, connector list, plugin browser, plugin manager | Crosses with [T11](../cases/extensibility.md#t11--plugin-install-anthropic--partners), [T33](../cases/extensibility.md#t33--plugin-browser), [T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip) |
| [`quick-entry.md`](./quick-entry.md) | Quick Entry popup window | Crosses with [T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused), [S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame) |
| [`notifications.md`](./notifications.md) | libnotify rendering for all notification sources | Crosses with [T23](../cases/code-tab-handoff.md#t23--desktop-notifications-fire), [T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies), [S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification) |

## Standard checklist row

Each UI file uses tables of the form:

| Element | Selector / location | Expected | Notes |
|---------|---------------------|----------|-------|
| Close button | Top-right of titlebar | Renders, hover state visible, click hides to tray (see T08) | KDE-W: ✓ |

Columns:

- **Element** — human-readable name.
- **Selector / location** — DOM selector if known, otherwise plain-language pointer ("right-click menu, second item from top"). The selector column is what becomes a Playwright/CDP assertion when automation lands.
- **Expected** — what the user should see / what should happen on click. Concise.
- **Notes** — known issues, environment caveats, screenshot links.

## Sweep workflow

A UI sweep on a row:

1. Take a baseline screenshot of each surface (`scrot`, `gnome-screenshot`, `grim`, `flameshot`).
2. Walk each table top-to-bottom. For each row, look at the element, click/hover/tab to it, compare against Expected.
3. Mark anomalies in the **Notes** column or file an issue if the deviation is environment-specific.
4. Save screenshots of any failure to a dated folder; reference them inline.

UI rows don't have stable IDs (`T##` / `S##`) — they're append-only checkpoints. When something becomes a regression candidate worth tracking long-term, promote it to a functional test in [`../cases/`](../cases/).

## Automation roadmap

Each UI checklist row is a candidate Playwright (via [Electron driver](https://playwright.dev/docs/api/class-electron)) or `xdotool` assertion:

```typescript
// Playwright shape
await page.locator('[data-testid="close-button"]').click()
await expect(window).toBeHidden()
```

Or for pure visual diffing:

```bash
# scrot + perceptualdiff
scrot -u baseline.png
# ... interaction ...
scrot -u current.png
perceptualdiff baseline.png current.png
```

The structure here is intentionally diff-friendly: rows are stable, tables are append-only, selectors live in their own column.
