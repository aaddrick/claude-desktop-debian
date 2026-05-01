# MCP Double-Spawn (Chat + Code/Agent Panel)

## Why This Exists

When a Claude Desktop session has both the classic chat panel
and the Code/Agent (Cowork) panel active, **every stdio MCP
server declared in `~/.config/Claude/claude_desktop_config.json`
gets spawned twice** by the Electron main process. Reported and
root-caused in detail in
[#526](https://github.com/aaddrick/claude-desktop-debian/issues/526).

## Symptoms

`ps -ef` after a session opens both panels shows two batches of
MCP children of the same Electron main PID, separated by however
long it took the user to open the second panel:

```
PID    PPID(electron)  CMD
372628 372434          python  ← batch 1 (chat panel)
372633 372434          node
372648 372434          python
...
373288 372434          python  ← batch 2 (Code/Agent panel)
373296 372434          node
373327 372434          python
```

Killing one PID disconnects one panel; the other survives. Two
independent client↔server pairs, no failover.

Most stdio MCPs don't notice they were doubled — each instance
talks to its own client and exits cleanly. The bug only surfaces
when an MCP touches **shared external state**: a single
WebSocket, files on disk that the other instance also writes,
external services with single-connection contracts, etc.

## Root Cause (Upstream)

Two parallel session managers live inside Electron main, each
holding an independent Claude Agent SDK `query`:

| Manager class            | IPC namespace                            | Coordinator     | Logs prefix |
|--------------------------|------------------------------------------|-----------------|-------------|
| `LocalSessions`          | `claude.web_$_LocalSessions_$_*`         | `n2t("ccd")`    | `[CCD]`     |
| `LocalAgentModeSessions` | `claude.web_$_LocalAgentModeSessions_$_*`| `n2t("cowork")` | `[LAM]`     |

The logs prefixes are what to grep `~/.config/Claude/logs/` for to
confirm a session is hitting both coordinators (and therefore this
bug specifically).

Each `query` holds its own SDK transport. The transport's
`spawnLocalProcess` (`Du.spawn`) launches stdio MCPs **without
consulting the global registry** that *would* dedupe them
(`hZ` map, accessed via `oUt(serverName)` /
`launchMcpServer`). That registry is only used for the
"internal" cowork in-process MessageChannelMain path.

Net result: 2 coordinators × N configured MCPs = 2N processes.

Symbol names (`n2t`, `hZ`, `oUt`, `LocalSessions`,
`LocalAgentModeSessions`) are minified and **will rename across
upstream releases**.

## Status

**Upstream Claude Desktop bug. Not patchable in this repo.** A
fix would require either:

- Routing the SDK stdio transport through `oUt`/`hZ` (the
  existing serialized-per-name registry), or
- Sharing one MCP-server registry between the `ccd` and
  `cowork` coordinators.

Both live inside the closed-source SDK transport / session
manager wiring. Regex-matching the minified symbols from
`scripts/patches/` would be fragile against release-to-release
renames and exceeds this repo's "minimal Linux-compat patches
only" charter.

## What's Already Verified Clean

- All 7 patches in `scripts/patches/*.sh` — zero references to
  MCP, mcpServer, LocalSessions, LocalAgentModeSessions,
  transportToClient, MessageChannelMain, n2t, hZ, oUt.
- `scripts/launcher-common.sh` — no MCP or config-load logic.
- `scripts/packaging/{appimage,deb,rpm}.sh` — no MCP or
  config-load logic.
- `scripts/doctor.sh:420` — only reads
  `claude_desktop_config.json` to JSON-lint it for diagnostics;
  not in the runtime spawn path.

The bug reproduces identically against the unmodified upstream
asar; no Linux-only init in this packaging contributes to the
double-load.

## Workaround (For MCP Authors)

Until upstream fixes it, MCPs that touch shared external state
can defend themselves:

1. **Lockfile + staleness check.** `fs.openSync('wx')` with PID,
   verified live via `process.kill(pid, 0)`. The second instance
   detects a live owner and backs off, or reclaims a stale lock.
   Reclaim atomically — write the new lock to a temp path and
   `rename()` over the stale one, never `unlink()` then re-open
   (a third instance can win the gap).
2. **Idempotent state writes.** Resolve target files/keys from
   the incoming message payload rather than from in-process
   state, so two instances writing the same broadcast end up at
   the same target instead of cross-contaminating per-process
   keys.

The reporter's `baro-voyager` MCP shipped both in commit
`cb7bfbb` as a worked reference.

## Routing Upstream Reports

- **Primary:** in-app feedback (Help → Send Feedback) or
  `support@anthropic.com`. The duplication happens in
  closed-source Desktop main.
- **Secondary:** an SDK-transport-flavored issue on
  [`anthropics/claude-agent-sdk-typescript`](https://github.com/anthropics/claude-agent-sdk-typescript)
  is defensible — the spawn path goes through the **Claude Agent
  SDK's** `query` transport (`spawnLocalProcess` / `Du.spawn`),
  which is shared surface area. Reference the missing `hZ`
  consultation explicitly.

The embedded Claude Code CLI subprocess inside Claude Desktop is
**not** the cause — it receives `--mcp-config` only when the
config map is non-empty, and is empty in this flow. Don't route
to `anthropics/claude-code` claiming the CLI itself is
double-spawning MCPs.
