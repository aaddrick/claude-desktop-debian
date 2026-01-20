#!/bin/bash
set -e

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"

echo "--- Starting Debian Package Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

PACKAGE_ROOT="$WORK_DIR/package"
INSTALL_DIR="$PACKAGE_ROOT/usr"

# Clean previous package structure if it exists
rm -rf "$PACKAGE_ROOT"

# Create Debian package structure
echo "Creating package structure in $PACKAGE_ROOT..."
mkdir -p "$PACKAGE_ROOT/DEBIAN"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# --- Icon Installation ---
echo "🎨 Installing icons..."
# Map icon sizes to their corresponding extracted files (relative to WORK_DIR)
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    icon_source_path="$WORK_DIR/${icon_files[$size]}"
    if [ -f "$icon_source_path" ]; then
        echo "Installing ${size}x${size} icon from $icon_source_path..."
        install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon at $icon_source_path"
    fi
done
echo "✓ Icons installed"

# --- Copy Application Files ---
echo "📦 Copying application files from $APP_STAGING_DIR..."

# Copy local electron first if it was packaged (check if node_modules exists in staging)
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying packaged electron..."
    cp -r "$APP_STAGING_DIR/node_modules" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
RESOURCES_DIR="$INSTALL_DIR/lib/$PACKAGE_NAME/node_modules/electron/dist/resources"
mkdir -p "$RESOURCES_DIR"
cp "$APP_STAGING_DIR/app.asar" "$RESOURCES_DIR/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$RESOURCES_DIR/"
echo "✓ Application files copied to Electron resources directory"

# --- Create Desktop Entry ---
echo "📝 Creating desktop entry..."
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF
echo "✓ Desktop entry created"

# --- Create Launcher Script ---
echo "🚀 Creating launcher script..."
cat > "$INSTALL_DIR/bin/claude-desktop" << EOF
#!/bin/bash
LOG_DIR="\${XDG_CACHE_HOME:-\$HOME/.cache}/claude-desktop-debian"
mkdir -p "\$LOG_DIR"
LOG_FILE="\$LOG_DIR/launcher.log"
echo "--- Claude Desktop Launcher Start ---" > "\$LOG_FILE"
echo "Timestamp: \$(date)" >> "\$LOG_FILE"
echo "Arguments: \$@" >> "\$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "\$LOG_FILE"
fi

# Check for display issues
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ]; then
  echo "No display detected (TTY session) - cannot start graphical application" >> "\$LOG_FILE"
  echo "Error: Claude Desktop requires a graphical desktop environment." >&2
  echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
  exit 1
fi

# Determine display backend mode
# Default: Use X11/XWayland on Wayland sessions for global hotkey support
# Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys won't work)
USE_X11_ON_WAYLAND=true
if [ "\$CLAUDE_USE_WAYLAND" = "1" ]; then
  USE_X11_ON_WAYLAND=false
  echo "CLAUDE_USE_WAYLAND=1 set, using native Wayland backend" >> "\$LOG_FILE"
  echo "Note: Global hotkeys (quick window) may not work in native Wayland mode" >> "\$LOG_FILE"
fi

# Determine Electron executable path
ELECTRON_EXEC="electron" # Default to global
LOCAL_ELECTRON_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/electron" # Correct path to executable
if [ -f "\$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="\$LOCAL_ELECTRON_PATH"
    echo "Using local Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
else
    # Check if global electron exists before declaring it as the choice
    if command -v electron &> /dev/null; then
        echo "Using global Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
    else
        echo "Error: Electron executable not found (checked local \$LOCAL_ELECTRON_PATH and global path)." >> "\$LOG_FILE" # Log the correct path checked
        # Optionally, display an error to the user via zenity or kdialog if available
        if command -v zenity &> /dev/null; then
            zenity --error --text="Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        elif command -v kdialog &> /dev/null; then
            kdialog --error "Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        fi
        exit 1
    fi
fi

# App is now in Electron's resources directory
APP_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/resources/app.asar"

# Build Chromium flags array - flags MUST come before app path
ELECTRON_ARGS=()

# Collect features to disable (must be combined into single --disable-features flag)
DISABLE_FEATURES="CustomTitlebar"

# Fix for KDE duplicate tray icons (issue #163)
# When xembedsniproxy is running (standard KDE component), Electron registers tray icons
# via both StatusNotifierItem (SNI) and XEmbed protocols. xembedsniproxy then bridges
# the XEmbed icon to SNI, creating a duplicate. Disabling UseStatusIconLinuxDbus
# prevents the dual registration.
if pgrep -x xembedsniproxy > /dev/null 2>&1; then
  echo "xembedsniproxy detected - disabling SNI to prevent duplicate tray icons" >> "\$LOG_FILE"
  DISABLE_FEATURES="\${DISABLE_FEATURES},UseStatusIconLinuxDbus"
fi

# Add combined disable-features flag (before app path!)
ELECTRON_ARGS+=("--disable-features=\${DISABLE_FEATURES}")

# Add compatibility flags based on display backend
if [ "\$IS_WAYLAND" = true ]; then
  if [ "\$USE_X11_ON_WAYLAND" = true ]; then
    # Default: Use X11 via XWayland for global hotkey support
    echo "Using X11 backend via XWayland (for global hotkey support)" >> "\$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--ozone-platform=x11")
    echo "To use native Wayland instead, set CLAUDE_USE_WAYLAND=1" >> "\$LOG_FILE"
  else
    # Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
    echo "Using native Wayland backend" >> "\$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations")
    ELECTRON_ARGS+=("--ozone-platform=wayland")
    ELECTRON_ARGS+=("--enable-wayland-ime")
    ELECTRON_ARGS+=("--wayland-text-input-version=3")
    echo "Warning: Global hotkeys may not work in native Wayland mode" >> "\$LOG_FILE"
  fi
