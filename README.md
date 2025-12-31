# Claude Desktop for Linux

This project provides build scripts to run Claude Desktop natively on Linux systems. It repackages the official Windows application for multiple Linux distributions, producing:
- **`.deb`** packages for Debian/Ubuntu-based systems
- **`.rpm`** packages for Fedora/RHEL-based systems
- **AppImages** for universal Linux support

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/aaddrick/claude-desktop-debian/issues) in this repository.

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration  
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**: 
  - X11 Global hotkey support (Ctrl+Alt+Space)
  - System tray integration
  - Desktop environment integration

### Screenshots

![Claude Desktop running on Linux](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![Global hotkey popup](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![System tray menu on KDE](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## Installation

### Using Pre-built Releases

Download the latest `.deb` or `.AppImage` from the [Releases page](https://github.com/aaddrick/claude-desktop-debian/releases).

### Building from Source

#### Prerequisites

**Supported Distributions:**
- **Debian/Ubuntu-based**: Debian, Ubuntu, Linux Mint, MX Linux, etc.
- **Fedora/RHEL-based**: Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux, etc.

**Dependencies:**

The build script will automatically check for and install missing dependencies. If you prefer to install them manually:

<details>
<summary>Debian/Ubuntu (click to expand)</summary>

```bash
sudo apt update
sudo apt install -y p7zip-full wget icoutils imagemagick nodejs npm dpkg-dev
```
</details>

<details>
<summary>Fedora/RHEL (click to expand)</summary>

```bash
sudo dnf install -y p7zip p7zip-plugins wget icoutils ImageMagick nodejs npm rpm-build
```
</details>

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build a .deb package (default on Debian/Ubuntu)
./build.sh --build deb

# Build an .rpm package (for Fedora/RHEL)
./build.sh --build rpm

# Build an AppImage (universal)
./build.sh --build appimage

# Build with custom options
./build.sh --build deb --clean no  # Keep intermediate files
```

**See also:** [RPM_BUILD_GUIDE.md](RPM_BUILD_GUIDE.md) for detailed RPM package build instructions.

#### Installing the Built Package

**For .deb packages (Debian/Ubuntu):**
```bash
sudo apt install ./claude-desktop_VERSION_ARCHITECTURE.deb

# Or using dpkg:
sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb
# If you encounter dependency issues:
sudo apt --fix-broken install
```

**For .rpm packages (Fedora/RHEL):**
```bash
sudo dnf install ./claude-desktop-VERSION-RELEASE.ARCH.rpm

# Or using rpm:
sudo rpm -ivh ./claude-desktop-VERSION-RELEASE.ARCH.rpm

# On RHEL/CentOS, you may need to use yum:
sudo yum install ./claude-desktop-VERSION-RELEASE.ARCH.rpm
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

### Application Logs

Runtime logs are available at:
```
$HOME/claude-desktop-launcher.log
```

## Uninstallation

**For .deb packages:**
```bash
# Remove package
sudo apt remove claude-desktop
# Or: sudo dpkg -r claude-desktop

# Remove package and configuration
sudo apt purge claude-desktop
# Or: sudo dpkg -P claude-desktop
```

**For .rpm packages:**
```bash
# Remove package
sudo dnf remove claude-desktop
# Or: sudo rpm -e claude-desktop

# On RHEL/CentOS:
sudo yum remove claude-desktop
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

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .deb package instead
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as:
   - **Debian package (.deb)**: Standard package for Debian/Ubuntu systems with full integration
   - **RPM package (.rpm)**: Standard package for Fedora/RHEL systems with full integration
   - **AppImage**: Portable, self-contained executable for universal Linux support

### Build Process

The build script (`build.sh`) handles:
- Dependency checking and installation
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement
- Package generation based on selected format

### Updating for New Releases

The script automatically detects system architecture and downloads the appropriate version. If Claude Desktop's download URLs change, update the `CLAUDE_DOWNLOAD_URL` variables in `build.sh`.

## Acknowledgments

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **k3d3** for the original NixOS implementation and native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)** for the title bar fix and alternative implementation approach

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.
