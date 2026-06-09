[< Back to README](../README.md)

# Troubleshooting

## Built-in Diagnostics

Run the `--doctor` flag to check your system for common issues:

```bash
# Deb install
claude-desktop --doctor

# AppImage
./claude-desktop-*.AppImage --doctor
```

This runs a series of checks and prints pass/fail results with
suggested fixes:

| Check | What it verifies |
|-------|-----------------|
| Installed version | Package version via dpkg |
| Display server | Wayland/X11 detection and mode |
| Input method | IBus/GTK immodule sanity (ibus-gtk3 installed, cache fresh, XWayland routing note) |
| Electron binary | Existence and version |
| Chrome sandbox | Correct permissions (4755/root) |
| User namespaces | AppArmor userns restriction + Claude profile presence (Ubuntu 24.04+) |
| SingletonLock | Stale lock file detection |
| MCP config | JSON validity and server count |
| Node.js | Version (v20+ recommended for MCP) |
| Desktop entry | `.desktop` file presence |
| Disk space | Free space on config partition |
| Log file | Log file size |

Example output:
```
Claude Desktop Diagnostics
================================

[PASS] Installed version: 1.1.4498-1.3.15
[PASS] Display server: Wayland (WAYLAND_DISPLAY=wayland-0)
[PASS] Electron: found at /usr/lib/claude-desktop/node_modules/electron/dist/electron
[PASS] Chrome sandbox: permissions OK
[PASS] SingletonLock: no lock file (OK)
[PASS] MCP config: valid JSON
[PASS] Node.js: v22.14.0
[PASS] Desktop entry: /usr/share/applications/claude-desktop.desktop
[PASS] Disk space: 632284MB free
[PASS] Log file: 1352KB

All checks passed.
```

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

### Global Hotkey Not Working (Wayland)

If the global hotkey (Ctrl+Alt+Space) doesn't work, ensure you're not running in native Wayland mode:

1. Check your logs at `~/.cache/claude-desktop-debian/launcher.log`
2. Look for "Using X11 backend via XWayland" - this means hotkeys should work
3. If you see "Using native Wayland backend", unset `CLAUDE_USE_WAYLAND` or ensure it's not set to `1`

**Note:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal.

See [configuration.md](configuration.md) for more details on the `CLAUDE_USE_WAYLAND` environment variable.

### Keyboard Input Doesn't Work (IBus / GTK Input Method)

