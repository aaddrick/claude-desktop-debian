# claude.ai UI Inventory Reconciliation

*Generated against [`ui-inventory.json`](./ui-inventory.json) v6 (captured 2026-05-03, app version 1.5354.0, 383 entries).*
*Reconciled 2026-05-02.*

This file diffs the human-written claims in [`ui/`](./ui/) against the
machine-captured ground-truth in [`ui-inventory.json`](./ui-inventory.json).

It is one-shot output meant to drive human cleanup of `ui/*.md` — re-run
the reconciliation script (TODO: not yet built) after major walker passes.

## Reading this document

Three categories of finding per surface:

- **In docs but not in renderer** — the doc names an element that has no
  corresponding inventory entry. Possible causes (don't read this as "doc
  is wrong"; the walker covers a subset of reality):
  - **OS / window-manager element** — title bar, close/min/max buttons,
    drop shadow, resize edges. These are drawn by the compositor, not by
    claude.ai's renderer; the walker can't see them.
  - **Out of renderer scope** — tray menu, libnotify notifications, IME
    composition popups, Quick Entry popup window. These are main-process
    or DE-level surfaces that don't exist in the claude.ai DOM.
  - **Walker coverage gap** — Settings overlay, dialogs, deep Code-tab
    panes (terminal, file pane, diff). The walker drilled some surfaces
    but not others; absence here is "not yet observed" not "not present."
  - **Account-state-dependent** — features that don't appear on this
    user's plan (e.g. SSH connections panel, managed-settings rows,
    specific Code-tab pane types).
  - **Speculative** — doc was written from upstream behavior, not from a
    Linux build. May not actually render.
- **In renderer but not in docs** — inventory captured an element that no
  doc row mentions. Either the doc is incomplete for that surface, or the
  element is tangential (search-results recency rows, instance-suffix
  duplicates with `#2`/`+5` markers).
- **Fingerprint potentially drifted** — doc and inventory agree on the
  element but the doc's selector hint disagrees with the inventory's
  `fingerprint.selector`. Most `ui/*.md` rows use prose ("Top-left of
  topbar") rather than CSS selectors, so this category is small.

Human triage is what closes any of these. Don't auto-edit `ui/*.md`.

## Summary

| Metric | Count |
|--------|-------|
| Inventory entries (total) | 383 |
| Inventory entries by kind | persistent 65 / structural 276 / menu 33 / instance 9 |
| Inventory entries marked `denylisted: true` | 9 (Send×4, Install×4, Remove×1) |
| `ui/*.md` files reconciled | 11 (10 surface files + README) |
| `ui/*.md` rows reconciled (rough — multi-element rows complicate the count) | ~210 element rows across all 10 surface files |
| Rows with confirmed inventory match | ~70 (~33%) |
| Rows flagged "in docs but not in renderer" | ~140 (~67%) — heavily skewed by OS-frame, tray, notifications, deep Code panes, Settings, Quick Entry being out-of-renderer or under-walked |
| Inventory entries with no `ui/*.md` mention | ~190 (~50%) — heavily skewed by per-conversation/per-skill/per-prompt-card structural rows that the docs treat as categories rather than enumerating |
| Doc rows with explicit selectors that drift from inventory | 0 verified — `ui/*.md` rows almost never carry CSS selectors |

Match counts are approximate. `ui/*.md` rows often describe categories
("Recent conversations," "Per-history-entry hover") that map to many
inventory entries; the inventory in turn enumerates structural elements
the docs intentionally don't list (every project skill button, every
search result option). The reconciliation is a triage signal, not a
metric.

## Per-surface breakdown

### `ui/window-chrome-and-tabs.md`

**Inventory surfaces likely covered:** none directly — OS window frame is
drawn by the compositor; the in-app topbar elements live under `root` as
`root.button.menu`, `root.button.collapse-sidebar`, `root.button.search`,
`root.button.back`, `root.button.forward`. The "tab strip" maps to
`root.button.chat`, `root.button.cowork`, `root.button.code`.

