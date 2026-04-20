# Claude Desktop for Linux

This project provides build scripts to run Claude Desktop natively on Linux systems. It repackages the official Windows application for Linux distributions, producing `.deb` packages (Debian/Ubuntu), `.rpm` packages (Fedora/RHEL), distribution-agnostic AppImages, an [AUR package](https://aur.archlinux.org/packages/claude-desktop-appimage) for Arch Linux, and a Nix flake for NixOS.

**Note:** This is an unofficial build script. For official support, please visit [Anthropic's website](https://www.anthropic.com). For issues with the build script or Linux implementation, please [open an issue](https://github.com/aaddrick/claude-desktop-debian/issues) in this repository.

---

> **⚠️ EXPERIMENTAL: Cowork Mode Support**
> Cowork mode is **enabled by default** in this build with a pluggable isolation backend:
>
> | Backend | Isolation | Requirements |
> |---------|-----------|-------------|
> | **bubblewrap** (default) | Namespace sandbox | `bwrap` installed and functional |
> | **host** (fallback) | None — runs directly on host | No additional requirements |
>
> The best available backend is auto-detected at startup. Run `claude-desktop --doctor` to check which backend will be used and which dependencies are missing.
>
> **Note:** The bubblewrap backend mounts your home directory as read-only (only the project working directory is writable). The host backend provides no isolation — use it only if you understand the security implications.
>
> **KVM status:** The KVM/QEMU backend code exists but is non-functional — VM file downloads are disabled on Linux to prevent a checksum loop (#337). The backend code remains for potential future use.

---

## Features

- **Native Linux Support**: Run Claude Desktop without virtualization or Wine
- **MCP Support**: Full Model Context Protocol integration
  Configuration file location: `~/.config/Claude/claude_desktop_config.json`
- **System Integration**:
  - Global hotkey support (Ctrl+Alt+Space) - works on X11 and Wayland (via XWayland)
  - System tray integration
  - Desktop environment integration

### Screenshots

<p align="center">
  <img src="https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/docs/images/claude-desktop-screenshot1.png" alt="Claude Desktop running on Linux" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/docs/images/claude-desktop-screenshot2.png" alt="Global hotkey popup" />
</p>

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

### Using Nix Flake (NixOS)

Install directly from the flake:

```bash
# Basic install
nix profile install github:aaddrick/claude-desktop-debian

# With MCP server support (FHS environment)
nix profile install github:aaddrick/claude-desktop-debian#claude-desktop-fhs
```

Or add to your NixOS configuration:

```nix
# flake.nix
{
  inputs.claude-desktop.url = "github:aaddrick/claude-desktop-debian";

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ claude-desktop.overlays.default ];
          environment.systemPackages = [ pkgs.claude-desktop ];
        })
      ];
    };
  };
}
```

### Using Pre-built Releases

Download the latest `.deb`, `.rpm`, or `.AppImage` from the [Releases page](https://github.com/aaddrick/claude-desktop-debian/releases).

### Building from Source

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions.

## Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

For additional configuration options including environment variables and Wayland support, see [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Troubleshooting

Run `claude-desktop --doctor` for built-in diagnostics that check common issues (display server, sandbox permissions, MCP config, stale locks, and more). It also reports cowork mode readiness — which isolation backend will be used, and which dependencies (KVM, QEMU, vsock, socat, virtiofsd, bubblewrap) are installed or missing.

For additional troubleshooting, uninstallation instructions, and log locations, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Acknowledgments

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux.

Special thanks to:
- **k3d3**
  - Original NixOS implementation
  - Native bindings insights
- **[emsi](https://github.com/emsi/claude-desktop)**
  - Title bar fix
  - Alternative implementation approach
- **[leobuskin](https://github.com/leobuskin/unofficial-claude-desktop-linux)** for the Playwright-based URL resolution approach
- **[yarikoptic](https://github.com/yarikoptic)**
  - Codespell support
  - Shellcheck compliance
- **[IamGianluca](https://github.com/IamGianluca)** for build dependency check improvements
- **[ing03201](https://github.com/ing03201)** for IBus/Fcitx5 input method support
- **[ajescudero](https://github.com/ajescudero)** for pinning @electron/asar for Node compatibility
- **[delorenj](https://github.com/delorenj)** for Wayland compatibility support
- **[Regen-forest](https://github.com/Regen-forest)** for suggesting Gear Lever as AppImageLauncher replacement
- **[niekvugteveen](https://github.com/niekvugteveen)** for fixing Debian packaging permissions
- **[speleoalex](https://github.com/speleoalex)** for native window decorations support
- **[imaginalnika](https://github.com/imaginalnika)** for moving logs to `~/.cache/`
- **[richardspicer](https://github.com/richardspicer)** for the menu bar visibility fix on Linux
- **[jacobfrantz1](https://github.com/jacobfrantz1)**
  - Claude Desktop code preview support
  - Quick window submit fix
- **[janfrederik](https://github.com/janfrederik)** for the `--exe` flag to use a local installer
- **[MrEdwards007](https://github.com/MrEdwards007)** for discovering the OAuth token cache fix
- **[lizthegrey](https://github.com/lizthegrey)** for version update contributions
- **[mathys-lopinto](https://github.com/mathys-lopinto)**
  - AUR package
  - Automated deployment
- **[pkuijpers](https://github.com/pkuijpers)** for root cause analysis of the RPM repo GPG signing issue
- **[dlepold](https://github.com/dlepold)** for identifying the tray icon variable name bug with a working fix
- **[Voork1144](https://github.com/Voork1144)**
  - Detailed analysis of the tray icon minifier bug
  - Root-cause analysis of the Chromium layout cache bug
  - Direct child `setBounds()` fix approach
- **[sabiut](https://github.com/sabiut)**
  - `--doctor` diagnostic command
  - SHA-256 checksum validation for downloads
  - Post-build integration tests for deb, rpm, and AppImage artifacts
- **[milog1994](https://github.com/milog1994)**
  - Popup detection
  - Functional stubs
  - Wayland compositor support
- **[jarrodcolburn](https://github.com/jarrodcolburn)**
  - Passwordless sudo support in container/CI environments
  - Identifying the gh-pages 4GB bloat fix
  - Identifying the virtiofsd PATH detection issue on Debian
  - Detailed analysis of the CI release pipeline failure caused by runner kills during compare-releases
  - Diagnosing the session-start hook sudo blocking issue with three solution approaches
- **[chukfinley](https://github.com/chukfinley)** for experimental Cowork mode support on Linux
- **[CyPack](https://github.com/CyPack)** for orphaned cowork daemon cleanup on startup
- **[IliyaBrook](https://github.com/IliyaBrook)** for fixing the platform patch for Claude Desktop >= 1.1.3541 arm64 refactor
- **[MichaelMKenny](https://github.com/MichaelMKenny)**
  - Diagnosing the `$`-prefixed electron variable bug
  - Root cause analysis and workaround
- **[daa25209](https://github.com/daa25209)** for detailed root cause analysis of the cowork platform gate crash and patch script
- **[noctuum](https://github.com/noctuum)**
  - `CLAUDE_MENU_BAR` env var with configurable menu bar visibility
  - Boolean alias support
- **[typedrat](https://github.com/typedrat)**
  - NixOS flake integration with build.sh
  - node-pty derivation
  - CI auto-update
  - Fixing the flake package scoping regression
- **[cbonnissent](https://github.com/cbonnissent)**
  - Reverse-engineering the Cowork VM guest RPC protocol
  - Fixing the KVM startup blocker
  - Fixing RPC response id echoing for persistent connections
  - Configurable bwrap mount points via a dedicated Linux config file
- **[joekale-pp](https://github.com/joekale-pp)** for adding `--doctor` support to the RPM launcher
- **[ecrevisseMiroir](https://github.com/ecrevisseMiroir)** for the bwrap backend sandbox isolation with tmpfs-based minimal root
- **[arauhala](https://github.com/arauhala)** for detailed root cause analysis of the NixOS `isPackaged` regression
- **[cromagnone](https://github.com/cromagnone)** for confirming the VM download loop on bwrap installs with detailed logs that disproved the initial triage
- **[aHk-coder](https://github.com/aHk-coder)** for diagnosing the hardcoded minified variable crash in the cowork smol-bin patch
- **[RayCharlizard](https://github.com/RayCharlizard)**
  - Detailed analysis of the self-referential `.mcpb-cache` symlink ELOOP bug
  - Fixing auto-memory path translation on HostBackend
- **[reinthal](https://github.com/reinthal)** for fixing the NixOS build breakage caused by the nixpkgs `nodePackages` removal
- **[gianluca-peri](https://github.com/gianluca-peri)**
  - Reporting the GNOME quit accessibility issue
  - Confirming tray behavior with AppIndicator
- **[martin152](https://github.com/martin152)** for detailed diagnosis and a complete patch for three launcher cleanup bugs: `cleanup_orphaned_cowork_daemon` self-match, `cleanup_stale_cowork_socket` socat dependency no-op, and the same self-match in `--doctor`
- **[hfyeh](https://github.com/hfyeh)** for diagnosing the Ubuntu 24.04 AppArmor unprivileged-userns block on Cowork bwrap and contributing the AppArmor profile workaround

## Sponsorship

If this project is useful to you, consider [sponsoring on GitHub](https://github.com/sponsors/aaddrick).

## License

The build scripts in this repository are dual-licensed under:
- MIT License (see [LICENSE-MIT](LICENSE-MIT))
- Apache License 2.0 (see [LICENSE-APACHE](LICENSE-APACHE))

The Claude Desktop application itself is subject to [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Privacy

This repository uses an automated triage bot that sends issue contents to Anthropic's API for classification and investigation when you file a bug report or feature request. The bot reads the issue body, title, and any referenced related issues; it does not follow URLs, execute code blocks, or read content outside the triggering issue.

Do not include credentials, tokens, personal data, or anything you wouldn't put on a public issue tracker. If you post sensitive content and then edit it out, the bot's original read is preserved as a run artifact for audit — GitHub's UI hides the edit, but the bot's view of what you wrote is recoverable by maintainers.

Full design and data inventory: [`docs/issue-triage/README.md`](docs/issue-triage/README.md).

## Contributing

Contributions are welcome! By submitting a contribution, you agree to license it under the same dual-license terms as this project.