If typing into the chat does nothing, characters get swallowed, or
dead-key sequences (e.g. ``` `e ``` → `è`) don't compose, your GTK
input module integration with the Electron-bundled GTK is broken.
Common symptoms:

- No characters appear when typing into any text field
- The first keystroke after focus is dropped, subsequent ones work
- CJK input methods (IBus, Fcitx) not engaging
- Compose key / dead-key sequences silently drop

**First step: run `claude-desktop --doctor`.** It checks for the
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
CLAUDE_GTK_IM_MODULE=xim claude-desktop

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
a FATAL exhaustion path. `claude-desktop --doctor` surfaces this
when `systemd-coredump` shows 3+ Electron crashes in the last 7
days, pointing at this issue.

Two ways to disable hardware acceleration as a workaround:

1. **In-app:** Settings → toggle hardware acceleration off →
   restart Claude Desktop. Persists in the upstream config.
2. **Env var (headless / persists across reinstalls):** set
   `CLAUDE_DISABLE_GPU=1` in the environment before launching.

```bash
# One-off:
CLAUDE_DISABLE_GPU=1 claude-desktop

# Persistent (shell profile):
echo 'export CLAUDE_DISABLE_GPU=1' >> ~/.profile
```

When `CLAUDE_DISABLE_GPU=1` is set, the launcher passes
`--disable-gpu --disable-software-rasterizer` to Electron (see
`scripts/launcher-common.sh`). This is the same pair of flags
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
MESA_LOADER_DRIVER_OVERRIDE=softpipe claude-desktop
```

The failing launch logs this signature in
`~/.cache/claude-desktop-debian/launcher.log`:

```
KMS: DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied
```

**Try the faster fallbacks first.** softpipe renders everything on
the CPU with no acceleration of any kind and is noticeably slow.
Before reaching for it:

1. `CLAUDE_DISABLE_GPU=1 claude-desktop` — disables hardware
   acceleration entirely (see the previous section).
2. `LIBGL_ALWAYS_SOFTWARE=1 claude-desktop` — selects llvmpipe,
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

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

### Cowork on Ubuntu 24.04+ (AppArmor Blocks User Namespaces)

**Cause:** Ubuntu 24.04+ sets `apparmor_restrict_unprivileged_userns=1`. This blocks the user namespaces Cowork's bubblewrap sandbox needs.

**Symptom:** `claude-desktop --doctor` shows `Cowork isolation: host-direct (bwrap probe failed)`.

**Fix (`.deb` installs):** None needed. The `postinst` installs `/etc/apparmor.d/claude-desktop-bwrap`, granting `userns` to `/usr/bin/bwrap`. Still failing? Reinstall the package — the `postinst` recreates the profile.

**Fix (AppImage, Nix, rpm, and manual installs):** The auto-install is deb-only; install the profile by hand:

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

**Existing profiles win:** The `postinst` defers to any profile already attaching to `/usr/bin/bwrap` — the hand-made `/etc/apparmor.d/bwrap` above, or `bwrap-userns-restrict` from the `apparmor-profiles` package — rather than shadowing it with its unconfined-mode one. If such a profile blocks `userns`, resolve the conflict yourself before expecting Cowork isolation to work.

**Customizing:** Put overrides in `/etc/apparmor.d/local/claude-desktop-bwrap` — they survive upgrades. Direct edits to the managed profile do not: the `postinst` rewrites any profile carrying its marker header on every upgrade, and removes it on purge.

**Security:** The profile grants `userns` to `/usr/bin/bwrap` host-wide. Bubblewrap's own sandbox does the confining. Review against your threat model.

**Credit:** [@hfyeh](https://github.com/hfyeh), [#351](https://github.com/aaddrick/claude-desktop-debian/issues/351).

### Claude Desktop crashes immediately on launch (Ubuntu 24.04+, AppArmor blocks user namespaces)

The `.deb` handles this automatically — this section is for the rare case
where it doesn't. Ubuntu 24.04+ sets
`apparmor_restrict_unprivileged_userns=1`, blocking the user namespaces
Chromium's sandbox needs (same root cause as the Cowork case above, but it
kills the **main app** on startup before any window appears). The deb's
`postinst` installs a scoped AppArmor profile
(`/etc/apparmor.d/claude-desktop`) that grants `userns` to the bundled
Electron binary only — exactly as the `google-chrome`, `code`, and `slack`
packages do — so a normal install needs no action.

You only need to act if the app still crashes on launch with:

- `FATAL:sandbox/linux/services/credentials.cc:131] Check failed: . :
  Permission denied (13)` in
  `~/.cache/claude-desktop-debian/launcher.log` (the line number varies by
  Electron version), and
- a `Trace/breakpoint trap` / core dump (exit code 133).

Run `sudo claude-desktop --doctor` first — the **User namespaces** check
reports whether the profile is actually loaded into the kernel (reading the
loaded set needs root; without `sudo` it can only confirm the profile is
present on disk). To (re)install it manually:

```bash
sudo tee /etc/apparmor.d/claude-desktop <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile claude-desktop /usr/lib/claude-desktop/node_modules/electron/dist/electron flags=(unconfined) {
    userns,

    include if exists <local/claude-desktop>
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/claude-desktop
```

To customize the profile on a `.deb` install, put overrides in
`/etc/apparmor.d/local/claude-desktop` — they survive upgrades; direct
edits to the managed profile are rewritten by the `postinst` on every
upgrade.

Don't use `--no-sandbox` as a permanent fix on the `.deb` — it disables the
Chromium sandbox entirely, which the package is built to keep. (AppImage
builds already launch with `--no-sandbox` because they can't ship a SUID
helper, so they never hit this crash.)

**Security note:** the profile grants the unconfined profile plus the
`userns` capability to the bundled Electron binary only, not system-wide —
narrower than relaxing `kernel.apparmor_restrict_unprivileged_userns`
globally, which would lift the restriction for every program on the host.
Review against your threat model before applying.

### Claude Desktop crashes immediately on launch (Ubuntu 24.04+, AppArmor blocks user namespaces)

The `.deb` handles this automatically — this section is for the rare case
where it doesn't. Ubuntu 24.04+ sets
`apparmor_restrict_unprivileged_userns=1`, blocking the user namespaces
Chromium's sandbox needs (same root cause as the Cowork case above, but it
kills the **main app** on startup before any window appears). The deb's
`postinst` installs a scoped AppArmor profile
(`/etc/apparmor.d/claude-desktop`) that grants `userns` to the bundled
Electron binary only — exactly as the `google-chrome`, `code`, and `slack`
packages do — so a normal install needs no action.

You only need to act if the app still crashes on launch with:

- `FATAL:sandbox/linux/services/credentials.cc:131] Check failed: . :
  Permission denied (13)` in
  `~/.cache/claude-desktop-debian/launcher.log` (the line number varies by
  Electron version), and
- a `Trace/breakpoint trap` / core dump (exit code 133).