**Doc rows reconciled:** ~22

#### In docs but not in renderer

| Doc element | Reason class |
|-------------|--------------|
| Title bar | OS / window-manager |
| Close button (X) | OS / window-manager |
| Minimize button | OS / window-manager |
| Maximize / restore button | OS / window-manager |
| Resize edges | OS / window-manager |
| Window menu (right-click titlebar) | OS / window-manager |
| Cowork ghost icon | Walker captures `root.button.cowork` (the tab) but not the ghost-icon visual within the topbar shim |
| Drag region (gaps between buttons) | Renders as empty space — not an actionable element |
| Active tab indicator | Visual styling, not an actionable element |
| Tab badges (unread / Dispatch) | None observed; user state at capture had no badges |
| About dialog | Walker did not surface a dialog; About is reachable only from app/tray menu, both out of renderer scope |
| App menu (macOS-style) | Doc itself notes this is N/A on Linux |
| Update prompt | Conditional, not present at capture |
| Crash report dialog | Conditional, not present at capture |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.menu` ("Menu", `aria-label="Menu"`) | This is the doc's "Hamburger menu" — renamed |
| `root.button.collapse-sidebar` ("Collapse sidebar") | Doc has "Sidebar toggle"; arguably the same |
| `root.button.search` ("Search") | Doc's "Search icon"; same |
| `root.button.back` / `root.button.forward` | Doc's back/forward arrows; same |
| `root.a.skip-to-content` ("Skip to content") | A11y skip link; not in doc |
| `root.button.new-chat-n` ("New chat⌘N") | Topbar new-chat button; not in doc |
| `root.button.pinned`, `root.button.recents`, `root.button.projects`, `root.button.artifacts`, `root.button.customize` | Sidebar nav buttons; doc covers some of these in `sidebar.md` not here |
| `root.button.awaaddrick-max` ("AWAaddrick·Max") | User/plan badge in topbar; not in doc |
| `root.button.get-apps-and-extensions` | Topbar shortcut to apps page; not in doc |
| `root.tab.write` / `root.tab.learn` / `root.tab.code` / `root.tab.from-calendar` / `root.tab.from-gmail` | Quick-prompt-template tabs in the prompt area; doc covers Write/Learn/Code as Chat/Cowork/Code tabs but the inventory's `root.tab.code` is distinct from `root.button.code` |

#### Fingerprint potentially drifted

None — doc rows for this surface use Location prose only.

#### Notable cross-cut

The doc's "Chat / Cowork / Code" tab strip maps cleanly to
`root.button.chat`, `root.button.cowork`, `root.button.code`. But the
inventory also has `root.tab.code` (a `[role="tab"]`, not a button) which
is a separate element — the prompt-area template strip — that the doc
conflates with the main Chat/Cowork/Code switcher. Worth a human note.

---

### `ui/tray.md`

**Inventory surfaces covered:** none — the tray is a main-process Electron
`Tray` object on the system SNI bus, not part of claude.ai's DOM.

**Doc rows reconciled:** ~17

#### In docs but not in renderer

Every row, by design. Categories:

- Tray icon (light / dark theme) — main-process `Tray.setImage()`
- Right-click menu items (Show/Hide, Quick Entry, Open at Login,
  Settings, About, Quit) — main-process `Menu.buildFromTemplate()`
- Left-click / double-click / middle-click behaviors — main-process
  event handlers
- Tooltip on hover, position, icon resolution, theme switch — SNI
  daemon and DE behavior

This entire file is correctly out of renderer scope; the walker is doing
the right thing by not capturing any of it.

#### In renderer but not in docs

N/A — surface mismatch.

---

### `ui/sidebar.md`

**Inventory surfaces likely covered:** `root` (sidebar lives in the root
chrome on claude.ai). Note: the doc opens "Code Tab Sidebar" but the
sidebar in the captured renderer is the global claude.ai sidebar, not a
Code-tab-specific one. The Code-tab-specific session list is captured
separately under `root.button.code.button.new-session-n` (60 entries).

**Doc rows reconciled:** ~18

#### In docs but not in renderer

| Doc element | Reason class |
|-------------|--------------|
| Filter: status / project / environment | Walker did not drill the filter dropdown |
| Group-by control | Same — within Code-tab session list |
| Session status indicator (idle/running/...) | Visual decoration on row, not an actionable element |
| Project / branch label | Same |
| Diff stats badge `+12 -1` | Conditional — no session at capture had pending diffs |
| Dispatch badge | Conditional — no Dispatch-spawned session at capture |
| Scheduled badge | Conditional — same |
| Hover archive icon | Hover-revealed; walker captures static state |
| Right-click context menu (Rename / Archive / etc.) | Walker does not synthesise right-clicks |
| Sidebar resize handle | Visual / draggable, not an aria-labeled element |
| Sidebar collapse toggle | Inventory has `root.button.collapse-sidebar` but doc treats it as a Code-tab element rather than chrome |
| Scrollbar | OS / theme-rendered |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` cycling | Keyboard shortcut, not a UI element |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.fine-tuning-diffusion-models-with-reinforcement-learning` | A pinned recent conversation — sidebar content |
| `root.button.more-options-for-fine-tuning-diffusion-models-with-reinforce` | Per-row menu trigger — doc mentions "right-click context menu" but inventory shows it's a discoverable button |
| `root.button.how-to-use-claude` + `root.button.more-options-for-how-to-use-claude` | Same pattern |
| `root.button.code.button.routines` | "Routines" link in Code-tab nav — doc's "Routines link" is here |
| `root.button.code.button.more-navigation-items` | Likely the doc's "Customize / Routines" expander — not enumerated |
| `root.button.code.button.filter` | The doc's "Filter: status" probably maps here |
| `root.button.code.button.appearance` | Not in doc |
| `root.button.code.button.show-5-more` | Pagination; not in doc |
| `root.button.code.button.open-session-*` (5 entries) | Each is a single session row in the Code-tab list — the doc's "Per-session row" category |

#### Fingerprint potentially drifted

None — doc rows for this surface use Location prose only.

---

### `ui/prompt-area.md`

**Inventory surfaces likely covered:** `root` (top-level prompt area
buttons), `root.button.add-files-connectors-and-more` (the `+` menu),
`root.button.model-opus-4-7-adaptive` (model picker), and several deep
sub-surfaces.

**Doc rows reconciled:** ~28

#### In docs but not in renderer

| Doc element | Reason class |
|-------------|--------------|
| Input field | The contenteditable / textarea itself isn't captured (no aria-label) |
| Placeholder text | Not an interactive element |
| Cursor caret / multi-line autosize / word wrap | Behavior, not element |
| Paste plain text / paste image | Behavior |
| `Enter` to send / `Shift+Enter` / `Esc` | Keyboard behavior |
| IME composition | Not a renderer element |
| Attachment button (left of input) | Not surfaced — possibly bundled into `root.button.add-files-connectors-and-more` |
| File-attached chip | Conditional — no attachment at capture |
| Multiple attachments / image preview / PDF preview | Conditional |
| Drag-drop overlay | Conditional, only renders during drag |
| `@filename` autocomplete | Conditional, only renders when typing `@` |
| `+` button | Likely IS the `root.button.add-files-connectors-and-more` button — see below |
| Slash menu (all rows: Built-in / Project skills / User skills / Plugin skills / filter / selection / `Esc`) | Walker did not type `/` to trigger the slash menu; no inventory entries |
| Effort picker (`Cmd+Shift+E`) | Possibly inside `root.button.code.button.opus-4-7-1m-extra-high` — uncertain |
| Stop button (replaces Send while responding) | Conditional — no in-flight response at capture |
| Usage ring | Possibly `root.button.code.button.usage-plan-11` ("Usage: plan 11%") |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.press-and-hold-to-record` ("Press and hold to record") | Voice / dictation button in prompt area — doc has no voice input row |
| `root.button.code.button.dictation-settings` | Dictation settings button |
| `root.button.code.button.transcript-view-mode` | Transcript view toggle in prompt area |
| `root.button.code.button.scroll-to-bottom` | Scroll-to-bottom affordance |
| `root.button.code.button.accept-edits` | Permission-mode-related quick action |
| `root.button.code.button.add` ("Add") | Likely the doc's `+` button, with a different label |
| `root.button.code.button.usage-plan-11` ("Usage: plan 11%") | Probably the doc's "Usage ring" |
| `root.button.code.button.opus-4-7-1m-extra-high` ("Opus 4.7 1M· Extra high") | Probably the doc's "Effort picker" |
| All `root.button.add-files-connectors-and-more.menuitem.*` entries (Add files or photos / Add to project / Skills / Connectors / Plugins / Research / Web search / Use style) | The `+` menu contents — doc has Slash commands / Skills / Connectors / Plugins / Add plugin; inventory surfaces additional items the doc misses (Add files or photos, Add to project, Web search, Use style) |
| `root.button.add-files-connectors-and-more.menuitem.use-style.*` (8 entries: Normal / Learning / Concise / Explanatory / Formal / Create & edit styles / Research mode) | Style picker is a whole sub-surface the doc doesn't mention |
| `root.button.model-opus-4-7-adaptive.menuitemradio.*` (Opus / Sonnet / Haiku / Adaptive thinking / More models) | Doc says "Sonnet, Opus, Haiku" — inventory adds Adaptive thinking + More models |

