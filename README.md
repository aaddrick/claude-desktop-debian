**Arch Linux users:** For the PKGBUILD and Arch-specific instructions: [https://github.com/aaddrick/claude-desktop-arch](https://github.com/aaddrick/claude-desktop-arch)

The build script now uses command-line flags to select the output format and cleanup behavior.

***THIS IS AN UNOFFICIAL BUILD SCRIPT FOR DEBIAN/UBUNTU BASED SYSTEMS (produces .deb or .AppImage)!***

If you run into an issue with this build script, make an issue here. Don't bug Anthropic about it - they already have enough on their plates.

# Claude Desktop for Linux

This project was inspired by [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) and their [Reddit post](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/) about running Claude Desktop natively on Linux. Their work provided valuable insights into the application's structure and the native bindings implementation.

Supports MCP!

Location of the MCP-configuration file is: `~/.config/Claude/claude_desktop_config.json`

![image](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

Supports the Ctrl+Alt+Space popup!
![image](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

Supports the Tray menu! (Screenshot of running on KDE)
![image](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

# Building & Installation (Debian/Ubuntu based)

For Debian-based distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.), you can build Claude Desktop using the provided build script. Use command-line flags to specify the desired output format (`.deb` or `.AppImage`) and whether to clean up intermediate build files.

```bash
# Clone this repository
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian

# Build the package (Defaults to .deb and cleans build files)
sudo ./build.sh

# Example: Build an AppImage and keep intermediate files
sudo ./build.sh --build appimage --clean no

# Example: Build a .deb (explicitly) and clean intermediate files (default)
sudo ./build.sh --build deb --clean yes
```

The script will automatically:
 - Check for and install required dependencies
 - Download and extract resources from the Windows version
 - Create a proper Debian package or AppImage
 - Perform the build steps based on selected flags

## After Building:

### If you chose Debian Package (.deb):

The script will output the path to the generated `.deb` file (e.g., `claude-desktop_0.9.1_amd64.deb`). Install it using `dpkg`:

```bash
# Replace VERSION and ARCHITECTURE with the actual values from the filename
sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb 

# If you encounter dependency issues, run:
sudo apt --fix-broken install 
```

### If you chose AppImage (.AppImage):

The script will output the path to the generated `.AppImage` file (e.g., `claude-desktop-0.9.1-amd64.AppImage`) and a corresponding `.desktop` file (`claude-desktop-appimage.desktop`).

**AppImage login will not work unless you setup the .desktop file correctly or use a tool like AppImageLauncher to manage it for you.**

1.  **Make the AppImage executable:**
    ```bash
    # Replace FILENAME with the actual AppImage filename
    chmod +x ./FILENAME.AppImage 
    ```
2.  **Run the AppImage:**
    ```bash
    ./FILENAME.AppImage
    ```
3.  **(Optional) Integrate with your system:**
    -   Tools like [AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher) can automatically integrate AppImages (moving them to a central location and adding them to your application menu) using the bundled `.desktop` file.
    -   Alternatively, you can manually move the `.AppImage` file to a preferred location (e.g., `~/Applications` or `/opt`) and copy the generated `claude-desktop-appimage.desktop` file to `~/.local/share/applications/` (you might need to edit the `Exec=` line in the `.desktop` file to point to the new location of the AppImage).

#### --no-sandbox

The AppImage script runs with electron's --no-sandbox flag. AppImage's don't have their own sandbox. chome-sandbox, which is used by electron, needs to escalate root privileges briefly in order to setup the sandbox. When you pack an AppImage, chrome-sandbox loses any assigned ownership and executes with user permissions. There's also an issue with [unprivileged namespaces](https://www.reddit.com/r/debian/comments/hkyeft/comment/fww5xb1) being set differently on different distributions.

**Alternatives to --no-sandbox**
 - Run claude-desktop as root
   - Doesn't feel warm and fuzzy.
 - Install chrome-sandbox outside of the AppImage(or leverage an existing install), set it with the right permissions, and reference it.
   - Counter-intuitive to the "batteries included" mindset of AppImages
 - Run it with --no-sandbox, but then wrap the whole thing inside another sandbox like bubblewrap
   - Not "batteries included", and configuring in such a way that it runs everywhere is beyond my immediate capabilities.

I'd love a better suggestion. Feel free to submit a PR or start a discussion if I missed something obvious.

# Uninstallation

## Debian Package (.deb)

If you installed the `.deb` package, you can uninstall it using `dpkg`:

```bash
sudo dpkg -r claude-desktop
```

If you also want to remove configuration files (including MCP settings), use `purge`:

```bash
sudo dpkg -P claude-desktop
```

## AppImage (.AppImage)

If you used the AppImage:
1.  Delete the `.AppImage` file.
2.  Delete the associated `.desktop` file (e.g., `claude-desktop-appimage.desktop` from where you placed it, like `~/.local/share/applications/`).
3.  If you used AppImageLauncher, it might offer an option to un-integrate the AppImage.

## Configuration Files (Both Formats)

To remove user-specific configuration files (including MCP settings), regardless of installation method:

```bash
rm -rf ~/.config/Claude
```

# Troubleshooting

Aside from the install logs, runtime logs can be found in (`$HOME/claude-desktop-launcher.log`).

If your window isn't scaling correctly the first time or two you open the application, right click on the claude-desktop panel (taskbar) icon and quit. When doing a safe shutdown like this, the application saves some states to the .config/claude folder which will resolve the issue moving forward. Force quitting the application will not trigger the updates. 

# How it works (Debian/Ubuntu Build)

Claude Desktop is an Electron application packaged as a Windows executable. Our build script performs several key operations to make it work on Linux:

1.  Downloads and extracts the Windows installer
2.  Unpacks the `app.asar` archive containing the application code
3.  Replaces the Windows-specific native module with a Linux-compatible stub implementation
4.  Repackages everything into the user's chosen format:
    *   **Debian Package (.deb):** Creates a standard Debian package installable via `dpkg`.
    *   **AppImage (.AppImage):** Creates a self-contained executable using `appimagetool`.

The process works because Claude Desktop is largely cross-platform, with only one platform-specific component that needs replacement.

## Build Process Details

The main build script (`build.sh`) orchestrates the process:

1. Checks for a Debian-based system and required dependencies
2. Parses command-line flags (`--build`, `--clean`) to determine output format and cleanup behavior.
3. Downloads the official Windows installer
4. Extracts the application resources
5. Processes icons for Linux desktop integration
6. Unpacks and modifies the app.asar:
   - Replaces the native mapping module with our Linux version
   - Preserves all other functionality
7. Calls the appropriate packaging script (`scripts/build-deb-package.sh` or `scripts/build-appimage.sh`) to create the final output:
   *   **For .deb:** Creates a package with desktop entry, icons, dependencies, and post-install steps.
   *   **For .AppImage:** Creates an AppDir, bundles Electron, generates an `AppRun` script and `.desktop` file, and uses `appimagetool` to create the final `.AppImage`.

## Updating the Build Script

When a new version of Claude Desktop is released, the script attempts to automatically detect the correct download URL based on your system architecture (amd64 or arm64). If the download URLs change significantly in the future, you may need to update the `CLAUDE_DOWNLOAD_URL` variables near the top of `build.sh`. The script should handle the rest of the build process automatically.

# k3d3's Original NixOS Implementation

For NixOS users, please refer to [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake) repository. Their implementation is specifically designed for NixOS and provides the original Nix flake that inspired this project. Go check their repo out if you want some more details about the core process behind this.

# Emsi's Alternative Debian Implementation

Emsi has put together a fork of this repo at [https://github.com/emsi/claude-desktop](https://github.com/emsi/claude-desktop). Aside from approaching the problem much more intelligently than I, his repo collection is full of goodies such as [https://github.com/emsi/MyManus](https://github.com/emsi/MyManus). This repo (aaddrick/claude-desktop-debian) currently relies on his title bar fix to keep the main title bar visible.

# License

The build scripts in this repository, are dual-licensed under the terms of the MIT license and the Apache License (Version 2.0).

See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE) for details.

The Claude Desktop application, not included in this repository, is likely covered by [Anthropic's Consumer Terms](https://www.anthropic.com/legal/consumer-terms).

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
