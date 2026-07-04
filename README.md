# Claude Desktop for Linux

This project repackages Claude Desktop for Linux formats Anthropic doesn't ship themselves: `.rpm` (Fedora/RHEL), distribution-agnostic AppImages, a Nix flake for NixOS, and an [AUR package](https://aur.archlinux.org/packages/claude-desktop-appimage) for Arch.

On 2026-06-30 Anthropic shipped a first-party Claude Desktop for Linux beta, distributed as a `.deb` (amd64 and arm64) from their own APT repository. Since v3.0.0, this project repackages that official Linux `.deb`. It no longer repackages the Windows installer.

The official `.deb` covers one packaging target. What it leaves out is a long tail of distros, desktops, and session types — catalogued from this project's own issue history in [the reported-environments survey](docs/reports/CDL-ANT-0009_patch-suite-history/reported-environments/grouped-families.md). That long tail is what this project serves, plus a launcher and a `--doctor` for the Linux environment quirks. The [Installation](#installation) section lays out what's ours and what's upstream.

**Note:** This is an unofficial repackaging project. For official support, visit [Anthropic's website](https://www.anthropic.com). For issues with the packaging or the Linux launcher, please [open an issue](https://github.com/aaddrick/claude-desktop-debian/issues) here.

**Documentation:** Full docs at [`docs/index.md`](docs/index.md). Release history in [`CHANGELOG.md`](CHANGELOG.md). Contributing: [`CONTRIBUTING.md`](CONTRIBUTING.md). Security reports: [`SECURITY.md`](SECURITY.md).

---

## Features

- **Official app, extra formats**: repackages Anthropic's official Linux `.deb` into `.rpm`, AppImage, and AUR builds.
- **MCP support**: full Model Context Protocol integration. Config lives at `~/.config/Claude/claude_desktop_config.json` (see [Configuration](#configuration)).
- **Launcher for Linux quirks**: opt-in native Wayland (`CLAUDE_USE_WAYLAND=1`), GPU-crash auto-recovery, XRDP detection, IM-module override, and autostart-entry healing.
- **`--doctor` diagnostics**: checks the display server, sandbox permissions, MCP config, stale locks, the KVM/Cowork stack, and official-version drift.
- **Cowork on Linux**: runs when KVM (hardware virtualization) is available. The doctor reports readiness.
- **System integration**: global hotkey (Ctrl+Alt+Space) on X11 and Wayland, system tray, and desktop-environment integration.

### Screenshots

<p align="center">
  <img src="https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/docs/images/claude-desktop-screenshot1.png" alt="Claude Desktop running on Linux" />
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/main/docs/images/claude-desktop-screenshot2.png" alt="Global hotkey popup" />
</p>

## Installation

Anthropic serves the `.deb`. We serve everything else. Since v3.0.0 our packages are named `claude-desktop-unofficial`, so they install side-by-side with Anthropic's official `claude-desktop` — but both share `~/.config/Claude`, so only one can run at a time. Here's the split:

| Format | Who serves it |
|--------|---------------|
| `.deb` (Debian/Ubuntu, amd64 + arm64) | Anthropic's official APT repo. Ours mirrors it as `claude-desktop-unofficial` (launcher + doctor added), so it can sit beside the official package. |
| `.rpm` (Fedora/RHEL) | This project. |
| AppImage (any distro) | This project. |
| AUR (Arch) | This project (builds the AppImage). |
| Nix flake (NixOS) | This project. |

On top of packaging, every format we build carries:

- **Our launcher.** Opt-in native Wayland via `CLAUDE_USE_WAYLAND=1`, GPU-crash auto-recovery, XRDP detection, IM-module override, and autostart-entry healing.
- **`claude-desktop-unofficial --doctor`.** Diagnostics for the KVM/Cowork stack, official-version drift, name collisions, and config problems.
- **Packaging fixes.** The RPM firmware compat symlink Cowork needs, and the Ubuntu 24.04+ AppArmor profile.

The app itself is the official `app.asar`, shipped byte-identical except for two small Linux-gap patches: a Quick Entry focus fix for KDE (pending upstream) and an org-plugins path fix Linux is missing upstream.

### Using APT Repository (Debian/Ubuntu - Recommended)

Add the repository for automatic updates via `apt`:

```bash
# Add the GPG key
curl -fsSL https://pkg.claude-desktop-debian.dev/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop-unofficial.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/claude-desktop-unofficial.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop-unofficial.list

# Update and install
sudo apt update
sudo apt install claude-desktop-unofficial
```

Future updates will be installed automatically with your regular system updates (`sudo apt upgrade`).

### Using DNF Repository (Fedora/RHEL - Recommended)

Add the repository for automatic updates via `dnf`:

```bash
# Add the repository
sudo curl -fsSL https://pkg.claude-desktop-debian.dev/rpm/claude-desktop-unofficial.repo -o /etc/yum.repos.d/claude-desktop-unofficial.repo

# Install
sudo dnf install claude-desktop-unofficial
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

See [docs/building.md](docs/building.md) for detailed build instructions.

## Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

**Quit Claude Desktop before you hand-edit this file, then reopen it.** The app rewrites its own config while running, so edits you make with the app open get overwritten the next time it writes. Quit first, edit, then relaunch. Servers loaded at startup survive restarts fine — this only bites manual edits made against a running app.

For additional configuration options including environment variables and Wayland support, see [docs/configuration.md](docs/configuration.md).

## Troubleshooting

Run `claude-desktop-unofficial --doctor` for built-in diagnostics. It checks the usual suspects: display server, sandbox permissions, MCP config, stale locks, and more. It also reports Cowork readiness. Cowork on Linux runs on a KVM-backed VM, so the doctor reports which of its dependencies (KVM, QEMU, OVMF firmware, vhost-vsock, virtiofsd) are installed or missing.

For additional troubleshooting, uninstallation instructions, and log locations, see [docs/troubleshooting.md](docs/troubleshooting.md).

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

The full contributor credits list — everyone whose PR, fix, or analysis
shaped this project, in chronological order — lives in
[ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).

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