#### Fingerprint potentially drifted

| Doc claim | Inventory says |
|-----------|----------------|
| `+` button → opens menu of "Slash commands / Skills / Connectors / Plugins / Add plugin" | The corresponding inventory button is labeled "Add files, connectors, and more" with `aria-label="Add files, connectors, and more"`. Menu contents don't include "Slash commands" or "Add plugin" sub-entry — doc menu structure is partly speculative |

---

### `ui/code-tab-panes.md`

**Inventory surfaces likely covered:** `root.button.code` (23 entries),
`root.button.code.button.new-session-n` (60 entries) — but no per-pane
sub-surfaces (no diff pane, no terminal pane, no preview pane, no file
pane).

**Doc rows reconciled:** ~50

#### In docs but not in renderer

Almost every Code-tab pane row is missing from the inventory. The walker
landed in the Code-tab "New session" shell but did not open or drill any
of the panes. Categories:

| Pane | Doc rows missing | Reason |
|------|------------------|--------|
| Pane chrome (header, drag/resize handles, close button, Views menu) | 5 rows | Walker coverage gap — no pane was open |
| Diff pane | 9 rows (file list, diff content, line click, Cmd+Enter, Accept/Reject, Review code) | Walker coverage gap |
| Preview pane | 11 rows | Walker coverage gap |
| Terminal pane | 7 rows | Walker coverage gap (also: only renders for Local sessions) |
| File pane | 7 rows | Walker coverage gap |
| Tasks / subagent pane | 5 rows | Walker coverage gap |
| Side chat overlay | 3 rows (trigger / content / close) | `root.button.code.button.close-side-chat` IS captured — the close button — but content isn't drilled |
| CI status bar | 5 rows | Conditional — no PR open at capture |
| View modes (Normal/Verbose/Summary) | 3 rows | Possibly behind `root.button.code.button.transcript-view-mode` — single inventory entry vs. 3 doc rows |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.code.button.local` ("Local") | Environment switcher chip — not in doc |
| `root.button.code.button.select-folder` ("Select folder…") | Folder-picker entry — doc references this only via T17 cross-reference |
| `root.button.code.button.send` (and `#2`, both denylisted) | Send button — doc has it under prompt-area, not panes |
| `root.button.code.button.transcript-view-mode` | The doc's "Transcript view dropdown" — single inventory entry |
| `root.button.code.button.opus-4-7-1m-extra-high` | Model selector inside Code-tab session shell |
| `root.button.code.button.usage-plan-11` | Usage ring inside Code-tab session shell |
| `root.button.code.button.accept-edits` ("Accept edits") | Permission-mode quick action — not in doc |
| All 60 `root.button.code.button.new-session-n.button.open-session-*` and per-session entries | Doc covers the session list in `sidebar.md`, not here, so this isn't really a gap for `code-tab-panes.md` |