Run `sudo claude-desktop --doctor` first — the **User namespaces** check
reports whether the profile is actually loaded into the kernel (reading the
loaded set needs root; without `sudo` it can only confirm the profile is
present on disk). To (re)install it manually:

```bash
sudo tee /etc/apparmor.d/claude-desktop <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile claude-desktop /usr/lib/claude-desktop/node_modules/electron/dist/electron flags=(unconfined) {
    userns,

    include if exists <local/claude-desktop>
}
EOF

sudo apparmor_parser -r /etc/apparmor.d/claude-desktop
```

Don't use `--no-sandbox` as a permanent fix on the `.deb` — it disables the
Chromium sandbox entirely, which the package is built to keep. (AppImage
builds already launch with `--no-sandbox` because they can't ship a SUID
helper, so they never hit this crash.)

**Security note:** the profile grants the unconfined profile plus the
`userns` capability to the bundled Electron binary only, not system-wide —
narrower than relaxing `kernel.apparmor_restrict_unprivileged_userns`
globally, which would lift the restriction for every program on the host.
Review against your threat model before applying.

### Cowork: "VM connection timeout after 60 seconds"

If Cowork fails with a VM timeout, the KVM backend is selected but the guest VM cannot connect back to the host via vsock within the timeout window. Common causes:

1. **First-boot initialization** — the guest VM may take longer than 60 seconds on first launch
2. **vsock driver issues** — the host may be missing the `vhost_vsock` module (`sudo modprobe vhost_vsock`), or the guest initrd may lack `vmw_vsock_virtio_transport`

**Fix:** Force the bubblewrap backend, which provides namespace-level isolation without a VM:

```bash
COWORK_VM_BACKEND=bwrap claude-desktop
```

See [configuration.md](configuration.md#cowork-backend) for how to make this permanent.

### Cowork: virtiofsd not found (Fedora/RHEL)

On Fedora and RHEL, `virtiofsd` installs to `/usr/libexec/virtiofsd` which is
outside `$PATH`. The `--doctor` check detects it there automatically and will
show `[PASS]`, but the KVM backend spawns `virtiofsd` by name at runtime and
resolves it through `$PATH` only.

**Fix:** Create a symlink so the KVM backend can find it at runtime:

```bash
sudo ln -s /usr/libexec/virtiofsd /usr/local/bin/virtiofsd
```

On Debian/Ubuntu, the same issue can occur with `/usr/lib/qemu/virtiofsd`.

### Cowork: cross-device link error on Fedora tmpfs /tmp

On Fedora, `/tmp` is a tmpfs by default. VM bundle downloads may fail with `EXDEV: cross-device link not permitted` when moving files from `/tmp` to `~/.config/Claude/`.

**Fix:** Set `TMPDIR` to a directory on the same filesystem:

```bash
mkdir -p ~/.config/Claude/tmp
TMPDIR=~/.config/Claude/tmp claude-desktop
```

Or add `TMPDIR=%h/.config/Claude/tmp` to the `Exec=` line in your `.desktop` file.

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

**Diagnosis:** `claude-desktop --doctor` detects this automatically
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

### Authentication Errors (401)

If you encounter recurring "API Error: 401" messages after periods of inactivity, the cached OAuth token may need to be cleared. This is an upstream application issue reported in [#156](https://github.com/aaddrick/claude-desktop-debian/issues/156).

To fix manually (credit: [MrEdwards007](https://github.com/MrEdwards007)):

1. Close Claude Desktop completely
2. Edit `~/.config/Claude/config.json`
3. Remove the line containing `"oauth:tokenCache"` (and any trailing comma if needed)
4. Save the file and restart Claude Desktop
5. Log in again when prompted

A scripted solution is also available at the bottom of [this comment](https://github.com/aaddrick/claude-desktop-debian/issues/156#issuecomment-2682547498).

## Uninstallation

### For APT repository installations (Debian/Ubuntu)

```bash
# Remove package
sudo apt remove claude-desktop

# Remove the repository and GPG key
sudo rm /etc/apt/sources.list.d/claude-desktop.list
sudo rm /usr/share/keyrings/claude-desktop.gpg
```

### For DNF repository installations (Fedora/RHEL)

```bash
# Remove package
sudo dnf remove claude-desktop

# Remove the repository
sudo rm /etc/yum.repos.d/claude-desktop.repo
```

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
sudo apt remove claude-desktop
# Or: sudo dpkg -r claude-desktop

# Remove package and configuration
sudo dpkg -P claude-desktop
```

### For .rpm packages

```bash
# Remove package
sudo dnf remove claude-desktop
# Or: sudo rpm -e claude-desktop
```

### For AppImages

1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

### Remove user configuration (all formats)

```bash
rm -rf ~/.config/Claude
```
