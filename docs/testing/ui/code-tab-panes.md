# UI — Code Tab Panes

Drag-and-drop panes inside a Code-tab session: diff, preview, terminal, file editor, tasks, subagent, plan, side chat. Related functional tests: [T19](../cases/code-tab-foundations.md#t19--integrated-terminal), [T20](../cases/code-tab-foundations.md#t20--file-pane-opens-and-saves), [T21](../cases/code-tab-workflow.md#t21--dev-server-preview-pane), [T22](../cases/code-tab-workflow.md#t22--pr-monitoring-via-gh), [T31](../cases/code-tab-workflow.md#t31--side-chat-opens).

## Pane chrome (common)

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Pane header | Top of pane | Shows pane title, drag handle, close button | — |
| Drag handle | Pane header | Drag repositions the pane in the layout | — |
| Resize handle | Edge between panes | Drag resizes; double-click resets | — |
| Close pane button | Pane header right | `Cmd+\` or Ctrl+\\ shortcut equivalent | — |
| Views menu | Session toolbar | Lists all openable panes; click to add | — |

## Diff pane

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Diff stats indicator | Chat / sidebar (entry point) | Shows `+12 -1` style. Click opens diff pane | — |
| File list | Left side of pane | Lists changed files, click to navigate | — |
| Diff content | Right side | Side-by-side or unified diff renders cleanly | Theme-aware (dark/light) |
| Line click → comment box | Click any line | Opens inline comment input | — |
| Comment submit (`Cmd+Enter` / `Ctrl+Enter`) | Press the shortcut after writing | Submits all comments at once | — |
| Accept button | Per-file or per-hunk | Applies the change to disk | — |
| Reject button | Per-file or per-hunk | Discards the change | — |
| **Review code** button | Top-right of pane | Triggers Claude self-review of diff | — |

## Preview pane

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Preview dropdown | Session toolbar | Lists configured servers from `.claude/launch.json` | — |
| **Start** action | Per-server entry | Launches the dev server | — |
| **Stop** action | Per-server entry | Stops the dev server | — |
| **Stop all servers** | Dropdown bottom | Stops every running server | — |
| **Edit configuration** | Dropdown bottom | Opens `.claude/launch.json` in the file pane | — |
| **Persist sessions** toggle | Dropdown | Persists cookies / localStorage across server restarts | — |
| Embedded browser frame | Pane content | Renders the running app | Uses Electron `<webview>` or `BrowserView` |
| URL bar / address | Top of pane | Shows current URL; editable | — |
| Reload button | Top of pane | Reloads the embedded URL | — |
| DevTools toggle | Top of pane (right) | Opens Electron DevTools for the embedded view | — |
| Auto-verify screenshots | When Claude verifies a change | Brief overlay shows screenshot being captured | — |

## Terminal pane

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Terminal pane | Opened via `Ctrl+`` or Views menu | Bash/zsh/fish session in the working directory ([T19](../cases/code-tab-foundations.md#t19--integrated-terminal)) | Local sessions only |
| Cursor | Inside terminal | Blinks; cursor shape per shell | — |
| Resize | Drag pane edges | Terminal cols/rows update; `tput cols` reflects new width | SIGWINCH should fire |
| Scrollback | Type many lines | Scrollable history; mouse scroll wheel works | — |
| Color rendering | Run `ls --color=auto`, `tput colors` | 256-color or truecolor support; theme-aware | — |
| Copy / paste | Select + `Ctrl+Shift+C` / `Ctrl+Shift+V` | Standard terminal-emulator shortcuts | — |
| Working directory inheritance | Open pane in a session | Opens at the session's project folder | Confirm with `pwd` |

## File pane

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| File pane | Opened by clicking a file path | Shows file content, syntax-highlighted | — |
| Save button | Pane toolbar | Writes current content to disk | — |
| Path label | Pane header | Click copies absolute path | — |
| On-disk-changed warning | If file changed externally after open | Banner with Override / Discard options ([T20](../cases/code-tab-foundations.md#t20--file-pane-opens-and-saves)) | — |
| Discard button | When edits unsaved | Reverts to disk content | — |
| Cursor / selection | Inside content | Renders correctly; multi-cursor not supported | — |
| Find / replace | `Ctrl+F` | Opens find-in-file overlay | Verify scoped to current pane only |

## Tasks pane / subagent pane

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Tasks pane | Opened via Views menu | Lists subagents, background shell commands, workflows | — |
| Task entry click | Click any task | Opens the subagent pane with output | — |
| Stop task button | Per-task | Sends interrupt signal | — |
| Task status indicator | Per-task | Running / Completed / Failed | — |
| Output stream | Inside subagent pane | Live-updating stdout/stderr | — |

## Side chat overlay

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Side chat trigger | `Ctrl+;` or `/btw` in main prompt | Opens overlay attached to current session ([T31](../cases/code-tab-workflow.md#t31--side-chat-opens)) | — |
| Side chat content | Overlay body | Reads main thread context; replies stay in side chat | — |
| Close button | Overlay top-right | Closes side chat, returns focus to main session | — |

## CI status bar

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| CI status row | Below prompt area when PR open | Shows current check states | Crosses with [T22](../cases/code-tab-workflow.md#t22--pr-monitoring-via-gh) |
| **Auto-fix** toggle | Top of CI bar | Toggles automatic check-failure fixes | — |
| **Auto-merge** toggle | Top of CI bar | Toggles auto-merge on green | Requires GitHub repo setting |
| Per-check entries | Each CI check | Shows pass / fail / pending state | Click to see logs |
| CI completion notification | When all checks resolve | Desktop notification posted ([T23](../cases/code-tab-handoff.md#t23--desktop-notifications-fire)) | — |

## View modes

| Mode | Trigger | Expected | Notes |
|------|---------|----------|-------|
| Normal | Default; cycle via `Ctrl+O` | Tool calls collapsed into summaries, full text responses | — |
| Verbose | Cycle via `Ctrl+O` | Every tool call, file read, intermediate step | Use for debugging |
| Summary | Cycle via `Ctrl+O` | Only Claude's final responses + changes | Use when scanning many sessions |
| Transcript view dropdown | Next to send button | Same as `Ctrl+O` | — |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Pane drag doesn't snap to layout zones | Layout engine state corruption; restart session | — |
| Terminal cursor doesn't blink | `xterm-256color` not propagated; `TERM` env wrong | `echo $TERM` inside the pane |
| File pane "Save" silently no-ops | Read-only filesystem ([S28](../cases/extensibility.md#s28--worktree-creation-surfaces-clear-error-on-read-only-mounts)); permissions wrong | `stat <file>` for ownership |
| Preview pane embedded browser blank | Dev server didn't bind expected port; `autoPort` config | Check launcher log; `lsof -i :<port>` |
| Auto-verify screenshots fail | Headless screenshot in embedded view broken on Wayland | Test on X11 row; report to upstream |
| CI bar shows stale state | `gh` polling interval; rate-limited | `gh api rate_limit`; manual `gh pr checks <num>` |
