**Arch Linux users:** For the PKGBUILD and Arch-specific instructions: [https://github.com/aaddrick/claude-desktop-arch](https://github.com/aaddrick/claude-desktop-arch)

***THIS IS AN UNOFFICIAL BUILD SCRIPT FOR DEBIAN/UBUNTU AND FEDORA!***

If you run into an issue with this build script, make an issue here. Don't bug Anthropic about it - they already have enough on their plates.

# Claude Desktop for Linux (Debian/Ubuntu & Fedora Builds)

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux. Their work provided valuable insights into the application's structure and the native bindings implementation.

Supports MCP!

Location of the MCP-configuration file is: `~/.config/Claude/claude_desktop_config.json`

![image](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

Supports the Ctrl+Alt+Space popup!
![image](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

Supports the Tray menu! (Screenshot of running on KDE)
![image](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

# Installation (Fedora)

For Fedora Linux distributions, you can build and install Claude Desktop using the provided RPM build script:

```bash
# Clone this repository
git clone https://github.com/your-repo/claude-desktop-fedora.git # <-- UPDATE THIS URL
cd claude-desktop-fedora

# Build the RPM package (this will prompt for sudo password to install build dependencies)
./build-rpm.sh

# The script will automatically:
# - Check for and install required build dependencies using dnf
# - Download and extract resources from the Windows version
# - Create a proper RPM package using rpmbuild
# - Output the location of the built RPM file (usually in ~/rpmbuild/RPMS/x86_64/)

# Install the built RPM package (replace <path-to-rpm> with the actual path)
sudo dnf install <path-to-rpm>
```

Requirements:
- Fedora Linux
- Node.js >= 12.0.0 and npm (will be installed as dependency)
- User account (do not run build script as root)

# Installation (Debian/Ubuntu)

For Debian-based distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.), you can build and install Claude Desktop using the provided Debian build script:

```bash
# Clone this repository
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build the package
sudo ./build-deb.sh
# Note: The version number (e.g., 0.8.1) in the command below is an example.
# The actual filename will contain the version detected by the script.
sudo dpkg -i ./build/claude-desktop_VERSION_amd64.deb # Replace VERSION with actual version

# The script will automatically:
# - Check for and install required dependencies using apt
# - Download and extract resources from the Windows version
# - Create a proper Debian package
# - Guide you through installation
```

Requirements:
- Any Debian-based Linux distribution
- Node.js >= 12.0.0 and npm
- Root/sudo access for dependency installation

# Uninstallation

**Fedora:**

If you installed the package using `dnf`, you can uninstall it using:

```bash
sudo dnf remove claude-desktop
```

**Debian/Ubuntu:**

If you installed the package using `dpkg`, you can uninstall it using:

```bash
sudo dpkg -r claude-desktop
```

If you also want to remove configuration files (including MCP settings), use `purge`:

```bash
sudo dpkg -P claude-desktop
```

# Troubleshooting

## Application Fails to Launch

If the Claude Desktop application installs successfully but fails to launch (you might see errors related to sandboxing or zygote processes in the terminal when running `claude-desktop`), try launching it with the `--no-sandbox` flag:

```bash
claude-desktop --no-sandbox
```

If this works, you can make it permanent by editing the launcher script:

1.  Open `/usr/bin/claude-desktop` with root privileges (e.g., `sudo nano /usr/bin/claude-desktop`).
2.  Find the line starting with `electron` or `$(dirname $0)/../lib/claude-desktop/node_modules/.bin/electron`.
3.  Append `--no-sandbox` to that line, before the `"$@"` part. For example:
    ```bash
    # Original:
    # electron /usr/lib/claude-desktop/app.asar "$@"
    # Modified:
    electron /usr/lib/claude-desktop/app.asar --no-sandbox "$@"
    ```
4.  Save the file.

**Note:** Disabling the sandbox reduces security isolation. Use this workaround if you understand the implications.

# NixOS Implementation

For NixOS users, please refer to [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) repository. Their implementation is specifically designed for NixOS and provides the original Nix flake that inspired this project.

# How it works (Linux Builds)

Claude Desktop is an Electron application packaged as a Windows executable. Our build scripts perform several key operations to make it work on Linux:

1. Downloads and extracts the Windows installer
2. Unpacks the app.asar archive containing the application code
3. Replaces the Windows-specific native module with a Linux-compatible stub implementation
4. Repackages everything into a proper Debian (`.deb`) or Fedora (`.rpm`) package

The process works because Claude Desktop is largely cross-platform, with only one platform-specific component that needs replacement.

## The Native Module Challenge

The only platform-specific component is a native Node.js module called `claude-native-bindings`. This module provides system-level functionality like:

- Keyboard input handling
- Window management
- System tray integration
- Monitor information

Our build script replaces this Windows-specific module with a Linux-compatible implementation that:

1. Provides the same API surface to maintain compatibility
2. Implements keyboard handling using the correct key codes from the reference implementation
3. Stubs out unnecessary Windows-specific functionality
4. Maintains critical features like the Ctrl+Alt+Space popup and system tray

The replacement module is carefully designed to match the original API while providing Linux-native functionality where needed. This approach allows the rest of the application to run unmodified, believing it's still running on Windows.

## Build Process Details

> Note: The original Debian build script was generated by Claude (Anthropic) to help create a Linux-compatible version of Claude Desktop. The Fedora build process follows similar steps using RPM tools.

**Fedora Build (`build-rpm.sh` and `claude-desktop.spec`):**

1. Checks for a Fedora system and required build dependencies (using `dnf`).
2. Downloads the official Windows installer.
3. Uses `rpmbuild` and the `.spec` file to manage the build process:
   - **`%prep`:** Extracts the application resources.
   - **`%build`:** Processes icons, unpacks and modifies `app.asar` (replacing the native module, updating keyboard keys), installs Electron locally, repacks `app.asar`.
   - **`%install`:** Copies files (app code, bundled Electron, icons, `.desktop` file, launcher script) into the RPM build root.
   - **`%post`:** Runs post-installation tasks like updating the desktop database and setting sandbox permissions.
   - **`%files`:** Defines which installed files belong to the package.
4. Creates a proper RPM package.

**Debian/Ubuntu Build (`build-deb.sh`):**

The build script (`build-deb.sh`) handles the entire process for Debian-based systems:

1. Checks for a Debian-based system and required dependencies
2. Downloads the official Windows installer
3. Extracts the application resources
4. Processes icons for Linux desktop integration
5. Unpacks and modifies the app.asar:
   - Replaces the native module with our Linux version
   - Updates keyboard key mappings
   - Preserves all other functionality
6. Creates a proper Debian package with:
   - Desktop entry for application menus
   - System-wide icon integration
   - Proper dependency management
   - Post-install configuration (sandbox permissions, desktop database update)

## Updating the Build Scripts

When a new version of Claude Desktop is released:

*   **Fedora:** Update the `%global claude_download_url` variable at the top of `claude-desktop.spec`. The `build-rpm.sh` script will automatically detect the version and update the spec file during the build.
*   **Debian/Ubuntu:** Update the `CLAUDE_DOWNLOAD_URL` constant at the top of `build-deb.sh`.

The scripts should handle the rest of the build process automatically.

# License

The build scripts in this repository, are dual-licensed under the terms of the MIT license and the Apache License (Version 2.0).

See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE) for details.

The Claude Desktop application, not included in this repository, is likely covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
