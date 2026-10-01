# Upstream report draft: Cowork device registry never links on Linux (issue #780)

This is the upstream bug report covering [#780](https://github.com/aaddrick/claude-desktop-debian/issues/780). **Drafted 2026-07-11, not yet filed** (Claude Desktop has no in-app engineering report path — see the filing-path note in [`README.md`](README.md)). Revisit on the next `CLAUDE_DESKTOP_VERSION` bump: if Anthropic ships the Linux hardware-key backend, the `linux-not-yet-supported` string disappears from the native `.node` and this report is obsolete.

## Template mismatch note

The `anthropics/claude-code` bug template is built for the Claude Code CLI, not Claude Desktop. Fields like "Claude Code Version" and "Terminal/Shell" don't apply cleanly. Other Claude Desktop reports in the same repo work around this by putting `N/A — Claude Desktop <version>` in the version field and selecting `Other` for terminal (see #43705, #36319, #14807).

## Title

```
[BUG] Claude Desktop for Linux 1.18286.2: Cowork cloud tasks stuck "Not linked to a computer" — remote-tools device can never register because @ant/claude-native has no Linux hardware-key backend (hardwareKeyGetOrCreate throws linux-not-yet-supported)
```

## Form fields

### Preflight Checklist

- [x] I have searched existing issues and this hasn't been reported yet
- [x] This is a single bug report
- [x] I am using the latest version of Claude Code

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian), which repackages the official Linux `.deb` into RPM/AppImage/Nix/AUR formats. A user hit a Cowork failure with a fully green KVM stack, so I read the shipped 1.18286.2 bundle to find the cause.

On Linux, every newly created Cowork task comes up "Not linked to a computer — To use files and apps on your computer, start a new task." New tasks can't read local files or run shell/Desktop Commander; `device_bash` / `device_list_dir` / `project_memory_*` report "no such tool" and the `remote-devices` server is absent from the MCP list. Tasks created earlier that run on-device (HostLoop) keep full access. A full reboot doesn't help — the device-registration step itself never completes for new tasks.

The device registry file `~/.config/Claude/ant-device-registry.json` stays at `{"<ACCOUNT_ID>":"none:<timestamp>"}` across app restarts and OS reboots. The remote-tools bridge WebSocket authenticates fine (`[remote-tools-device] authenticated` against `bridge.claudeusercontent.com`), and `bridge-state.json` shows `enabled:true, userConsented:true` — but the device never becomes "available".

The root cause is that the hardware-backed device key Cowork's `DeviceRegistry` depends on is not implemented on Linux. The native binding `node_modules/@ant/claude-native/claude-native-binding.node` (ELF x86-64) exports `hardwareKeyGetOrCreate`, `hardwareKeyGetPublic`, `hardwareKeySign`, `hardwareKeyDelete`, and the binary carries the literal string `hardwareKeyUnavailable: linux-not-yet-supported`. On macOS/Windows these are Secure-Enclave / TPM backed; on Linux they throw. Every device sign/attest path dead-ends there:

- `Ger(A)` calls `hardwareKeyGetOrCreate(...)` on the binding → throws `linux-not-yet-supported`.
- The error mapper maps that string → availability reason `"linux"`, so `DeviceRegistry.getAvailability` returns `{available:false, isHardwareBacked:false, reason:"linux"}`.
- The own-pubkey probe resolves to `undefined`, so the row-PK resolver fetches `/api/organizations/{org}/cowork/remote_devices` but can never match a local enclave key. When no device matches, it writes `"none:" + Date.now()` into `ant-device-registry.json` — exactly the `none:<ts>` the user sees.
- `signAttestationPreimage` / `signForSessionHeader` / `signCreateSessionBind` all route through the same key and throw, so the device can't register server-side or bind a session.

This is a platform-parity gap, not a design choice: the same API is hardware-backed on macOS/Windows, and Linux Cowork is otherwise fully built — the KVM stack evaluates as supported, the VM boots, virtiofs shares the tree, and the bridge authenticates. Only the device-attestation layer is stubbed.

### What Should Happen?

A new Cowork task on Linux should register/attach the local device so "use files and apps on your computer" works, matching macOS/Windows. Two paths, either or both:

1. **Implement the Linux hardware-key backend** in `@ant/claude-native` — TPM 2.0 where available, with a software-key fallback (a keyring/keyctl-backed or file-backed key) where it isn't. That closes the parity gap directly.
2. **Expose a supported way to default new tasks to HostLoop on Linux.** Pre-existing on-device sessions already run in HostLoop (`hostLoopMode:true`), which bypasses device attestation entirely and works today — but it isn't user-selectable in this build. The older `claude_desktop_linux_config.json` / `coworkIsolationBackend` knobs that might have forced this are removed in 1.18286.x (zero references; the app reads only `claude_desktop_config.json`). A supported toggle would give Linux users a working path until (1) lands.

### Error Messages/Logs

Device registry stuck at `none` across restarts and reboot:

