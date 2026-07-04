# Official-deb rebase verification

Byte-level verification of Anthropic's official Claude Desktop for Linux
`.deb` (1.17377.2, audited 2026-07-02) that decides which patches the
v3.0.0 rebase deletes and which install paths are safe to move. Reproduce
any row with `tools/patch-necessity-audit.sh` (report-only; fetches the
pinned `.deb` from the official APT pool and greps the extracted bundle).

Background: the full teardown of 1.17377.1 is report CDL-ANT-0008; this
page records only what the rebase implementation depends on, verified
against 1.17377.2.

Accessibility overlay (2026-07-03): an accessibility-maximizing
reassessment of these verdicts, re-verified against a pristine official
**1.18286.0** `.deb` (sha256 `8f314ad1…0536`), reclassifies three rows
below and firms a fourth. The reasoning is in
[`../reports/CDL-ANT-0009_patch-suite-history/verdict-reassessment-accessibility.md`](../reports/CDL-ANT-0009_patch-suite-history/verdict-reassessment-accessibility.md).
A verdict that gained a `verify` caveat is an annotation of residual risk,
**not** a code reversal — the shipped deletions stand.

Live-hardware settlement (2026-07-03/04): the open checks were then run on
the local VM fleet and a real KDE/kwallet6 host against the rebased
1.18286.0 build. **FF-1 and WCO-1 both resolved — the frame-fix and wco-shim
deletions are confirmed on live hardware.** CF-1 (#400) closed as SKIP, LD-2
resolved (the official build handles close-to-tray natively), SB-1 fixed
(artifact tests repointed), and several new findings surfaced (LOG-1,
keep-awake no-op on wlroots, AUTO-1). The outcomes are folded into the matrix
and open-items sections below; the row-by-row live evidence lived in the
CDL-ANT-0009 verification notebook (not committed — a working journal).

## Patch-necessity matrix

| Legacy patch / injected file | Verdict | Evidence (official bytes; 1.17377.2 baseline, `verify` rows re-checked on 1.18286.0) |
|---|---|---|
| `frame-fix-wrapper.js` | **delete** (frame core) **/ verify** (accreted fixes) | The `frame:!1` sites (Quick Entry + two overlays) are intentionally frameless everywhere and the main window omits `frame`; that slice, plus titlebar-mode and the autoUpdater no-op, is byte-moot (delete stands). But the wrapper also carried ~18 accreted Electron-runtime fixes tracking *unfixed upstream* bugs (#416 hover-raise, #605 sleep inhibitor, #128 openAtLogin, #623 quit hatch); the audit returns `check` on pristine 1.18286.0 ("frame:!1 occurs 3x — confirm Linux reachability"). **FF-1 resolved live (2026-07-03):** #416 shows no focus-steal on a focus-follows-mouse WM (niri); #605's sleep inhibitor both registers *and* releases at the IPC layer on KDE (session-bus `Inhibit`/`UnInhibit`, every cookie paired) — it does not reproduce, and is a silent no-op on wlroots/i3 where no inhibit service exists (functional gap, upstream candidate); #128 survives reboot; quit-without-tray (#321/#623) is handled natively by **Settings ▸ General ▸ System Tray** (off = quit-on-close). Deletion confirmed. |
| `tray.sh` mutex/delay/in-place | **delete** | Official rebuild takes an in-place `setImage` branch keyed on icon-path change; `Tray.destroy()` only runs when the user disables the tray. No SNI re-registration gap exists. |
| `tray.sh` icon selection | **delete** | The `TrayIconTemplate.png` anchor survives only in the macOS `template-image` branch. The Linux `png` branch natively selects `TrayIconLinux(-Dark).png` (GNOME or dark theme → Dark). |
| menuBarEnabled default | **delete** | Defaults map ships `menuBarEnabled:!0`. |
| `wco-shim.sh` | **delete** (local WCO) **/ verify** (remote UA gate) | `mainView.js` has no `windowControlsOverlay`/`isWindows` gating (audit `not-needed`, "mainView refs: 0") — the frameless/WCO half is dead. But that only covers the *local* bundle; the load-bearing gate is claude.ai's server-delivered `isWindows()` UA regex, unknowable from `.deb` bytes. **WCO-1 resolved live (2026-07-03):** the in-app claude.ai topbar renders on both KDE and niri, so the `isWindows()` UA gate does **not** hide it on Linux — deletion confirmed, no UA-override survivor needed. (Sway draws a *second*, server-side titlebar on top of it — SWAY-1, a decoration-suppression bug, not a topbar-absence one.) |
| `claude-code.sh` | **delete** | `getHostPlatform` has a native `linux-x64`/`linux-arm64` branch. |
| `claude-native-stub.js` | **delete** | Real Rust NAPI ELF at `resources/app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node`. |
| node-pty rebuild + `nix/node-pty.nix` | **delete** | Prebuilt `prebuilds/linux-x64/pty.node` ships in `app.asar.unpacked`. |
| autoUpdater no-op Proxy | **delete** | Updater bootstrap early-returns with `apt_channel_pending`; "Check for updates" opens the browser. |
| cowork asar-path guards (#383/#622/#632) | **delete** | The `statSync().isDirectory()` helpers still exist (3 anchors, no upstream `.asar` guard), but the official launcher is a bare ELF symlink — no `app.asar` argv ever reaches them. The guards existed only because the repackage passed the asar on argv. |
| `config.sh` #649 trusted-folder guards | **delete** | `addTrustedFolder(o)` present without a `.asar` guard, but same reasoning as above: no on-disk `.asar` argv path exists on Linux. |
| `config.sh` #400 mcpServers merge | **verify behaviorally → SKIP (patch stays retired)** | The `Config file written` write anchor is intact (`write_fn=ji`, `path=e`, `cfg=A` on 1.18286.0). **CF-1 closed (2026-07-03):** #400 reproduces only in the *edit-the-file-while-running* case — the normal edit→restart flow is safe (startup-loaded `mcpServers` are preserved across every settings write). The patch stays out of `active_patches`: 1.18286.0's `setMcpServers` programmatically deletes entries (`delete i[a]`, `delete e[t.name]`), so the old `Object.assign({}, onDisk, inMemory)` merge would **resurrect a legitimately-deleted server**. A correct fix needs delete-tracking. Upstream report for the edit-while-running loss; README gets a "quit before hand-editing the config" note (MCP-DOC-1). |
| `quick-window.sh` KDE blur/focus | **verify** (keep-pending repro) | Pristine 1.18286.0 quick var `ms`: the `\|\|hide()` anchor is present with no `blur()` — the Electron-on-KDE stale-`isFocused()` signal is structurally intact (var was `Ns` on 1.17377.2; anchor survived the bump). The bug lives in Electron, not app bytes, so bytes cannot prove it still reproduces. Stays in `active_patches`. **QW-1 partial (2026-07-03):** the happy-path submit→raise-main→new-chat flow works on both niri (unpatched — the patch is KDE-gated) and the KDE host (patched); the KDE stale-focus raise edge (does the popup reliably reappear when the main window is hidden / visible-but-unfocused) still wants a dedicated run before dropping. |
| `org-plugins.sh` | **survivor** | Byte-confirmed on pristine 1.18286.0: the path switch has `darwin`/`win32` cases then `default:return null` — **no linux case** (count 0), so MDM org plugins are dead on Linux upstream. Keeping preserves our `/etc/claude/org-plugins` behavior; keep-cost ~0 (self-defusing anchor); file upstream. (An earlier audit against a *patched* build tree false-positived a "native linux case" by matching our own injection — always audit the pristine `.deb`.) |
| `cowork.sh` reroute + `cowork-vm-service.js` | **park** (3.1 track) | Official Cowork is coworkd (Go) + QEMU/KVM over a `SO_PEERCRED` Unix socket. A bwrap fallback now means impersonating that protocol — off the 3.0.0 critical path. 3.0.0 ships KVM-only with doctor guidance. |

Patch-zero score (shipped): 11 delete (applied), 2 survivors active
(`patch_quick_window`, `patch_org_plugins_path`), 1 behavioral check,
1 parked subsystem.

Accessibility overlay (2026-07-03, re-verified pristine 1.18286.0): the
shipped deletions all stand, and three verdicts that gained a byte-level
caveat have since been settled on live hardware —
`frame-fix-wrapper.js` and `wco-shim.sh` were delete-with-residual-risk (the
accreted Electron-runtime fixes and the remote UA gate are unverifiable from
bytes), and **both cleared their live checks (FF-1 / WCO-1); the deletions
are confirmed.** `quick-window.sh` moved survivor-candidate → verify (happy
path confirmed, one KDE stale-focus edge open, QW-1) and stays active;
`org-plugins.sh` firmed survivor-candidate → survivor. These annotate
residual risk; they do not un-delete shipped code.

## Install-layout facts the rebase depends on

- **Helper resolution is relocation-safe.** `index.js` locates
  `cowork-linux-helper` via `process.resourcesPath` when packaged (function
  `t_t()`), not a hardcoded path, and coworkd's own strings contain no
  `/usr/lib/claude-desktop` references (static Go binary). Moving the tree
  to `/usr/lib/claude-desktop-unofficial` is safe for Cowork.
- **OVMF firmware probe is NOT relocation-safe across distros.** Hardcoded
  probe list, no env override: x86_64 →
  `/usr/share/OVMF/OVMF_CODE_4M.fd`, `/usr/share/OVMF/OVMF_CODE.fd`;
  arm64 → `/usr/share/AAVMF/AAVMF_CODE.fd`. Fedora/Arch/Nix ship edk2
  firmware elsewhere → RPM needs compat symlinks (+ `Requires: edk2-ovmf`),
  Nix FHS env must bind the probed path, AppImage gets doctor messaging.
  File upstream (env override / probe-list request).
- **VM rootfs** is fetched from
  `https://downloads.claude.ai/vms/linux/${arch}/${sha}/...` — arch is
  parameterized and coworkd carries `qemu-system-aarch64` strings, so
  arm64 Cowork is provisioned (live arm64 image check still pending).
- **`/usr/bin/claude-desktop` is a symlink** to
  `../lib/claude-desktop/claude-desktop`. Our launcher script replaces the
  symlink at our renamed path — that is the whole wrapper surface.
- **chrome-sandbox ships SUID-recorded** (`-rwsr-xr-x root/root` in
  `data.tar.xz`). Non-root `ar | tar` extraction strips it, so our postinst
  must re-assert `root:root 4755` (existing pattern in
  `scripts/packaging/deb.sh` ports over).
- **The tree is bare co-located** — `/usr/lib/claude-desktop/{claude-desktop,
  chrome-sandbox, resources/app.asar}`, with **no `node_modules/electron/dist`
  directory** (confirmed pristine on 1.17377.2 and 1.18286.0; `deb.sh`,
  `rpm.sh`, and `appimage.sh` all ship it as-is via `cp -a`, and every
  launcher resolves `app_exec=.../claude-desktop`, the bare ELF). **SB-1
  fixed:** only the three `tests/test-artifact-*.sh` scripts genuinely
  failed — they assert the on-disk layout, and the old
  `node_modules/electron/dist/` paths do not exist in the rebase packages;
  they are now repointed to
  `/usr/lib/claude-desktop/{claude-desktop,chrome-sandbox,resources}`. The
  `launcher-common.bats` / `doctor.bats` hits were *not* failures — they are
  synthetic example strings fed to path-agnostic matchers/parsers (keyed on
  `--type=` / `--class=$WM_CLASS` / the `/usr/lib/claude-desktop/` install
  prefix, so they passed regardless of the electron-path segment); repointed
  for realism only. Compression also varies across the train — 1.17377.2 is
  `data.tar.zst`, 1.18286.0 is `data.tar.xz`; `_extract_deb_member` handles
  both.
- **AppArmor**: official postinst writes
  `/etc/apparmor.d/claude-desktop` attaching
  `profile claude-desktop /usr/lib/claude-desktop/claude-desktop
  flags=(unconfined) { userns, }`, gated on `abi/4.0` presence. Renaming
  our profile and attachment path defuses the collision.
- **APT self-registration**: official postinst writes the Anthropic keyring
  unconditionally and a marker-guarded
  `/etc/apt/sources.list.d/claude-desktop.list` (deb line currently
  commented; `APT_REPO_DEFAULT="false"`, admin override via
  `CLAUDE_DESKTOP_ADD_REPO` in `/etc/default/claude-desktop`). We discard
  official maintainer scripts at extraction, so none of this is inherited.
- **Icons**: hicolor icons ship at
  `usr/share/icons/hicolor/{16x16,32x32,48x48,128x128,256x256}/apps/claude-desktop.png`
  — `scripts/staging/icons.sh` (wrestool from the Windows exe) is replaced
  by a straight copy.
- **`productName` is `Claude`** (`app.asar` `package.json`), so the
  `WM_CLASS='Claude'` invariant and `~/.config/Claude` survive the rebase.
  Note: the official `.desktop` sets `StartupWMClass=claude-desktop`, which
  mismatches the productName-derived WM class — check at runtime; likely an
  upstream bug worth filing. Our packaging keeps `StartupWMClass=Claude`.
- **glibc floors** (objdump): main Electron ELF **2.25**; `virtiofsd` and
  `chrome-native-host` **2.34** (matches `libc6 (>= 2.34)` in Depends);
  coworkd static (Go). Core app is more portable than the Depends line
  suggests; Cowork/browser-bridge are the 2.34-bound parts.
- **Dependency contract differs per arch** — arm64 Recommends
  `qemu-system-arm, qemu-efi-aarch64` instead of `qemu-system-x86, ovmf`.
  Packaging must re-emit Depends/Recommends verbatim from the extracted
  control file, not hardcode a copy.
- **The official APT repo is plain HTTPS** (no bot challenge). The
  Packages indexes carry Version/Filename/SHA256 for both arches, so
  version detection is a curl + awk parse
  (`resolve_official_deb` in `scripts/setup/official-deb.sh`) and
  `scripts/resolve-download-url.py` (Playwright) is deletable.

## Open items

### Resolved by live verification (2026-07-03/04)

- **FF-1** — the `frame-fix` deletion holds. #416 (no focus-steal on a FFM
  WM), #605 (KDE inhibitor registers *and* releases, cookie-paired at the
  IPC layer; no-op on wlroots/i3), #128 (survives reboot), #321/#623
  (native Settings ▸ General ▸ System Tray toggle → quit-on-close).
- **WCO-1** — the `wco-shim` deletion holds. In-app topbar renders on KDE +
  niri; the server-side `isWindows()` UA gate does not hide it on Linux.
- **CF-1 (#400)** — SKIP. Reproduces only edit-while-running; edit→restart
  is safe; the merge patch would resurrect deleted servers. Upstream report.
- **LD-2 (#321/#623)** — the `CLAUDE_QUIT_ON_CLOSE` removal is deliberate,
  not an oversight: close-to-tray is handled natively by the tray toggle.
  Re-scoped from "restore the var" to "note it's a no-op, point to the
  toggle."
- **SB-1** — artifact tests repointed to the bare co-located layout
  (this PR); the bats/doctor example strings repointed for realism.
- **LD-2** — **fixed (this PR):** `_check_legacy_env` now calls out
  `CLAUDE_QUIT_ON_CLOSE` as a deliberate no-op and points at the native
  Settings ▸ General ▸ System Tray toggle.
- **AU-1/MB-1** — **fixed (this PR):** `patch_app_asar` greps the
  pristine asar for `apt_channel_pending` and `menuBarEnabled:!0` and
  fails the build if either anchor disappears, so an upstream
  autoupdater/menu-bar flip is caught at build time instead of landing
  silently.
- **AUTO-1** — **fixed (this PR):** `heal_autostart_entry` in
  `launcher-common.sh` rewrites the app-written autostart `Exec` (the
  raw ELF, or the ephemeral `/tmp/.mount_claude*` path under AppImage)
  to the launcher on every start. Safe against the Settings toggle:
  upstream's is-enabled check reads only file existence plus
  `Hidden`/`X-GNOME-Autostart-enabled`, never the Exec content
  (verified on 1.18286.0 bytes).
- **CW-1** — **fixed (this PR):** the RPM `%post` creates a compat
  symlink at the probed firmware path (`OVMF_CODE_4M.fd` /
  `AAVMF_CODE.fd`) when no probed path exists but a known edk2/qemu
  layout does; `%postun` removes it on erase only when it is unowned
  and points at a bridged layout. deb needs nothing (the official
  Recommends `ovmf` matches the probe); AppImage stays
  doctor-messaging; the Nix FHS bind rides the @typedrat derivation.
- Runtime switch passthrough — confirmed on niri forced to native Wayland
  (`--ozone-platform=wayland`, `--enable-wayland-ime`, `WaylandWindowDecorations`
  all take; clean repaint through fullscreen⇄tile, no GPU fallback).

### Still need hardware

- **QW-1** (narrowed) — happy-path Quick Entry submit works on niri
  (unpatched) and KDE (patched); the KDE **stale-focus raise** edge still
  decides whether `patch_quick_window` stays.
- **LD-1** (partial) — KDE/kwallet6 with a **pre-existing** wallet PASSES
  (os_crypt autodetect seals cookies, auto-probe dropped). The
  **fresh-no-wallet KDE** freeze edge is still untested. Keyring-less
  compositors (niri/sway/i3) persist via the `basic` backend but store the
  token unencrypted-at-rest and raise an advisory "install a keyring" prompt.
- Live arm64 rootfs availability check (needs the manifest sha from a
  running install).
- Cowork socket protocol capture on a KVM host (feeds the 3.1
  `cowork-bwrapd` scoping; owner @RayCharlizard).

### No-hardware follow-ons (separate PRs; tracked in `.tmp/plans/official-deb-rebase-tracking.md`)

- **ACQ-1** — the Nix derivation is a hard `throw` (`nix/claude-desktop.nix`);
  every `nix build` fails. Largest install channel; on the 3.0.0 critical
  path (@typedrat).
- **LOG-1** — **fixed (this PR):** `log_message` now redacts the query
  string of any `claude://login` argv token, so OAuth codes stop landing in
  `launcher.log`.
- **LD-3** — a doctor keyring/persistence warning: probe for a reachable
  Secret Service and, when absent, note the token is stored unencrypted
  under `basic`. Pairs with LD-1. Net-new doctor surface → aaddrick's
  scope call, not built unilaterally.
- **MCP-DOC-1** — README: quit Claude Desktop before hand-editing
  `claude_desktop_config.json` (direct consequence of CF-1).
- **SHORTCUT-1 / SWAY-1 / OMARCHY-1 / GPU-1 / S10** — environment-scoped
  UX/rendering findings (KDE hotkey re-registration, sway doubled titlebar,
  omarchy AppImage integration, i3 guest greeter, niri square Quick Entry
  frame); mostly upstream reports or docs, none blocking the rebase.
