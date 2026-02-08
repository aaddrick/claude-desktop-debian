# Claude Desktop for Linux

This project provides build scripts to run Claude Desktop natively on Linux systems. It repackages the official Windows application for Linux distributions, producing `.deb` packages (Debian/Ubuntu), `.rpm` packages (Fedora/RHEL), distribution-agnostic AppImages, and an [AUR package](https://aur.archlinux.org/packages/claude-desktop-appimage) for Arch Linux.

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/aaddrick/claude-desktop-debian/issues) in this repository.

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

### Using APT Repository (Debian/Ubuntu - Recommended)

Add the repository for automatic updates via `apt`:

```bash
# Add the GPG key
curl -fsSL https://aaddrick.github.io/claude-desktop-debian/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://aaddrick.github.io/claude-desktop-debian stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list

# Update and install
sudo apt update
sudo apt install claude-desktop
```

Future updates will be installed automatically with your regular system updates (`sudo apt upgrade`).

### Using DNF Repository (Fedora/RHEL - Recommended)

Add the repository for automatic updates via `dnf`:

```bash
# Add the repository
sudo curl -fsSL https://aaddrick.github.io/claude-desktop-debian/rpm/claude-desktop.repo -o /etc/yum.repos.d/claude-desktop.repo

# Install
sudo dnf install claude-desktop
```

Future updates will be installed automatically with your regular system updates (`sudo dnf upgrade`).

### Using AUR (Arch Linux)

The [`claude-desktop-appimage`](https://aur.archlinux.org/packages/claude-desktop-appimage) package is available on the AUR and is automatically updated with each release.

```bash
# Using yay
yay -S claude-desktop-appimage

# Or using paru
paru -S claude-desktop-appimage
```

The AUR package installs the AppImage build of Claude Desktop.

### Using Pre-built Releases

Download the latest `.deb`, `.rpm`, or `.AppImage` from the [Releases page](https://github.com/aaddrick/claude-desktop-debian/releases).

### Building from Source

#### Prerequisites

- Linux distribution (Debian/Ubuntu, Fedora/RHEL, or other)
- Git
- Basic build tools (automatically installed by the script)

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build with auto-detected format (based on your distro)
./build.sh

# Or specify a format explicitly:
./build.sh --build deb       # Debian/Ubuntu .deb package
./build.sh --build rpm       # Fedora/RHEL .rpm package
./build.sh --build appimage  # Distribution-agnostic AppImage

# Build with custom options
./build.sh --build deb --clean no  # Keep intermediate files

# Build using a locally downloaded installer
# (useful when the bundled download URL is outdated)
./build.sh --exe /path/to/Claude-Setup.exe
```

The build script automatically detects your distribution and selects the appropriate package format:
| Distribution | Default Format | Package Manager |
|--------------|----------------|-----------------|
| Debian, Ubuntu, Mint | `.deb` | apt |
| Fedora, RHEL, CentOS | `.rpm` | dnf |
| Arch Linux | `.AppImage` (via AUR) | yay/paru |
| Other | `.AppImage` | - |

#### Installing the Built Package

**For .deb packages (Debian/Ubuntu):**
```bash
sudo apt install ./claude-desktop_VERSION_ARCHITECTURE.deb
# Or: sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb

# If you encounter dependency issues:
sudo apt --fix-broken install
```

**For .rpm packages (Fedora/RHEL):**
```bash
sudo dnf install ./claude-desktop-VERSION-1.ARCH.rpm
# Or: sudo rpm -i ./claude-desktop-VERSION-1.ARCH.rpm
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
~/.cache/claude-desktop-debian/launcher.log
```

## Uninstallation

**For APT repository installations (Debian/Ubuntu):**
```bash
# Remove package
sudo apt remove claude-desktop

# Remove the repository and GPG key
sudo rm /etc/apt/sources.list.d/claude-desktop.list
sudo rm /usr/share/keyrings/claude-desktop.gpg
```

**For DNF repository installations (Fedora/RHEL):**
```bash
# Remove package
sudo dnf remove claude-desktop

# Remove the repository
sudo rm /etc/yum.repos.d/claude-desktop.repo
```

**For AUR installations (Arch Linux):**
```bash
# Using yay
yay -R claude-desktop-appimage

# Or using paru
paru -R claude-desktop-appimage

# Or using pacman directly
sudo pacman -R claude-desktop-appimage
```

**For .deb packages (manual install):**
```bash
# Remove package
sudo apt remove claude-desktop
# Or: sudo dpkg -r claude-desktop

# Remove package and configuration
sudo dpkg -P claude-desktop
```

**For .rpm packages:**
```bash
# Remove package
sudo dnf remove claude-desktop
# Or: sudo rpm -e claude-desktop
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

1. Check your logs at `~/.cache/claude-desktop-debian/launcher.log`
2. Look for "Using X11 backend via XWayland" - this means hotkeys should work
3. If you see "Using native Wayland backend", unset `CLAUDE_USE_WAYLAND` or ensure it's not set to `1`

**Note:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal.

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

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as one of:
   - **Debian package (.deb)**: For Debian, Ubuntu, and derivatives
   - **RPM package (.rpm)**: For Fedora, RHEL, CentOS, and derivatives
   - **AppImage**: Portable, distribution-agnostic executable

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
- **[yarikoptic](https://github.com/yarikoptic)** for codespell support and shellcheck compliance
- **[IamGianluca](https://github.com/IamGianluca)** for build dependency check improvements
- **[ing03201](https://github.com/ing03201)** for IBus/Fcitx5 input method support
- **[ajescudero](https://github.com/ajescudero)** for pinning @electron/asar for Node compatibility
- **[delorenj](https://github.com/delorenj)** for Wayland compatibility support
- **[Regen-forest](https://github.com/Regen-forest)** for suggesting Gear Lever as AppImageLauncher replacement
- **[niekvugteveen](https://github.com/niekvugteveen)** for fixing Debian packaging permissions
- **[speleoalex](https://github.com/speleoalex)** for native window decorations support
- **[imaginalnika](https://github.com/imaginalnika)** for moving logs to `~/.cache/`
- **[richardspicer](https://github.com/richardspicer)** for the menu bar visibility fix on Linux
- **[jacobfrantz1](https://github.com/jacobfrantz1)** for Claude Desktop code preview support and quick window submit fix
- **[janfrederik](https://github.com/janfrederik)** for the `--exe` flag to use a local installer
- **[MrEdwards007](https://github.com/MrEdwards007)** for discovering the OAuth token cache fix
- **[lizthegrey](https://github.com/lizthegrey)** for version update contributions
- **[mathys-lopinto](https://github.com/mathys-lopinto)** for the AUR package and automated deployment
- **[pkuijpers](https://github.com/pkuijpers)** for root cause analysis of the RPM repo GPG signing issue
- **[dlepold](https://github.com/dlepold)** for identifying the tray icon variable name bug with a working fix
- **[Voork1144](https://github.com/Voork1144)** for detailed analysis of the tray icon minifier bug

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.
