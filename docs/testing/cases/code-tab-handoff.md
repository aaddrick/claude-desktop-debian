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

## T24 — Open in external editor

**Severity:** Should
**Surface:** Code tab → Right-click → Open in
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Install at least one of: VS Code, Cursor, Zed (any install method — flatpak, AppImage, distro package).
2. In the Code tab, right-click a file path → **Open in** → choose the editor.
3. Confirm the editor opens at that file.

**Expected:** Right-click → **Open in** launches the chosen editor with the file path. Resolution goes via `xdg-open` / desktop-entry rather than hard-coded paths.

**Diagnostics on failure:** `xdg-mime query default text/plain`, `desktop-file-validate` on the editor's `.desktop` file, `xdg-open <file>` from terminal (sanity check), launcher log.

**References:** [Open files in other apps](https://code.claude.com/docs/en/desktop#open-files-in-other-apps)

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

## T38 — Continue in IDE

**Severity:** Should
**Surface:** Code tab → Continue in menu
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, click the IDE icon (bottom right of session toolbar) → **Continue in** → choose an IDE.
2. Confirm the IDE opens at the working directory.

**Expected:** Selected IDE opens the project at the current working directory. Resolution via `xdg-open` / `.desktop` files.

**Diagnostics on failure:** `xdg-open <project-dir>` sanity check, `xdg-mime query default inode/directory`, launcher log, the IDE's `.desktop` file.

**References:** [Continue in another surface](https://code.claude.com/docs/en/desktop#continue-in-another-surface)

## T39 — `/desktop` CLI handoff (graceful N/A)

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
