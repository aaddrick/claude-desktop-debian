[< Back to README](../README.md)

# Troubleshooting

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
