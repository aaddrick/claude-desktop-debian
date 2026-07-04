[< Back to README](../README.md)

# Building from Source

`build.sh` downloads Anthropic's official Claude Desktop Linux `.deb`, optionally patches its `app.asar`, and repackages the official application tree as a `.deb`, `.rpm`, or AppImage.

```bash
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build with the auto-detected format for your distro
./build.sh

# Or pick a format explicitly
./build.sh --build deb
./build.sh --build rpm
./build.sh --build appimage
```

The default format is detected from the host distribution:

| Distribution family | Default format |
|---------------------|----------------|
| Debian, Ubuntu, Mint (`/etc/debian_version`) | `deb` |
| Fedora, RHEL, CentOS | `rpm` |
| NixOS | `nix` (currently a stub — see [Nix](#nix) below) |
| Anything else (including Arch) | `appimage` |

## Prerequisites

The official `.deb` is unpacked with `ar` + `tar` instead of `dpkg-deb`, so rpm-family and Arch hosts can build too. Per format:

| Needed for | Commands |
|------------|----------|
| Every format | `wget`, `ar` (binutils), `tar`, `xz`, `zstd` |
| `--build deb` | `dpkg-deb` (dpkg-dev) |
| `--build rpm` | `rpmbuild` (rpm-build) |
| `--build appimage` | `appimagetool` — downloaded into `build/` automatically when not on PATH |
| The asar patch stage | Node.js v20+ — a local v20.18.1 is downloaded into `build/` when the system Node is missing or too old; `@electron/asar` is npm-installed into `build/` |

On Debian- and RPM-family hosts, `build.sh` offers to install the missing system packages via `apt`/`dnf` (`check_dependencies` in `scripts/setup/dependencies.sh`). On other distros it lists what to install manually.

## Build flags

From `parse_arguments` in `scripts/setup/detect-host.sh`:

```
./build.sh [--build deb|rpm|appimage|nix] [--clean yes|no]
           [--deb /path/to/claude-desktop.deb] [--arch amd64|arm64]
           [--release-tag TAG] [--source-dir /path] [--test-flags]
```

| Flag | Default | Effect |
|------|---------|--------|
| `-b`, `--build` | auto-detected | Output format: `deb`, `rpm`, `appimage`, or `nix`. |
| `-c`, `--clean` | `yes` | Remove intermediate files in `build/` after packaging. `--clean no` keeps them for inspection. |
| `-d`, `--deb` | download | Use a locally downloaded official `.deb` instead of fetching the pinned one. The SHA256 pin check is skipped for local files. |
| `-a`, `--arch` | `uname -m` | Override the target architecture (`amd64` or `arm64`) for cross-building — repackaging the official `.deb` is arch-independent, so an amd64 host can produce an arm64 package. |
| `-r`, `--release-tag` | unset | Release tag (e.g. `v3.0.0+claude1.18286.0`); the wrapper version is extracted and appended to the package version (`1.18286.0-3.0.0`). Used by CI. |
| `-s`, `--source-dir` | repo root | Path to the repo root for scripts and assets, for out-of-tree invocations. |
| `--test-flags` | off | Parse flags, print the results, and exit without building. |

## How the official .deb is resolved

The build never scrapes a download page — it pulls a pinned artifact from Anthropic's official APT pool:

- `scripts/setup/official-deb.sh` pins `OFFICIAL_DEB_VERSION` (currently `1.18286.0`) plus a per-architecture pool path and SHA256 against `https://downloads.claude.ai/claude-desktop/apt/stable`.
- The download is verified against the pinned SHA256 before extraction.
- `ar` + `tar` extract `data.tar.*` and `control.tar.*` (zst/xz/gz all handled); the app tree must land at `usr/lib/claude-desktop` or the build aborts with an upstream-layout error.
- The package version is read from the extracted control file; a mismatch against the pin is a warning, not a failure.
- `Depends:` and `Recommends:` are read from the official control file and re-emitted verbatim into our packages — the contract differs per arch (arm64 recommends a different qemu stack than amd64), and re-emitting tracks upstream automatically.

The pins are bumped automatically: the `check-claude-version` workflow polls the official APT `Packages` index, rewrites the `OFFICIAL_DEB_*` pins in `scripts/setup/official-deb.sh`, updates the `CLAUDE_DESKTOP_VERSION` repo variable, and pushes a `v{REPO_VERSION}+claude{VERSION}` tag that triggers the release build.

To build a version before the automation catches it, download the `.deb` from the official pool yourself and pass `--deb /path/to/claude-desktop_VERSION_ARCH.deb`.

## The patch stage (patch-zero contract)

`active_patches` in `scripts/patches/app-asar.sh` lists every asar patch still active. The default verdict for any patch is delete: when the array is empty, the official `app.asar` ships **byte-identical** — it is never extracted or repacked. Two patches currently survive:

- `patch_quick_window` (`scripts/patches/quick-window.sh`) — KDE-gated blur/focus workaround so the main window reappears after a Quick Entry submit (Electron stale-focus bug on Plasma).
- `patch_org_plugins_path` (`scripts/patches/org-plugins.sh`) — adds a `case "linux"` to the upstream org-plugins platform switch, which only handles darwin/win32; without it MDM org plugins are silently dead on Linux (filed upstream).

Two build-time tripwires grep the pristine `app.asar` on every build and fail loudly if upstream flips behavior we deleted patches for: `apt_channel_pending` (AU-1 — the marker that keeps the official autoupdater dormant while the APT channel is pending) and `menuBarEnabled:!0` (MB-1 — the settings default that keeps the menu bar on).

When patches do run, the repack preserves upstream's `app.asar.unpacked` set exactly and aborts if the sets diverge.

## Installing the built package

### For .deb packages (Debian/Ubuntu)

```bash
sudo apt install ./claude-desktop-unofficial_VERSION_ARCHITECTURE.deb
# Or: sudo dpkg -i ./claude-desktop-unofficial_VERSION_ARCHITECTURE.deb

# If you encounter dependency issues:
sudo apt --fix-broken install
```

### For .rpm packages (Fedora/RHEL)

```bash
sudo dnf install ./claude-desktop-unofficial-VERSION-1.ARCH.rpm
# Or: sudo rpm -i ./claude-desktop-unofficial-VERSION-1.ARCH.rpm
```

### For AppImages

```bash
# Make executable
chmod +x ./claude-desktop-unofficial-*.AppImage

# Run directly
./claude-desktop-unofficial-*.AppImage

# Or integrate with your system using Gear Lever
```

**Note:** AppImage login requires proper desktop integration. Use [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) or manually install the generated `.desktop` file to `~/.local/share/applications/`.

**Automatic updates:** AppImages downloaded from GitHub releases include embedded update information and work with Gear Lever for automatic updates. Locally-built AppImages can be configured manually in Gear Lever.

## Nix

The derivation (`nix/claude-desktop.nix`) repackages the official `.deb`: `fetchurl` from the official APT pool, `autoPatchelfHook` over the bare co-located tree, no nixpkgs Electron. The FHS output (`nix/fhs.nix`, the flake default) additionally provides MCP runtime dependencies and OVMF firmware at Cowork's hardcoded probe paths.

```bash
nix build .#claude-desktop
nix build .#claude-desktop-fhs
```

Build-verified on x86_64; runtime on real NixOS and the aarch64 leg are open validation items (owner @typedrat). Design contract, SRI auto-bump anchors, and a no-NixOS testing recipe: [`docs/learnings/nix.md`](learnings/nix.md).

Two facts about the `--build nix` path that hold on this branch: `build.sh --build nix` requires `--deb` (it never downloads inside the sandbox), and it stops after the patch stage — the Nix derivation is expected to handle installation itself.
