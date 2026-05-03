# claude.ai UI Map

*Last updated: 2026-05-02*

This file is the index from "UI surface" → "test-harness abstraction." It
answers: *which renderer surface does each Layer-2 helper cover, and where
are the gaps?* For human-readable behavior and visual specs of each surface
(what each button looks like, what each menu does), see [`ui/`](./ui/).
For the architectural rationale and growth strategy of the wrapper, see
[`claudeai-ui-mapping-plan.md`](./claudeai-ui-mapping-plan.md).

A `✓` marker means the helper exists today, with a `file:line` reference
into [`tools/test-harness/src/lib/claudeai.ts`](../../tools/test-harness/src/lib/claudeai.ts).
A `TODO` marker is a planned helper — when a third test needs the same
shape, promote it from inline `evalInRenderer` to a top-level helper or
page-object method (see plan Phase 3).

## Top-level routes

- `/new` — chat composer page (default landing for signed-in users)
- `/chat/<uuid>` — open chat session
- `/epitaxy` — Code tab landing
- `/projects/<id>` — project view
- `/login`, `/auth/*` — pre-login routes (test harness skips here)

The Code df-pill click does **not** change the URL — the router rerenders
the tab body inline. Helpers must poll for body-mount signals (e.g. a
compact pill rendering) rather than waiting on navigation.

## Surfaces by tab

### Chat (df-pill "Chat", route /new)

UI reference: [`ui/prompt-area.md`](./ui/prompt-area.md),
[`ui/window-chrome-and-tabs.md`](./ui/window-chrome-and-tabs.md).

- df-pill activation — `lib/claudeai.ts:activateTab` (:44) ✓
- Composer textarea — TODO `ChatTab.composer()`
- "+" submenu (Add files / Add to project / Skills / Connectors / ...)
  — TODO `ChatTab.openAttachMenu()`
- Slash menu (triggered by typing `/`) — TODO `ChatTab.openSlashMenu()`
- Model picker — TODO `ChatTab.openModelPicker()`
- Permission mode picker — TODO `ChatTab.openPermissionPicker()`
- Effort picker — TODO
- Send button — TODO `ChatTab.send()`
- Stop button (replaces Send while responding) — TODO `ChatTab.stop()`
- Attachment chip / drag-drop overlay — TODO
- Usage ring — TODO

### Cowork (df-pill "Cowork")

UI reference: see ghost-icon row in
[`ui/window-chrome-and-tabs.md`](./ui/window-chrome-and-tabs.md). No
dedicated surface doc yet — the ghost icon is the canonical "topbar shim
alive" indicator and the tab body itself is largely undocumented at the
time of writing.

- df-pill activation — `lib/claudeai.ts:activateTab` (:44) ✓
- Workspace list — TODO `CoworkTab.listWorkspaces()`
- Environment switcher — TODO `CoworkTab.switchEnvironment()`
- Dispatch state indicator — TODO

### Code (df-pill "Code", route /epitaxy)

UI reference: [`ui/code-tab-panes.md`](./ui/code-tab-panes.md),
[`ui/sidebar.md`](./ui/sidebar.md),
[`ui/prompt-area.md`](./ui/prompt-area.md).

- df-pill activation — `lib/claudeai.ts:activateTab` (:44) ✓
- Tab activation + body-mount wait — `lib/claudeai.ts:CodeTab.activate` (:285) ✓
- Env pill (Local / Cloud / SSH) — `lib/claudeai.ts:CodeTab.openEnvPill` (:317) ✓
- Local env selection — `lib/claudeai.ts:CodeTab.selectLocal` (:350) ✓
- Select-folder pill (rendered after Local) — used internally by
  `lib/claudeai.ts:CodeTab.openFolderPicker` (:368) ✓
- Folder picker dialog (full chain) — `lib/claudeai.ts:CodeTab.openFolderPicker` (:368) ✓
- Folder picker dialog mock + assertion — `lib/claudeai.ts:installOpenDialogMock`
  (:70) ✓ + `lib/claudeai.ts:getOpenDialogCalls` (:113) ✓
- File tree (left panel) — TODO `CodeTab.fileTree()`
- Editor pane — TODO `CodeTab.editor()`
- Diff pane — TODO `CodeTab.openDiff()`
- Preview pane — TODO `CodeTab.openPreview()`
- Integrated terminal — TODO `CodeTab.openTerminal()`
- Tasks / subagent / plan panes — TODO
- Side-chat — TODO `CodeTab.openSideChat()`
- Recent-folder selection (radio in Select-folder menu) — TODO

## Surfaces independent of tab

### Sidebar

UI reference: [`ui/sidebar.md`](./ui/sidebar.md).

- Search overlay (topbar Search icon) — TODO `SidebarNav.search()`
- Recent conversations — TODO `SidebarNav.openRecent(idx | uuid)`
- "More options" per row — TODO `SidebarNav.rowContextMenu(uuid)`
- "+ New session" button — TODO `SidebarNav.newSession()`
- Routines link — TODO `SidebarNav.openRoutines()`
- Customize link — TODO `SidebarNav.openCustomize()`
- Status / project / environment filters — TODO
- Group-by control — TODO
- Collapse toggle — TODO

### Window chrome / topbar (in-app hybrid)

UI reference: [`ui/window-chrome-and-tabs.md`](./ui/window-chrome-and-tabs.md).

- Hamburger menu — TODO `Topbar.openHamburger()`
- Sidebar toggle — TODO `Topbar.toggleSidebar()`
- Back / forward arrows — TODO
- Cowork ghost icon (topbar-alive sentinel) — TODO `Topbar.coworkGhostPresent()`

