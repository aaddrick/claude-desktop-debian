# Upstream report draft: MCP double-spawn (issue #546)

This is the draft for the upstream bug report covering [#546](https://github.com/aaddrick/claude-desktop-debian/issues/546). Filing target is `anthropics/claude-code` GitHub Issues, with an in-app `/bug` from Claude Desktop as a complement so the report ties to build telemetry.

## Template mismatch note

The `anthropics/claude-code` bug template is built for the Claude Code CLI, not Claude Desktop. Required fields like "Claude Code Version" and "Terminal/Shell" don't apply cleanly. Other Claude Desktop bug reports in the same repo work around this by putting `N/A — Claude Desktop <version>` in the version field and selecting `Other` for terminal (see #43705, #36319, #14807).

## Title

```
[BUG] Claude Desktop 1.5354.0: stdio MCP servers double-spawn from independent CCD/LAM coordinator registries
```

## Form fields

### Preflight Checklist

- [x] I have searched existing issues and this hasn't been reported yet
- [x] This is a single bug report
- [x] I am using the latest version of Claude Code

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) (~2,300 package downloads/day across the last 3 releases), which repackages the Windows Electron build for Linux. I was reading the MCP spawn path in 1.5354.0 and found that stdio MCP servers configured in `claude_desktop_config.json` get spawned twice when both the chat panel and Code/Agent panel are active.

The user-visible symptom is two `node` processes per MCP, both children of the Electron main PID. Killing one disconnects one panel and the other keeps working. They're independent client/server pairs with no failover between them.

