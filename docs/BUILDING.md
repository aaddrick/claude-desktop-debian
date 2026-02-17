[< Back to README](../README.md)

# Building from Source

## Prerequisites

- Linux distribution (Debian/Ubuntu, Fedora/RHEL, or other)
- Git
- Basic build tools (automatically installed by the script)

## Build Instructions

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

## Installing the Built Package

### For .deb packages (Debian/Ubuntu)

```bash
sudo apt install ./claude-desktop_VERSION_ARCHITECTURE.deb
# Or: sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb

# If you encounter dependency issues:
sudo apt --fix-broken install
```

### For .rpm packages (Fedora/RHEL)

```bash
sudo dnf install ./claude-desktop-VERSION-1.ARCH.rpm
# Or: sudo rpm -i ./claude-desktop-VERSION-1.ARCH.rpm
```

### For AppImages

```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the provided `.desktop` file to `~/.local/share/applications/`.

**Automatic Updates:** AppImages downloaded from GitHub releases include embedded update information and work seamlessly with Gear Lever for automatic updates. Locally-built AppImages can be manually configured for updates in Gear Lever.

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
