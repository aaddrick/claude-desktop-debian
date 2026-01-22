# Claude Desktop for openSUSE

This project provides build scripts to run Claude Desktop natively on openSUSE Linux. It repackages the official Windows application for openSUSE, producing either `.rpm` packages or AppImages.

**Note:** This is an unofficial build script forked from [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) and adapted for openSUSE. For official Claude support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or openSUSE-specific implementation, please [open an issue](https://github.com/comandeo/claude-desktop-opensuse/issues) in this repository.

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**:
  - Global hotkey support (Ctrl+Alt+Space) - works on X11 and Wayland (via XWayland)
  - System tray integration
  - Desktop environment integration

### Screenshots

![Claude Desktop running on Linux](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Global hotkey popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![System tray menu on KDE](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## Installation

### Using Pre-built Releases

Download the latest `.rpm` or `.AppImage` from the [Releases page](https://github.com/comandeo/claude-desktop-opensuse/releases).

### Building from Source

#### Prerequisites

- openSUSE Linux distribution (openSUSE Leap, openSUSE Tumbleweed, etc.)
- Git
- Basic build tools (automatically installed by the script)

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/comandeo/claude-desktop-opensuse.git
cd claude-desktop-opensuse

# Build an RPM package (default)
./build.sh

# Build an AppImage
./build.sh --build appimage

# Build with custom options
./build.sh --build rpm --clean no  # Keep intermediate files

# Build using a locally downloaded installer
# (useful when the bundled download URL is outdated)
./build.sh --exe /path/to/Claude-Setup.exe
```

#### Installing the Built Package

**For RPM packages:**
```bash
sudo zypper install ./claude-desktop-VERSION-*.ARCHITECTURE.rpm

# Or using rpm directly:
sudo rpm -i ./claude-desktop-VERSION-*.ARCHITECTURE.rpm
```

**For AppImages:**
```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the provided `.desktop` file to `~/.local/share/applications/`.

**Automatic Updates:** AppImages downloaded from GitHub releases include embedded update information and work seamlessly with Gear Lever for automatic updates. Locally-built AppImages can be manually configured for updates in Gear Lever.

## Configuration

### MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_USE_WAYLAND` | unset | Set to `1` to use native Wayland instead of XWayland. Note: Global hotkeys won't work in native Wayland mode. |

**Wayland Note:** By default, Claude Desktop uses X11 mode (via XWayland) on Wayland sessions to ensure global hotkeys work. If you prefer native Wayland and don't need global hotkeys:

```bash
# One-time launch
CLAUDE_USE_WAYLAND=1 claude-desktop

# Or add to your environment permanently
export CLAUDE_USE_WAYLAND=1
```

### Application Logs

Runtime logs are available at:
```
~/.cache/claude-desktop-opensuse/launcher.log
```

## Uninstallation

**For RPM packages:**
```bash
# Remove package
sudo zypper remove claude-desktop

# Or using rpm directly
sudo rpm -e claude-desktop
```

**For AppImages:**
1. Delete the `.AppImage` file
2. Remove the `.desktop` file from `~/.local/share/applications/`
3. If using Gear Lever, use its uninstall option

**Remove user configuration (both formats):**
```bash
rm -rf ~/.config/Claude
```

## Troubleshooting

### Window Scaling Issues

If the window doesn't scale correctly on first launch:
1. Right-click the Claude Desktop tray icon
2. Select "Quit" (do not force quit)
3. Restart the application

This allows the application to save display settings properly.

### Global Hotkey Not Working (Wayland)

If the global hotkey (Ctrl+Alt+Space) doesn't work, ensure you're not running in native Wayland mode:

1. Check your logs at `~/.cache/claude-desktop-opensuse/launcher.log`
2. Look for "Using X11 backend via XWayland" - this means hotkeys should work
3. If you see "Using native Wayland backend", unset `CLAUDE_USE_WAYLAND` or ensure it's not set to `1`

**Note:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal.

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the RPM package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as either:
   - **RPM package**: Standard openSUSE system package with full integration
   - **AppImage**: Portable, self-contained executable

### Build Process

The build script (`build.sh`) handles:
- Dependency checking and installation
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement
- Package generation based on selected format

### Automated Version Detection

A GitHub Actions workflow runs daily to check for new Claude Desktop releases:

1. Uses Playwright to resolve Anthropic's Cloudflare-protected download redirects
2. Compares resolved URLs with those in `build.sh`
3. If a new version is detected:
   - Updates `build.sh` with new download URLs
   - Creates a new release tag
   - Triggers automated builds for both architectures

This ensures the repository stays up-to-date with official releases automatically.

### Manual Updates

If you need to build with a specific version before the automation catches it:

1. **Use a local installer**: Download the latest installer from [claude.ai/download](https://claude.ai/download) and build with:
   ```bash
   ./build.sh --exe /path/to/Claude-Setup.exe
   ```

2. **Update the URL**: Modify the `CLAUDE_DOWNLOAD_URL` variables in `build.sh`.

## Acknowledgments

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **k3d3** for the original NixOS implementation and native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)** for the title bar fix and alternative implementation approach
- **[leobuskin](https://github.com/leobuskin/unofficial-claude-desktop-linux)** for the Playwright-based URL resolution approach

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.
