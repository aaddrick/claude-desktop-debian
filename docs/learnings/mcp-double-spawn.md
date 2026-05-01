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

Multiple session managers live inside Electron main, each
holding its own MCP coordinator state with its own registry. The
two that spawn stdio MCPs from `claude_desktop_config.json` and
trigger this bug:

| Manager class            | IPC namespace                            | Coordinator     | Logs prefix |
|--------------------------|------------------------------------------|-----------------|-------------|
| `LocalSessions`          | `claude.web_$_LocalSessions_$_*`         | `n2t("ccd")`    | `[CCD]`     |
| `LocalAgentModeSessions` | `claude.web_$_LocalAgentModeSessions_$_*`| `n2t("cowork")` | `[LAM]`     |

A third coordinator class — `SshMcpServerManager` — follows the
same per-coordinator-registry pattern but uses an SSH transport
and doesn't contribute to the local-node double-spawn. Its
existence does say something about the design intent: per-
coordinator isolated state appears to be a deliberate
architectural pattern, not a one-off oversight.

The logs prefixes are what to grep `~/.config/Claude/logs/` for to
confirm a session is hitting both coordinators (and therefore this
bug specifically).

Each coordinator dedups **within its own scope**: CCD's launch
function serializes per server name through a promise queue and
shuts down any prior entry before respawn; LAM's
`getOrCreateConnection` reuses connected entries from its own
`connections` Map. The double-spawn is strictly **cross-
coordinator** — one process per coordinator that has the server
in its config.

In current versions (verified against `1.5354.0`) both
coordinators route their transport creation through a shared
Claude Desktop-side factory, but the factory itself doesn't
dedupe and the per-coordinator registries above it aren't
unified.

Net result: 2 coordinators × N configured MCPs = 2N processes.

### Symbol drift

Minified symbols rename across upstream releases. Issue
[#546](https://github.com/aaddrick/claude-desktop-debian/issues/546)
maintains the current symbol mappings (verified against
`1.5354.0`) plus extraction regexes that work against both
minified and beautified bundles.

## Status

**Upstream Claude Desktop bug. Not patchable in this repo.** The
proximate cause is in Claude Desktop's session manager wiring. A
real fix needs either:

- LAM proxying its MCP traffic through CCD's existing connection
  (so only one coordinator owns the spawn), or
- A multiplexing wrapper transport that lets one spawned stdio
  child serve multiple SDK clients via demuxing.

Stdio MCP is 1:1 at the protocol layer — one stdin/stdout pair,
one transport, one SDK client. Sharing one process across
coordinators requires real engineering, not a sed patch on
minified code, and exceeds this repo's "minimal Linux-compat
patches only" charter.

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
  closed-source Desktop main, in the per-coordinator registry
  wiring.
- **Secondary:** an issue on
  [`anthropics/claude-agent-sdk-typescript`](https://github.com/anthropics/claude-agent-sdk-typescript)
  is defensible only if it advocates for a shared-transport /
  multiplex primitive that would make this kind of bug
  structurally harder. The SDK's spawn implementation is doing
  what it's told — the bug is one layer up, in Claude Desktop
  calling spawn from two separate coordinators.

The embedded Claude Code CLI subprocess inside Claude Desktop is
**not** the cause — it receives `--mcp-config` only when the
config map is non-empty, and is empty in this flow. Don't route
to `anthropics/claude-code` claiming the CLI itself is
double-spawning MCPs.