### Native dialogs

- File / folder picker mock — `lib/claudeai.ts:installOpenDialogMock` (:70) ✓
- File / folder picker call inspection — `lib/claudeai.ts:getOpenDialogCalls` (:113) ✓
- Message box / confirm — TODO `installShowMessageBoxMock`
- Save dialog — TODO `installShowSaveDialogMock`

### Menus / popovers

- Compact-pill discovery — `lib/claudeai.ts:findCompactPills` (:130) ✓
- Compact-pill open + menu read — `lib/claudeai.ts:openPill` (:162) ✓
- Click any menuitem by text regex — `lib/claudeai.ts:clickMenuItem` (:210) ✓
- Dismiss popover via Escape — `lib/claudeai.ts:pressEscape` (:256) ✓
- Modal dismiss / confirm — TODO `Modal.dismiss()` / `Modal.confirm()`
- Toast / status — TODO `waitForToast(regex)`
- Right-click context menus (sidebar row, etc.) — TODO `openContextMenu(target)`

### Settings

UI reference: [`ui/settings.md`](./ui/settings.md).

- Open Settings — TODO `Settings.open()`
- Hotkey rebind — TODO `Settings.rebindHotkey(action, chord)`
- Theme toggle — TODO `Settings.setTheme('dark' | 'light' | 'auto')`
- Account / sign-out — TODO `Settings.signOut()`
- Computer-use toggle (absent on Linux per S22) — TODO
- Keep-computer-awake toggle (per S20) — TODO

### Routines page

UI reference: [`ui/routines-page.md`](./ui/routines-page.md).

- Routines list — TODO `RoutinesPage.list()`
- New-routine form — TODO `RoutinesPage.create(spec)`
- Routine detail page — TODO `RoutinesPage.open(id)`

### Connectors and plugins

UI reference: [`ui/connectors-and-plugins.md`](./ui/connectors-and-plugins.md).

- Connector picker — TODO `ConnectorPicker.open()`
- Connector list / status — TODO
- Plugin browser — TODO `PluginBrowser.open()`
- Plugin install (Anthropic & Partners flow) — TODO `PluginBrowser.install(slug)`
- Plugin manager (installed list) — TODO

### Quick Entry popup

UI reference: [`ui/quick-entry.md`](./ui/quick-entry.md). Note: the
Quick Entry harness lives in [`quickentry.ts`](../../tools/test-harness/src/lib/quickentry.ts),
not `claudeai.ts`. The `installOpenDialogMock` shape here intentionally
mirrors `QuickEntry.installInterceptor` (quickentry.ts:86) — keep them
aligned when extending either.

- Open Quick Entry (global shortcut) — covered by `lib/quickentry.ts`
- Compose + send — covered by `lib/quickentry.ts`
- Closeout cases (S29–S37) — covered by `lib/quickentry.ts`

### Notifications

UI reference: [`ui/notifications.md`](./ui/notifications.md). libnotify
rendering is environmental — likely stays a manual checklist rather than
a renderer-side helper. No `claudeai.ts` coverage planned.

### Tray

UI reference: [`ui/tray.md`](./ui/tray.md). Tray is owned by the main
process / native bindings, not the renderer DOM — outside the scope of
`claudeai.ts`. Covered by separate tests (T03, S08).

## Atoms inventory

Stable structural patterns the lib already anchors on. See the
discovery comment at the top of
[`tools/test-harness/src/lib/claudeai.ts`](../../tools/test-harness/src/lib/claudeai.ts)
for why each is shape-matched rather than class-matched.

| Atom | Fingerprint | Helper |
|---|---|---|
| df-pill | `button[aria-label][class*="df-pill"]` | `activateTab(name)` (:44) |
| compact-pill | `button[aria-haspopup=menu] > span.truncate.max-w-[*]` | `findCompactPills` (:130), `openPill` (:162) |
| menu / menuitem | `[role=menu] [role=menuitem*]` | `clickMenuItem(regex)` (:210) |
| Escape dismiss | `document.dispatchEvent(KeyboardEvent('keydown', Escape))` | `pressEscape` (:256) |
| Electron `dialog.showOpenDialog` | main-process IPC | `installOpenDialogMock` (:70), `getOpenDialogCalls` (:113) |

Atoms not yet abstracted (when a third test needs the same shape,
promote to a top-level helper):

| Atom | Probable fingerprint | Status |
|---|---|---|
| modal | `[role=dialog]` | not seen yet |
| toast | `[role=status][aria-live]` | not seen yet |
| sidebar nav row | `[class*="df-row"] [aria-label]` | seen, not abstracted |
| chat composer | textarea / contenteditable in composer container | not abstracted |
| right-click context menu | `[role=menu]` triggered by `contextmenu` event | not abstracted |
| Electron `dialog.showMessageBox` | main-process IPC | not abstracted |
| Electron `dialog.showSaveDialog` | main-process IPC | not abstracted |
| settings panel section | route-anchored container in Settings tab | not abstracted |

## See also

- [`claudeai-ui-mapping-plan.md`](./claudeai-ui-mapping-plan.md) —
  governing plan and phase rollout
- [`automation.md`](./automation.md) — harness architecture and the
  SIGUSR1 / runtime-attach pattern
- [`ui/`](./ui/) — per-surface visual / behavior specs
- [`cases/`](./cases/) — functional test specs (T## / S##)