```
~/.config/Claude/ant-device-registry.json
{"<ACCOUNT_ID>":"none:<timestamp>"}
```

Bridge authenticates but device never becomes available:

```
~/.config/Claude/logs/main.log
[remote-tools-device] connecting wss://bridge.claudeusercontent.com/devices/<ENV>_<ACCOUNT>/fedora/bridge
[remote-tools-device] authenticated
```

Working (pre-existing) sessions run in host-loop mode:

```
[HostLoop] Session local_<id>: initializing → running
```

The native binding string that gates it all (from `strings` on the shipped `.node`):

```
hardwareKeyUnavailable: linux-not-yet-supported
```

### Steps to Reproduce

1. Linux host with a working Cowork stack (KVM, vsock, QEMU, OVMF, virtiofsd all present; `--doctor` Cowork section all green).
2. Sign in and start a new task from the desktop app.
3. Task shows "Not linked to a computer"; no local file/app/shell access; every new task is cloud-only.
4. Reboot; repeat step 2 — identical result.
5. Open a task created earlier that ran on-device — it still has full local access.

Inspect `~/.config/Claude/ant-device-registry.json`: it holds `"none:<ts>"` and never advances to a `pk1:` entry.

### Claude Model

Not sure / Multiple models

### Is this a regression?

I don't know

### Last Working Version

(leave blank)

### Claude Code Version

```
N/A — this is a Claude Desktop issue. Bundle version: 1.18286.2
```

### Platform

Anthropic API

### Operating System

Ubuntu/Debian Linux

### Terminal/Shell

Other

### Additional Information

Anchor table for 1.18286.2. Minified symbols rename between releases, so each row carries a stable string anchor. Line numbers are against the beautified bundle (`asar extract` + `prettier` on the official Linux `.deb`); they're indicative, not load-bearing.

| Role | Symbol in 1.18286.2 | Stable anchor | Beautified loc |
|---|---|---|---|
| Native key exports | (Rust binding) | `hardwareKeyGetOrCreate` / `...GetPublic` / `...Sign` / `...Delete` | `@ant/claude-native/claude-native-binding.node` |
| Linux stub string | (Rust binding) | `hardwareKeyUnavailable: linux-not-yet-supported` | same `.node` |
| Key create → throws | `Ger(A)` | `e.hardwareKeyGetOrCreate(t)` | index.js:399398 |
| Error → reason mapper | `UUn` | `.includes("linux-not-yet-supported") ? "linux"` | index.js:399381 |
| Availability IPC | `getAvailability` | `{available, isHardwareBacked, reason}` | index.js:399118 |
| Own-pubkey probe | `xtt` | probes `Ger().getPublicKey()`, memoized | index.js:399356 |
| Registry filename | `SUn` | `"ant-device-registry.json"` (under `userData`) | index.js:399218 |
| `none:` writer | `bUn()` | `"none:" + Date.now()` | index.js:399260 |
| `pk1:` writer | `vUn(A,e)` | `"pk1:" + fp + ":" + rowPk` | index.js:399249 |
| Row-PK resolver | `Ler(A,e,t)` | fetch `/cowork/remote_devices`, else write `none:` | index.js:399273 |
| Remote-devices fetch | — | `/api/organizations/${A}/cowork/remote_devices` | index.js:399305 |
| Bridge logger | — | `[remote-tools-device]` | index.js:403735 |
| HostLoop IPC | `isHostLoopModeEnabled` | `ClaudeVM.isHostLoopModeEnabled` | index.js:77949 |

The `none:` vs `pk1:` distinction is the whole story: `pk1:` means a hardware-backed key matched a server-side device row (registered); `none:` means the resolver couldn't match, which on Linux is guaranteed because `hardwareKeyGetOrCreate` throws before any key exists.

Full downstream provenance: [aaddrick/claude-desktop-debian#780](https://github.com/aaddrick/claude-desktop-debian/issues/780). The reporter gathered the host evidence (registry file, bridge/HostLoop log lines, bridge-state) directly during a troubleshooting session; I traced the mechanism against the shipped bundle.

One question where a one-line answer would help us route this downstream: is a Linux hardware-key backend on the roadmap, or is HostLoop the intended Linux path for now? If it's HostLoop, a supported way to default new tasks to it would unblock Linux users immediately.

---
Written by Claude Opus 4.8 via [Claude Code](https://claude.ai/code)

## Filing checklist

When you're ready to file:

1. Open https://github.com/anthropics/claude-code/issues/new?template=bug_report.yml
2. Paste each section above into the matching form field
3. Submit
4. Drop the GitHub issue URL as a comment on [#780](https://github.com/aaddrick/claude-desktop-debian/issues/780) so the trail is bidirectional
5. Per the survival playbook: author comment within 3 days; `has repro` phrasing is already in the body

## Voice and authorship

Drafted against the form schema in `anthropics/claude-code/.github/ISSUE_TEMPLATE/bug_report.yml`, from static analysis verified against the beautified 1.18286.2 bundle in `build-reference/` (native-binding strings verified with `strings` on the shipped `.node`).
