# Official cowork-linux-helper socket protocol (1.18286.0)

The wire contract the official client speaks to its helper over
`$XDG_RUNTIME_DIR/claude-cowork-vm.sock`, extracted from the beautified
bundle (`build-reference/app-extracted/.vite/build/index.js`, line refs
below drift between releases). `cowork-vm-service.js` implements the
server side of this contract when `COWORK_VM_BACKEND=bwrap` swaps it in
for the native helper.

## Spawn contract

The client spawns the helper itself (`~157177`):

```
<helper> -socket $XDG_RUNTIME_DIR/claude-cowork-vm.sock
```

- stdio is piped; stdout/stderr lines land in `cowork_vm_node.log`.
- Restart backoff is client-owned (exponential 1 s → 60 s, reset after
  30 s uptime). The helper just needs to bind the socket and serve.
- On `ENOENT`/`ECONNREFUSED` during a request, the client respawns the
  helper and retries (5 attempts, 1 s apart).
- The client connects via `@ant/claude-native`'s
  `connectUnixSocketSameUid` — the server process must run as the same
  uid (a locally spawned child always does). The socket's parent dir
  must be `0700`, same-uid, and the socket path must not be a symlink
  (client-side checks at `~157010`/`~157026`).

## Framing

Every connection, both directions: 4-byte big-endian length prefix +
UTF-8 JSON body (`~157249`). Max body 10 MiB (`~157259`).

## Connection modes

The client opens three kinds of connections to the same socket:

1. **One-shot request** (`~157268`): `{method, params?}` (no `id`),
   one `{success, result?|error?}` reply, then the client half-closes.
   Used always when remote-config flag `770567414` is on, and as the
   fallback when the persistent pipe can't connect.
2. **Persistent RPC pipe** (`~157384`): `{method, id, params?}` with an
   incrementing numeric `id`; replies `{success, result?|error?, id}`
   matched by `id`, out-of-order allowed. Client-side timeout 30 s
   (remote-configurable). Immediately after connecting, the client
   sends `configure {userDataName, userDataRoot, sessionOnly: true}`
   on the pipe.
3. **Event subscription** (`~157539`): client sends
   `{method: "subscribeEvents", params: {userDataName, userDataRoot}}`
   and expects an ack frame `{success: true}` FIRST, then a stream of
   event frames on the same connection (server → client only):

   | frame | shape |
   |---|---|
   | stdout/stderr | `{type, id, data}` |
   | exit | `{type: "exit", id, exitCode?, signal?, oomKillCount?}` |
   | error | `{type: "error", id, message, fatal?}` |
   | networkStatus | `{type: "networkStatus", status}` |
   | apiReachability | `{type: "apiReachability", status}` |
   | startupStep | `{type: "startupStep", step, status}` |
   | guest request | `{type: "request", id, method, params}` |

   Guest requests are answered out-of-band by the client via the
   `sendGuestResponse` RPC. If the subscription drops, the client
   resubscribes after 1–5 s.

`userDataName`/`userDataRoot` identify the Electron profile (multi-
profile isolation); the server may scope per-profile state by them.

## Methods

`params` / expected `result` (all optional fields may be absent):

| method | params | result consumed by client |
|---|---|---|
| `configure` | `{userDataName, userDataRoot, networkDrives, memoryMB?, cpuCount?, smolBinPath, logDir, virtiofsdPath, firmwareCodePath, firmwareVarsTemplatePath}` (also `{…, sessionOnly: true}` pipe-connect variant) | — |
| `subscribeEvents` | `{userDataName, userDataRoot}` | ack `{success: true}`, then events |
| `createVM` | `{bundlePath, diskSizeGB}` | — |
| `startVM` | `{bundlePath, memoryGB?, cpuCount?, apiProbeURL?}` | — |
| `stopVM` | — | — |
| `isRunning` | — | `{running}` |
| `isGuestConnected` | — | `{connected}` |
| `spawn` | `{id, name, command, args, isResume, cwd?, env?, additionalMounts?, allowedDomains?, oneShot?, mountSkeletonHome?, oauthToken?}` | `{failedMounts?}` |
| `kill` | `{id, signal}` | — |
| `writeStdin` | `{id, data}` | — |
| `isProcessRunning` | `{id}` | `{running, exitCode?}` |
| `sendGuestResponse` | `{id, resultJson?, error?}` | — |
| `setDebugLogging` | `{enabled}` | — |
| `mountPath` | `{processId, subpath, mountName, mode}` | — |
| `readFile` | `{processName, filePath}` | `{content}` |
| `getSessionsDiskInfo` | `{lowWaterBytes}` | `{totalBytes, freeBytes, sessions[]}` |
| `deleteSessionDirs` | `{names[]}` | `{deleted[], errors{}}` |
| `pruneSessionCaches` | `{onlyIfFreeBytesBelow, includeSessionTmp, sessionTmpOlderThanSeconds}` | `{prunedSessions[], skippedSessions[], freedBytes, errors{}}` |
| `installSdk` | `{sdkSubpath, version}` | — |
| `addApprovedOauthToken` | `{token}` | — |
| `getNetworkDrives` | — | `{drives[]}` (Linux client builds `networkDrives` as `[]`) |

`isRunning`, `isGuestConnected`, `isProcessRunning`, `readFile` are
called through an idempotent-retry wrapper — they must be safe to
repeat.

## Boot sequence the server must satisfy

From the client's Linux boot orchestrator (`~283525`):

1. `configure` (RPC) — "Linux VM helper configured" logged on success.
2. `startVM {bundlePath, memoryGB?, cpuCount?, apiProbeURL?}` — must
   return success; the client treats a thrown error as `vm_boot_error`.
3. The client then polls `isGuestConnected` (a few times per second,
   multi-minute timeout) until `{connected: true}`.
4. `installSdk {sdkSubpath, version}` — the `sdk_install` step.
5. Cowork sessions arrive as `spawn` calls; their stdout/stderr/exit
   flow back as events on the subscription connection.

Balloon-related methods (`getMemoryTier`, `enableBalloonMonitoring`,
`getHostMemoryInfo`) are optional-chained client-side and absent from
the Linux client — never called over the wire.

The client's heartbeat and "already connected" fast path both reduce to
`isGuestConnected`, so the server must keep answering it truthfully for
the daemon's lifetime.

## Support gate context (not part of the wire protocol)

The client only dials the helper when the `yukonSilver` evaluator
(`~281877`) reports `supported`, which requires qemu/OVMF/virtiofsd,
`/dev/kvm`, and `/dev/vhost-vsock`. The `COWORK_VM_BACKEND=bwrap` asar
patch short-circuits that evaluator and swaps the spawn target; see
`scripts/patches/cowork-bwrap.sh`.
