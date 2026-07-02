# Official-deb rebase verification

Byte-level verification of Anthropic's official Claude Desktop for Linux
`.deb` (1.17377.2, audited 2026-07-02) that decides which patches the
v3.0.0 rebase deletes and which install paths are safe to move. Reproduce
any row with `tools/patch-necessity-audit.sh` (report-only; fetches the
pinned `.deb` from the official APT pool and greps the extracted bundle).

Background: the full teardown of 1.17377.1 is report CDL-ANT-0008; this
page records only what the rebase implementation depends on, verified
against 1.17377.2.

## Patch-necessity matrix

| Legacy patch / injected file | Verdict | Evidence (official 1.17377.2 bytes) |
|---|---|---|
| `frame-fix-wrapper.js` | **delete** | The only `frame:!1` sites are the Quick Entry popup and two transparent overlay windows — intentionally frameless on every platform. The main window omits `frame` (system frame). |
| `tray.sh` mutex/delay/in-place | **delete** | Official rebuild takes an in-place `setImage` branch keyed on icon-path change; `Tray.destroy()` only runs when the user disables the tray. No SNI re-registration gap exists. |
| `tray.sh` icon selection | **delete** | The `TrayIconTemplate.png` anchor survives only in the macOS `template-image` branch. The Linux `png` branch natively selects `TrayIconLinux(-Dark).png` (GNOME or dark theme → Dark). |
| menuBarEnabled default | **delete** | Defaults map ships `menuBarEnabled:!0`. |
| `wco-shim.sh` | **delete** | Never frameless, no UA spoof; `mainView.js` has no `windowControlsOverlay`/`isWindows` gating. |
| `claude-code.sh` | **delete** | `getHostPlatform` has a native `linux-x64`/`linux-arm64` branch. |
| `claude-native-stub.js` | **delete** | Real Rust NAPI ELF at `resources/app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node`. |
| node-pty rebuild + `nix/node-pty.nix` | **delete** | Prebuilt `prebuilds/linux-x64/pty.node` ships in `app.asar.unpacked`. |
| autoUpdater no-op Proxy | **delete** | Updater bootstrap early-returns with `apt_channel_pending`; "Check for updates" opens the browser. |
| cowork asar-path guards (#383/#622/#632) | **delete** | The `statSync().isDirectory()` helpers still exist (3 anchors, no upstream `.asar` guard), but the official launcher is a bare ELF symlink — no `app.asar` argv ever reaches them. The guards existed only because the repackage passed the asar on argv. |
| `config.sh` #649 trusted-folder guards | **delete** | `addTrustedFolder(o)` present without a `.asar` guard, but same reasoning as above: no on-disk `.asar` argv path exists on Linux. |
| `config.sh` #400 mcpServers merge | **verify behaviorally** | The `Config file written` write anchor is intact, so the config writer is structurally unchanged. Reproduce #400 against a live official install before deciding; file upstream either way. |
| `quick-window.sh` KDE blur/focus | **survivor candidate** | Quick window var `Ns`: the `\|\|hide()` anchor is present with no `blur()` — the Electron-on-KDE stale-focus bug likely persists. Verify on Plasma; keep only if it reproduces. |
| `org-plugins.sh` | **survivor candidate** | The org-plugins path switch has `darwin` and `win32` cases and `default:return null` — **no linux case**, so MDM org plugins are dead on Linux upstream. Keeping the patch preserves our `/etc/claude/org-plugins` behavior; file upstream. |
| `cowork.sh` reroute + `cowork-vm-service.js` | **park** (3.1 track) | Official Cowork is coworkd (Go) + QEMU/KVM over a `SO_PEERCRED` Unix socket. A bwrap fallback now means impersonating that protocol — off the 3.0.0 critical path. 3.0.0 ships KVM-only with doctor guidance. |

Patch-zero score: 11 delete, 2 survivor candidates (≤2 budget holds),
1 behavioral check, 1 parked subsystem.

## Install-layout facts the rebase depends on

- **Helper resolution is relocation-safe.** `index.js` locates
  `cowork-linux-helper` via `process.resourcesPath` when packaged (function
  `t_t()`), not a hardcoded path, and coworkd's own strings contain no
  `/usr/lib/claude-desktop` references (static Go binary). Moving the tree
  to `/usr/lib/claude-desktop-linux` is safe for Cowork.
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

- Reproduce config #400 against a live official install (behavioral).
- Quick Entry stale-focus repro on KDE Plasma with the official build.
- Runtime switch passthrough smoke (`--ozone-platform`, `--class`,
  `--disable-gpu`) — expected fine (stock Electron), needs a live run.
- Live arm64 rootfs availability check (needs the manifest sha from a
  running install).
- Cowork socket protocol capture on a KVM host (feeds the 3.1
  `cowork-bwrapd` scoping; owner @RayCharlizard).
