# Dossier: Cowork Linux reroute (`patch_cowork_linux` + `cowork-vm-service.js` bwrap daemon)

Unit: the patch suite that reroutes Claude Desktop's Cowork (Local Agent) mode
from the macOS/Windows VM helper to a hand-written Node daemon on Linux.
Files on main: `scripts/patches/cowork.sh` (`patch_cowork_linux()`, lines
217–1001) and `scripts/cowork-vm-service.js` (2,766 lines). Subsystem owner:
@RayCharlizard (per memory/CODEOWNERS note; not re-verified against
`.github/CODEOWNERS` in this pass).

Note on scope: `scripts/patches/cowork.sh` on main also carries
`patch_asar_path_filter()`, `patch_asar_argv_file_drop_guard()` (#383/#622/#632
asar-argv guards — a separate matrix row, "cowork asar-path guards") and
`install_node_pty()` (node-pty row). Those are other units' dossiers; this one
covers only the reroute + daemon.

## Mechanism

Two cooperating halves, wired together by the build:

**1. The asar patch — `patch_cowork_linux()`** (`main:scripts/patches/cowork.sh:217`).
Runs a single embedded `node` heredoc (`COWORK_PATCH`) against
`app.asar.contents/.vite/build/index.js`. Version guard at the top:
`if ! grep -q 'vmClient (TypeScript)' "$index_js"` → skip entirely on bundles
without Cowork code (cowork.sh:221). A `patchCount` tally prints
`WARNING: Some patches failed` if fewer than 5 land (cowork.sh:991). The
numbered patches, with their load-bearing anchors:

- **Patch 1 — startVM support gate** (FATAL on miss). Anchors on the unique
  log string `'[startVM] VM not supported'`, then rewrites the nearest
  preceding `if((r==null?void 0:r.status)!=="supported")` (the yukonSilver
  feature-flag check) to
  `if(process.platform!=="linux"&&(...)!=="supported")` so Linux passes
  through startVM (cowork.sh:266–299). Idempotency: regex re-test for the
  already-injected `process.platform!=="linux"&&` form (cowork.sh:269).
- **Patch 1b — support *evaluator*** (WARN on miss). Anchors on the
  evaluator's opening
  `/(const [\w$]+="win32",([\w$]+)=process\.arch;if\(\2!=="x64"&&\2!=="arm64"\))/`
  and prepends `if(process.platform==="linux")return{status:"supported"};` so
  the renderer un-grays the Cowork tab (cowork.sh:321–341).
- **Patch 1c — keep the VM-image download disabled** (WARN on partial).
  Two sites: the download driver
  (`/(\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported")\?!1:/`, confirmed
  by the `'[downloadVM] Download already in progress'` string in the same
  function) and the warm prefetch
  (`if(!X||X.status!=="supported"){await Y([]);return}`); both get an ORed
  `process.platform==="linux"` so 1b's "supported" flip cannot re-arm the
  multi-GB rootfs download that #337 disabled (cowork.sh:359–399).
- **Patch 2 — vmClient module-load gate** (WARN on miss). Anchors on the
  unique string `"vmClient (TypeScript)"`, finds the last `return FN()?`
  before it (FN = the minified isMsix detector, captured dynamically), and
  widens it to `return (FN()||process.platform==="linux")?` — explicitly does
  NOT patch the detector itself, which also drives install-type detection
  (cowork.sh:401–449).
- **Patch 3 — socket path**. Regex-matches the Windows named-pipe string
  `/([\w$]+)(\s*=\s*)"([^"]*\\\\[^"]*cowork-vm-service[^"]*)"/` and replaces
  the assignment with a ternary:
  `process.platform==="linux"?(process.env.XDG_RUNTIME_DIR||"/tmp")+"/cowork-vm-service.sock":"<pipe>"`
  (cowork.sh:455–470).
- **Patch 4 — bundle manifest**. Inserts `,linux:{x64:[],arm64:[]}` into the
  VM-files manifest (located via a `sha:"<40-hex>"` anchor + balanced-brace
  `extractBlock` over the `files` object). Empty arrays exploit `[].every()`
  vacuous truth so the download IPC short-circuits (cowork.sh:472–512).
