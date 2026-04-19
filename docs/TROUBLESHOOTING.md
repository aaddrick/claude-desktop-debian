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

This runs 10 checks and prints pass/fail results with suggested fixes:

| Check | What it verifies |
|-------|-----------------|
| Installed version | Package version via dpkg |
| Display server | Wayland/X11 detection and mode |
| Electron binary | Existence and version |
| Chrome sandbox | Correct permissions (4755/root) |
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

See [CONFIGURATION.md](CONFIGURATION.md) for more details on the `CLAUDE_USE_WAYLAND` environment variable.

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

### Cowork on Ubuntu 24.04+ (AppArmor Blocks User Namespaces)

Ubuntu 24.04 ships with `apparmor_restrict_unprivileged_userns=1`
by default, which blocks the unprivileged user namespaces that
Cowork's bubblewrap sandbox relies on. Symptoms:

- `claude-desktop --doctor` reports `bubblewrap: sandbox probe failed`
  with `Operation not permitted` in stderr.
- `~/.config/Claude/logs/cowork_vm_daemon.log` contains
  `bwrap is installed but cannot create a user namespace`.
- Cowork sessions hang at "Starting VM..." or loop on reconnect.

Permit user namespaces for `bwrap` via an AppArmor profile (one-time
setup, requires sudo):

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

After applying the profile, run `claude-desktop --doctor` — the
bubblewrap probe should pass, and Cowork should start without
falling back to host-direct.

**Security note:** this grants `/usr/bin/bwrap` the unconfined
profile plus the `userns` capability. It matches the behavior
bwrap had on Ubuntu 22.04 and earlier, and on most other distros,
but is a system-wide change that affects every program invoking
`/usr/bin/bwrap` (not just Claude Desktop). Review the profile
against your threat model before applying.

Credit: this workaround was contributed by
[@hfyeh](https://github.com/hfyeh) in
[#351](https://github.com/aaddrick/claude-desktop-debian/issues/351).

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
