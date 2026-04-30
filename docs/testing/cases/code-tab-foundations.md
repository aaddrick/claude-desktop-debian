# Code Tab — Foundations

Tests covering Code-tab availability on Linux (officially unsupported per upstream docs), sign-in flow, folder picker, drag-and-drop, and the basic editing surfaces (terminal, file pane). See [`../matrix.md`](../matrix.md) for status.

## T15 — Sign-in completes via browser handoff

**Severity:** Smoke
**Surface:** Auth / xdg-open
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Launch a fresh app instance (signed-out state).
2. Click **Sign in**. Observe the system default browser opening.
3. Authenticate on claude.ai. Observe callback returning to Claude Desktop.

**Expected:** Sign-in opens the default browser via `xdg-open`, user authenticates on claude.ai, OAuth callback returns to Claude Desktop. Account dropdown populates; no auth banner remains.

**Diagnostics on failure:** `xdg-mime query default x-scheme-handler/https`, registered `.desktop` handler, the callback URL scheme (`claude://` or HTTP localhost), launcher log, browser console for callback errors.

**References:** [Code tab auth troubleshooting](https://code.claude.com/docs/en/desktop#403-or-authentication-errors-in-the-code-tab)

## T16 — Code tab loads

**Severity:** Smoke
**Surface:** Code tab — top-level UI
**Applies to:** All rows
**Issues:** —

**Steps:**
1. After sign-in, click the **Code** tab at the top center.
2. Wait a few seconds.

**Expected:** Code tab renders the session UI (sidebar, prompt area, environment dropdown). Per upstream docs the Code tab is "not supported" on Linux — the patched build under this project should render the UI normally or surface a clear, actionable message. Not a blank screen, infinite spinner, or `Error 403: Forbidden`.

**Diagnostics on failure:** Screenshot, DevTools console, network captures (auth/feature-flag responses), launcher log, the active patch set in `scripts/patches/`.

**References:** [Use Claude Code Desktop](https://code.claude.com/docs/en/desktop), [Get started with the desktop app](https://code.claude.com/docs/en/desktop-quickstart)

## T17 — Folder picker opens

**Severity:** Smoke
**Surface:** Code tab → Environment selection
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In the Code tab, click the environment pill → **Local** → **Select folder**.
2. Choose a project directory.

**Expected:** Native file chooser opens. On Wayland sessions the chooser is `xdg-desktop-portal`-backed (verify with `busctl --user tree org.freedesktop.portal.Desktop`). On X11 sessions the GTK/Qt native picker fires. Selected path appears in the env pill.

**Diagnostics on failure:** `systemctl --user status xdg-desktop-portal`, `XDG_SESSION_TYPE`, the portal backend in use (`xdg-desktop-portal-kde`, `xdg-desktop-portal-gnome`, `xdg-desktop-portal-wlr`), launcher log.

**References:** [Local sessions](https://code.claude.com/docs/en/desktop#local-sessions)

## T18 — Drag-and-drop files into prompt

**Severity:** Critical
**Surface:** Code tab → Prompt area
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Open a Code-tab session.
2. From the system file manager, drag one or more files into the prompt area.
3. Repeat with multiple files at once.

**Expected:** Files attach to the prompt. `text/uri-list` MIME is decoded correctly. Multi-file drops attach each file. Works on both Wayland and X11.

**Diagnostics on failure:** Screen recording, `wl-paste --list-types` (Wayland) or `xclip -selection clipboard -t TARGETS -o` (X11) during drag, DevTools console, launcher log.

**References:** [Add files and context](https://code.claude.com/docs/en/desktop#add-files-and-context-to-prompts)

## T19 — Integrated terminal

**Severity:** Critical
**Surface:** Code tab → Terminal pane
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, press `` Ctrl+` `` (or open via the Views menu).
2. Confirm the terminal opens in the session's working directory.
3. Run `git status`, `npm --version`, `gh auth status`.

**Expected:** Terminal pane opens in the session's working directory, inherits the same `PATH` Claude sees. Standard commands run cleanly. Terminal pane is local-session-only per docs.

**Diagnostics on failure:** Terminal pane content, `echo $PATH` from inside the pane, `pwd`, the shell binary in use, launcher log.

**References:** [Run commands in the terminal](https://code.claude.com/docs/en/desktop#run-commands-in-the-terminal)

## T20 — File pane opens and saves

**Severity:** Critical
**Surface:** Code tab → File pane
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, click a file path in chat or diff to open it in the file pane.
2. Make a small edit. Click **Save**.
3. Modify the file externally (e.g. `echo >> file`). Re-edit in the pane. Observe the on-disk-changed warning.

**Expected:** File opens in the editor pane. Edits write back to disk on Save. If the file changed on disk since opening, the pane shows the on-disk-changed warning and offers override or discard.

**Diagnostics on failure:** `stat <file>` output (mtime), launcher log, DevTools console, screen recording of the warning state.

**References:** [Open and edit files](https://code.claude.com/docs/en/desktop#open-and-edit-files)