#### Fingerprint potentially drifted

None — doc is prose-only.

---

### `ui/settings.md`

**Inventory surfaces likely covered:** `root.button.settings` (only 1
entry — "Settings" button itself), `root.button.awaaddrick-max.menuitem.settingsctrl`
(the menu-item route to Settings, label "SettingsCtrl,").

**Doc rows reconciled:** ~28

#### In docs but not in renderer

The Settings page itself is essentially un-walked. Settings opens as an
overlay/modal which the walker treated as a single button rather than
drilling into. Every row in the doc beyond "Settings window opens" lacks
a matching inventory entry:

| Doc section | Rows missing | Reason |
|-------------|--------------|--------|
| Settings root (close button, sidebar nav) | 3 rows | Walker coverage gap |
| Desktop app → General (Computer use, Keep computer awake, Denied apps, Unhide apps, Theme picker) | 5 rows | Walker coverage gap; some rows account-state-dependent |
| Desktop app → Account (name/email, plan badge, Sign out) | 3 rows | Walker coverage gap |
| Claude Code (Worktree location, Branch prefix, Auto-archive toggle, Persist preview, Preview toggle, Bypass-permissions toggle, Auto mode availability) | 7 rows | Walker coverage gap |
| Connectors page (list, per-connector entry, Manage, Disconnect, Add connector) | 5 rows | Walker coverage gap; partially covered by the in-session connectors menu |
| SSH connections (list, Add SSH connection button, per-connection entry) | 3 rows | Walker coverage gap; account-state-dependent |
| Keyboard shortcuts (list, value, Reset, Quick Entry shortcut) | 4 rows | Walker coverage gap |
| Local environment editor (open, Add variable, Remove variable, Apply to dev servers) | 4 rows | Walker coverage gap; account-state-dependent |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.settings` ("Settings", `aria-label="Settings"`) | The button that opens Settings — confirmed in chrome |
| `root.button.awaaddrick-max.menuitem.settingsctrl` ("SettingsCtrl,") | Settings menu item under the user/plan menu — alternate path |

#### Fingerprint potentially drifted

None.

#### Walker coverage note

Settings is a known walker coverage gap (see preamble). This doc is
substantively un-reconciled until a Settings drill pass lands.

---

### `ui/routines-page.md`

**Inventory surfaces likely covered:** none directly. Routines are
reachable via `root.button.code.button.routines`, but the page itself
isn't drilled.

**Doc rows reconciled:** ~26

#### In docs but not in renderer

Every doc row except the "Routines page link" itself is unmatched — the
walker captured the entry point but did not open the Routines page.

| Doc section | Rows missing | Reason |
|-------------|--------------|--------|
| Routines list (header, New routine button, list, per-routine row, Run-now icon, Pause/resume, click row) | 7 rows | Walker coverage gap |
| New routine form Local (Name, Description, Instructions, permission-mode picker, model picker, Working folder, Worktree toggle, Schedule preset, Time picker, Day picker, Save, Cancel, Folder-trust prompt) | 13 rows | Walker coverage gap |
| New routine form Remote (Trigger type, Connectors picker, Network access controls) | 3 rows | Walker coverage gap; doc itself is partly speculative ("Per upstream docs") |
| Routine detail (Run now, Active/Paused toggle, Edit, Delete, Review history, hover tooltip, Show more, Always allowed, Revoke approval) | 9 rows | Walker coverage gap |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.code.button.routines` ("Routines") | The entry-point link — doc's "Routines page link" |

