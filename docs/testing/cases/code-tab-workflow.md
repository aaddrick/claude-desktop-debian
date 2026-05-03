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

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:262175` — `Pae = "Claude Preview"` + `preview_*` MCP tool table (`preview_start`, `preview_stop`, `preview_list`, `preview_screenshot`, `preview_snapshot`, `preview_inspect`, `preview_click`, `preview_fill`, `preview_eval`, `preview_network`, `preview_resize`).
- `build-reference/app-extracted/.vite/build/index.js:259604` — `setAutoVerify()` and `parseLaunchJson()` (reads `.claude/launch.json`, honours `autoVerify` flag default-on).
- `build-reference/app-extracted/.vite/build/index.js:260015` — `capturePage()` / `captureViaCDP()` drive `preview_screenshot` against the embedded preview WebContents.

## T22 — PR monitoring via `gh`

**Severity:** Critical
**Surface:** Code tab → CI status bar
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Ensure `gh` is installed and authenticated (`gh auth status`).
2. In a Code-tab session, ask Claude to open a PR for a small change.
3. Observe the CI status bar. Toggle **Auto-fix** and **Auto-merge**.
4. Run a separate test on a row where `gh` is **not** installed — confirm the missing-`gh` prompt appears the first time a PR action is taken.

**Expected:** With `gh` present and authenticated, CI status bar surfaces in the session toolbar. Auto-fix and Auto-merge toggles work (auto-merge requires the corresponding GitHub repo setting). If `gh` is missing, the app surfaces a prompt directing the user to https://cli.github.com (auto-install via `installGh` only runs on macOS/brew; Linux returns an error string with the install URL).

**Diagnostics on failure:** `gh auth status`, `which gh`, launcher log, DevTools console, screenshot of status bar, the GitHub repo's "Allow auto-merge" setting.

**References:** [Monitor pull request status](https://code.claude.com/docs/en/desktop#monitor-pull-request-status)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:464281` — `GitHubPrManager` (`prStateCache`, `prChecksCache`); `getPrChecks` at line 464964 fans out to `gh pr view`.
- `build-reference/app-extracted/.vite/build/index.js:464368` — `"gh CLI not found in PATH"` throw site that backs the missing-`gh` prompt.
- `build-reference/app-extracted/.vite/build/index.js:464480` — `installGh()`: macOS-only `brew install gh`; Linux/Windows return error pointing to https://cli.github.com.
- `build-reference/app-extracted/.vite/build/index.js:465019` — `autoMergeRequest { enabledAt }` GraphQL fragment; `enableAutoMerge` / `disableAutoMerge` at lines 465531 / 465556.
- `build-reference/app-extracted/.vite/build/index.js:534033` — `AutoFixEngine.handleSessionEvent` toggles on `autoFixEnabled` per session.

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

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:462835` — `getWorktreeParentDir()`: returns `<baseRepo>/.claude/worktrees`, or `<chillingSlothLocation.customPath>/<basename>` when overridden in Settings.
- `build-reference/app-extracted/.vite/build/index.js:462843` — `createWorktree()`: runs `git worktree add` with `core.longpaths=true` under the parent dir.
- `build-reference/app-extracted/.vite/build/index.js:463290` — `git worktree remove --force` invoked on archive (cleanup path).
- `build-reference/app-extracted/.vite/build/index.js:55231` — `chillingSlothLocation: "default"` settings key (Settings → "Worktree location").

## T30 — Auto-archive on PR merge

**Severity:** Should
**Surface:** Code tab → Sidebar
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In Settings → Claude Code, enable **Auto-archive on PR close** (`ccAutoArchiveOnPrClose`).
2. Open a PR from a local session. Merge or close it on GitHub.
3. Wait up to ~5–6 minutes (sweep runs every 5 minutes, with a 30s startup delay). Observe the sidebar.

**Expected:** Local session whose PR is `merged` or `closed` is archived from the sidebar on the next sweep tick (≤ ~5 min) after the merge/close event. Cached PR-state lookups have a 1-hour cooldown for sessions whose state isn't yet terminal. Remote and SSH sessions are not affected.

**Diagnostics on failure:** Screenshot of sidebar, `gh pr view <num>` output (confirming merge state), launcher log, settings file content (`ccAutoArchiveOnPrClose`).

**References:** [Work in parallel with sessions](https://code.claude.com/docs/en/desktop#work-in-parallel-with-sessions)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:55269` — default `ccAutoArchiveOnPrClose: !1` setting.
- `build-reference/app-extracted/.vite/build/index.js:533517` — sweep cadence constants: `$3n = 300_000` ms (5 min interval), `W3n = 3_600_000` ms (1 h recheck cooldown), `Fst = 10` (concurrent batch size).
- `build-reference/app-extracted/.vite/build/index.js:533520` — `AutoArchiveEngine.start()` schedules the 5-min interval + 30s initial delay.
- `build-reference/app-extracted/.vite/build/index.js:533537` — `sweep()` gates on `Qi("ccAutoArchiveOnPrClose")` and archives sessions whose `prState` lowercases to `merged` or `closed` (`D3A` predicate at line 533607).
- `build-reference/app-extracted/.vite/build/index.js:533571` — `archiveSession(..., { cleanupWorktree: true })` removes the worktree alongside the archive.

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

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:487025` — side-chat system-prompt suffix: "You are running in a side chat — a lightweight fork… nothing you say here lands in the main transcript."
- `build-reference/app-extracted/.vite/build/index.js:487265` — `this.sideChats = new Map()` per-session fork registry.
- `build-reference/app-extracted/.vite/build/index.js:491658` — `startSideChat()` implementation; emits `side_chat_ready` / `side_chat_assistant` / `side_chat_turn_end` / `side_chat_closed` / `side_chat_error` events.
- `build-reference/app-extracted/.vite/build/mainView.js:7506` — preload IPC bridges: `startSideChat`, `sendSideChatMessage`, `stopSideChat` (the renderer SPA wires `Ctrl+;` / `/btw` to these — UI lives in claude.ai's remote bundle, not build-reference).

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

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:459463` — `getSupportedCommands({sessionId})` aggregates per-session `slashCommands` + cowork command registry (`p2()`) + built-ins (`Q_t`).
- `build-reference/app-extracted/.vite/build/index.js:332711` — `slashCommands: Di.array(Di.string()).optional()` schema field on the session record.
- `build-reference/app-extracted/.vite/build/index.js:377670` — `SkillManager` constructor: `skillDir = <agentDir>/.claude/skills`, `_discoverSkills()` walks project skills.
- `build-reference/app-extracted/.vite/build/index.js:444678` — private/public skill split under `<skillsRoot>/skills/{private,public}` for plugin-supplied skills.