else
  # X11 session - no special flags needed
  echo "X11 session detected" >> "\$LOG_FILE"
fi

# Add app path LAST - Chromium flags must come before this
ELECTRON_ARGS+=("\$APP_PATH")
# Try to force native frame
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

# Change to the application directory (not resources dir - app needs this as base)
APP_DIR="/usr/lib/$PACKAGE_NAME"
echo "Changing directory to \$APP_DIR" >> "\$LOG_FILE"
cd "\$APP_DIR" || { echo "Failed to cd to \$APP_DIR" >> "\$LOG_FILE"; exit 1; }

# Execute Electron with app path, flags, and script arguments
# Redirect stdout and stderr to the log file
FINAL_CMD="\"\$ELECTRON_EXEC\" \"\${ELECTRON_ARGS[@]}\" \"\$@\""
echo "Executing: \$FINAL_CMD" >> "\$LOG_FILE"
"\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EXIT_CODE=\$?
echo "Electron exited with code: \$EXIT_CODE" >> "\$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "\$LOG_FILE"
exit \$EXIT_CODE
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"
echo "✓ Launcher script created"

# --- Create Control File ---
echo "📄 Creating control file..."
# Determine dependencies based on whether electron was packaged
DEPENDS="nodejs, npm, p7zip-full" # Base dependencies
# Electron is now always packaged locally, so it's not listed as an external dependency.
echo "Electron is packaged locally; not adding to external Depends list."

cat > "$PACKAGE_ROOT/DEBIAN/control" << EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Depends: $DEPENDS
Description: $DESCRIPTION
 Claude is an AI assistant from Anthropic.
 This package provides the desktop interface for Claude.
 .
 Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.)
 Requires: nodejs (>= 12.0.0), npm
EOF
echo "✓ Control file created"

# --- Create Postinst Script ---
echo "⚙️ Creating postinst script..."
cat > "$PACKAGE_ROOT/DEBIAN/postinst" << EOF
#!/bin/sh
set -e

# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database /usr/share/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox if electron is installed globally or locally packaged
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
# Electron is always packaged locally now, so only check the local path.
LOCAL_SANDBOX_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/chrome-sandbox" # Correct path to sandbox
if [ -f "\$LOCAL_SANDBOX_PATH" ]; then
    SANDBOX_PATH="\$LOCAL_SANDBOX_PATH"
fi

if [ -n "\$SANDBOX_PATH" ] && [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found in local package at \$LOCAL_SANDBOX_PATH. Sandbox may not function correctly." # Log the correct path checked
fi

exit 0
EOF
chmod +x "$PACKAGE_ROOT/DEBIAN/postinst"
echo "✓ Postinst script created"

# --- Build .deb Package ---
echo "📦 Building .deb package..."
DEB_FILE="$WORK_DIR/${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb"

# Fix DEBIAN directory permissions (must be 755 for dpkg-deb)
echo "Setting DEBIAN directory permissions..."
chmod 755 "$PACKAGE_ROOT/DEBIAN"

# Fix script permissions in DEBIAN directory
echo "Setting script permissions..."
chmod 755 "$PACKAGE_ROOT/DEBIAN/postinst"

if ! dpkg-deb --build "$PACKAGE_ROOT" "$DEB_FILE"; then
    echo "❌ Failed to build .deb package"
    exit 1
fi

echo "✓ .deb package built successfully: $DEB_FILE"
echo "--- Debian Package Build Finished ---"

exit 0