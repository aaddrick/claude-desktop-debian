# Claude Desktop for Linux (Fedora)

## Acknowledgments

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **k3d3** for the original NixOS implementation and native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)** for the title bar fix and alternative implementation approach
- **[aaddrick](https://github.com/aaddrick/claude-desktop-debian)** for the Debian/Ubuntu implementation

For NixOS users, please refer to [k3d3's repository](https://github.com/k3d3/claude-desktop-linux-flake) for a Nix-specific implementation.
For Debian/Ubuntu users, please refer to [aaddrick's repository](https://github.com/aaddrick/claude-desktop-debian) for a Debian-specific implementation.

This project provides build scripts to run Claude Desktop natively on Linux systems, with a focus on Fedora and RPM-based distributions. It repackages the official Windows application for Fedora, RHEL, and other RPM-based systems, producing either `.rpm` packages or AppImages.

**Note:** This is an unofficial build script and a Fedora-focused fork. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/Frost26/Claude-Linux-Desktop/issues) in this repository.

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

Download the latest `.rpm` or `.AppImage` from the [Releases page](https://github.com/Frost26/Claude-Linux-Desktop/releases).

### Building from Source

#### Prerequisites

- Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux, openSUSE, or other RPM-based Linux distribution
- Git
- Basic build tools (automatically installed by the script)
- sudo access for dependency installation

**Note:** The build script automatically detects your system architecture (x86_64/aarch64) and installs required dependencies including:
- p7zip and p7zip-plugins for extraction
- wget for downloads
- icoutils for icon processing
- ImageMagick for image conversion
- rpm-build for RPM package creation
- Node.js 20+ (installed locally if system version is insufficient)

#### Build Instructions

```bash
# Clone the repository
git clone https://github.com/Frost26/Claude-Linux-Desktop.git
cd Claude-Linux-Desktop

# Make the build script executable
chmod +x build-fedora.sh

# Build an RPM package (default for this fork)
./build-fedora.sh --build rpm

# Build an AppImage
./build-fedora.sh --build appimage

# Build with custom options
./build-fedora.sh --build rpm --clean no  # Keep intermediate files
./build-fedora.sh --test-flags              # Test argument parsing
```

#### Installing the Built Package

**For .rpm packages:**
```bash
# Install with DNF (Fedora)
sudo dnf install ./claude-desktop-*.rpm

# Or with YUM (RHEL/CentOS)
sudo yum install ./claude-desktop-*.rpm

# Or with Zypper (openSUSE)
sudo zypper install ./claude-desktop-*.rpm
```

**For AppImages:**
```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Important:** AppImage login requires proper desktop integration for the `claude://` URL scheme to work correctly.

**Recommended:** Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) for proper AppImage integration:
```bash
# Install Gear Lever via Flatpak
flatpak install flathub it.mijorus.gearlever
```

**Manual Integration:** If not using Gear Lever, install the generated `.desktop` file:
```bash
cp claude-desktop-appimage.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/
```

**Automatic Updates:** 
- AppImages from GitHub releases include embedded update information
- Gear Lever automatically handles updates from GitHub releases
- Locally-built AppImages can be manually configured for updates in Gear Lever

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

**For .rpm packages:**
```bash
# Remove package (DNF/Fedora)
sudo dnf remove claude-desktop

# Or with YUM (RHEL/CentOS)
sudo yum remove claude-desktop

# Or with Zypper (openSUSE)
sudo zypper remove claude-desktop
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

### Build Issues

If you encounter permission errors during build:
```bash
# Ensure the script is executable
chmod +x build-fedora.sh

# If sudo authentication fails
sudo -v  # Validate sudo credentials
```

If Node.js version issues occur, the script will automatically download and install Node.js 20.18.1 locally.

### AppImage Sandbox Warning

AppImages run with `--no-sandbox` due to Electron's chrome-sandbox requiring root privileges for unprivileged namespace creation. This is a known limitation of AppImage format with Electron applications.

For enhanced security, consider:
- Using the .rpm package instead (recommended for system-wide installation)
- Running the AppImage within a separate sandbox (e.g., bubblewrap)
- Using Gear Lever's integrated AppImage management for better isolation

### Architecture Support

The build script automatically detects and supports:
- **x86_64** (Intel/AMD 64-bit)
- **aarch64** (ARM 64-bit)

Both architectures support RPM and AppImage output formats.

## Technical Details

### How It Works

Claude Desktop is an Electron application distributed for Windows. This project:

1. Downloads the official Windows installer
2. Extracts application resources
3. Replaces Windows-specific native modules with Linux-compatible implementations
4. Repackages as either:
   - **RPM package**: Standard system package with full integration for Fedora/RHEL/openSUSE
   - **AppImage**: Portable, self-contained executable

### Build Process

The build script (`build-fedora.sh`) handles:
- Dependency checking and installation for RPM-based systems
- Resource extraction from Windows installer
- Icon processing for Linux desktop standards
- Native module replacement
- Package generation based on selected format (RPM or AppImage)

### Updating for New Releases

The script automatically detects system architecture and downloads the appropriate version. Current supported Claude Desktop architectures:
- AMD64: `Claude-Setup-x64.exe`
- ARM64: `Claude-Setup-arm64.exe`

If Claude Desktop's download URLs change, update the `CLAUDE_DOWNLOAD_URL` variables in `build-fedora.sh`.

### Security Features

The build process includes multiple security enhancements:
- Input validation and sanitization
- Secure file extraction with directory traversal prevention
- Package name whitelisting
- Checksum verification for Node.js downloads
- File integrity checking with backup creation
- Secure temporary directory creation

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.
