# Extensibility — Plugins, MCP, Hooks, Memory

Tests covering the Anthropic & Partners plugin install flow, the plugin browser, MCP server config, hooks, `CLAUDE.md` memory loading, and per-user storage of plugins/worktrees. See [`../matrix.md`](../matrix.md) for status.

## T11 — Plugin install (Anthropic & Partners)

**Severity:** Smoke
**Surface:** Plugin browser → install flow
**Applies to:** All rows
**Issues:** [`docs/learnings/plugin-install.md`](../../learnings/plugin-install.md)

**Steps:**
1. In a Code-tab session, click **+** → **Plugins** → **Add plugin**.
2. Find an Anthropic & Partners plugin. Click **Install**.
3. Verify it lands in **Manage plugins** and its skills appear in the slash menu.
4. Re-install the same plugin to verify idempotence.

**Expected:** Install completes end-to-end: gate logic accepts, backend endpoint responds, plugin appears in the plugin list. Re-install is idempotent.

**Diagnostics on failure:** DevTools network panel during install, launcher log, `~/.claude/plugins/` content, the gate-logic code path (see learnings doc).

**References:** [`docs/learnings/plugin-install.md`](../../learnings/plugin-install.md), [Install plugins](https://code.claude.com/docs/en/desktop#install-plugins)

## T33 — Plugin browser

**Severity:** Should
**Surface:** Plugin browser UI
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Click **+** → **Plugins** → **Add plugin**.
2. Confirm entries from the official Anthropic marketplace appear.
3. Install a non-Anthropic plugin end-to-end.
4. Verify it shows in **Manage plugins** and contributes its skills to the slash menu.

**Expected:** Plugin browser opens, shows the marketplace, install completes. Installed plugins appear under Manage plugins and contribute to the slash menu.

**Diagnostics on failure:** Screenshot of plugin browser, network captures, launcher log, `~/.claude/plugins/` listing.

**References:** [Install plugins](https://code.claude.com/docs/en/desktop#install-plugins)

## T35 — MCP server config picked up

**Severity:** Critical
**Surface:** MCP / Code tab
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Add an MCP server to `~/.claude.json` or `<project>/.mcp.json`.
2. Open a Code-tab session against the project.
3. Type `/` in the prompt — verify MCP-provided tools appear in the slash menu (or invoke one directly).
4. Separately, confirm `claude_desktop_config.json` (Chat-tab MCP) is **not** picked up by Code tab.

**Expected:** MCP servers in `~/.claude.json` or `.mcp.json` start when a Code session opens. Tools appear in the slash menu, calls succeed end-to-end. `claude_desktop_config.json` is separate per upstream docs.

**Diagnostics on failure:** Server stderr (MCP servers log to stderr), `~/.claude.json` and `.mcp.json` content, launcher log, DevTools console for MCP wire errors.

**References:** [MCP servers: desktop chat app vs Claude Code](https://code.claude.com/docs/en/desktop#shared-configuration), [`docs/learnings/plugin-install.md`](../../learnings/plugin-install.md)

## T36 — Hooks fire

**Severity:** Critical
**Surface:** Hooks runtime
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Add a `SessionStart` hook in `~/.claude/settings.json` that writes a marker file.
2. Open a new Code-tab session.
3. Confirm the marker file exists.
4. Repeat with `PreToolUse` / `PostToolUse` hooks. Switch transcript view to Verbose to see the hook output.

**Expected:** Hooks defined in `~/.claude/settings.json` execute at the documented points. Hook output is visible in Verbose transcript mode. A failing hook surfaces a clear error rather than silently breaking the session.

**Diagnostics on failure:** Hook script stderr, marker file presence, launcher log, settings file content, Verbose transcript output.

**References:** [Shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration)

## T37 — `CLAUDE.md` memory loads

**Severity:** Critical
**Surface:** Memory / Code tab session prompt
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Confirm a project `CLAUDE.md` exists at the working folder.
2. Confirm `~/.claude/CLAUDE.md` exists with at least one identifying token.
3. Open a Code-tab session against the project.
4. Ask Claude "what's in your CLAUDE.md" — verify the response matches on-disk content.
5. Edit `CLAUDE.md`. Start a new session — verify the new content is loaded.

**Expected:** Project `CLAUDE.md` and `CLAUDE.local.md` at the working folder, plus `~/.claude/CLAUDE.md`, are loaded into the session's system prompt. Updates after edit on the next session start.

**Diagnostics on failure:** `cat CLAUDE.md` and `cat ~/.claude/CLAUDE.md` outputs, launcher log, system-prompt dump if accessible (Verbose transcript may show it).

**References:** [Shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration)

## S27 — Plugins install per-user, not into system paths

**Severity:** Should
**Surface:** Plugin storage
**Applies to:** All rows
**Issues:** —

**Steps:**
1. As a non-root user, install a plugin via the desktop plugin browser.
2. Inspect `~/.claude/plugins/` for the install.
3. Verify nothing was written under `/usr` or other system-managed trees (`find /usr -newer /tmp/marker -name '*claude*' 2>/dev/null` after `touch /tmp/marker; install plugin`).

**Expected:** Plugins land under `~/.claude/plugins/` (or the equivalent per-user dir). Never under `/usr`. Non-root install/enable/disable works without `sudo`.

**Diagnostics on failure:** `find / -name '*<plugin-name>*' 2>/dev/null`, install logs, launcher log.

**References:** [Install plugins](https://code.claude.com/docs/en/desktop#install-plugins)

## S28 — Worktree creation surfaces clear error on read-only mounts

**Severity:** Could
**Surface:** Worktree creation on read-only filesystem
**Applies to:** All rows (NixOS users hit this most often)
**Issues:** —

**Steps:**
1. Place a project on a read-only mount (e.g. squashfs, NFS read-only export, `mount -o ro` bind).
2. Open a Code-tab session against it.
3. Try to start a parallel session that needs a worktree.

**Expected:** Worktree creation fails with a clear error pointing at the read-only mount. No silent loss of work, no writes to a wrong directory, no parent-repo corruption.

**Diagnostics on failure:** `mount | grep <project-path>`, `git worktree add` direct invocation (does it fail the same way?), launcher log, screenshot of error dialog.

**References:** [Work in parallel with sessions](https://code.claude.com/docs/en/desktop#work-in-parallel-with-sessions)
