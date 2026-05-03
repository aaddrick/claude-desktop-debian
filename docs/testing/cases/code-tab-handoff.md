# Code Tab — Handoffs to Other Apps

Tests covering desktop notifications, "Open in" external editor, "Show in Files" file manager, connector OAuth round-trips, IDE handoff, and graceful failure of the macOS/Windows-only `/desktop` CLI command. See [`../matrix.md`](../matrix.md) for status.

## T23 — Desktop notifications fire

**Severity:** Critical
**Surface:** Notifications (libnotify / XDG Notifications)
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Trigger each notification source: scheduled-task fire ([T27](./routines.md#t27--scheduled-task-fires-and-notifies)), CI completion ([T22](./code-tab-workflow.md#t22--pr-monitoring-via-gh)), Dispatch handoff ([S24](./platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification)).
2. Observe each notification appears.
3. Click each — confirm it focuses the relevant session.

**Expected:** Notifications appear in the active DE's notification area (Plasma's notification daemon, Mako on wlroots, gnome-shell, etc.) and are clickable to focus the relevant session.

**Diagnostics on failure:** `gdbus call --session --dest=org.freedesktop.Notifications --object-path=/org/freedesktop/Notifications --method=org.freedesktop.DBus.Introspectable.Introspect`, `notify-send "test"` (sanity check daemon), launcher log, DE-specific notification logs.

**References:** [Scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks), [Monitor pull request status](https://code.claude.com/docs/en/desktop#monitor-pull-request-status)

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:494456` (`new hA.Notification(r)` — backed by Electron's libnotify on Linux); `:495110` (`showNotification(title, body, tag, navigateTo)` dispatches Swift on macOS, Electron elsewhere); `:511174`, `:512738` (cu-lock / tool-permission notifications wire a click callback that navigates to `/local_sessions/{sessionId}` to focus the session).

## T24 — Open in external editor

**Severity:** Should
**Surface:** Code tab → Right-click → Open in
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Install at least one of: VS Code, Cursor, Zed, Windsurf (any install method —
   flatpak, AppImage, distro package). Xcode is darwin-only and absent on Linux.
2. In the Code tab, right-click a file path → **Open in** → choose the editor.
3. Confirm the editor opens at that file.

**Expected:** Right-click → **Open in** launches the chosen editor with the file
path. Editor is invoked by URL scheme (`vscode://file/<path>`,
`cursor://file/<path>`, `zed://file/<path>`, `windsurf://file/<path>`) via
`shell.openExternal`, which delegates to `xdg-open`'s
`x-scheme-handler/<editor>` resolution rather than hard-coded paths.

**Diagnostics on failure:** `xdg-mime query default x-scheme-handler/vscode` (or
`cursor`/`zed`/`windsurf`), `desktop-file-validate` on the editor's `.desktop`
file, `xdg-open vscode://file/<path>` from terminal (sanity check), launcher
log.

**References:** [Open files in other apps](https://code.claude.com/docs/en/desktop#open-files-in-other-apps)

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:59076`
(editor enum: VSCode, Cursor, Zed, Windsurf, Xcode); `:463902` (`Mtt`
registry — `vscode://`, `cursor://`, `zed://`, `windsurf://`, `xcode://` with
darwin-only flag on Xcode); `:463956` (`getInstalledEditors` probes via
`app.getApplicationInfoForProtocol`); `:464011`
(`shell.openExternal('<scheme>://file/<encoded-path>:<line>')` — path is
URL-encoded but `/` separators are preserved); `:68816` IPC handler
`LocalSessions.openInEditor(path, editor, sshConfig, line)`.

## T25 — Show in Files / file manager

**Severity:** Should
**Surface:** Code tab → Right-click → Show in Files
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In the Code tab, right-click a file path → "Show in Files" (Linux equivalent of macOS "Show in Finder" / Windows "Show in Explorer").
2. Confirm the system file manager opens with the containing folder selected.

**Expected:** System file manager (Nautilus on GNOME, Dolphin on KDE, Thunar on Xfce, etc.) opens with the file pre-selected. Resolution respects `xdg-mime` defaults.

**Diagnostics on failure:** `xdg-mime query default inode/directory`, `xdg-open <dir>` from terminal, the menu label rendered (was it Linux-specific or stuck on "Show in Finder"?), launcher log.

**References:** [Open files in other apps](https://code.claude.com/docs/en/desktop#open-files-in-other-apps)

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:66652` IPC
handler `FileSystem.showInFolder(path)`; `:509431` impl thin-wraps
`hA.shell.showItemInFolder(Tc(path))`. Electron's `showItemInFolder` on Linux
falls back to `xdg-open` on the parent directory when no DBus FileManager1
service is present, so the file is rarely pre-selected on minimal DEs — only
the parent folder opens.

## T34 — Connector OAuth round-trip

**Severity:** Critical
**Surface:** Connectors → OAuth handoff
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, click **+** → **Connectors** → choose a service (Slack, GitHub, Linear, Notion, Google Calendar).
2. Step through the OAuth flow in the system browser.
3. Return to Claude Desktop and verify the connector appears in **Settings → Connectors**.
4. Use the connector in a prompt (e.g. "list my Slack channels").

**Expected:** Adding a connector launches the browser via `xdg-open`, OAuth callback hands control back to Claude Desktop, connector appears in Settings, and is usable in subsequent prompts.

**Diagnostics on failure:** `xdg-mime query default x-scheme-handler/https`, the callback URL scheme, network captures of OAuth redirect, launcher log, DevTools console.

**References:** [Connect external tools](https://code.claude.com/docs/en/desktop#connect-external-tools), [Connectors for everyday life](https://claude.com/blog/connectors-for-everyday-life)

**Code anchors:**
`build-reference/app-extracted/.vite/build/index.js:524819`
(`hA.app.setAsDefaultProtocolClient("claude")` — registers the `claude://`
deep-link scheme used by the OAuth callback); `:525026` mainWindow
`setWindowOpenHandler` routes external URLs through `MAA(url)` →
`:525102`–`:525135` (only `http:`/`https:`/`mailto:`/`tel:`/`sms:`/
`ms-(excel|powerpoint|word):` are forwarded to system handlers; everything
else is dropped); `:136233` `$a(url)` thin-wraps `hA.shell.openExternal(url)`
(this is the single egress point for browser handoff); `:159634`
`mcpSubmitOAuthCallbackUrl(serverName, callbackUrl)` and `:159651`
`claudeOAuthCallback(authorizationCode, state)` — IPC bridges that consume
the deep-link callback. See [`docs/learnings/plugin-install.md`](../../learnings/plugin-install.md)
for orgId/sessionKey cookie chain that gates connector listing.

## T38 — Continue in IDE

**Severity:** Should
**Surface:** Code tab → Continue in menu
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, click the IDE icon (bottom right of session toolbar) → **Continue in** → choose an IDE.
2. Confirm the IDE opens at the working directory.

**Expected:** Selected IDE opens the project at the current working directory. Resolution via `xdg-open` / `.desktop` files.

**Diagnostics on failure:** `xdg-open <project-dir>` sanity check, `xdg-mime query default x-scheme-handler/vscode` (or matching scheme for the chosen IDE), launcher log, the IDE's `.desktop` file.

**References:** [Continue in another surface](https://code.claude.com/docs/en/desktop#continue-in-another-surface)

**Code anchors:** Same IPC surface as [T24](#t24--open-in-external-editor) —
`build-reference/app-extracted/.vite/build/index.js:68816`
(`LocalSessions.openInEditor(path, editor, sshConfig, line)` accepts a
directory path the same way as a file path); `:463902` editor registry;
`:464011` `shell.openExternal('<scheme>://file/<cwd>')`. The "Continue in"
chooser UI is rendered server-side by claude.ai and not present in the local
asar — only the IPC bridge can be code-anchored.

## T39 — `/desktop` CLI handoff (graceful N/A)

> **Note** — This test exercises the upstream `claude` CLI binary, not the
> Electron app. The CLI ships separately from this packaging (out of
> `build-reference/`), so no anchor in `app-extracted/.vite/build/` exists for
> the slash-command handler. Re-verify behaviour against the CLI binary that
> ships with the upstream version under test (currently 1.5354.0).

**Severity:** Could
**Surface:** CLI `/desktop` command
**Applies to:** All rows (Linux equally)
**Issues:** —

**Steps:**
1. In a CLI session, run `/desktop`.
2. Inspect exit code and output.

**Expected:** `/desktop` is documented as macOS/Windows-only. On Linux it must fail gracefully — print a clear "not supported on Linux" message and exit cleanly. No partial state transition, no panic, no corrupted session file.

**Diagnostics on failure:** Full CLI output, exit code, the session file before/after (`~/.claude/sessions/...`), strace if the CLI hangs.

**References:** [Coming from the CLI](https://code.claude.com/docs/en/desktop#coming-from-the-cli)
