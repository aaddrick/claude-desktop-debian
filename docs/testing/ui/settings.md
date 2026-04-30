# UI — Settings

The Settings window holds Desktop app preferences, Claude Code settings, connector management, and account controls. Related functional tests: [S20](../cases/routines.md#s20--keep-computer-awake-inhibits-idle-suspend), [S22](../cases/platform-integration.md#s22--computer-use-toggle-is-absent-or-visibly-disabled-on-linux), [T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge).

## Settings root

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Settings window | Opened via app menu, tray menu, or in-app shortcut | Window opens with sidebar nav and content area | — |
| Window close button | Top-right (or top-left on GNOME) | Closes settings; main app continues running | — |
| Sidebar nav | Left of window | Lists every settings page | — |

## Desktop app → General

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| **Computer use** toggle | Top of page | Either absent on Linux, or rendered disabled with a "not supported on Linux" hint ([S22](../cases/platform-integration.md#s22--computer-use-toggle-is-absent-or-visibly-disabled-on-linux)) | Critical: must not appear functional |
| **Keep computer awake** toggle | Mid-page | Toggles `systemd-inhibit --what=idle:sleep` lock ([S20](../cases/routines.md#s20--keep-computer-awake-inhibits-idle-suspend)) | Verify with `systemd-inhibit --list` |
| **Denied apps** list | Computer-use related | Likely absent on Linux (computer use unsupported) | — |
| **Unhide apps when Claude finishes** toggle | Computer-use related | Likely absent on Linux | — |
| Theme picker (if exposed) | Mid-page | System / Light / Dark | Tray icon should respond ([S08](../cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update)) |

## Desktop app → Account

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Account name / email | Top of page | Reflects signed-in identity | — |
| Plan badge | Below name | Shows Pro / Max / Team / Enterprise | — |
| Sign out button | Bottom of page | Signs out cleanly; subsequent launches show sign-in screen | — |

## Claude Code

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| **Worktree location** | Top of page | Default: `<project-root>/.claude/worktrees/`. Editable to a custom directory | Crosses with [T29](../cases/code-tab-workflow.md#t29--worktree-isolation) |
| **Branch prefix** | Mid-page | Optional prefix prepended to every worktree branch | — |
| **Auto-archive after PR merge or close** toggle | Mid-page | When ON, sessions archive on PR resolution ([T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge)) | — |
| **Persist preview sessions** toggle | Mid-page | Toggles cookies/localStorage persistence in Preview pane | Crosses with [T21](../cases/code-tab-workflow.md#t21--dev-server-preview-pane) |
| **Preview** toggle | Mid-page | When OFF, preview pane and auto-verify are disabled | — |
| **Allow bypass permissions mode** toggle | Mid-page | When ON, exposes Bypass mode in mode picker | Enterprise admins can disable |
| **Auto** mode availability | Mid-page | Research preview; not on Pro plans | Per upstream docs |

## Connectors

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Connectors list | Page content | Lists connected services with status | Crosses with [T34](../cases/code-tab-handoff.md#t34--connector-oauth-round-trip) |
| Per-connector entry | List row | Name, last-connected timestamp, manage / disconnect buttons | — |
| **Manage** button | Per row | Opens connector-specific settings | — |
| **Disconnect** button | Per row | Revokes access; connector becomes unusable in subsequent sessions | — |
| **Add connector** button | Top of page | Opens the connector picker (same surface as `+ → Connectors`) | — |

## SSH connections

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| SSH connections list | Page content | Lists user-added + managed (read-only) connections | — |
| **Add SSH connection** button | Top of page | Opens dialog with Name / SSH Host / SSH Port / Identity File fields | — |
| Per-connection entry | List row | Edit / delete (user-added) or "Managed" badge (admin-distributed) | — |

## Keyboard shortcuts

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Shortcut list | Page content | Tabular list of all configurable shortcuts | — |
| Shortcut value | Per row | Click to rebind; shows current binding | — |
| Reset to default | Per row | Reverts to upstream default | — |
| Quick Entry shortcut | Specifically called out | Default `Ctrl+Alt+Space`; rebind here | Crosses with [T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused) |

## Local environment editor

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Env editor open | Environment dropdown → Local → gear icon | Opens encrypted env-var editor | Crosses with [S18](../cases/platform-integration.md#s18--local-environment-editor-persists-across-reboot) |
| Add variable | In editor | Name + value fields; save | — |
| Remove variable | Per row | Deletes the variable | — |
| **Apply to dev servers** indicator | Near save | Confirms vars also reach preview servers | — |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Computer-use toggle visible and toggleable on Linux | [S22](../cases/platform-integration.md#s22--computer-use-toggle-is-absent-or-visibly-disabled-on-linux) regression | File a bug; users will be misled |
| Keep-computer-awake toggle has no effect | `systemd-inhibit` integration not wired ([S20](../cases/routines.md#s20--keep-computer-awake-inhibits-idle-suspend)) | Verify lock list before/after |
| Worktree location field rejects valid paths | Path validation too strict; absolute vs `~`-prefixed | Check both forms |
| SSH connection list missing managed entries | Managed-settings file not loaded; admin distribution failed | Confirm file exists at expected path |
| Env editor not encrypting | Linux secret-store not wired ([S18](../cases/platform-integration.md#s18--local-environment-editor-persists-across-reboot)) | `secret-tool search`; `kwallet5-query` |
