[< Back to README](../README.md)

# Troubleshooting

Run the built-in doctor first — it detects most of the problems on this page and prints fix commands inline:

```bash
# Deb / RPM install
claude-desktop-unofficial --doctor

# AppImage
./claude-desktop-unofficial-*.AppImage --doctor
```

## Built-in Diagnostics

`--doctor` runs this check set (from `scripts/doctor.sh`) and prints pass/fail results with suggested fixes:

| Check | What it verifies |
|-------|-----------------|
| Installed version | Package version from the manager that owns the install (rpm ownership of the binary is probed first, then dpkg) |
| Version drift | Installed upstream version vs the newest in Anthropic's official APT pool (network best-effort; skipped offline) |
| Package-name collision | Warns when a legacy pre-rename `claude-desktop` install from this project sits alongside Anthropic's official APT repo — before the rename to `claude-desktop-unofficial` both pools shipped a package named `claude-desktop`, and whichever version sorts higher wins on upgrade |
| Display server | Wayland/X11 detection and the XWayland/native-Wayland mode in effect |
| Input method | IBus/GTK immodule sanity (ibus-gtk3 installed, immodules cache fresh, XWayland-routes-IBus-through-XIM note) |
| Legacy environment | Warns on 2.x variables no longer honored (`CLAUDE_TITLEBAR_STYLE`, `CLAUDE_MENU_BAR`, `CLAUDE_KEEP_AWAKE`); `CLAUDE_QUIT_ON_CLOSE` gets a pointer to its native replacement, Settings > General > System Tray |
| Electron binary | The official ELF at `/usr/lib/claude-desktop-unofficial/claude-desktop` exists and is executable |
| Chrome sandbox | `/usr/lib/claude-desktop-unofficial/chrome-sandbox` has 4755/root |
| User namespaces | AppArmor userns restriction and whether the `claude-desktop-unofficial` profile is loaded (Ubuntu 24.04+; run with `sudo` to confirm the kernel-loaded state) |
| SingletonLock | Stale lock file detection |
| Password store | Reports upstream `os_crypt` autodetect vs a `CLAUDE_PASSWORD_STORE` override (informational) |
| MCP config | JSON validity and server count |
| Node.js | Version (v20+ recommended for MCP servers) |
| Desktop entry | `.desktop` file presence |
| Disk space | Free space on the config partition |
| Cowork: KVM | `/dev/kvm` present and read-write |
| Cowork: vsock | `/dev/vhost-vsock` present |
| Cowork: QEMU stack | Arch-matched `qemu-system-*` on `PATH`, firmware at the officially probed paths, virtiofsd (off-PATH locations tolerated), plus a one-line readiness summary |
| Filename limit | `NAME_MAX` ≥ 200 under `~/.claude/projects` (catches eCryptfs) |
| Cowork daemon (2.x leftover) | Orphaned `cowork-vm-service.js` from a 2.x install still holding locks |
| Recent crashes | 3+ Electron coredumps in the last 7 days → GPU-FATAL pointer ([#583](https://github.com/aaddrick/claude-desktop-debian/issues/583)) |
| Log file | Launcher log size |

Setting `COWORK_VM_BACKEND=bwrap` additionally runs the legacy bubblewrap diagnostics for the parked `scripts/cowork-fallback/` path — the shipped client has no bwrap backend.

When opening an issue, include the output of `--doctor` to help with diagnosis.

## Application Logs

Runtime logs are available at:
```
~/.cache/claude-desktop-debian/launcher.log
```

## Common Issues

### Window Scaling Issues

If the window doesn't scale correctly on first launch:
1. Right-click the Claude Desktop tray icon
2. Select "Quit" (do not force quit)
3. Restart the application

This allows the application to save display settings properly.

### Tray icon invisible on a dark panel (Linux Mint Cinnamon, etc.)

Upstream ships two Linux tray PNGs: `TrayIconLinux.png` (dark glyph for
light panels) and `TrayIconLinux-Dark.png` (light glyph for dark
panels). It picks between them from `nativeTheme.shouldUseDarkColors`
and a GNOME desktop check. Cinnamon often uses a **dark panel** while
GTK still reports a **light colour scheme**, so the black icon lands on
a dark gray tray ([#604](https://github.com/aaddrick/claude-desktop-debian/issues/604)).

Our launcher auto-detects Cinnamon themes whose panel styling is dark
(via `org.cinnamon.theme`) and sets `CLAUDE_TRAY_USE_DARK_ICON=1`; a
small asar patch threads that flag into upstream's existing selector.
Override manually if needed:

```bash
# force the light-on-dark icon (white glyph)
CLAUDE_TRAY_USE_DARK_ICON=1 claude-desktop-unofficial

# force the dark-on-light icon (black glyph)
CLAUDE_TRAY_USE_DARK_ICON=0 claude-desktop-unofficial
```

Persist either value in
`~/.config/claude-desktop-debian/environment`. `--doctor` reports which
mode is in effect (preset, Cinnamon auto-detect, or upstream default),
so include its output when reporting tray icon issues. Interim fix
pending [upstream #77170](https://github.com/anthropics/claude-code/issues/77170).

### Global Hotkey Not Working (Wayland)

If the global hotkey (Ctrl+Alt+Space) doesn't work, ensure you're not running in native Wayland mode:

1. Check your logs at `~/.cache/claude-desktop-debian/launcher.log`
2. Look for "Using X11 backend via XWayland" - this means hotkeys should work
3. If you see "Using native Wayland backend", unset `CLAUDE_USE_WAYLAND` or ensure it's not set to `1`

**Note:** Native Wayland mode routes the shortcut through the XDG GlobalShortcuts portal, which only works on some compositors (GNOME ≤ 49, KDE) due to Electron/Chromium limitations.

See [configuration.md](configuration.md#wayland-support) for more details on the `CLAUDE_USE_WAYLAND` environment variable.

### Keyboard Input Doesn't Work (IBus / GTK Input Method)

If typing into the chat does nothing, characters get swallowed, or
dead-key sequences (e.g. ``` `e ``` → `è`) don't compose, your GTK
input module integration with the bundled GTK is broken.
Common symptoms:

- No characters appear when typing into any text field
- The first keystroke after focus is dropped, subsequent ones work
- CJK input methods (IBus, Fcitx) not engaging
- Compose key / dead-key sequences silently drop

**First step: run `claude-desktop-unofficial --doctor`.** It checks for the
common misconfigurations and prints fix commands inline:

- `ibus-gtk3` package missing while `GTK_IM_MODULE=ibus`
- GTK immodules cache stale (the active module isn't listed by
  `gtk-query-immodules-3.0`)
- XWayland session routing IBus through XIM (lossy for some IMEs —
  set `CLAUDE_USE_WAYLAND=1` to use native Wayland IME)
- Active value of `CLAUDE_GTK_IM_MODULE` if you've set the override

If `--doctor` is clean but input still misbehaves, switch the
launcher to a different GTK input module. Set `CLAUDE_GTK_IM_MODULE`
and Claude Desktop will propagate it as `GTK_IM_MODULE` to Electron
at startup:

```bash
# Bypass IBus entirely — uses the X Input Method (XIM) protocol
CLAUDE_GTK_IM_MODULE=xim claude-desktop-unofficial

# To make it persistent, export it from your shell profile:
# echo 'export CLAUDE_GTK_IM_MODULE=xim' >> ~/.profile
```

Valid values: anything your GTK installation supports (`xim`, `ibus`,
`fcitx`, `simple`, etc.). When the override is active, the launcher
logs a line to `~/.cache/claude-desktop-debian/launcher.log`:

```
GTK_IM_MODULE override: ibus -> xim (via CLAUDE_GTK_IM_MODULE)
```

**Trade-off:** `xim` is the lowest-common-denominator input module
and does not support advanced IME features like CJK candidate
windows or rich compose-key sequences. Only reach for it if your
real input method (IBus/Fcitx) is broken; if you depend on CJK or
compose, prefer fixing the IBus/Fcitx integration instead.

### Repeated Electron Crashes / GPU Process FATAL ([#583](https://github.com/aaddrick/claude-desktop-debian/issues/583))

If Claude Desktop crashes repeatedly on launch or shortly after,
the most common cause on Linux is the Chromium GPU process hitting
a FATAL exhaustion path. `claude-desktop-unofficial --doctor` surfaces this
when `systemd-coredump` shows 3+ Electron crashes in the last 7
days, pointing at this issue.

Two ways to disable hardware acceleration as a workaround:

1. **In-app:** Settings → toggle hardware acceleration off →
   restart Claude Desktop. Persists in the upstream config.
2. **Env var (headless / persists across reinstalls):** set
   `CLAUDE_DISABLE_GPU=1` in the environment before launching.

```bash
# One-off:
CLAUDE_DISABLE_GPU=1 claude-desktop-unofficial

# Persistent (shell profile):
echo 'export CLAUDE_DISABLE_GPU=1' >> ~/.profile
```

When `CLAUDE_DISABLE_GPU=1` is set, the launcher passes
`--disable-gpu --disable-software-rasterizer` to the official binary
(see `scripts/launcher-common.sh`). This is the same pair of flags
applied automatically inside XRDP sessions, where software
rendering is required regardless. Either signal is sufficient —
the launcher won't stack duplicate flags.

If the previous launch already died with the GPU-process FATAL
signature and `CLAUDE_DISABLE_GPU` is unset, the next launch
auto-applies the same flags and keeps them applied on subsequent
launches. Set `CLAUDE_DISABLE_GPU=0` to suppress the auto-fallback
when retesting hardware acceleration after a driver fix — any
explicitly set value suppresses it; only `1` forces the flags on.

**When to prefer which:** the in-app toggle is friendlier if you
can reach Settings without the app crashing. Reach for
`CLAUDE_DISABLE_GPU=1` when the app crashes before you can open
Settings, when running in environments with no GPU available
(XRDP, headless CI smoke tests, some VMs), or when you want the
behavior to persist across reinstalls and config resets.

Tracking issue: [#583](https://github.com/aaddrick/claude-desktop-debian/issues/583).

### Black screen on Fedora KDE with Intel Iris Xe ([#706](https://github.com/aaddrick/claude-desktop-debian/issues/706))

If the window opens but renders entirely black on Fedora KDE with
Intel Iris Xe graphics (TigerLake-LP GT2), force Mesa's reference
software rasterizer:

```bash
MESA_LOADER_DRIVER_OVERRIDE=softpipe claude-desktop-unofficial
```

The failing launch logs this signature in
`~/.cache/claude-desktop-debian/launcher.log`:

```
KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
```

**Try the faster fallbacks first.** softpipe renders everything on
the CPU with no acceleration of any kind and is noticeably slow.
Before reaching for it:

1. `CLAUDE_DISABLE_GPU=1 claude-desktop-unofficial` — disables
   hardware acceleration entirely (see the previous section).
2. `LIBGL_ALWAYS_SOFTWARE=1 claude-desktop-unofficial` — selects llvmpipe,
   Mesa's supported software fallback, several times faster than
   softpipe.

Use `MESA_LOADER_DRIVER_OVERRIDE=softpipe` only if
`LIBGL_ALWAYS_SOFTWARE=1` also produces a black screen. To make it
persistent:

```bash
echo 'export MESA_LOADER_DRIVER_OVERRIDE=softpipe' >> ~/.profile
```

Tracking issue:
[#706](https://github.com/aaddrick/claude-desktop-debian/issues/706).
Credit: workaround discovered and confirmed by
[@dubreal](https://github.com/dubreal) while diagnosing
[#593](https://github.com/aaddrick/claude-desktop-debian/issues/593)
and
[#599](https://github.com/aaddrick/claude-desktop-debian/pull/599).

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` because Electron's chrome-sandbox requires root privileges for unprivileged namespace creation, which the FUSE-mounted AppImage cannot provide. This is a known limitation of the AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb or .rpm package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

### Claude Desktop crashes immediately on launch (Ubuntu 24.04+, AppArmor blocks user namespaces)

The `.deb` handles this automatically — this section is for the rare case
where it doesn't. Ubuntu 24.04+ sets
`apparmor_restrict_unprivileged_userns=1`, blocking the user namespaces
Chromium's sandbox needs, which kills the app on startup before any window
appears. The deb's `postinst` installs a scoped AppArmor profile
(`/etc/apparmor.d/claude-desktop-unofficial`) that grants `userns` to the official
Electron binary only — exactly as the `google-chrome`, `code`, and `slack`
packages do — so a normal install needs no action. (X11 sessions only:
on Wayland the deb launcher runs with `--no-sandbox`, and AppImage builds
always do, so neither can hit this crash.)

You only need to act if the app still crashes on launch with:

- `FATAL:sandbox/linux/services/credentials.cc:131] Check failed: . :
  Permission denied (13)` in
  `~/.cache/claude-desktop-debian/launcher.log` (the line number varies by
  Electron version), and
- a `Trace/breakpoint trap` / core dump (exit code 133).

Run `sudo claude-desktop-unofficial --doctor` first — the **User namespaces** check
reports whether the profile is actually loaded into the kernel (reading the
loaded set needs root; without `sudo` it can only confirm the profile is
present on disk). To (re)install it manually:

```bash
sudo tee /etc/apparmor.d/claude-desktop-unofficial <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile claude-desktop-unofficial /usr/lib/claude-desktop-unofficial/claude-desktop flags=(unconfined) {
    userns,

    include if exists <local/claude-desktop-unofficial>
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/claude-desktop-unofficial
```

To customize the profile on a `.deb` install, put overrides in
`/etc/apparmor.d/local/claude-desktop-unofficial` — they survive upgrades; direct
edits to the managed profile are rewritten by the `postinst` on every
upgrade (a profile without the package's marker header is treated as
hand-made and preserved instead).

Don't use `--no-sandbox` as a permanent fix on the `.deb` — it disables the
Chromium sandbox entirely, which the package is built to keep.

**Security note:** the profile grants the unconfined profile plus the
`userns` capability to the official Electron binary only, not system-wide —
narrower than relaxing `kernel.apparmor_restrict_unprivileged_userns`
globally, which would lift the restriction for every program on the host.
Review against your threat model before applying.

### Cowork unavailable (doctor: "Cowork: unavailable until the KVM stack is complete")

Cowork on the official Linux client is KVM-only — there is no bubblewrap or
host-direct fallback. If Cowork won't start, run
`claude-desktop-unofficial --doctor`;
the Cowork Mode section reports each missing piece with a fix:

- **`/dev/kvm` not present** — enable hardware virtualization (VT-x/AMD-V)
  in your BIOS/UEFI, then `sudo modprobe kvm`.
- **`/dev/kvm` not read-write** — `sudo usermod -aG kvm $USER`, then log
  out and back in.
- **`/dev/vhost-vsock` missing** — `sudo modprobe vhost_vsock`; persist
  with `echo vhost_vsock | sudo tee /etc/modules-load.d/vhost_vsock.conf`.
- **`qemu-system-x86_64` (or `qemu-system-aarch64`) not on PATH** —
  install your distro's QEMU/KVM packages; the doctor prints the exact
  command.
- **Firmware missing at the probed paths** — the official client hardcodes
  its firmware probe list (`/usr/share/OVMF/OVMF_CODE_4M.fd`,
  `/usr/share/OVMF/OVMF_CODE.fd`; arm64: `/usr/share/AAVMF/AAVMF_CODE.fd`)
  with no env override, so edk2 firmware installed elsewhere is not found.
  Our RPM package's `%post` creates a compat symlink at the probed path
  automatically (CW-1); on other layouts, symlink your edk2 firmware to
  one of the probed paths by hand.
- **virtiofsd not found** — install it (Debian/Ubuntu:
  `qemu-system-common`; Fedora: `virtiofsd`).

### Cowork: virtiofsd not found (Fedora/RHEL)

On Fedora and RHEL, `virtiofsd` installs to `/usr/libexec/virtiofsd`, which
is outside `$PATH`. The `--doctor` check searches the well-known off-PATH
locations (`/usr/libexec/virtiofsd`, `/usr/lib/qemu/virtiofsd`,
`/usr/lib/virtiofsd`) and reports `found at ... (not on PATH)` in that case.
The official client's virtiofsd spawn semantics haven't been verified
against those off-PATH locations — if the doctor finds virtiofsd off PATH
but Cowork still fails to start a VM, put it on `PATH`:

```bash
sudo ln -s /usr/libexec/virtiofsd /usr/local/bin/virtiofsd
```

### Cowork: cross-device link error on Fedora tmpfs /tmp

On Fedora, `/tmp` is a tmpfs by default. VM bundle downloads may fail with `EXDEV: cross-device link not permitted` when moving files from `/tmp` to `~/.config/Claude/`. This was reported against the 2.x backend and has not been re-verified against the official client; if you hit it:

**Fix:** Set `TMPDIR` to a directory on the same filesystem:

```bash
mkdir -p ~/.config/Claude/tmp
TMPDIR=~/.config/Claude/tmp claude-desktop-unofficial
```

Or add `TMPDIR=%h/.config/Claude/tmp` to the `Exec=` line in your `.desktop` file.

### Cowork on Ubuntu 24.04+: bwrap fallback probe fails (parked diagnostics only)

This applies **only** to the opt-in bubblewrap fallback
(`COWORK_VM_BACKEND=bwrap`, `scripts/cowork-fallback/`). The default Cowork
backend is KVM and is not affected by the user-namespace restriction below.
Ubuntu 24.04+ sets `apparmor_restrict_unprivileged_userns=1`, which blocks
the user namespaces bwrap needs, so the doctor's `bubblewrap: sandbox probe
failed` warning is expected there whether or not you ever set
`COWORK_VM_BACKEND=bwrap`.

**No package installs a bwrap AppArmor profile.** The only workaround we
can document attaches the profile to the **shared** `/usr/bin/bwrap`
binary, which grants `userns` to *every* program on the host that runs
bwrap through that same path — Flatpak, Steam, your own scripts — not just
Claude:

```bash
sudo tee /etc/apparmor.d/bwrap <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,

    include if exists <local/bwrap>
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/bwrap
```

Review that blast radius against your threat model before applying it.

**Why this can't be scoped to Claude in documentation alone:** the
per-application AppArmor pattern that opam and Apptainer use (see
[opam's profile](https://gitlab.com/apparmor/apparmor/-/blob/master/profiles/apparmor.d/opam)
and [Apptainer#2262](https://github.com/apptainer/apptainer/pull/2262))
attaches `flags=(unconfined)` to a binary *they own* that creates the
namespace — opam's `bwrap` copy, Apptainer's `starter-suid`. Claude has no
equivalent owned binary in this path: the namespace is created by the
system's shared `/usr/bin/bwrap`, and the scoped
`/etc/apparmor.d/claude-desktop-unofficial` profile installed above covers
only the Electron binary — a separate `bwrap` child process is not covered
by it (see `scripts/packaging/deb.sh`). Narrowing this for real needs a
Claude-owned wrapper binary at a stable path for a profile to attach to;
that's tracked as follow-up work on
[#542](https://github.com/aaddrick/claude-desktop-debian/issues/542) and is
not implemented yet.

This only affects launches that opt into `COWORK_VM_BACKEND=bwrap` on
Ubuntu 24.04+ — the default KVM backend never spawns bwrap and is
unaffected either way.

**AppImage:** the mount path changes every run
(`/tmp/.mount_claudeXXXXXX/…`), so an AppImage build can't ship or pin a
profile keyed to its own binary path. That doesn't matter for bwrap
specifically, though: `/usr/bin/bwrap` is a fixed host path regardless of
where the AppImage mounts, so the same system-wide recipe and warning above
apply unchanged to an AppImage-launched bwrap fallback. (The Electron
launch-crash profile above never applies to AppImage builds — they always
run with `--no-sandbox`, see
["AppImage Sandbox Warning"](#appimage-sandbox-warning) — so there's
nothing AppImage-specific to add there either.)

No package ships a bwrap profile as of v3.0.0+; the deb's `postrm` still
removes the 2.x-era `/etc/apparmor.d/claude-desktop-bwrap` leftover (and a
`claude-desktop-unofficial-bwrap` sibling, if one exists) on purge.

**Credit:** [@hfyeh](https://github.com/hfyeh)
([#351](https://github.com/aaddrick/claude-desktop-debian/issues/351)) for
the original profile workaround;
[@slovdahl](https://github.com/slovdahl) for flagging the system-wide
over-scope and the opam/Apptainer precedent, in
[PR #434](https://github.com/aaddrick/claude-desktop-debian/pull/434#issuecomment-4352273336)
(tracked in [#542](https://github.com/aaddrick/claude-desktop-debian/issues/542)).

### Cowork: ENAMETOOLONG on encrypted home (eCryptfs)

Cowork sessions can fail with an opaque `ENAMETOOLONG` error when
`$HOME` is on a filesystem with a short filename limit. The common
case is **eCryptfs** — the legacy "encrypted home" option on older
Ubuntu and Linux Mint installs, which caps individual filenames at
143 chars because of filename-encryption overhead. Standard
filesystems (ext4, btrfs, xfs, zfs) cap at 255 chars and are fine.

**Why it happens:** Claude Code creates one directory per session
under `~/.claude/projects/`, named after the sanitized host CWD. For
cowork sessions the host CWD is the deeply nested outputs dir under
`~/.config/Claude/local-agent-mode-sessions/<accountId>/<orgId>/local_<uuid>/outputs`,
which sanitizes to ~180 chars — fits ext4 but exceeds the eCryptfs
143-char ceiling.

**Diagnosis:** `claude-desktop-unofficial --doctor` detects this automatically
and emits a `[WARN] Filename limit: NAME_MAX=143…` line, plus an
eCryptfs-specific hint when the filesystem type matches. You can
also check by hand:

```bash
df -T $HOME              # look for type "ecryptfs"
getconf NAME_MAX $HOME   # eCryptfs reports 143; ext4 reports 255
```

**Workaround:** move Claude's data onto a separate LUKS-encrypted
ext4 volume (NAME_MAX = 255) and symlink the original paths back.
`~/.claude/` is the critical one — that's where Claude Code creates
the long-named per-session dirs that overflow the limit — and
`~/.config/Claude/` plus `~/.cache/claude-desktop-debian/` are
relocated alongside it so all Claude state lives on the same volume.
This keeps the data encrypted at rest while sidestepping the
eCryptfs filename-length cap.

```bash
# 1. Create a 2 GB LUKS container
sudo dd if=/dev/urandom of=/opt/claude-secure.img bs=1M count=2048 \
    status=progress
sudo cryptsetup luksFormat /opt/claude-secure.img
sudo cryptsetup open /opt/claude-secure.img claude-secure
sudo mkfs.ext4 /dev/mapper/claude-secure

# 2. Mount and move Claude's data in
sudo mkdir -p /mnt/claude-secure
sudo mount /dev/mapper/claude-secure /mnt/claude-secure
sudo chown "$USER:$USER" /mnt/claude-secure

mv ~/.config/Claude /mnt/claude-secure/Claude-config
mv ~/.cache/claude-desktop-debian /mnt/claude-secure/claude-cache
# ~/.claude may not exist yet on a fresh install — create the target
# either way so the symlink below resolves.
if [ -e ~/.claude ]; then
    mv ~/.claude /mnt/claude-secure/claude-home
else
    mkdir -p /mnt/claude-secure/claude-home
fi

ln -s /mnt/claude-secure/Claude-config ~/.config/Claude
ln -s /mnt/claude-secure/claude-cache ~/.cache/claude-desktop-debian
ln -s /mnt/claude-secure/claude-home ~/.claude

# 3. Verify the filename limit and the symlinks
getconf NAME_MAX /mnt/claude-secure   # should print 255
mountpoint /mnt/claude-secure         # confirms the volume is mounted
readlink ~/.claude                    # /mnt/claude-secure/claude-home
readlink ~/.config/Claude             # /mnt/claude-secure/Claude-config
```

**If you've set `CLAUDE_CONFIG_DIR`** (or otherwise reconfigured
Claude Code to use a directory other than `~/.claude/`), the
`~/.claude` symlink above doesn't apply — adapt the path to wherever
your Claude Code config actually lives. The constraint is the same:
the directory tree where Claude Code creates per-session project
dirs must sit on a filesystem with `NAME_MAX` ≥ ~200.

**Auto-mount at login** with `pam_mount` so the volume unlocks
without a manual `cryptsetup open`:

```bash
sudo apt install libpam-mount
```

Add a `<volume>` entry to `/etc/security/pam_mount.conf.xml`
(replace `YOUR_USERNAME` with your login name):

```xml
<volume user="YOUR_USERNAME" fstype="crypt"
        path="/opt/claude-secure.img"
        mountpoint="/mnt/claude-secure"
        options="" />
```

`libpam-mount` registers itself with `/etc/pam.d/common-auth` and
`/etc/pam.d/common-session` automatically on install.

**Notes:**
- Tested on Linux Mint with LightDM as the display manager.
- **LUKS passphrase tradeoff:** for `pam_mount` to unlock silently
  at login the LUKS passphrase must match your login password. That
  means one compromise unlocks both your session and the encrypted
  volume — equivalent to the threat surface eCryptfs already had,
  but worth a deliberate choice. Use a distinct LUKS passphrase if
  you'd rather be prompted on each unlock.
- **Confidentiality posture vs eCryptfs.** The LUKS image lives at
  `/opt/claude-secure.img`, outside `$HOME` and outside whatever
  encryption envelope eCryptfs gives you. If `pam_mount` ever fails
  silently — wrong passphrase, mount race at login, profile error —
  Claude won't start (the symlink targets won't exist), so writes
  fail loudly rather than landing on plaintext disk. Verify with
  `mountpoint /mnt/claude-secure` after login if you're unsure.
- 2 GB is a conservative starting size; the Claude config
  directory can exceed 500 MB once cowork session history
  accumulates. Resize if needed.
- This is a system-wide change that affects login flow — review
  the pam_mount config against your threat model before applying.

Credit: reported with detailed `--doctor` output by
[@michelsfun](https://github.com/michelsfun); LUKS-volume workaround
contributed by [@proffalken](https://github.com/proffalken) in
[#590](https://github.com/aaddrick/claude-desktop-debian/issues/590).

### Autostart ("Run on startup") launches without launcher policy

When "Run on startup" is enabled, the official app writes its own XDG
autostart entry pointing `Exec=` at the raw Electron binary (or, under
AppImage, at the ephemeral `/tmp/.mount_claude*` path, which breaks
entirely after the image unmounts). A login-time launch through that entry
bypasses every launcher policy — Wayland backend selection, GPU-crash
recovery, `--class`, `CLAUDE_PASSWORD_STORE`.

**Fix:** launch Claude Desktop manually once. The launcher rewrites the
autostart entry's `Exec=` to point at itself
(`/usr/bin/claude-desktop-unofficial`, or the AppImage path) on every
start (AUTO-1, `heal_autostart_entry` in
`scripts/launcher-common.sh`). The heal repeats per launch because the
app rewrites the entry each time the Settings toggle is switched on; the
toggle itself keeps working, since upstream's is-enabled check reads only
file existence, never the `Exec` content. Entries pointing at a
hand-rolled wrapper are left alone.

### Authentication Errors (401)

If you encounter recurring "API Error: 401" messages after periods of inactivity, the cached OAuth token may need to be cleared. This is an upstream application issue reported in [#156](https://github.com/aaddrick/claude-desktop-debian/issues/156).

To fix manually (credit: [MrEdwards007](https://github.com/MrEdwards007)):

1. Close Claude Desktop completely
2. Edit `~/.config/Claude/config.json`
3. Remove the line containing `"oauth:tokenCache"` (and any trailing comma if needed)
4. Save the file and restart Claude Desktop
5. Log in again when prompted

A scripted solution is also available at the bottom of [this comment](https://github.com/aaddrick/claude-desktop-debian/issues/156#issuecomment-2682547498).

### trying to overwrite '/usr/share/metainfo/io.github.aaddrick.claude-desktop-debian.metainfo.xml', which is also in package claude-desktop ([#769](https://github.com/aaddrick/claude-desktop-debian/issues/769))

`apt install` / `dpkg -i` fails with that `trying to overwrite`
message, or `dnf install` / `rpm -i` fails with `file
/usr/share/metainfo/io.github.aaddrick.claude-desktop-debian.metainfo.xml
... conflicts between attempted installs`.

The other package is a **pre-rename build of this project itself** —
never Anthropic's official `claude-desktop` package, which ships no
AppStream metainfo file at all and can never own that path. Before
this fix, releases at Claude ≥ `1.16000` (for example
`v2.0.22+claude1.18286.0`) hardcoded the installed metainfo filename
to the frozen AppStream ID instead of deriving it from the package
name, so it did not follow the `claude-desktop` →
`claude-desktop-unofficial` rename and stayed byte-shared between the
old and new package names.

A version at or above `1.16000` does **not** prove the conflicting
`claude-desktop` package is Anthropic's official build in this
specific case — that version-number heuristic does not apply here.
Instead, check which package actually owns the metainfo file:

```bash
dpkg -L claude-desktop | grep metainfo   # rpm -ql claude-desktop on Fedora
```

If that lists
`.../io.github.aaddrick.claude-desktop-debian.metainfo.xml`, the
installed `claude-desktop` is this project's own pre-rename build and
is safe to remove:

```bash
sudo apt remove claude-desktop   # sudo dnf remove claude-desktop
```

Then install `claude-desktop-unofficial` as usual. Releases built
after this fix ships no longer share this path with either package,
so the conflict cannot recur.

## Uninstallation

### For APT repository installations (Debian/Ubuntu)

```bash
# Remove package
sudo apt remove claude-desktop-unofficial

# Remove the repository and GPG key
sudo rm /etc/apt/sources.list.d/claude-desktop-unofficial.list
sudo rm /usr/share/keyrings/claude-desktop-unofficial.gpg
```

### For DNF repository installations (Fedora/RHEL)

```bash
# Remove package
sudo dnf remove claude-desktop-unofficial

# Remove the repository
sudo rm /etc/yum.repos.d/claude-desktop-unofficial.repo
```

### For legacy pre-rename installations (`claude-desktop` from this project)

Installs from before the rename to `claude-desktop-unofficial` used the
package name `claude-desktop` — the same name Anthropic's official
package uses. Check whose package you have before removing anything:

```bash
dpkg -s claude-desktop | grep '^Version:'   # rpm -q claude-desktop on Fedora
```

A version below `1.16000` is this project's legacy package; remove it
with `sudo apt remove claude-desktop` (or `sudo dnf remove
claude-desktop`). A version of `1.17377.1` or higher is **Anthropic's
official package** — leave it alone unless you mean to uninstall the
official app too.

### For AUR installations (Arch Linux)

```bash
# Using yay
yay -R claude-desktop-appimage

# Or using paru
paru -R claude-desktop-appimage

# Or using pacman directly
sudo pacman -R claude-desktop-appimage
```

### For .deb packages (manual install)

```bash
# Remove package
sudo apt remove claude-desktop-unofficial
# Or: sudo dpkg -r claude-desktop-unofficial

# Remove package and configuration
sudo dpkg -P claude-desktop-unofficial
```

### For .rpm packages

```bash
# Remove package
sudo dnf remove claude-desktop-unofficial
# Or: sudo rpm -e claude-desktop-unofficial
```

### For AppImages

1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

### Remove user configuration (all formats)

```bash
rm -rf ~/.config/Claude
```