#### Fingerprint potentially drifted

None.

---

### `ui/connectors-and-plugins.md`

**Inventory surfaces likely covered:** `root.button.add-files-connectors-and-more.menuitem.connectors`
(the in-session connector picker, 5 entries), plus the deeper per-connector
sub-surfaces under `.connectors.menuitemcheckbox.gmail.*` (15 entries).
Plugin browser surfaces (`root.button.back.*`) cover Skills, Connectors,
Add plugin, Typescript lsp, Php lsp, Playwright, Connectors, etc.

**Doc rows reconciled:** ~24

#### In docs but not in renderer

| Doc element | Reason class |
|-------------|--------------|
| Connectors menu — "Per-connector row" with status indicator | Inventory has Gmail and Google Calendar but not status decorations |
| Empty state | Conditional — user has connectors configured |
| Connector catalog (modal body, per-connector tile with logo/description) | Walker coverage gap — the Add-connector flow opens a modal that wasn't drilled |
| OAuth in-app overlay | Conditional, not present at capture |
| Permission consent screen | External (provider's UI) |
| Callback completion | Behavior, not an element |
| Custom connector entry point | Walker coverage gap |
| Plugin browser modal (browser modal, marketplace selector, per-plugin tile, scope selector, install progress, success state, error state) | Walker captured plugin surfaces under `root.button.back.*` (Add plugin, Typescript lsp, Php lsp, Playwright) but not the modal anatomy |
| Manage plugins (installed list, per-plugin row, Enable toggle, Plugin skills sub-list) | Walker coverage gap — no Manage-plugins surface drilled |

#### In renderer but not in docs

| Inventory entry | Notes |
|-----------------|-------|
| `root.button.add-files-connectors-and-more.menuitem.connectors` ("Connectors", in-session menu) | Doc covers this — the in-session Connectors menu |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitemcheckbox.gmail` ("Gmail") | Per-connector row — doc "Per-connector row" category |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitemcheckbox.google-calendar` ("Google Calendar") | Per-connector row — same |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitem.manage-connectors` ("Manage connectors") | Doc's "Manage connectors entry" |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitem.add-connector` ("Add connector") | Doc has "Add connector button" in Settings; inventory shows it also exists in the in-session menu |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitem.tool-accessload-tools-when-needed` ("Tool accessLoad tools when needed") | Per-connector tool-access setting — not in doc |
| `root.button.back.a.skills` ("Skills") | Plugin browser — Skills tab |
| `root.button.back.a.connectors` / `root.button.back.a.connectors#2` (both "Connectors") | Plugin browser — Connectors tab (instance suffix `#2` indicates duplicate detection) |
| `root.button.back.button.add-plugin` ("Add plugin") | Plugin browser — Add plugin button |
| `root.button.back.a.typescript-lsp` / `root.button.back.a.php-lsp` / `root.button.back.a.playwright` | Installed plugins — doc treats this as "Manage plugins → Per-plugin row," walker captures the actual plugin names |
| `root.button.back.button.connect-your-appslet-claude-read-and-write-to-the-tools-you-` ("Connect your appsLet Claude read...") | Plugin browser landing pane CTA — not in doc |
| `root.button.back.a.create-new-skillsteach-claude-your-processes-team-norms-and-` ("Create new skillsTeach Claude your processes, team norms, and expertise.") | Skills-creation CTA — not in doc |
| `root.button.back.button.browse-pluginsadd-pre-built-knowledge-for-your-field` ("Browse pluginsAdd pre-built knowledge for your field.") | Browse-plugins CTA — not in doc |
| `root.button.add-files-connectors-and-more.menuitem.connectors.menuitemcheckbox.gmail.button.develop-storytelling-frameworks` and 9 similar `.option`/`.button` pairs | Connector-suggested prompt cards. Walker captured these as a side-effect of drilling Gmail — they aren't a doc-targeted UI element |

#### Fingerprint potentially drifted

| Doc claim | Inventory says |
|-----------|----------------|
| `+` → **Connectors** opens "Connectors menu" | Inventory: button is "Add files, connectors, and more" not "+"; menu item is "Connectors". Functionally the same surface |

---

### `ui/quick-entry.md`

**Inventory surfaces covered:** none — Quick Entry is a separate
`BrowserWindow` constructed in the main process (`index.js:515375`), not
part of claude.ai's renderer. The walker started at `https://claude.ai/new`
which never reaches it.

**Doc rows reconciled:** ~17

#### In docs but not in renderer

Every row, by design. Categories:

- Window appearance (frame, background, rounded corners, drop shadow,
  position, always-on-top, lifecycle, persistence after main destroy) —
  main-process BrowserWindow construction
- Input area (text input, placeholder, multi-line, Enter/Shift+Enter,
  Esc, click-outside, paste, IME) — popup renderer (separate from
  claude.ai)
- Submit feedback (transition, loading, error) — popup renderer + IPC
  bridge

This entire file is correctly out of renderer scope. Doc rows are
already heavily annotated with `index.js:515xxx` references to upstream
main-process source — that's the right substrate.

#### In renderer but not in docs

N/A — surface mismatch.

---

### `ui/notifications.md`

**Inventory surfaces covered:** none — notifications fire via libnotify
on the `org.freedesktop.Notifications` DBus path; they are not DOM
elements.

**Doc rows reconciled:** ~17

#### In docs but not in renderer

Every row, by design. Categories:

- Notification sources (Scheduled fires, Catch-up, CI status, PR merged,
  Dispatch handoff, Permission prompt) — main-process emitters
- Per-notification anatomy (App identity, icon, title, body, actions,
  click target) — DBus payload
- Per-DE rendering (KDE/GNOME/Mako/Dunst/swaync/Niri) — daemon behavior
- Notification persistence (history, DND) — daemon behavior

This entire file is correctly out of renderer scope.

#### In renderer but not in docs

N/A — surface mismatch.

---

## Top-level findings

### Coverage by source-of-truth axis

- **OS-level / window-manager elements** (window-chrome rows for
  title bar, close/min/max, resize edges, drop shadow) — never going to
  appear in the renderer inventory. ~10 doc rows.
- **Main-process Electron windows** (Quick Entry popup, About dialog,
  crash dialog, file pickers) — never going to appear in the renderer
  inventory. ~25 doc rows.
- **Tray menu** (Show/Hide, Quick Entry, Settings, About, Quit, Open
  at Login) — main-process `Menu.buildFromTemplate()`. ~12 doc rows.
- **libnotify notifications** — DBus, not DOM. ~17 doc rows.
- **Walker coverage gaps** (Settings overlay, Routines page, plugin
  browser modal, all Code-tab panes, dialogs, slash menu, drag-drop
  overlay) — would appear if the walker drilled them. ~70 doc rows.
- **Account-state-dependent surfaces** (CI bar, Dispatch badges, file
  attachments, SSH connections panel) — would appear in some sessions
  but didn't at capture. ~15 doc rows.
- **Conditional / hover / behavior** (right-click context menus, hover
  archive icons, drag-drop overlays, tooltips) — wouldn't appear in a
  static walker pass even if the surface was visited. ~10 doc rows.

The combined explanation: roughly half of the "in docs but not in
renderer" mismatches are unfixable (different source of truth), and
roughly half are walker coverage gaps that future passes can close.

### Top 3 surfaces with the most "in docs but not in renderer" mismatches

These are likely candidates for speculative claims OR for un-walked
surfaces. Treat as triage queue:

1. **`ui/code-tab-panes.md`** — ~50 unmatched rows. Almost entirely
   walker-coverage gap (the walker landed in the Code-tab shell but
   opened no panes). Until the walker drills diff/preview/terminal/file/
   tasks panes, this doc is un-reconcilable.
2. **`ui/settings.md`** — ~28 unmatched rows. Settings opens as an
   overlay; walker captured only the Settings entry-point button. Needs
   targeted drill.
3. **`ui/routines-page.md`** — ~26 unmatched rows. Same shape as
   Settings — entry-point captured, page contents unwalked.

### Top 3 surfaces with the most "in renderer but not in docs" surplus

These docs are most-incomplete relative to ground truth:

1. **`ui/sidebar.md`** — Inventory has 60+ Code-tab session-list entries
   under `root.button.code.button.new-session-n`. Doc treats sessions as
   a single category row. This is intentional doc behavior, but it means
   the doc doesn't help when reasoning about the actual structural
   buttons (Filter, Appearance, Routines, More navigation items, Show 5
   more, etc.) that the walker found.
2. **`ui/prompt-area.md`** — Inventory has the entire Use-style picker
   sub-tree (Normal / Learning / Concise / Explanatory / Formal / Create
   & edit styles + 5 preset cards), the Press-and-hold-to-record voice
   button, dictation settings, transcript view mode, scroll-to-bottom,
   and the model picker's "Adaptive thinking" / "More models" entries —
   none of which the doc enumerates.
3. **`ui/connectors-and-plugins.md`** — Inventory has the entire plugin
   browser sub-tree (`root.button.back.*` — 12 entries: Skills, Add
   plugin, Typescript lsp, Php lsp, Playwright, Browse plugins, Create
   new skills, Connect your apps, Connectors×2, Back to Claude, Select
   a folder), and connector-suggested prompt cards (10 entries under
   `.gmail.button.*`). Doc treats these surfaces at a higher level of
   abstraction.

## Acknowledged gaps in inventory itself

Not all inventory absences are doc errors. Known walker gaps as of v6:

- **Settings page deep content** — only the entry-point button
  (`root.button.settings`) and the menu shortcut
  (`...menuitem.settingsctrl`) captured. Settings opens as an overlay
  the walker did not drill.
- **Dialogs** — 0 captured. claude.ai may not use `[role=dialog]` for
  most modals, or the walker's drill paths didn't reach them.
- **Code tab panes** — only the Code-tab session shell was drilled;
  diff, preview, terminal, file, tasks, subagent, plan, side chat, CI
  bar are uncaptured.
- **Routines page** — only the entry-point link was captured.
- **Plugin browser modal anatomy** — surrounding list captured, the
  per-plugin install modal wasn't.
- **Slash menu** — walker did not type `/` to trigger.
- **Hover/right-click/drag-only affordances** — static walker; no
  context menus or drag-drop overlays.
- **Quick Entry / Tray / Notifications** — out of renderer scope.

These are walker tickets, not bugs against the v6 capture.

## Triage suggestions for `ui/*.md` cleanup

Aimed at humans editing the docs. Ordered by impact:

1. **Mark out-of-renderer surfaces explicitly.** `ui/tray.md`,
   `ui/quick-entry.md`, `ui/notifications.md`, and the OS-frame section
   of `ui/window-chrome-and-tabs.md` already reference main-process
   source and DE behavior — add a header note that this surface
   intentionally doesn't appear in `ui-inventory.json`.
2. **Annotate walker-coverage-gap surfaces.** `ui/code-tab-panes.md`,
   `ui/settings.md`, `ui/routines-page.md` — header note that the
   inventory does not yet drill these surfaces; rows reflect upstream
   behavior and are unverified in the renderer.
3. **Add missing topbar/prompt-area elements** to `ui/window-chrome-and-tabs.md`
   and `ui/prompt-area.md` from the "In renderer but not in docs" lists.
4. **Decide the doc/inventory boundary for sidebar session lists.** Doc
   treats sessions as a category; inventory enumerates each. Pick one
   shape and document it.
5. **Flag speculative Linux-conditional rows** — `ui/settings.md` SSH
   connections, "Denied apps" / "Unhide apps when Claude finishes" for
   Computer Use — mark as "may not render on Linux; verify before
   assuming."
