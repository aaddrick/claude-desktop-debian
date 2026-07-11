# Changelog

All notable changes to `aaddrick/claude-desktop-debian` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — semantic versioning applies to `REPO_VERSION`; upstream Claude Desktop bumps (the `+claude{X.Y.Z}` suffix on the tag) are tracked separately by the `check-claude-version` workflow.

## [Unreleased]

<!-- Updated automatically by check-claude-version; will be current at release time. -->

### Added

- `--doctor` now reports Cowork device-registration state: it flags when `ant-device-registry.json` is stuck at `none` because Linux has no hardware-backed device key yet (upstream), which is why new Cowork cloud tasks show "Not linked to a computer" ([#780](https://github.com/aaddrick/claude-desktop-debian/issues/780)).

### Fixed

- The launcher no longer hangs at startup on a large `launcher.log`. The pre-launch GPU-recovery check (`_previous_launch_hit_gpu_fatal`) accumulated each log section into an awk string, which is O(n²) in the size of the largest section — one GPU-crash-looping session could grow a single section to megabytes and make the check take minutes, blocking Electron from ever starting. The check is now a single-pass, constant-memory scan that tracks only the previous section's crash-signature flags, and `setup_logging` now rotates `launcher.log` when it exceeds 5 MB (keeping 2 old copies under `~/.cache/claude-desktop-debian/`) so it can't grow without bound across sessions. Retires the unbounded-growth half of [#582](https://github.com/aaddrick/claude-desktop-debian/issues/582) (the journald-flood half stays open pending a 3.x retest). ([#747](https://github.com/aaddrick/claude-desktop-debian/issues/747))
- `claude-desktop-unofficial` deb/RPM installs no longer fail with a
  file conflict on
  `/usr/share/metainfo/io.github.aaddrick.claude-desktop-debian.metainfo.xml`.
  That path was hardcoded to the reverse-DNS AppStream ID, so unlike
  every other installed file it did not follow the v3.0.0 package
  rename and stayed byte-shared with this project's own pre-rename
  `claude-desktop` builds at Claude ≥ 1.16000 (e.g.
  `v2.0.22+claude1.18286.0`); the version-scoped `<< 1.16000` conflict
  metadata deliberately does not sweep those (that bound protects
  side-by-side coexistence with Anthropic's official package, which
  ships no metainfo). The installed metainfo filename now follows the
  rename to `io.github.aaddrick.claude-desktop-unofficial.metainfo.xml`,
  so the path can no longer collide with any other
  `claude-desktop`-named package.
  ([#769](https://github.com/aaddrick/claude-desktop-debian/issues/769))

## [v3.1.0] — 2026-07-10

### Added

- Opt-in bubblewrap Cowork backend for hosts that can't run the official KVM microVM, enabled with `COWORK_VM_BACKEND=bwrap`. The official Linux client gates Cowork on `/dev/kvm` + `/dev/vhost-vsock` and drives QEMU through a bundled native helper; ChromeOS Crostini blocks `vhost_vsock` at the Termina kernel level, so that gate can never pass there no matter what's installed ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772)). A new `cowork-bwrap` asar patch reinstates the pre-3.0.0 bubblewrap daemon as a fallback: it reports the KVM support evaluator as supported, swaps the native-helper spawn for a bundled Node daemon (`resources/cowork-vm-service.js`) that speaks the same length-prefixed-JSON socket protocol backed by `bwrap` instead of QEMU, and suppresses the unused multi-GB VM-image download. Every injected branch is gated on `process.platform==="linux" && COWORK_VM_BACKEND==="bwrap"`, so on an unflagged launch every branch evaluates false and the official KVM path runs unchanged — nothing changes for the KVM majority (per [D-002](docs/decisions.md), this clears the patch bar as an opt-in path compensating a genuine Linux-environment gap). Because the official binary's `RunAsNode` fuse is off, the daemon runs under a system `node`/`nodejs` (auto-detected by the launcher, exported as `COWORK_NODE_PATH`) that provides `fs.statfsSync` (Node >= 18.15 / 16.19, feature-detected by the daemon, launcher, and `--doctor`). To persist the flag for desktop/app-menu launches — which can't carry a per-command environment — the launcher reads an allowlisted `KEY=value` config file at `${XDG_CONFIG_HOME:-~/.config}/claude-desktop-debian/environment` (an explicit command-line env still wins; the file is never executed as shell). Isolation is namespace-level, not a VM — weaker than the KVM default, which is the trade for running where KVM can't. ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772))
- `claude-desktop-unofficial --version` prints the package version (`<claude-version>-<repo-version>`, e.g. `1.18286.0-3.0.1`) and exits, on all three launcher formats (deb, RPM, AppImage). Previously the flag fell through to the full launch path, where the launcher redirects all Electron output into `~/.cache/claude-desktop-debian/launcher.log` — so the terminal printed nothing. ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772))

### Fixed

- Post-rename `claude-desktop` leftovers found in a repo-wide audit: doctor's hardcoded chrome-sandbox default probed the official package's `/usr/lib/claude-desktop/` tree instead of ours, two doctor fix hints said to reinstall `claude-desktop`, and the docs (quickstart, configuration, testing runbook/cases, triage-form mirror) still told users to run `claude-desktop`. All now use `claude-desktop-unofficial`; references that genuinely mean Anthropic's official package, the upstream ELF/process name, or the transitional dummy are unchanged. ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772))

### Changed

- The artifact tests now assert that Cowork's bundled `resources/virtiofsd` is present and executable in every package format: the [#771](https://github.com/aaddrick/claude-desktop-debian/issues/771) un-gate makes it the universal fallback and the client resolves it with `X_OK`, so a repack that drops the exec bit would silently kill Cowork on hosts without a client-probed system virtiofsd. The doctor's virtiofsd probe tests also grew coverage for the `_cowork_incomplete` readiness flag (the WARN branches were previously unasserted — `run` subshells discard the mutation), the client-path-over-bundled precedence, and the mode-stripped bundled copy falling through to WARN. ([#774](https://github.com/aaddrick/claude-desktop-debian/pull/774))

## [v3.0.1] — 2026-07-05

### Added

- The launcher now rotates out-of-band backups of `claude_desktop_config.json` and the per-account Cowork stores (`spaces.json`, `remote-session-spaces.json`, `scheduled-tasks.json`) before each launch, keeping the last 5 changed copies under `~/.cache/claude-desktop-debian/config-backups/`. This is the recovery path for the durable-loss config-wipe class: the official loader falls back to an empty value on a failed cold-start read and the next settings write serializes that empty state over the whole file, stubbing out keys whose only source of truth is the file itself — `mcpServers`, trusted folders, and the Cowork `spaces.json` content (upstream anthropics/claude-code#32345/#59640/#63651). Groupings/stars mirrored from IndexedDB (`epitaxyPrefs`) self-heal on restart and were the recoverable cousin that surfaced this during [#768](https://github.com/aaddrick/claude-desktop-debian/issues/768). Because the backup runs before Electron starts, an in-session wipe leaves the pre-wipe copy recoverable down the rotation. Patch-zero-clean (launcher-only; the official `app.asar` still ships byte-identical) and covers the corrupt-JSON / ENOENT / single-bad-entry-Zod modes an in-band guard would miss. Mechanism and the parked in-band guard: [`docs/learnings/config-wipe-guard.md`](docs/learnings/config-wipe-guard.md). ([#768](https://github.com/aaddrick/claude-desktop-debian/issues/768))
- The Nix FHS env ships `qemu_kvm`, so Cowork can boot its VM. Cowork gates VM boot on two requirements — `firmwarePath` (the OVMF shim already provided it) and `qemuPath` (a PATH search for `qemu-system-x86_64`/`-aarch64`); `coworkd` then launches a real `accel=kvm` guest (pflash OVMF, vhost-vsock, virtiofsd). Firmware alone left the gate at `requirement_missing`. `qemu_kvm` is the host-cpu-only build (~1.5 GB closure vs 2.1 GB for the all-targets `qemu`); `/dev/kvm` and `/dev/vhost-vsock` are reachable inside the env since buildFHSEnv binds the whole `/dev`, but the host must still grant kvm-group access (`/dev/kvm` is `root:kvm 0660`) and load `vhost_vsock` (`--doctor` flags both). x86_64 live-verified: a VM boots with KVM acceleration, and both the qemu binaries and usermode networking work. The aarch64 leg is still unverified. ([#766](https://github.com/aaddrick/claude-desktop-debian/pull/766))

### Fixed

- Cowork reported "requires QEMU. Install it with…" on Arch, Debian, and Ubuntu-derivative hosts with a complete, doctor-green KVM stack: the official client resolves virtiofsd from exactly two absolute paths (`/usr/libexec/virtiofsd`, `/usr/bin/virtiofsd`) and falls back to its own bundled copy only when `/etc/os-release` reports `ID=ubuntu` with `VERSION_ID` 22.x — so Arch's `/usr/lib/virtiofsd`, Debian's `/usr/lib/qemu/virtiofsd`, and any Ubuntu derivative (`ID=pop`, `ID=linuxmint`) all resolve null and the `yukonSilver` support evaluator gates VM startup before it ever spawns QEMU. A new `virtiofsd-probe` asar patch un-gates the bundled fallback (system paths stay preferred; the probe list is deliberately not widened, since `/usr/lib/qemu/virtiofsd` can be the CLI-incompatible legacy C implementation on qemu < 8 hosts). Reproduced on Anthropic's own `.deb`, so it is filed upstream as a genuine Linux gap per [D-002](docs/decisions.md) ([`docs/upstream-reports/771-cowork-virtiofsd-probe.md`](docs/upstream-reports/771-cowork-virtiofsd-probe.md)). ([#771](https://github.com/aaddrick/claude-desktop-debian/issues/771), [#772](https://github.com/aaddrick/claude-desktop-debian/issues/772))
- `--doctor` no longer PASSes a virtiofsd the client cannot see: the old check searched the broad distro path list (`/usr/lib/virtiofsd`, `/usr/lib/qemu/virtiofsd`, PATH), which produced the all-green doctor / "requires QEMU" app disagreement in [#771](https://github.com/aaddrick/claude-desktop-debian/issues/771). The check now mirrors the client's actual probe order — the two hardcoded paths, then the bundled `resources/virtiofsd` — and a binary found anywhere else WARNs with the one-line symlink fix instead of passing. ([#771](https://github.com/aaddrick/claude-desktop-debian/issues/771))
- The Nix build crash-looped at startup on real NixOS: the GPU process failed EGL init (`Could not dlopen native EGL: libEGL.so.1`), exited, and relaunched forever. Chromium's bundled ANGLE (`libEGL.so`/`libGLESv2.so`) `dlopen`s the glvnd dispatcher by soname against the *calling* lib's runpath, and `runtimeDependencies` reaches only dynamic executables (not the co-located `.so`), so `libGL` never landed where the dlopen needed it. `appendRunpaths` now adds the glvnd libs + NixOS driver tree to every patched ELF; glvnd then self-locates the vendor ICD under `/run/opengl-driver`. Runpath, not a `LD_LIBRARY_PATH` wrapper, so the driver tree stays out of the env of the MCP servers the app spawns. Chromium's bundled Vulkan loader can't be reached by runpath, so the launcher is wrapped to prepend the NixOS ICD dir via `VK_ADD_DRIVER_FILES` (additive, so it can't shadow a user's config; harmless in spawned CLI subprocesses). Verified x86_64 + nvidia; mesa (Intel/AMD) and aarch64 unconfirmed. ([#765](https://github.com/aaddrick/claude-desktop-debian/pull/765))
- The Nix FHS firmware shim shipped only the OVMF/AAVMF **CODE** file, so Cowork's VM boot would have failed with `no EFI variable-store template configured`: Cowork derives its writable EFI VARS template from the CODE path by renaming `OVMF_CODE`→`OVMF_VARS` / `AAVMF_CODE`→`AAVMF_VARS`, and that sibling didn't exist on the Nix FHS (deb/rpm hide this — the distro's edk2 package already drops `OVMF_VARS` beside CODE). The `ovmfCompat` shim now symlinks the matched **CODE+VARS** pair on both arches and drops the wrong `QEMU_EFI.fd` aarch64 fallback (unpadded, no matching VARS name). With the qemu FHS entry landed ([#766](https://github.com/aaddrick/claude-desktop-debian/pull/766)), Cowork now boots a VM end-to-end on x86_64 with this shim in place; aarch64 stays unverified. **Build-behavior change on aarch64:** a build-time guard now fails the build on nixpkgs OVMF-layout drift (e.g. a pinned nixpkgs missing the AAVMF pair) rather than shipping a dangling symlink that only bites at VM boot — fail-loud on the unverified arch is the deliberate trade, since there's no clean fallback (`QEMU_EFI` is unpadded and qemu rejects it for pflash). ([#767](https://github.com/aaddrick/claude-desktop-debian/pull/767))

## [v3.0.0] — 2026-07-04

Rebased onto Anthropic's official first-party Claude Desktop for Linux `.deb` (pin 1.18286.0), replacing the Windows-installer repackaging and most of the legacy patch suite.

### Added

- Build-time tripwires on upstream behavior we deleted patches for: the build now fails if the official bundle stops shipping the `apt_channel_pending` autoupdater marker (upstream turning on self-updating would fight the package manager — see [D-001](docs/decisions.md)) or the `menuBarEnabled:!0` menu-bar default. Replaces the per-patch WARNINGs that left with each deletion. (AU-1/MB-1, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- The launcher self-heals the "Run on startup" autostart entry. The official app writes `~/.config/autostart/claude-desktop.desktop` with `Exec=<its own ELF> --startup`, which bypasses the launcher's env/flag policy (Wayland opt-in, GPU recovery, `--class`, `CLAUDE_PASSWORD_STORE`) — and under AppImage points at an ephemeral `/tmp/.mount_claude*` path that rots on unmount. Each launch now repoints the entry's `Exec` at the launcher (deb/rpm: `/usr/bin/claude-desktop-unofficial`; AppImage: the persistent `$APPIMAGE` path). The Settings toggle is unaffected — static analysis of the official bundle shows its is-enabled check never reads the `Exec` content. (AUTO-1, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- The RPM bridges Cowork's hardcoded firmware probe on non-Debian layouts: `%post` creates a compat symlink at the probed path (`/usr/share/OVMF/OVMF_CODE_4M.fd`, arm64 `/usr/share/AAVMF/AAVMF_CODE.fd`) when no probed path exists but a known edk2/qemu location does; erase removes it only if it is ours. Fedora already ships its own compat layer and is untouched. (CW-1, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- `claude-desktop-unofficial --doctor` warns when no keyring backend (Secret Service or KWallet, running or D-Bus-activatable) is reachable on the session bus: without one, Chromium's `os_crypt` falls back to the plaintext `basic` backend and the login token persists unencrypted at rest. Advisory only — login itself still works (live-verified on keyring-less wlroots/i3 sessions). (LD-3, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))

### Changed

- **BREAKING:** The packaging pipeline now consumes Anthropic's official Linux `.deb` instead of repackaging the Windows installer. `build.sh` resolves the newest pool entry via the APT `Packages` index, SHA-256 verifies it, and extracts with `ar`/`tar` (no `dpkg`, so RPM-family hosts still build). The official `app.asar` ships byte-identical in the common case — `app-asar.sh` is a thin orchestrator with an `active_patches` array, and only genuine Linux gaps are patched (see Removed). Full delete/keep rationale, byte-verified against the pristine bundle, is in [`docs/learnings/official-deb-rebase-verification.md`](docs/learnings/official-deb-rebase-verification.md) and report CDL-ANT-0009. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- **BREAKING:** `--password-store` is no longer auto-detected. It is passed only when `CLAUDE_PASSWORD_STORE` is set; otherwise Chromium's official `os_crypt` autodetect owns the default. Governing rule of the rework: no default launcher flag may shadow an official code path. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- **BREAKING:** The build flag `--exe` is now `--deb`, and `--node-pty-dir` is removed.
- **BREAKING:** Our package is renamed `claude-desktop-unofficial` (deb + rpm; matching artifact names for AppImage) so it can be installed beside Anthropic's official `claude-desktop` package. Install paths move to `/usr/lib/claude-desktop-unofficial`, `/usr/bin/claude-desktop-unofficial`, `/etc/apparmor.d/claude-desktop-unofficial`. The conflict metadata is version-scoped (`Conflicts:`/`Replaces: claude-desktop (<< 1.16000)`; rpm `Obsoletes: claude-desktop < 1.16000`), so it swaps out our legacy Windows-repack packages (≤ 1.15200.x) and never touches the official package (≥ 1.17377.1). DNF migrates on a normal `dnf upgrade`; APT migrates via a transitional `claude-desktop` 1.16000.0 dummy package. Side-by-side installs share `~/.config/Claude`, so only one build can run at a time. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- The Nix derivation was rebuilt for the official tree: `fetchurl` the official `.deb` from the APT pool (SRI hashes auto-bumped by `check-claude-version`), `autoPatchelfHook` over the bare co-located tree (no nixpkgs Electron, no node-pty build, no resourcesPath hack), and the FHS env bind-provides OVMF firmware at Cowork's hardcoded probe paths. Build-verified on x86_64 (both flake outputs, zero unresolved libraries); the aarch64 leg and Cowork VM boot are still unverified — [@typedrat](https://github.com/typedrat) owns the final shape. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- `claude-desktop-unofficial --doctor` reworked for the official layout: new checks for the KVM/Cowork stack (`/dev/kvm`, `/dev/vhost-vsock`, OVMF/AAVMF firmware), official-version drift (embedded `Packages` resolver, network-optional), name collision with Anthropic's own package, and set-but-dead legacy env vars. chrome-sandbox / pkg-version / AppArmor checks moved to the bare co-located ELF. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- CI: `check-claude-version` resolves upstream via the `Packages` index instead of Playwright; `build-amd64` and `build-arm64` collapse into one cross-building `build.yml`; RC tags (`v*-rc*`) publish as prerelease and skip the repo jobs; a new `mirror-official-deb` job archives every consumed official `.deb` to its release. New `tools/chromium-switch-smoke.sh` + checked-in baseline fail CI if the effective launcher switch list drifts. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- Shipped docs rewritten for the official-deb reality: README repositioned (Anthropic serves the `.deb`; this project serves everything else plus the launcher and doctor), building/configuration/troubleshooting reworked against the actual branch scripts, obsolete deep-dives moved to `docs/archive/` with obsolescence headers, the Electron WCO findings extracted to `docs/upstream-reports/`, and the rebase recorded as ADR [D-002](docs/decisions.md). ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))

### Removed

- **BREAKING:** Launcher env vars `CLAUDE_TITLEBAR_STYLE`, `ELECTRON_USE_SYSTEM_TITLE_BAR`, `CLAUDE_MENU_BAR`, `CLAUDE_KEEP_AWAKE`, and `CLAUDE_QUIT_ON_CLOSE` — the official build handles these natively (close-to-tray moved to **Settings ▸ General ▸ System Tray**, on = tray / off = quit). The doctor warns if it sees a dead one still set, and points `CLAUDE_QUIT_ON_CLOSE` at the tray toggle specifically. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- 11 legacy patches now redundant against the official Linux build: the frame-fix wrapper (incl. the autoUpdater no-op), the claude-native Rust-binding stub, the tray patches (`tray.sh`), the WCO shim, `claude-code.sh`, the node-pty rebuild (+ `nix/node-pty.nix`), the menuBarEnabled default, the cowork/`.config` `.asar` guards, and the i18n + tray-icon asar copies. Two Linux-specific survivors stay: `quick-window` (KDE stale-focus) and `org-plugins` (upstream has no Linux case). ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- The Windows-installer acquisition path: `download.sh`, the Playwright `resolve-download-url.py`, `fetch-electron-binary.js`, and `scripts/staging/*`. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- The codespell workflow (`.github/workflows/codespell.yml`) and `.codespellrc`. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))

### Fixed

- Cross-built arm64 AppImages embedded an x86_64 first-stage runtime stub, so they could not start on arm64 hardware: appimagetool always embeds the runtime bundled with the tool itself (host-arch) — the `ARCH` export only covers naming/validation. The build now downloads the target-arch runtime from the same AppImageKit release and passes `--runtime-file` explicitly. Caught by the first native-arm64 run of the artifact tests. ([#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))
- Artifact tests (`tests/test-artifact-{deb,rpm,appimage}.sh`) no longer assert the old `node_modules/electron/dist/` on-disk layout, which the official bare co-located tree (`/usr/lib/claude-desktop/{claude-desktop,chrome-sandbox,resources}`) does not ship — they are repointed to the real layout, so the release-gating artifact jobs pass against the rebase packages. (SB-1, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))

### Security

- The launcher no longer writes the login OAuth authorization code to `launcher.log`. A relaunch through the auth redirect carried `claude://login/…?code=<code>` in argv, which the `Executing:`/`Arguments:` log lines recorded verbatim; the `log_message` chokepoint now strips the query string of any `claude://login` token. Low residual risk (single-use, redeemed), but a plaintext secret should not land in a log. (LOG-1, [#763](https://github.com/aaddrick/claude-desktop-debian/pull/763))

> **Known gap:** the reworked Nix derivation is build-verified on x86_64 only — runtime on real NixOS, the aarch64 leg, and Cowork VM boot are still unvalidated (owner [@typedrat](https://github.com/typedrat)).

## [v2.0.22] — 2026-06-25

Tracks upstream Claude Desktop 1.15200.0.

### Fixed

- The Cowork tab is no longer grayed out on Linux with a *"Cowork requires a newer installation — Reinstall the desktop app"* tooltip. Upstream 1.13576+ gates the tab's visibility on the yukonSilver support *evaluator* (`$oe`/`q4r`, the Windows capability probe), which returns `msix_required` on Linux — a separate consumer from the `startVM` execution gate that [#736](https://github.com/aaddrick/claude-desktop-debian/pull/736) re-derived. The evaluator now reports `supported` on Linux so the renderer un-grays the tab (the bwrap daemon was already healthy underneath), while the VM-image download drivers it also feeds are re-blocked so they don't pull the multi-GB `rootfs.vhdx` bundle that is intentionally disabled on Linux — cowork runs through the bwrap sandbox, not a downloaded VM. ([#743](https://github.com/aaddrick/claude-desktop-debian/pull/743), #736 follow-up)
- Claude Desktop no longer hangs at startup on Linux with no window ever appearing (a regression introduced by upstream 1.13576+). The bundle calls the Windows-only `@ant/claude-native` methods `readRegistryValues()` and `getWindowsElevationType()` unconditionally during its enterprise-policy lookup, guarding only the native module being null and not the method being absent — so the Linux stub threw `"<method> is not a function"` at top-level execution, which the early empty `uncaughtException` handler swallowed, leaving the process alive but windowless. The Linux native stub now provides neutral no-ops for these Windows-only registry / MSIX / UAC methods. ([#729](https://github.com/aaddrick/claude-desktop-debian/issues/729))
- Cowork Linux patches apply again on Claude Desktop 1.13576+ — the build's "Verify cowork patches in shipped asar" step had started failing with 9/11 markers missing. Upstream re-architected the cowork/VM subsystem ("yukonSilver") between 1.12603.1 and 1.13576.0: the platform gate moved from a `darwin`/`win32` check into `startVM`'s `yukonSilver.status` feature-flag check, the vmClient module load moved behind the isMsix detector, and `sharedCwdPath`/`mountConda` were removed. Patch 1 (which anchored on the gone check) `process.exit(1)`'d, which killed the whole node block and dropped every subsequent cowork patch. Patches 1, 2 and the daemon auto-launch anchor were re-derived against the new bundle, the smol-bin idempotency guard was fixed (it false-matched upstream's own log), the obsolete `sharedCwdPath` threading (Patch 12) was retired in favor of the daemon's mountMap fallback, and the Linux smol-bin copy patch gained a verification marker. ([#736](https://github.com/aaddrick/claude-desktop-debian/pull/736))
- Builds (deb, RPM, AppImage, nix) no longer abort in the patch phase with `FATAL: --add-dir pattern matches 2 times (expected 1)`. Upstream Claude Desktop 1.12603.1 ships two identical `--add-dir` dispatch loops, but the `.asar` filter patch ([#650](https://github.com/aaddrick/claude-desktop-debian/pull/650)) asserted exactly one. The patch now filters every matching dispatch loop instead of bailing on a duplicate, and stays idempotent on re-runs. ([#718](https://github.com/aaddrick/claude-desktop-debian/issues/718))
- `claude-desktop --doctor` reports the installed version from the package manager that actually owns the install (probed via `rpm -qf` on the bundled Electron binary) instead of trusting `dpkg-query` alone — rpm installs on hosts that also carry a stale dpkg record (e.g. Fedora boxes with dpkg installed as a build tool) no longer show a months-old version with a PASS. ([#712](https://github.com/aaddrick/claude-desktop-debian/pull/712), fixes [#711](https://github.com/aaddrick/claude-desktop-debian/issues/711))

## [v2.0.19] — 2026-06-10

Tracks upstream Claude Desktop 1.11847.5.

### Added

- AppStream metainfo (`io.github.aaddrick.claude-desktop-debian.metainfo.xml`) installed by the deb, RPM, and AppImage builds, so the package appears in GNOME Software, KDE Discover, and App Center with correct unofficial-repackaging branding and a `LicenseRef-proprietary` project license. Store search for not-yet-installed users needs repo-side DEP-11/appstream metadata, tracked in [#708](https://github.com/aaddrick/claude-desktop-debian/issues/708). ([#633](https://github.com/aaddrick/claude-desktop-debian/pull/633))
- GPU crash auto-recovery in the launcher: when the previous launch died to a Chromium GPU-process FATAL (the [#583](https://github.com/aaddrick/claude-desktop-debian/issues/583) SIGTRAP signature), the next launch automatically applies safe GPU flags — and stays recovered on subsequent launches instead of oscillating crash/work/crash. Detects NixOS launcher log headers too; set `CLAUDE_DISABLE_GPU=0` to override. ([#666](https://github.com/aaddrick/claude-desktop-debian/pull/666))

### Fixed

- `claude-desktop --doctor` no longer reports a false-green PASS when the password store reads back empty or when `df` returns a non-numeric disk reading — bad reads now fail or print a visible skip instead of falling through to the PASS branch, and leading-zero `df` output can no longer slip past as octal arithmetic. ([#692](https://github.com/aaddrick/claude-desktop-debian/pull/692))
- Explicit quit now keeps the launcher alive until Electron exits, then runs
  stale-helper cleanup for Desktop-owned Cowork, Claude config, and extension
  helpers. Close-to-tray still leaves the app and helpers running.
  ([#682](https://github.com/aaddrick/claude-desktop-debian/pull/682))
- All launchers (deb, RPM, AppImage, nix) no longer pass `app.asar` as an Electron
  argument. Electron auto-loads `app.asar` from its default `resources/` dir next to the
  binary, so the extra argv entry was redundant — and the app treated it as a
  file-to-open, surfacing a spurious "Attach app.asar?" prompt on launch and on every
  taskbar reopen. This removes the path at the source, complementing the renderer-side
  `.asar` guards in [#669](https://github.com/aaddrick/claude-desktop-debian/pull/669)
  and surviving upstream re-minification. Live-UI detection in the launcher and doctor,
  which fingerprinted on the now-removed argv, was updated alongside.
  ([#700](https://github.com/aaddrick/claude-desktop-debian/pull/700),
  fixes [#696](https://github.com/aaddrick/claude-desktop-debian/issues/696))
- Cowork's VM daemon never auto-launched on packages built under a restrictive umask (CI builds with umask `022`, so released artifacts were unaffected; local builds with e.g. `umask 077` were) because the bundled `app.asar.unpacked/` directory shipped as mode `0700` owned by the build uid, so the desktop user running the app couldn't traverse it and the auto-launch `fs.existsSync()` fork guard silently returned `false` (symptom: endless `connect ENOENT …/cowork-vm-service.sock`, no `cowork_vm_daemon.log`, no `[cowork-autolaunch]` line). `deb.sh` now normalizes the installed tree to canonical permissions (directories and executables `755`, other files `644`) and builds with `dpkg-deb --root-owner-group` for `root:root` ownership; `appimage.sh` applies the same normalization to the AppDir before `mksquashfs` (it copies with `cp -a`, which preserved the bad modes); and `rpm.sh` normalizes file modes in `%install` — `%defattr(-, root, root, 0755)` forces directory modes in the payload, but its `-` first field preserves file modes from the `cp -r`-populated buildroot, so a restrictive-umask RPM build shipped an unreadable `app.asar` and a non-executable electron binary.
- Claude Desktop no longer crashes on launch on Ubuntu 24.04+, where `apparmor_restrict_unprivileged_userns=1` blocks the user namespaces Chromium's sandbox needs (`sandbox/linux/services/credentials.cc` FATAL, `Trace/breakpoint trap`, exit 133). The `.deb` `postinst` now installs a scoped AppArmor profile granting `userns` to the bundled Electron binary — mirroring the `google-chrome`/`code`/`slack` packages — and removes it again on uninstall. The Chromium sandbox stays enabled (no `--no-sandbox`). `claude-desktop --doctor` gained a **User namespaces** check that flags a missing profile. ([#687](https://github.com/aaddrick/claude-desktop-debian/pull/687))
- Cowork mode no longer silently falls back to host-direct (no isolation) on Ubuntu 24.04+, where `apparmor_restrict_unprivileged_userns=1` blocks the user namespaces its bubblewrap sandbox needs. The `.deb` `postinst` now installs a second scoped AppArmor profile granting `userns` to `/usr/bin/bwrap` (distinct from the Electron profile above), automating the manual workaround from [#351](https://github.com/aaddrick/claude-desktop-debian/issues/351) (contributed by [@hfyeh](https://github.com/hfyeh)). The profile is gated on the kernel's `apparmor_restrict_unprivileged_userns` knob and defers to any profile already attaching to `/usr/bin/bwrap` (a hand-made `/etc/apparmor.d/bwrap`, `apparmor-profiles`' `bwrap-userns-restrict`); put local overrides in `/etc/apparmor.d/local/claude-desktop-bwrap` — they survive upgrades. `bubblewrap` is now a `Recommends`. ([#694](https://github.com/aaddrick/claude-desktop-debian/pull/694))

### Changed

- CI now validates the arm64 deb, RPM, and AppImage artifacts on native `ubuntu-22.04-arm` runners (previously only amd64 was tested), and the AppImage launch smoke test's process sweep is keyed to `mount_claude` and gated behind `$CI` so a local test run can't kill a developer's live Claude Desktop session. The launcher's orphaned-daemon reaper also gained mutation-tested BATS coverage. ([#691](https://github.com/aaddrick/claude-desktop-debian/pull/691), [#693](https://github.com/aaddrick/claude-desktop-debian/pull/693))
- The native-Wayland launch path now routes Quick Entry's global shortcut (`Ctrl+Alt+Space`) through the XDG GlobalShortcuts portal: `GlobalShortcutsPortal` is added to the `--enable-features` set, and all Chromium feature requests are merged into a single `--enable-features=` switch (Chromium honours only the last one, so the previous code could silently clobber features). GNOME Wayland users can opt into the portal route with `CLAUDE_USE_WAYLAND=1`, which works on GNOME ≤ 49 after a one-time portal permission dialog and fixes the focus-bound hotkey from [#404](https://github.com/aaddrick/claude-desktop-debian/issues/404). The default GNOME session stays on XWayland (no rendering/IME regression risk); auto-selecting native Wayland on GNOME is deferred until it can be gated on a real render check. **On GNOME 50 / xdg-desktop-portal ≥ 1.20 the portal route is currently a no-op** — Electron/Chromium doesn't perform the portal's new host `Registry.Register` app-id handshake (filed upstream as [electron/electron#51875](https://github.com/electron/electron/issues/51875)). `CLAUDE_USE_WAYLAND` is now tri-state: `1` native Wayland, `0` force XWayland, unset auto-detects. ([#404](https://github.com/aaddrick/claude-desktop-debian/issues/404))

## [v2.0.18] — 2026-06-04

Tracks upstream Claude Desktop 1.10628.2.

### Fixed

- Tray icon no longer stuck black at startup on dark desktops. `nativeTheme.shouldUseDarkColors` reads `false` for the first ~50 ms then flips `true`, but the leading-edge rebuild mutex latched the transient `false` and dropped the corrective `"updated"` events; the mutex is now trailing-edge (re-applies the final value) and the obsolete 3 s startup-suppression window was removed. ([#680](https://github.com/aaddrick/claude-desktop-debian/pull/680), fixes [#679](https://github.com/aaddrick/claude-desktop-debian/issues/679))
- Restored the in-place tray `setImage` fast-path ([#515](https://github.com/aaddrick/claude-desktop-debian/pull/515)), which silently stopped applying after upstream changed the context-menu wiring from `setContextMenu(BUILDER())` to a prebuilt `setContextMenu(MENU)` object — `patch_tray_inplace_update` now resolves the builder in both shapes, so the duplicate-icon SNI race no longer regresses. ([#680](https://github.com/aaddrick/claude-desktop-debian/pull/680))
- File-drop collector no longer re-attaches the app's own `app.asar` on every taskbar reopen. Electron's ASAR VFS shim returns `true` from `existsSync()` for `.asar` paths, so the second-instance argv collector dispatched `app.asar` to the file-drop handler and surfaced an attach prompt on each relaunch; it now rejects `.asar` paths, mirroring the existing `statSync` guard. ([#669](https://github.com/aaddrick/claude-desktop-debian/pull/669), fixes [#668](https://github.com/aaddrick/claude-desktop-debian/issues/668))

### Changed

- CI now runs a headless launch smoke test for the deb and rpm artifacts — previously only the AppImage actually booted, so a startup-only regression (e.g. the Fedora `SyntaxError`) could stay green on the formats it broke. A shared `run_launch_smoke_test` helper covers all three formats and gracefully skips when a container forbids Chromium's sandbox. ([#671](https://github.com/aaddrick/claude-desktop-debian/pull/671), closes [#670](https://github.com/aaddrick/claude-desktop-debian/issues/670))

## [v2.0.17] — 2026-06-04

Tracks upstream Claude Desktop 1.10628.2.

### Fixed

- `addTrustedFolder` `.asar` guard re-anchored on the `async addTrustedFolder(…)` method declaration. Upstream Claude Desktop 1.10628.x folded the `LocalAgentModeSessions.addTrustedFolder: ${i}` log call into a comma-expression inside an `if`, removing the trailing `` `); `` the old anchor matched — `./build.sh` aborted with `[FAIL] addTrustedFolder anchor not found`. Both the parameter extraction and the injection point now key off the unminified method name, so they can't drift apart if upstream drops the log line. ([#685](https://github.com/aaddrick/claude-desktop-debian/pull/685))

## [v2.0.16] — 2026-05-27

Tracks upstream Claude Desktop 1.9255.0.

### Fixed

- Cowork spawn guard now captures `$`-prefixed minified function names (e.g. `$Be`) and uses `globalThis._lastSpawn` instead of a bare `_globalLastSpawn` identifier, fixing `ReferenceError: _globalLastSpawn is not defined` that broke Cowork on all platforms with upstream 1.9255.0. ([#660](https://github.com/aaddrick/claude-desktop-debian/pull/660), fixes [#658](https://github.com/aaddrick/claude-desktop-debian/issues/658), [#659](https://github.com/aaddrick/claude-desktop-debian/issues/659), [#661](https://github.com/aaddrick/claude-desktop-debian/issues/661))

## [v2.0.15] — 2026-05-27

Tracks upstream Claude Desktop 1.9255.0.

### Fixed

- `StartupWMClass` aligned to `Claude` to match what Electron actually advertises via `productName`. The v2.0.14 value `claude-desktop` was silently ignored by Electron, causing orphan windows and duplicate gear icons on GNOME/KDE. Value centralized from 6 hardcoded locations to one source of truth in `build.sh`, with build-time substitution and a `productName` assertion guard. ([#655](https://github.com/aaddrick/claude-desktop-debian/pull/655), fixes [#652](https://github.com/aaddrick/claude-desktop-debian/issues/652))
- Tray variable extraction re-anchored on `.Tray()` literal instead of minifier-dependent syntax that upstream 1.9255.0 reshuffled. ([#657](https://github.com/aaddrick/claude-desktop-debian/pull/657), fixes [#656](https://github.com/aaddrick/claude-desktop-debian/issues/656))

## [v2.0.14] — 2026-05-25

Tracks upstream Claude Desktop 1.8555.2.

### Fixed

- `WM_CLASS` and `StartupWMClass` aligned to `claude-desktop` across all formats (deb, RPM, AppImage, autostart). Resolves ambiguity with the Claude Code CLI (`claude`) and ensures consistent taskbar grouping on KDE/GNOME. ([#648](https://github.com/aaddrick/claude-desktop-debian/pull/648), fixes [#647](https://github.com/aaddrick/claude-desktop-debian/issues/647))

### Changed

- AppImage smoke test: replaced flat 10s sleep with readiness-marker poll (30s ceiling, 0.5s tick), unified cleanup trap to prevent 190MB `squashfs-root` leaks on interrupt. ([#646](https://github.com/aaddrick/claude-desktop-debian/pull/646))

## [v2.0.13] — 2026-05-24

Tracks upstream Claude Desktop 1.8555.2.

### Added

- `CLAUDE_KEEP_AWAKE=0` env var to suppress `powerSaveBlocker` sleep inhibitor that upstream holds indefinitely on Linux (no lifecycle management). Adds diagnostic logging for all `powerSaveBlocker` calls and `--doctor` visibility. ([#605](https://github.com/aaddrick/claude-desktop-debian/issues/605))
- `--doctor` flags filesystems with `NAME_MAX < 200` (eCryptfs, certain encrypted overlays) and surfaces the LUKS-symlink workaround for cowork. Thanks @RayCharlizard, @lizthegrey for the repro. ([#614](https://github.com/aaddrick/claude-desktop-debian/pull/614), fixes [#590](https://github.com/aaddrick/claude-desktop-debian/issues/590))
- F11 fullscreen toggle via hidden menu accelerator — Linux parity with macOS green button / Windows F11. ([#638](https://github.com/aaddrick/claude-desktop-debian/pull/638), fixes [#580](https://github.com/aaddrick/claude-desktop-debian/issues/580))
- Linux org-plugins path (`/etc/claude/org-plugins`) added to platform switch, enabling MDM-managed plugin configuration. ([#639](https://github.com/aaddrick/claude-desktop-debian/pull/639), fixes [#607](https://github.com/aaddrick/claude-desktop-debian/issues/607))
- Top-level governance docs: this `CHANGELOG.md`, [`RELEASING.md`](RELEASING.md) (pre-release checklist + tag-driven CI flow), [`SECURITY.md`](SECURITY.md) (private GHSA reporting + in/out-of-scope), [`docs/index.md`](docs/index.md) (navigation hub), and [`docs/styleguides/docs_styleguide.md`](docs/styleguides/docs_styleguide.md) (page anatomy, naming, antipatterns). [`CLAUDE.md`](CLAUDE.md) gains explicit § Required reading, § Anti-patterns, and § Docs sections; [`AGENTS.md`](AGENTS.md) becomes a byte-identical mirror of the new body (was a 13-line stub) so non-Claude tools get the same instructions.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) "Before you start" triage section: where to go for a bug, a fix-in-hand, a new-feature ask, or a security report.
- `--password-store` keyring detection: probes D-Bus for kwallet6 / gnome-libsecret at startup and injects the flag before the app path, fixing session persistence on KDE Plasma and other desktops where `safeStorage.isEncryptionAvailable()` returned false. Adds `CLAUDE_PASSWORD_STORE` env override and `--doctor` diagnostic. Thanks @dubreal. ([#611](https://github.com/aaddrick/claude-desktop-debian/pull/611), fixes [#593](https://github.com/aaddrick/claude-desktop-debian/issues/593))
- Unzip fallback for Node 24: detects missing electron binary after `extract-zip` silently no-ops and recovers from the `@electron/get` cache using system `unzip`. Thanks @JustinJLeopard. ([#631](https://github.com/aaddrick/claude-desktop-debian/pull/631), fixes [#584](https://github.com/aaddrick/claude-desktop-debian/issues/584))

### Fixed

- Config writes no longer drop externally-added `mcpServers`. The stale in-memory cache was overwriting disk on every preference change; now re-reads `mcpServers` from disk before each write. ([#643](https://github.com/aaddrick/claude-desktop-debian/pull/643), fixes [#400](https://github.com/aaddrick/claude-desktop-debian/issues/400))
- Menu bar toggle fires on Alt keyup only, not keydown — fixes Alt+Shift (language switch) and Alt+F4 accidentally triggering the menu bar. `CLAUDE_MENU_BAR=hidden` disables the Alt toggle entirely. ([#642](https://github.com/aaddrick/claude-desktop-debian/pull/642), fixes [#630](https://github.com/aaddrick/claude-desktop-debian/issues/630))
- `.asar` paths rejected in directory check, preventing Electron's ASAR VFS shim from dispatching `app.asar` to Cowork as a "folder drop". Fixes permission dialog on every launch, forced Cowork mode on reopen from tray, and "No conversation found" loop in Claude Code >=2.1.111. ([#640](https://github.com/aaddrick/claude-desktop-debian/pull/640), fixes [#383](https://github.com/aaddrick/claude-desktop-debian/issues/383), [#622](https://github.com/aaddrick/claude-desktop-debian/issues/622), [#632](https://github.com/aaddrick/claude-desktop-debian/issues/632))
- Identifier captures across all patch scripts hardened from `\w+` to `[$\w]+` (PCRE) / `[[:alnum:]_$]+` (ERE). Fixes broken idempotency guard in `tray.sh`, adds missing guards to `cowork.sh` patches 6/9/10, adds `\s*` whitespace tolerance to multiple patterns. ([#644](https://github.com/aaddrick/claude-desktop-debian/pull/644))
- `exec` before Electron invocation in deb, RPM, and Nix launchers so Ctrl+C and signals forward correctly to the Electron process. ([#637](https://github.com/aaddrick/claude-desktop-debian/pull/637), fixes [#424](https://github.com/aaddrick/claude-desktop-debian/issues/424))
- `--class=Claude` added to launcher args ensuring WM_CLASS matches `StartupWMClass` in the .desktop file, preventing GNOME extension crashes from unexpected class values. ([#636](https://github.com/aaddrick/claude-desktop-debian/pull/636), ref [#635](https://github.com/aaddrick/claude-desktop-debian/issues/635))
- Sloppy/focus-follows-mouse: suppress redundant `webContents.focus()` calls that trigger X11 `_NET_ACTIVE_WINDOW` raise-on-hover. Grace window handles stale `isFocused()` on tray-restore and minimize-restore. Thanks @tkrag. ([#589](https://github.com/aaddrick/claude-desktop-debian/pull/589), fixes [#416](https://github.com/aaddrick/claude-desktop-debian/issues/416))
- Tray: extracted JS identifier captures now accept `$` so the 1.8089.1 minified bundle ('`i$A`' menu handler) matches. Switches `\w+` to `[\w$]+`. ([#627](https://github.com/aaddrick/claude-desktop-debian/pull/627), fixes [#625](https://github.com/aaddrick/claude-desktop-debian/issues/625))
- RPM: silence "File listed twice" warning on `chrome-sandbox` by moving `chmod 4755` into `%install` (replaces `%attr` in `%files`). Adds regression guard that fails the build if the warning reappears. Thanks @JoshuaVlantis. ([#610](https://github.com/aaddrick/claude-desktop-debian/pull/610), fixes [#609](https://github.com/aaddrick/claude-desktop-debian/issues/609))
- Window close with `CLAUDE_QUIT_ON_CLOSE=1` now actively quits via `app.quit()` instead of relying on the bundled handler that hardcodes hide-to-tray on Linux. Rides upstream's own quit-in-progress guard. Thanks @phelps-matthew. ([#624](https://github.com/aaddrick/claude-desktop-debian/pull/624), fixes [#623](https://github.com/aaddrick/claude-desktop-debian/issues/623))
- node-pty: wipe upstream Windows binaries (winpty.dll, winpty-agent.exe, Windows `.node` files) before staging the Linux build, preventing PE32+ orphans in the packaged asar. Thanks @JoshuaVlantis. ([#597](https://github.com/aaddrick/claude-desktop-debian/pull/597), addresses [#401](https://github.com/aaddrick/claude-desktop-debian/issues/401))

### Changed

- CI injection hardening: moved `${{ steps.*.outputs.* }}` expressions from `run:` blocks to `env:` blocks in `issue-triage-v2.yml`. Build pipeline: `process.exit(0)` → `process.exit(1)` in `quick-window.sh` when patch anchors aren't found so CI fails instead of shipping broken patches. Packaging scriptlets: replaced `&> /dev/null` with `> /dev/null 2>&1` for dash compatibility in deb/RPM postinst. ([#641](https://github.com/aaddrick/claude-desktop-debian/pull/641))
- Credit @lizthegrey, @sabiut, @typedrat, @RayCharlizard in README Acknowledgments. ([#626](https://github.com/aaddrick/claude-desktop-debian/pull/626))
- Troubleshooting: new "Repeated Electron Crashes / GPU Process FATAL" section documenting `CLAUDE_DISABLE_GPU=1`. Adds tuning-rationale comments around the `--doctor` 3-in-7-days threshold and the `coredumpctl` `COMM=electron` assumption. Thanks @sabiut. ([#615](https://github.com/aaddrick/claude-desktop-debian/pull/615), addresses [#608](https://github.com/aaddrick/claude-desktop-debian/issues/608))
- Docs filenames are now lowercase kebab-case (`docs/building.md`, `docs/configuration.md`, `docs/decisions.md`, `docs/troubleshooting.md`); `STYLEGUIDE.md` moved to [`docs/styleguides/bash_styleguide.md`](docs/styleguides/bash_styleguide.md). Cross-references swept across README, CONTRIBUTING, CODEOWNERS, `.github/`, `.claude/`, `scripts/`, and `claude-desktop --doctor` user-facing output.
- `[$\w]+` is the codified identifier-capture convention for patch-script regexes (CONTRIBUTING § Patch-script regexes; `patch-engineer` agent examples updated to match). Closes a docs-vs-code gap that left the rule only in [`docs/learnings/patching-minified-js.md`](docs/learnings/patching-minified-js.md) — the same `\w+` trap fixed in patches by [#555](https://github.com/aaddrick/claude-desktop-debian/pull/555) and [#627](https://github.com/aaddrick/claude-desktop-debian/pull/627).

## [v2.0.12] — 2026-05-19

Tracks upstream Claude Desktop 1.7196.3.

### Added

- Headless launch + `--doctor` smoke tests for the AppImage artifact. ([#592](https://github.com/aaddrick/claude-desktop-debian/pull/592))

### Changed

- CI: add concurrency group to `test-flags` workflow. ([#606](https://github.com/aaddrick/claude-desktop-debian/pull/606))

## [v2.0.11] — 2026-05-16

Tracks upstream Claude Desktop 1.7196.1.

### Fixed

- Catch About window after upstream `titleBarStyle` change; guard Hardware Buddy. ([#481](https://github.com/aaddrick/claude-desktop-debian/pull/481), [#489](https://github.com/aaddrick/claude-desktop-debian/pull/489))
- RPM `chrome-sandbox` SUID now set via `%attr` instead of `%post chmod`. ([#539](https://github.com/aaddrick/claude-desktop-debian/pull/539), [#595](https://github.com/aaddrick/claude-desktop-debian/pull/595))
- No-op `autoUpdater` on Linux to defend against feed activation; mask thenable/coercion traps on the Proxy. ([#567](https://github.com/aaddrick/claude-desktop-debian/pull/567), [#596](https://github.com/aaddrick/claude-desktop-debian/pull/596))
- `node-pty` install fails loudly on `npm install` failure; require `gcc`/`make`/`python3`. ([#401](https://github.com/aaddrick/claude-desktop-debian/pull/401), [#598](https://github.com/aaddrick/claude-desktop-debian/pull/598))
- Fetch electron binary via `@electron/get`, drop `^41` pin; resolve from `work_dir` not script dir. ([#587](https://github.com/aaddrick/claude-desktop-debian/pull/587))
- Dedupe packages mapped from multiple commands.

## [v2.0.10] — 2026-05-06

Tracks upstream Claude Desktop 1.6259.0, 1.6259.1, 1.6608.0, 1.6608.2, 1.7196.0.

### Added

- `--doctor` surfaces recent Electron crashes with a `#583` pointer; `CLAUDE_DISABLE_GPU=1` opt-in for GPU-process fatal crashes. ([#583](https://github.com/aaddrick/claude-desktop-debian/pull/583), [#585](https://github.com/aaddrick/claude-desktop-debian/pull/585))
- `--doctor` detects IBus/GTK misconfigurations that break input. ([#572](https://github.com/aaddrick/claude-desktop-debian/pull/572))
- Launcher: `CLAUDE_GTK_IM_MODULE` opt-in override. ([#571](https://github.com/aaddrick/claude-desktop-debian/pull/571))
- Launcher: log session/IME env block at startup. ([#570](https://github.com/aaddrick/claude-desktop-debian/pull/570))
- Linux compatibility test harness. ([#579](https://github.com/aaddrick/claude-desktop-debian/pull/579))
- Lifecycle: notify and offer restart on in-place package upgrade. ([#564](https://github.com/aaddrick/claude-desktop-debian/pull/564))
- `desktopName` set for Wayland window grouping. Thanks @jslatten. ([#562](https://github.com/aaddrick/claude-desktop-debian/pull/562))

### Fixed

- Pin electron to `^41` to restore postinstall binary fetch. ([#584](https://github.com/aaddrick/claude-desktop-debian/pull/584), [#586](https://github.com/aaddrick/claude-desktop-debian/pull/586))
- Nix: make electron binary executable. ([#581](https://github.com/aaddrick/claude-desktop-debian/pull/581))
- `cowork.sh`: emit WARNING on Patch 2a/2b inner anchor miss. ([#576](https://github.com/aaddrick/claude-desktop-debian/pull/576))
- CI: force primary GPG key for `repomd.xml` signing. Thanks @ProfFlow. ([#566](https://github.com/aaddrick/claude-desktop-debian/pull/566))
- DNF: set `metadata_expire=1h` on generated `.repo`. ([#551](https://github.com/aaddrick/claude-desktop-debian/pull/551))
- BATS: isolate `cleanup_stale_cowork_socket` from host `pgrep` state. ([#534](https://github.com/aaddrick/claude-desktop-debian/pull/534))

### Changed

- Static-grep shipped asar for PR #555 markers as a verification step. ([#559](https://github.com/aaddrick/claude-desktop-debian/pull/559), [#575](https://github.com/aaddrick/claude-desktop-debian/pull/575))
- New `patching-minified-js` learnings doc + `CONTRIBUTING`. ([#574](https://github.com/aaddrick/claude-desktop-debian/pull/574))
- Refine `mcp-double-spawn` root cause and routing in learnings. ([#546](https://github.com/aaddrick/claude-desktop-debian/pull/546), [#547](https://github.com/aaddrick/claude-desktop-debian/pull/547))
- Archive upstream report draft for #546 (filed as `anthropics/claude-code#55353`). ([#552](https://github.com/aaddrick/claude-desktop-debian/pull/552))

## [v2.0.8] — 2026-05-02

Tracks upstream Claude Desktop 1.5354.0 (unchanged from v2.0.7).

### Fixed

- Cowork starts again on Claude Desktop 1.5354.0. Upstream's minifier started emitting `$`-containing identifiers (`C$i`, `g$i`); two regex anchors in `scripts/patches/cowork.sh` used `\w+`, which doesn't match `$`. Patch 2b silently no-op'd, the Swift VM module assignment never landed, and you'd hit `Swift VM addon not available` at session init. Widens both anchors to `[\w$]+`. Patch 6 also moves from `indexOf` to `lastIndexOf` on the retry-delay anchor. Thanks @sirfaber, @HumboldtJoker, @zabka. ([#555](https://github.com/aaddrick/claude-desktop-debian/pull/555), fixes [#558](https://github.com/aaddrick/claude-desktop-debian/issues/558), likely fixes [#553](https://github.com/aaddrick/claude-desktop-debian/issues/553) and [#445](https://github.com/aaddrick/claude-desktop-debian/issues/445))

## [v2.0.7] — 2026-05-01

Tracks upstream Claude Desktop 1.5354.0 (unchanged from v2.0.6).

### Added

- Linux in-app topbar works now. New `hybrid` titlebar mode is the default: native OS frame plus a BrowserView preload shim that satisfies claude.ai's UA gate, so the hamburger, sidebar, search, and nav buttons render and are clickable. Layout is stacked (DE titlebar above the in-app topbar) rather than combined like Windows. Set `CLAUDE_TITLEBAR_STYLE=native` to opt out and hide the in-app topbar. The upstream `frame:false` + WCO config is preserved as `hidden` for investigation but still has unclickable buttons on Linux; `--doctor` warns when it's active. Verified on KDE Plasma X11/Wayland and Hyprland; GNOME, Sway, Niri, and NixOS pending. ([#538](https://github.com/aaddrick/claude-desktop-debian/pull/538))

## [v2.0.6] — 2026-05-01

Tracks upstream Claude Desktop 1.5354.0. Absorbs three upstream bumps from v2.0.5: 1.4758.0, 1.5220.0, 1.5354.0.

### Added

- Cowork bwrap mounts accept a `{src, dst}` form, so you can map a host directory under `$HOME` onto a different path inside the sandbox. Unlocks persistent-`/tmp` so Bash tool calls don't wipe state between invocations. String form unchanged. Thanks @cbonnissent. ([#531](https://github.com/aaddrick/claude-desktop-debian/pull/531))
- `--doctor` warns when `COWORK_VM_BACKEND` is set to an unknown value instead of silently falling through to auto-detect; adds a `COWORK_VM_BACKEND` row and a Cowork Backend section to `docs/configuration.md`. Thanks @CyPack. ([#324](https://github.com/aaddrick/claude-desktop-debian/issues/324))
- `--doctor` warns when an additional bwrap mount destination shadows a default sandbox path like `/usr`, `/etc`, `/bin`, `/sbin`, `/lib`. ([#531](https://github.com/aaddrick/claude-desktop-debian/pull/531))
- Troubleshooting entries for Cowork VM connection timeout, virtiofsd outside `$PATH` on Fedora/RHEL (`/usr/libexec/virtiofsd`), and Fedora tmpfs `EXDEV` errors. ([#324](https://github.com/aaddrick/claude-desktop-debian/issues/324))

### Fixed

- Closing the window no longer kills the app on Linux. The X button hides to tray, matching Windows and macOS. Quit explicitly with Ctrl+Q, the tray menu, or your DE's quit shortcut. Set `CLAUDE_QUIT_ON_CLOSE=1` to restore the old behavior. Fixes scheduled tasks and `/schedule` firings getting silently dropped overnight. Thanks @lizthegrey. ([#451](https://github.com/aaddrick/claude-desktop-debian/pull/451))
- "Run on startup" toggle persists on Linux now. Electron's `setLoginItemSettings` isn't implemented on Linux; the wrapper backs the toggle with `~/.config/autostart/claude-desktop.desktop` per the XDG Autostart spec. Thanks @lizthegrey. ([#450](https://github.com/aaddrick/claude-desktop-debian/pull/450), fixes [#128](https://github.com/aaddrick/claude-desktop-debian/issues/128))
- Tray icon updates in place on OS theme change instead of briefly duplicating on KDE Plasma. Uses `setImage` + `setContextMenu` rather than destroy + recreate. Thanks @IliyaBrook. ([#515](https://github.com/aaddrick/claude-desktop-debian/pull/515))
- Window visibility check works again after an upstream minified-name change broke it. Thanks @Andrej730. ([#496](https://github.com/aaddrick/claude-desktop-debian/pull/496), fixes [#495](https://github.com/aaddrick/claude-desktop-debian/issues/495))

### Changed

- APT/DNF install instructions point at `pkg.claude-desktop-debian.dev` directly, bypassing the GitHub Pages 301. Pages serves the redirect over `http://` because it can't provision a cert for the `pkg.` subdomain (DNS belongs to the Cloudflare Worker), and `apt` refuses HTTPS→HTTP downgrades. DNF was unaffected. ([#510](https://github.com/aaddrick/claude-desktop-debian/pull/510), [#514](https://github.com/aaddrick/claude-desktop-debian/pull/514))

## [v2.0.5] — 2026-04-23

Wrapper/packaging update; upstream Claude Desktop unchanged at 1.3883.0.

### Fixed

- CI: smoke test accepts release-assets CDN hostname. ([#509](https://github.com/aaddrick/claude-desktop-debian/pull/509))
- Strip CRLF from `cowork-plugin-shim.sh` during staging. ([#499](https://github.com/aaddrick/claude-desktop-debian/pull/499), [#505](https://github.com/aaddrick/claude-desktop-debian/pull/505))

## [v2.0.4] — 2026-04-23

Wrapper/packaging update; upstream Claude Desktop unchanged at 1.3883.0. No GitHub Release published.

### Fixed

- CI: smoke test accepts `http://` on Pages 301 hop. ([#506](https://github.com/aaddrick/claude-desktop-debian/pull/506))
- Worker: use `raw.githubusercontent.com` as origin to avoid Pages 301 loop. ([#504](https://github.com/aaddrick/claude-desktop-debian/pull/504))

### Changed

- Worker: flip route from staging to production for Phase 4a. ([#503](https://github.com/aaddrick/claude-desktop-debian/pull/503))

## [v2.0.3] — 2026-04-23

Wrapper/packaging update; upstream Claude Desktop unchanged at 1.3883.0. No GitHub Release published.

### Added

- APT/DNF Worker scaffolding. ([#498](https://github.com/aaddrick/claude-desktop-debian/pull/498))

### Fixed

- CI: resolve DNF Worker chain blockers. ([#500](https://github.com/aaddrick/claude-desktop-debian/issues/500), [#501](https://github.com/aaddrick/claude-desktop-debian/issues/501), [#502](https://github.com/aaddrick/claude-desktop-debian/pull/502))

### Changed

- Plan APT/DNF distribution via Cloudflare Worker. ([#493](https://github.com/aaddrick/claude-desktop-debian/pull/493), [#494](https://github.com/aaddrick/claude-desktop-debian/pull/494))

## [v2.0.2] — 2026-04-22

Wrapper/packaging update; upstream Claude Desktop unchanged at 1.3883.0.

### Added

- BATS unit tests for `launcher-common.sh`. ([#395](https://github.com/aaddrick/claude-desktop-debian/pull/395))

### Fixed

- Copy `ion-dist` static assets for the `app://` protocol handler. ([#490](https://github.com/aaddrick/claude-desktop-debian/pull/490))

## [v2.0.1] — 2026-04-21

Wrapper/packaging update; tracks upstream Claude Desktop 1.3561.0, 1.3883.0.

### Added

- Triage Phase 4 sub-PRs: Stage 8c enhancement-design variant, suspicious-input tells, `regression_of` + edit-during-triage. ([#470](https://github.com/aaddrick/claude-desktop-debian/pull/470), [#471](https://github.com/aaddrick/claude-desktop-debian/pull/471), [#472](https://github.com/aaddrick/claude-desktop-debian/pull/472))
- Triage Phase 3: Stage 6 adversarial reviewer + duplicate gate. ([#465](https://github.com/aaddrick/claude-desktop-debian/pull/465))
- Decision log with D-001 (auto-update direction). ([#477](https://github.com/aaddrick/claude-desktop-debian/pull/477))
- `@sabiut` added to CODEOWNERS for testing & release quality. ([#468](https://github.com/aaddrick/claude-desktop-debian/pull/468))

### Fixed

- Export `GDK_BACKEND=wayland` in native Wayland mode. Thanks @aJV99. ([#397](https://github.com/aaddrick/claude-desktop-debian/pull/397))
- Scope Ctrl+Q to the focused window, not system-wide. ([#484](https://github.com/aaddrick/claude-desktop-debian/pull/484))
- Cowork: forward `CLAUDE_CODE_OAUTH_TOKEN` to VM spawn env. ([#482](https://github.com/aaddrick/claude-desktop-debian/pull/482), [#485](https://github.com/aaddrick/claude-desktop-debian/pull/485))
- Launcher: disable GPU compositing on XRDP sessions. ([#475](https://github.com/aaddrick/claude-desktop-debian/pull/475))
- Triage: normalize `claimed_version` before drift compare. ([#483](https://github.com/aaddrick/claude-desktop-debian/pull/483))
- Triage: drift-as-banner — demote drift from gate to modifier. ([#476](https://github.com/aaddrick/claude-desktop-debian/pull/476))
- Triage: pull broken-expectation rule up into first-pass classify. ([#469](https://github.com/aaddrick/claude-desktop-debian/pull/469))
- Triage: raise 8b comment word cap 150 → 300. ([#464](https://github.com/aaddrick/claude-desktop-debian/pull/464))

### Changed

- Triage v2 production cutover; README synced with shipped pipeline (drop plan + research). ([#478](https://github.com/aaddrick/claude-desktop-debian/pull/478), [#480](https://github.com/aaddrick/claude-desktop-debian/pull/480))
- Rename `feature` classification to `enhancement` in triage. ([#466](https://github.com/aaddrick/claude-desktop-debian/pull/466))

## [v2.0.0] — 2026-04-20

First v2 wrapper release; tracks upstream Claude Desktop 1.3109.0, 1.3561.0.

### Added

- Always-on lifecycle logging for `cowork-vm-service`. ([#408](https://github.com/aaddrick/claude-desktop-debian/pull/408))
- `cowork-vm-daemon` learnings doc and Anthropic & Partners plugin install flow doc. ([#439](https://github.com/aaddrick/claude-desktop-debian/pull/439))
- `.github/CODEOWNERS` for per-subsystem review ownership.
- `shellcheck -x` to follow sourced modules in CI.

### Fixed

- Restore `cowork-vm-service` daemon recovery after crash. ([#408](https://github.com/aaddrick/claude-desktop-debian/pull/408))
- Forward `userSelectedFolders[0]` as `sharedCwdPath` on cowork spawn. ([#412](https://github.com/aaddrick/claude-desktop-debian/pull/412), [#436](https://github.com/aaddrick/claude-desktop-debian/pull/436))
- Strip mode on `node-pty` cp at source; retire `chmod`. Chmod `node-pty` unpacked files before overwriting in Nix builds. ([#432](https://github.com/aaddrick/claude-desktop-debian/pull/432), [#438](https://github.com/aaddrick/claude-desktop-debian/pull/438))
- Diagnose AppArmor userns block on bwrap probe. ([#351](https://github.com/aaddrick/claude-desktop-debian/issues/351), [#434](https://github.com/aaddrick/claude-desktop-debian/pull/434))
- Suppress Cowork tab auto-select on every launch. ([#341](https://github.com/aaddrick/claude-desktop-debian/issues/341), [#433](https://github.com/aaddrick/claude-desktop-debian/pull/433))
- `home --dir` before SDK `--ro-bind` in bwrap sandbox. ([#426](https://github.com/aaddrick/claude-desktop-debian/pull/426))
- Only route `claude` commands through SDK binary in `cowork-vm-service`. ([#430](https://github.com/aaddrick/claude-desktop-debian/pull/430))
- `launcher-common.sh` self-match and stale socket cleanup. ([#407](https://github.com/aaddrick/claude-desktop-debian/pull/407), [#425](https://github.com/aaddrick/claude-desktop-debian/pull/425))
- Translate guest paths inside `--allowedTools` and `--disallowedTools`. ([#411](https://github.com/aaddrick/claude-desktop-debian/pull/411))
- Resolve working directory from primary mount on HostBackend. ([#392](https://github.com/aaddrick/claude-desktop-debian/pull/392))

### Changed

- **BREAKING**: Split `build.sh` into topical modules under `scripts/`; relocate packaging scripts into `scripts/packaging/`; extract `--doctor` into `scripts/doctor.sh`. Patch files now live in `scripts/patches/*.sh` (one per subsystem); `build.sh` is just an orchestrator. CI paths updated to `scripts/setup/detect-host.sh`.
- Simplify cowork daemon recovery patch. ([#408](https://github.com/aaddrick/claude-desktop-debian/pull/408))

[Unreleased]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.13+claude1.8555.2...HEAD
[v2.0.13]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.12+claude1.8555.2...v2.0.13+claude1.8555.2
[v2.0.12]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.11+claude1.7196.1...v2.0.12+claude1.7196.3
[v2.0.11]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.10+claude1.7196.0...v2.0.11+claude1.7196.1
[v2.0.10]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.8+claude1.5354.0...v2.0.10+claude1.6259.0
[v2.0.8]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.7+claude1.5354.0...v2.0.8+claude1.5354.0
[v2.0.7]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.6+claude1.5354.0...v2.0.7+claude1.5354.0
[v2.0.6]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.5+claude1.5354.0...v2.0.6+claude1.5354.0
[v2.0.5]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.4+claude1.3883.0...v2.0.5+claude1.3883.0
[v2.0.4]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.3+claude1.3883.0...v2.0.4+claude1.3883.0
[v2.0.3]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.2+claude1.3883.0...v2.0.3+claude1.3883.0
[v2.0.2]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.1+claude1.3883.0...v2.0.2+claude1.3883.0
[v2.0.1]: https://github.com/aaddrick/claude-desktop-debian/compare/v2.0.0+claude1.3561.0...v2.0.1+claude1.3883.0
[v2.0.0]: https://github.com/aaddrick/claude-desktop-debian/releases/tag/v2.0.0+claude1.3109.0