- **Patch 4b — auto-select suppression (#341)**. Rewrites
  `getDownloadStatus(){return X()?E.Downloading:Y()?E.Ready:E.NotDownloaded}`
  to return `E.NotDownloaded` on Linux, killing the "download just finished"
  auto-navigation on every launch (cowork.sh:514–553).
- **Patch 6 — daemon auto-launch** (the reroute's keystone). Anchors on
  `'VM service not running. The service failed to start.'`. Step 1 expands the
  retry loop's `VAR.code==="ENOENT"` to also match `ECONNREFUSED` on Linux
  (stale sockets refuse instead of ENOENT). Step 2 injects, before the retry
  delay (`await FN(delay)`), a fork of
  `process.resourcesPath/app.asar.unpacked/cowork-vm-service.js` with
  `ELECTRON_RUN_AS_NODE:"1"`, `detached:true`, stdio appended to
  `~/.config/Claude/logs/cowork_vm_daemon.log`, PID stored at
  `global.__coworkDaemonPid`, guarded by a 10 s timestamp cooldown
  (`FUNC._lastSpawn`, fallback `globalThis._lastSpawn`) so a dead daemon can
  respawn without fork storms (issue #408). Idempotency:
  `code.includes('cowork-autolaunch')` (cowork.sh:562–692).
- **Patch 6b — reinstall delete list** (WARN no-op on current bundles).
  Extends `const X=["rootfs.img",...]` with `"sessiondata.img"` and
  `"rootfs.img.zst"` so auto-reinstall actually recovers (#408 secondary
  cause). Anchor gone since the yukonSilver refactor — documented safe no-op
  (cowork.sh:694–739).
- **Patch 8 — VM-download tmpdir** (WARN no-op on current bundles). Rewrites
  `mkdtemp(path.join(os.tmpdir(),"wvm-"))` to use the bundle dir on Linux
  (tmpfs ENOSPC, ~9 GB decompress); anchor gone post-yukonSilver
  (cowork.sh:747–798).
- **Patch 9 — Linux smol-bin copy**. Injects an
  `if(process.platform==="linux"){...}` block after the win32 block's
  `"[VM:start] Windows VM service configured"` anchor that copies
  `smol-bin.${arch}.vhdx` without calling the Windows-only `_.configure()`
  (which hung with "Request timed out", #315). All six minified vars
  (path/fs/logger/stream/arch/bundle) are extracted dynamically with `[$\w]+`
  classes (the `$e` fs-var trap, issue #418); idempotency keys on the fork's
  own injected `to bundle (Linux)` sentinel, not upstream's similar log
  (cowork.sh:800–931).
- **Patch 10 — quit handler**. Finds the `registerQuitHandler:` export,
  appends a Linux-only registration `cowork-linux-daemon-shutdown` that
  SIGTERMs `global.__coworkDaemonPid` after verifying `/proc/PID/cmdline`
  contains `cowork-vm-service` (PID-reuse safety), then polls up to 10 s
  (cowork.sh:933–987).
- Patches 5 and 7 are documented no-ops (upstream code already win32-gated;
  cowork.sh:555–559, 741–745).

**2. The daemon — `scripts/cowork-vm-service.js`** (2,766 lines on main).
Header block (lines 1–28) documents the contract: listens on
`$XDG_RUNTIME_DIR/cowork-vm-service.sock` speaking the same 4-byte
big-endian length-prefixed JSON protocol as the Windows named pipe.
Architecture: `VMManager` dispatcher + pluggable backends — `HostBackend`
(no isolation), `BwrapBackend` (bubblewrap namespace sandbox, the default),
`KvmBackend` (QEMU/KVM + vsock + virtiofs/9p). Selection order
bwrap → kvm → host, overridable via `COWORK_VM_BACKEND`; debug via
`COWORK_VM_DEBUG=1`; always-on lifecycle logging to
`~/.config/Claude/logs/cowork_vm_daemon.log` with the log dir pre-created at
startup (issue #408 comment at the `fs.mkdirSync(path.dirname(LOG_FILE))`
site).

**Build wiring**: the daemon is copied into the asar
(`main:scripts/patches/app-asar.sh:142-143`) and — because
`child_process.fork` cannot execute from inside an asar — into
`app.asar.unpacked/cowork-vm-service.js` by `finalize_app_asar()`
(`main:scripts/staging/electron.sh`, "Copy cowork VM service daemon (must be
unpacked for child_process.fork)"). Launcher scripts gained
`cleanup_stale_cowork_socket` / orphaned-daemon cleanup as part of the same
subsystem (PR #269 commit body: "Add cleanup_stale_cowork_socket() to
launcher scripts (all formats)").

## Origin

- **Predecessor (stub era)**: `cad0b06` (author chukfinley, author-dated
  2026-01-25 on the contributor fork) — "feat: add experimental Cowork mode
  support for Linux". A JavaScript stub of `@ant/claude-swift` that simulated
  the VM lifecycle and spawned Claude Code directly on the host. Shipped with
  a KNOWN ISSUE: stdout events from the spawned process never fired in
  Electron, so Cowork loaded but displayed no responses (documented in the
  commit body, which links the external report
  chukfinley/claude-desktop-linux#1). It landed in-repo via PR #198
  (@chukfinley, `chukfinley/feature/cowork-mode-support`, merge commit
  `b8b2893`, merged 2026-02-16) — so the *in-tree* stub era lasted hours, not
  the three weeks the 2026-01-25 author date suggests: `b8b2893` → `25e7932`
  → `4d837d3` are all dated 2026-02-16 in main's history, in that order. No
  in-repo motivating issue was found.
- **True origin of this unit**: `25e7932` (2026-02-16) — "feat: fix Cowork
  mode communication for Linux". Deleted `scripts/claude-swift-stub.js` and
  replaced the stub approach with the current architecture: a new 630-line
  `scripts/cowork-vm-service.js` "implementing Windows pipe protocol over
  Unix socket" plus `patch_cowork_linux()` with 6 index.js patches in
  `build.sh` (the function predates the `scripts/patches/` split). The commit
  body records the first daemon bug set: stripping `CLAUDECODE=1` (the
  "cannot be launched inside another Claude Code session" trigger),
  preserving `CLAUDE_CODE_*` auth env, `error`→`message` event field fix,
  guest-path stripping from `CLAUDE_CONFIG_DIR`/cwd/`--plugin-dir`/`--add-dir`,
  synchronous stale-socket cleanup, and file-based debug logging.
- **Situation at the time**: upstream Cowork was macOS/Windows-only — the
  Electron client talked to a Windows `cowork-vm-service` over a named pipe
  (the string Patch 3 matches), and the Linux repackage had no VM helper at
  all. Without the unit, Cowork mode was dead on Linux (stub era) or entirely
  gated off (post-yukonSilver).

## Revision history

Substantive changes in date order (formatting/lint-only commits skipped):

- `cad0b06` (authored 2026-01-25; merged into main 2026-02-16 via PR #198,
  merge `b8b2893`) — claude-swift stub predecessor (see Origin).
- `25e7932` 2026-02-16 — stub replaced by daemon + `patch_cowork_linux()`
  (see Origin). Same day, `4d837d3` simplified the daemon and the README
  notice (refactor).
- `2017011` 2026-02-25 — first anchor-rot fix for the platform gate: v1.1.4173
  renamed the anchor `Unsupported platform` → `unsupported_platform`, so
  Patch 1 silently missed and the app crashed at startup on Linux. The commit
  matches both anchor strings, widens the fallback regex search from 50 to
  200 chars, and — decisively — makes Patch 1 failure a hard build error
  (`process.exit(1)`) "to prevent shipping packages that crash at runtime",
  establishing the FATAL-on-miss property the 2026-06 yukonSilver breakage
  narrative (`83ea637`, below) depends on. "Fixes #259".
- `4929dde` 2026-02-28 (PR #269) — monolithic VMManager refactored into
  Host/Bwrap/Kvm pluggable backends; `COWORK_VM_BACKEND` override; `--doctor`
  Cowork section; Patch 8 (tmpfs ENOSPC); ENOENT→ECONNREFUSED expansion +
  launcher stale-socket cleanup; bwrap DNS fix (systemd-resolved bind);
  `$HOME` mounted read-only; security-review fixes (execFileSync, readFile
  path validation, QMP timer leak) — all itemized in the PR's commit bodies.
- `d7a4606` 2026-03-03 — daemon guest-path translation rework: the daemon had
  been *stripping* `--plugin-dir`/`--add-dir` args containing VM guest paths
  (`/sessions/{id}/mnt/{name}/...`), so Claude Code never found skills or
  plugins. Added `translateGuestPath()` with path-traversal prevention and
  `buildMountMap()` (merges `additionalMounts` + mountBinds, rejects paths
  escaping the home directory); refactored `cleanSpawnArgs()`,
  `buildSpawnEnv()` (`CLAUDE_CONFIG_DIR`), and `resolveWorkDir()` from
  stripping to translating guest paths; `BwrapBackend.spawn()` bind-mounts
  the validated mount map; env block redacted from request logs (may contain
  API keys). "Fixes #265". This is the foundation the later path-translation
  fixes (#373 double-nested homes, PR #411 allowedTools translation) build
  on.
- 2026-03-19 KVM wire-protocol series (issue #288, landed via PR #300 then
  hardened by `932044d` "harden cowork VM service daemon after #300 merge"):
  `af1f2e3` ready event in FORWARDED_EVENTS, `0eb5ce3` wait for virtiofsd
  socket, `fc0d55f` shared-memory virtiofs, `ae92893` session disk +
  smol-bin drive, `d96b787` virtiofs tag/guest mount, `283e669` guest RPC
  wire protocol, `06a8cd3`/`10e745a` installSdk forwarding + writeStdin as
  notification, `5d6f897` SDK-install simplification, `1d7699e` app-provided
  bundlePath, `a5f16b2` extract smol-bin + plugin shim from the Windows
  installer, `e8a5651` virtio-9p fallback when virtiofsd fails, `473b0ba`
  `security_model=none` for unprivileged 9p. PR #269's earlier commit had
  already fixed the vsock direction/port (guest connects to host, port 51234,
  "confirmed via disassembly of the guest binary").
- `b9c3573` 2026-03-20 — echo request id in RPC responses; fixes the
  persistent-connection timeout (issue #312).
- `4711b24` 2026-03-20 — Patch 9 introduced: the earlier approach of widening
  the win32 platform gate also activated the Windows-HCS `_.configure()`
  call, which hung with "Request timed out: configure" on Linux. Replaced
  with a separate Linux-only block injected after the win32 block that copies
  the smol-bin VHDX to the bundle dir (KVM guest SDK access) without calling
  `_.configure()`. "Fixes #315".
- `219ddbe` 2026-03-20 (PR #309, author ecrevisseMiroir) — bwrap backend
  mounts at guest paths and uses a minimal sandbox root (security fix).
- `3ada749` 2026-03-21 — bubblewrap made the default backend
  (bwrap → KVM → host), KVM behind `COWORK_VM_BACKEND=kvm`; "Fixes #326".
- `aa6b87d` 2026-03-22 — Patch 4 given real Linux CDN checksums (issue #329);
  superseded a day later by `a3190c3` 2026-03-22/23 (PR #337) which rewrote
  Patch 4 to empty `linux:{x64:[],arm64:[]}` arrays because the checksums
  drifted from CDN content and caused an infinite download-retry loop —
  "Fixes #334, Closes #329, Closes #332"; commit body notes the root cause:
  Patch 1 had made the download path reachable on bwrap-only installs.
- `9afacd5` 2026-03-25 (PR #345) — Patch 9 hardened: the initial block
  hardcoded five minified variable names (`Qe`, `ft`, `vg`, `tt`, `uX`),
  which change between upstream releases, crashing Cowork with
  `"Qe is not defined"` (issue #344). All six vars (path/fs/logger/stream/
  arch/bundle) are now extracted dynamically from the nearby win32 block with
  regexes handling both minified and beautified code, plus diagnostic logging
  of the extracted names. This is the extraction machinery the Mechanism
  section describes.
- `cc6230e` 2026-03-25 — remove self-referential `.mcpb-cache` symlinks
  before bwrap mount (PR #346).
- `e82975c` 2026-03-23 + `58b3562` 2026-03-30 (PR #340, author cbonnissent;
  feature issue #339) — configurable `coworkBwrapMounts` via
  `claude_desktop_linux_config.json`.
- `0bcc245`/`9b3c8f4` 2026-04-03 — resolve double-nested home paths in the
  daemon's mountPath handling (issue #373).
- `379d8eb` 2026-04-12 (PR #389, @RayCharlizard) — translate
  `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` on HostBackend.
- `605ccab` 2026-04-12 (PR #391) — Patch 10 quit handler; upstream's
  `cowork-vm-shutdown` handler needs the Swift addon absent on Linux, so the
  daemon survived app exit leaving QEMU/virtiofsd running; "Fixes #369".
- `cb0d636` 2026-04-16 — Patch 6 one-shot `_svcLaunched` boolean replaced by
  the 10 s `_lastSpawn` cooldown + daemon stdio to the log file; Patch 6b
  added (issue #408: daemon died mid-session and never recovered, persisted
  across reboots because upstream preserved sessiondata.img/rootfs.img.zst).
  `a349dee` 2026-04-16 added always-on lifecycle logging to the daemon (#408).
- `2f6194f` 2026-04-17 (PR #421, author @Joost-Maker, merge commit
  `2fd9faf`) — widen all six Patch 9 extraction regexes from `(\w+)` to
  `[$\w]+` after Claude ≥ 1.3109.0 renamed the win32 fs var `e` → `$e`: the
  old regex captured the suffix `e`, which resolves at runtime to the options
  object, dying with `TypeError: e.existsSync is not a function` and blocking
  Cowork boot. Also adds a defensive strip step (brace-counts and removes any
  future upstream-emitted Linux block so two blocks never compete). Commit
  body records end-to-end verification (`vars: ... fs=$e`, clean VM start).
  "Fixes #418".
- `37379b4` 2026-04-18 — HostBackend resolves working directory from the
  primary mount (PR #392).
- `9514623` 2026-04-18 — translate guest paths inside `--allowedTools` /
  `--disallowedTools` (PR #411).
- `36d08ec` 2026-04-18 — only route `claude` commands through the SDK binary
  (PR #430; motivating issue #427, `mcp__workspace__bash` hitting "Not logged
  in").
- `c4fe361` 2026-04-18 — home `--dir` before SDK `--ro-bind` in the bwrap
  argv (PR #426).
- `87f4f0f` 2026-04-18 — merge revalidating Patch 6 against upstream
  1.3109.0 (anchor-rot maintenance).
- `3c84324` 2026-04-19 — diagnose AppArmor user-namespace blocks on the bwrap
  probe (issue #351, PR #434) — Ubuntu 24.04's userns restriction silently
  broke bwrap.
- `9e577cc` 2026-04-19 (PR #433) — Patch 4b: suppress Cowork tab auto-select
  on every launch (issue #341); side-effect of Patch 4's vacuous-truth
  "Ready".
- `44cd5a6` 2026-04-19 (PR #436) — Patch 12: forward `userSelectedFolders[0]`
  as `sharedCwdPath` on cowork spawn (issue #412: upstream never sends it on
  Linux). Later retired (see `83ea637`).
- `ff4821e` 2026-04-20 — `build.sh` split; the unit moves to
  `scripts/patches/cowork.sh` unchanged (pure move).
- `7e33c09` 2026-04-20 — KvmBackend probes virtiofsd fallback paths
  (`/usr/libexec/virtiofsd` on Ubuntu; issue #447, PR #454).
- `a9719c9` 2026-04-21 — forward `CLAUDE_CODE_OAUTH_TOKEN` to the VM spawn
  env (issue #482, PR #485) — the origin-era env filter was too aggressive.
- `8ac73e6` 2026-04-30 — `{src, dst}` mount form in `coworkBwrapMounts`
  (PR #531).
- `244c08a` 2026-05-02 — allow `$` in minified identifier anchors; defensive
  `lastIndexOf` (PR #555) — anchor-hardening after upstream re-minification.
- `8882f0f` 2026-05-05 — WARNING on Patch 2a/2b inner anchor miss (PR #576;
  motivated by audit issue #559, the third `$`-identifier recurrence).
- `b40441c` 2026-05-24 — harden regex patterns for minified JS identifiers
  across patch files, cowork.sh included (PR #644).
- `2ed0194` 2026-05-27 — Patch 6 spawn-guard: `funcNameRe` used `\w+` which
  missed `$`-prefixed function names (`$Be`), leaving the fallback as a bare
  `_globalLastSpawn` identifier → `ReferenceError` and no daemon spawn.
  Widened to `[$\w]+` and changed fallback to `globalThis._lastSpawn`;
  "Fixes #659" (duplicates #658, #661).
- `83ea637` 2026-06-23 — full re-derivation for upstream's yukonSilver VM
  refactor (Claude Desktop 1.13576+), which had staled Patch 1's anchor and,
  because Patch 1 is FATAL (since `2017011`), killed the whole cowork node
  block ("main has been red since the 1.13576.0 bump on 2026-06-17" —
  commit body). Patch 1
  re-anchored on the yukonSilver status gate; Patches 2a+2b collapsed into
  one isMsix-gate widening; Patch 6 re-anchored on the new `await FN(delay)`
  retry shape; Patch 9 idempotency fixed (false-matched upstream's own
  smol-bin log); Patch 12 retired (upstream now flows `userSelectedFolders`
  → `additionalMounts` natively); Patches 6b/8 documented as safe no-ops.
- `7327c95` 2026-06-25 — Patches 1b + 1c added: the renderer gates the tab on
  the support *evaluator* (`$oe`/`q4r`), which returned
  `unsupportedCode:"msix_required"` on Linux (grayed-out "Reinstall" tab
  despite a healthy daemon); 1b flips the evaluator, 1c re-blocks the two
  VM-download consumers 1b would otherwise re-arm (#337 regression guard).
  Also added `cowork-patches.bats`, backend-detection tests pinning the
  KVM-opt-in contract, and the "one gate, multiple consumers" learning.
  Matches open-then-closed issue #742 (closed "completed" 2026-06-26);
  linkage is by symptom + timing — the commit does not cite the number
  (inference).

## Related issues and PRs

Motivation / feature track:
- #198 (PR, merged, @chukfinley) "feat: add experimental Cowork mode support for Linux" — landed the claude-swift stub predecessor in-repo (merge `b8b2893`, 2026-02-16).
- #269 (PR, closed) "feat: KVM/bwrap isolation backends for cowork mode" — introduced the backend architecture (`4929dde`).
- #288 (issue, closed) "Cowork fails to start the VM due to missing qcow2 files" — motivated the 2026-03-19 KVM wire-protocol series.
- #300 (PR, closed) "fix: resolve Cowork VM 'starting up' blocker (#288)" — landed the KVM fixes; hardened post-merge by `932044d`.
- #326 (issue, closed) "Make bubblewrap (bwrap) the default cowork isolation backend" — fixed by `3ada749`.
- #339 (issue, closed) "Feature: configurable bwrap mount points…" / #340 (PR, closed, cbonnissent) — implemented it (`e82975c`).
- #531 (PR, closed) "feat(bwrap): support {src, dst} mount form in coworkBwrapMounts" (`8ac73e6`).
- #369 (issue, open) "Cowork processes survive app quit…" — motivated Patch 10 via #391 (PR, closed) "fix: kill cowork daemon on app quit" (`605ccab`).

Regressions in / fixed by revisions:
- #259 (issue, closed) app crashes at startup after v1.1.4173 anchor rename — fixed by `2017011` (first platform-gate anchor-rot fix; made Patch 1 FATAL).
- #265 (issue, closed, @leomayer) "Skills not seen" — fixed by `d7a4606` (guest-path translation rework: `translateGuestPath()`/`buildMountMap()`).
- #315 (issue, closed) "v1.1.7714-1.3.18 is trying to start windows vm service" — motivated Patch 9 (skip `_.configure()`); fixed by `4711b24`.
- #344 (issue, closed, @aHk-coder) Cowork crashes with "Qe is not defined" — fixed by #345 (PR, merged) "fix: extract minified vars dynamically in cowork patch 9" (`9afacd5`).
- #312 (issue, closed) RPC request-id echo — fixed by `b9c3573`.
- #309 (PR, closed) bwrap guest-path mounts + minimal sandbox root — security review fix.
- #329, #332, #334 (issues, closed) — the VM-download checksum-loop cluster; fixed by #337 (PR, closed) "fix: disable VM file downloads on Linux…" (`a3190c3`; interim fix `aa6b87d`).
- #341 (issue, closed) "Cowork tab auto selects every time the app opens" — fixed by #433 (PR, closed) = Patch 4b (`9e577cc`).
- #346 (PR, closed) .mcpb-cache symlink removal before bwrap mount (`cc6230e`).
- #351 (issue, closed) "Using Claude Cowork on Ubuntu 24.04" (AppArmor userns) — diagnosed by #434 (PR, closed) (`3c84324`).
- #373 (issue, closed) double-nested home paths — fixed by `0bcc245`/`9b3c8f4`.
- #389 (PR, closed, @RayCharlizard) memory-path override translation (`379d8eb`).
- #392 (PR, closed) working dir from primary mount (`37379b4`).
- #408 (issue, closed) daemon dies mid-session, no recovery — fixed by `cb0d636` (respawn cooldown + Patch 6b) and `a349dee` (lifecycle logging).
- #411 (PR, closed) guest-path translation in --allowedTools/--disallowedTools (`9514623`).
- #412 (issue, closed) upstream never sends `sharedCwdPath` — worked around by #436 (PR, closed) = Patch 12 (`44cd5a6`); patch retired in `83ea637` when upstream shipped first-class folder flow.
- #418 (issue, closed, @Joost-Maker) "TypeError: e.existsSync is not a function" — the `$e` minified-identifier capture trap in Patch 9 (cited in cowork.sh:829-832 comment); fixed by #421 (PR, merged, @Joost-Maker) "fix: cowork existsSync crash on 1.3109+ and unblock node-pty terminal" (`2f6194f`, merged 2026-04-17).
- #426 (PR, closed) home `--dir` before SDK `--ro-bind` (`c4fe361`).
- #427 (issue, closed) workspace bash "Not logged in" — fixed by #430 (PR, closed) SDK-binary routing (`36d08ec`).
- #447 (issue, closed) virtiofsd at /usr/libexec — fixed by #454 (PR, closed) (`7e33c09`).
- #482 (issue, closed) OAuth token stripped from spawn env — fixed by #485 (PR, closed) (`a9719c9`).
- #658, #661 (issues, closed) duplicates and #659 (issue, closed) `_globalLastSpawn is not defined` — fixed by `2ed0194`.
- #742 (issue, closed) "Cowork tab gated on Linux (yukonSilver unsupported)…" — addressed by `7327c95` (Patch 1b/1c); linkage inferred from symptom + timing.

Anchor-rot / methodology track:
- #555 (PR, closed) `$` in identifier anchors (`244c08a`).
- #559 (issue, closed) regex-patch methodology audit — motivated #576 (PR, closed) Patch 2a/2b WARNING (`8882f0f`).
- #644 (PR, closed) regex hardening sweep (`b40441c`).
- #558, #560 (issues, closed) Cowork broken in 1.5354.0 with Swift-addon errors — breakage reports from the anchor-rot era; association with the Patch 2 anchor miss is inference (no fix commit cites them).
- #601 (issue, closed) "server pushes app_too_old via setYukonSilverConfig, overriding local patch" — records the server-side gating limit of the client-side reroute.

Open at park time (bwrap-backend scope, unresolved on main):
- #442 (issue, open) --doctor "unknown backend" on invalid COWORK_VM_BACKEND.
- #667 (issue, open) NixOS: missing /nix bwrap mount breaks shell commands.
- #676 (issue, open) non-home volume mounts as incoherent eCryptfs bind.
- #697 (issue, closed) NixOS FHS: bwrap missing from FHS env → KVM fallback "rootfs not found".
- #590 (issue, closed) ENAMETOOLONG in cowork session — adjacent: drove the doctor's filesystem check (doctor.sh cites #590), not the reroute itself.

## Learnings

- `docs/learnings/cowork-vm-daemon.md` — the unit's dedicated page:
  architecture overview (daemon + Patch 6 wiring), the lifecycle
  (connect → ENOENT/ECONNREFUSED → fork with 10 s cooldown → retry), the
  #408 recovery story (one-shot `_svcLaunched` root cause, `_lastSpawn` fix,
  preserved-images secondary cause, Patch 6b), silent-death logging,
  `app.asar.unpacked` traversability packaging trap, key files, and
  diagnostic commands.
- `docs/learnings/patching-minified-js.md` — uses cowork.sh as its main
  specimen: the `\w` vs `[$\w]` identifier-capture trap, which the doc
  records as "Three recurrences (PRs #253, #421, #555) before the convention
  stuck" (line 19; #253 = `546f845`, the repo-wide electron-var fix for
  #252 — outside this unit). This dossier's own cowork-specific count of the
  same trap is: PR #421/`2f6194f` (#418), the #555/#559 anchor-hardening
  pair, and `2ed0194` (#659) — the last postdating or falling outside the
  doc's enumeration, which names neither #418 nor `2ed0194`. Also
  idempotency-guard patterns
  (`cowork.sh` auto-nav/includes checks), non-unique anchor disambiguation
  (`lastIndexOf(serviceErrorStr)`), the Patch 12 `mountConda` anchor story
  (PR #436), and the "one gate, multiple consumers" yukonSilver trap from
  `7327c95` (Patch 1b re-arming the downloads that 1c re-blocks).
- `docs/learnings/official-deb-rebase-verification.md` — the fate row (below)
  plus the Cowork-relevant install-layout facts: `cowork-linux-helper`
  resolves via `process.resourcesPath` (relocation-safe), the hardcoded
  OVMF/AAVMF firmware probe list (not distro-safe), arm64 QEMU provisioning,
  and the open "Cowork socket protocol capture on a KVM host" item.

## Fate under the official-deb rebase

Matrix row, verbatim (`docs/learnings/official-deb-rebase-verification.md`,
line 31):

> | `cowork.sh` reroute + `cowork-vm-service.js` | **park** (3.1 track) | Official Cowork is coworkd (Go) + QEMU/KVM over a `SO_PEERCRED` Unix socket. A bwrap fallback now means impersonating that protocol — off the 3.0.0 critical path. 3.0.0 ships KVM-only with doctor guidance. |

Byte-level evidence behind the verdict (same doc): the official 1.17377.2
`.deb` ships its own Linux Cowork stack — a static Go `coworkd` plus
QEMU/KVM, with the helper located through `process.resourcesPath` (function
`t_t()`), rootfs fetched from
`https://downloads.claude.ai/vms/linux/${arch}/${sha}/...`, and a hardcoded
OVMF/AAVMF firmware probe list. The Windows named-pipe client the legacy
patches rerouted no longer exists in the Linux build, so every anchor the
reroute greps for targets a protocol surface that upstream replaced.

How the working tree (branch `rebase/official-deb`) handles it:

- **Unwired, not deleted.** Commit `d9cef9e` ("Phases 1+2") moved the stack
  to `scripts/cowork-fallback/`: `cowork.sh` (798 lines — only
  `patch_cowork_linux()`; the asar-argv guards and `install_node_pty` were
  NOT carried over, they belong to deleted rows), `cowork-vm-service.js`
  (byte-identical to main — `git diff main:scripts/cowork-vm-service.js
  rebase/official-deb:scripts/cowork-fallback/cowork-vm-service.js` is
  empty), three bats suites (`cowork-backend-detection.bats`,
  `cowork-bwrap-config.bats`, `cowork-path-translation.bats`), and a README
  stating "Nothing here is executed, installed, or patched into any
  artifact" and assigning the 3.1 `cowork-bwrapd` investigation to
  @RayCharlizard behind a binary-dispatcher design ("no asar patching").
- **Not in the patch pipeline.** `scripts/patches/app-asar.sh` on the branch
  lists `active_patches=(patch_quick_window patch_org_plugins_path)` — no
  cowork entry; an empty array ships the official `app.asar` byte-identical.
  `scripts/setup/official-deb.sh` contains no cowork references (grep empty).
- **KVM-only with doctor guidance.** `scripts/doctor.sh` implements the
  "doctor guidance" half of the verdict: `_check_kvm` (/dev/kvm presence +
  rw, "Cowork isolation on the official client is KVM-only… Cowork absence
  is never a failure"), `_check_vhost_vsock` (modprobe hint), and
  `_check_cowork_stack` (arch-matched qemu-system binary on PATH, firmware
  at the officially probed paths ONLY with an explanation for Fedora/Arch
  edk2 layouts, virtiofsd via `_find_virtiofsd` with off-PATH tolerated).
- **Migration hygiene.** `scripts/launcher-common.sh` keeps
  `cleanup_orphaned_cowork_daemon()` to kill leftover 2.x
  `cowork-vm-service.js` daemons (LevelDB locks + stale socket), and its
  process matchers distinguish the 2.x daemon from the official Rust
  `cowork-linux-helper` in both the UI-liveness check
  (`_claude_desktop_ui_cmdline_matches`) and helper cleanup
  (`_desktop_helper_cmdline_matches`).
- **Open verification items** (doc, lines 95–104): Cowork socket protocol
  capture on a KVM host feeds the 3.1 `cowork-bwrapd` scoping (owner
  @RayCharlizard); live arm64 rootfs availability check pending; the OVMF
  probe-list distro gap is flagged for upstream filing. The parked
  `cowork.sh` anchors "were written against the Windows-repackage bundle and
  need re-verification against official bytes" (cowork-fallback README).

## Gaps

- **#742 → `7327c95` linkage is inferred** from identical symptom description
  and dates (issue closed "completed" 2026-06-26, commit 2026-06-25); the
  commit message does not cite #742.
- **#558/#560 attribution is inferred**: they describe Swift-addon fallback
  errors in 1.5354.0 consistent with a Patch 2 anchor miss, but no fix
  commit references them.
- **No in-repo motivating issue for the origin** (`cad0b06`/`25e7932`) was
  found; the only cited report is external
  (chukfinley/claude-desktop-linux#1).
- **The "rebase ADR" referenced by `scripts/cowork-fallback/README.md` does
  not exist yet**: `docs/decisions.md` on the branch has no rebase or cowork
  entry (grep empty; last ADR is D-001 auto-update). Phase 6 docs are the
  next arc per the tracking plan, so the decision trail currently lives only
  in the verification learning + commit messages.
- Runtime behavior (daemon spawn, bwrap sandbox, doctor output) was not
  executed in this pass — all claims are from code, commit messages, and
  issue metadata.
- The `@RayCharlizard` subsystem-owner claim comes from session memory and
  the cowork-fallback README/verification doc, not re-checked against
  `.github/CODEOWNERS`.
