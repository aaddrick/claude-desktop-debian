# Code Tab — Workflow Surfaces

Tests covering the dev-server preview pane, PR monitoring, worktree isolation, auto-archive, side chat, and the slash command menu. See [`../matrix.md`](../matrix.md) for status.

## T21 — Dev server preview pane

**Severity:** Should
**Surface:** Code tab → Preview pane
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, ensure `.claude/launch.json` is configured (or let auto-detect populate it).
2. Click **Preview** dropdown → **Start**.
3. Interact with the embedded browser. Verify auto-verify takes screenshots.
4. Stop the server from the dropdown.

**Expected:** Configured dev server starts. Embedded browser renders the running app. Auto-verify takes screenshots and inspects DOM. Stopping from the dropdown actually stops the process.

**Diagnostics on failure:** `lsof -i :<port>` to see the server, screenshot of preview pane state, `.claude/launch.json` content, launcher log, DevTools console.

**References:** [Preview your app](https://code.claude.com/docs/en/desktop#preview-your-app)

## T22 — PR monitoring via `gh`

**Severity:** Critical
**Surface:** Code tab → CI status bar
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Ensure `gh` is installed and authenticated (`gh auth status`).
2. In a Code-tab session, ask Claude to open a PR for a small change.
3. Observe the CI status bar. Toggle **Auto-fix** and **Auto-merge**.
4. Run a separate test on a row where `gh` is **not** installed — confirm the install prompt appears the first time a PR action is taken.

**Expected:** With `gh` present and authenticated, CI status bar surfaces in the session toolbar. Auto-fix and Auto-merge toggles work (auto-merge requires the corresponding GitHub repo setting). If `gh` is missing, the app prompts to install it without crashing.

**Diagnostics on failure:** `gh auth status`, `which gh`, launcher log, DevTools console, screenshot of status bar, the GitHub repo's "Allow auto-merge" setting.

**References:** [Monitor pull request status](https://code.claude.com/docs/en/desktop#monitor-pull-request-status)

## T29 — Worktree isolation

**Severity:** Critical
**Surface:** Code tab → Sidebar (parallel sessions)
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session against a Git project, open two new sessions in parallel via **+ New session**.
2. Make different edits in each session.
3. Confirm `<project-root>/.claude/worktrees/<branch>` exists for each.
4. Archive one session via the sidebar archive icon.

**Expected:** Each session creates an isolated worktree at `<project-root>/.claude/worktrees/<branch>` (or the dir configured in Settings → Claude Code → "Worktree location"). Edits in one session do not appear in another until committed. Archiving removes the worktree.

**Diagnostics on failure:** `git worktree list` from project root, `ls -la <project-root>/.claude/worktrees/`, launcher log.

**References:** [Work in parallel with sessions](https://code.claude.com/docs/en/desktop#work-in-parallel-with-sessions)

## T30 — Auto-archive on PR merge

**Severity:** Should
**Surface:** Code tab → Sidebar
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In Settings → Claude Code, enable **Auto-archive after PR merge or close**.
2. Open a PR from a local session. Merge or close it on GitHub.
3. Wait ~1 minute. Observe the sidebar.

**Expected:** Local session whose PR merges (or closes) is archived from the sidebar within ~1 minute of the merge event. Remote and SSH sessions are not affected.

**Diagnostics on failure:** Screenshot of sidebar, `gh pr view <num>` output (confirming merge state), launcher log, settings file content.

**References:** [Work in parallel with sessions](https://code.claude.com/docs/en/desktop#work-in-parallel-with-sessions)

## T31 — Side chat opens

**Severity:** Should
**Surface:** Code tab → Side chat overlay
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, press `Ctrl+;` (or type `/btw` in the prompt).
2. Ask a question in the side chat. Confirm the side chat sees the main thread context.
3. Close the side chat. Confirm focus returns to the main session and the side chat content is not in the main thread.

**Expected:** Side chat opens, has access to main-thread context, but its replies do not appear in the main conversation. Closing returns focus.

**Diagnostics on failure:** Screenshot, launcher log, DevTools console.

**References:** [Ask a side question](https://code.claude.com/docs/en/desktop#ask-a-side-question-without-derailing-the-session)

## T32 — Slash command menu

**Severity:** Should
**Surface:** Code tab → Prompt slash menu
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, type `/` in the prompt box.
2. Verify built-in commands, custom skills under `~/.claude/skills/`, project skills, and skills from installed plugins all appear.
3. Select an entry — confirm it inserts as a highlighted token.

**Expected:** Slash menu lists every available command/skill. Selection inserts the token correctly.

**Diagnostics on failure:** Screenshot of slash menu, `ls ~/.claude/skills/`, project `.claude/skills/`, installed plugin manifest, launcher log.

**References:** [Use skills](https://code.claude.com/docs/en/desktop#use-skills)