The original symptom report came from @communitytranslations against an earlier build (tracked in our repo as #526). I went back and read the bundle to confirm the cause. What I found was different from what we'd previously documented.

CCD wraps the spawn path in a per-key promise queue keyed by server name. It shuts down any prior entry in its global registry Map before respawning. That's correct dedup within CCD. But LAM (`LocalMcpServerManager`) has its own `this.connections` Map and its own `getOrCreateConnection` path. It never consults CCD's registry.

CCD and LAM each maintain independent spawn lifecycle management. They each spawn their own copy of the same MCP server. The double-spawn is structural in the current architecture. Each coordinator legitimately holds its own connection.

There's also a third coordinator class, `SshMcpServerManager`, that follows the same per-coordinator-registry pattern. It uses an SSH transport, so it doesn't contribute to local-node double-spawn directly. Its existence suggests per-coordinator isolated state is a deliberate pattern, not a one-off.

Secondary bug worth flagging while you're in this code. The `child_process.spawn` wrapper does proper signal escalation (end stdin, wait 2s, SIGTERM, wait 2s, SIGKILL). The `utilityProcess.fork` wrapper doesn't. It sends `process.kill()` (default SIGTERM), waits 5s, then calls `kill()` again with the same default signal. No SIGKILL escalation. A built-in-node MCP server that ignores SIGTERM could leak as an orphaned utility process.

### What Should Happen?

One process per stdio MCP server entry in `claude_desktop_config.json`, regardless of how many panels are open. Resource-side that means no more 2x memory and 2x stdin/stdout traffic per server. User-side that means `ps` shows one entry per declared server.

The fix is architectural. CCD and LAM share a registry, or the local-spawn factory dedups at the transport layer, or LAM proxies through CCD when running in-process. Any of those would collapse the duplication.

### Error Messages/Logs

The user-facing log prefixes are stable across releases. Grep `~/.config/Claude/logs/` for:

```
[CCD]
[LAM]
[LocalMcpServerManager]
[SshMcpServerManager]
```

For the spawn lifecycle specifically, look for:

```
"Launching MCP Server: <name>"      (CCD spawn entry)
"Shutting down MCP Server: <name>"  (CCD shutdown entry)
"local-mcp-server-cleanup"          (LAM cleanup path)
```

Two of these per declared MCP server is the diagnostic signal.

### Steps to Reproduce

1. Linux host running Claude Desktop at or near 1.5354.0
2. Declare at least one stdio MCP server in `~/.config/Claude/claude_desktop_config.json`
3. Open Claude Desktop, start a session, open the Code/Agent panel and let it initialize fully (the original report waited about 5 minutes)
4. `ps -ef | grep <server-binary-name>`

Expected: 1 process per MCP. Actual: 2 processes per MCP, both children of the same Electron main PID.

### Claude Model

Not sure / Multiple models

### Is this a regression?

I don't know

### Last Working Version

(leave blank)

### Claude Code Version

```
N/A — this is a Claude Desktop issue. Bundle version: 1.5354.0
```

### Platform

Anthropic API

### Operating System

Ubuntu/Debian Linux

### Terminal/Shell

Other

### Additional Information

Bundle reference table for 1.5354.0. Symbols rename across releases, so each row has a stable string anchor for re-finding them.

| Role | Symbol in 1.5354.0 | Stable anchor |
|---|---|---|
| CCD spawn function | `BPt` | `"Launching MCP Server:"` |
| CCD shutdown function | `CPt` | `"Shutting down MCP Server:"` |
| CCD per-key promise queue | `dPt` | called by CCD spawn fn: `await dPt(e, async () => {...})` |
| CCD server registry Map | `xX` | `.get()` immediately preceding the CCD shutdown log line |
| Shared transport factory | `oPt` | `"built-in-node"` literal in factory body |
| LAM manager class | `p0A` | `"[LocalMcpServerManager]"` or `"local-mcp-server-cleanup"` |
| SSH manager class | `Rde` | `"[SshMcpServerManager]"` or `"ssh-mcp-server-cleanup"` |
| `utilityProcess.fork` wrapper | `mFr` | constructed in shared factory's `built-in-node` branch |
| `child_process.spawn` wrapper | `tFr` | constructed in shared factory's default branch |

Extraction commands (verified against 1.5354.0):

```bash
cd build-reference/app-extracted/.vite/build

# CCD spawn function name
grep -Pzo 'async function \K\w+(?=\(\w*\)\s*\{(?s).{0,800}?Launching MCP Server)' index.js | tr '\0' '\n'

# Shared transport factory (anchored on the unique 'built-in-node' string)
grep -Pzo 'async function \K\w+(?=\([^)]*\)\s*\{(?s).{0,400}?built-in-node)' index.js | tr '\0' '\n'

# All coordinator classes following the per-coordinator-registry pattern
grep -Pzo 'class \K\w+(?=\s*\{(?s).{0,300}?this\.connections\s*=\s*new Map)' index.js | tr '\0' '\n'

# LAM manager class specifically
grep -Pzo 'class \K\w+(?=\s*\{(?s).{0,500}?local-mcp-server-cleanup)' index.js | tr '\0' '\n'
```

Two questions where a one-line answer from the team would help us route this downstream:

1. Is per-coordinator isolated state intentional, or is it legacy drift from when each coordinator instantiated its transport inline?
2. Is the recent extraction of the shared transport factory (`oPt`) the start of a dedup refactor, or incidental cleanup?

If (1) is "intentional," we'll point users at the lockfile workaround as the supported path. If (2) is "in progress," this report saves you the duplicate analysis work.

Full provenance: [aaddrick/claude-desktop-debian#546](https://github.com/aaddrick/claude-desktop-debian/issues/546). Related learnings doc updates: [#527](https://github.com/aaddrick/claude-desktop-debian/pull/527) and [#547](https://github.com/aaddrick/claude-desktop-debian/pull/547).

## Filing checklist

When you're ready to file:

1. Open https://github.com/anthropics/claude-code/issues/new?template=bug_report.yml
2. Paste each section above into the matching form field
3. Submit
4. Drop the GitHub issue URL as a comment on [#546](https://github.com/aaddrick/claude-desktop-debian/issues/546) so the trail is bidirectional

Note: there is no in-app engineering bug-report path in Claude Desktop. `/bug` and `/feedback` are inert. The Help menu has "Get Support" (routes to the support chat, wrong queue for engineering) and "Troubleshooting" (self-diagnostic — useful for attaching `Copy Installation ID` or `Show Logs in File Manager` output to a GitHub issue, but not a reporting step on its own).

## Voice and authorship

Drafted using the [aaddrick-voice](https://github.com/aaddrick/written-voice-replication/blob/78f178dcf832943bcf1d5a65bf7627c3a20053a6/.claude/agents/aaddrick-voice.md) style profile against the form schema in `anthropics/claude-code/.github/ISSUE_TEMPLATE/bug_report.yml`.

---
Written by Claude Opus 4.7 via [Claude Code](https://claude.ai/code)
