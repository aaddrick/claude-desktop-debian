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

# Copy shared launcher library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/launcher-common.sh" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
echo "✓ Shared launcher library copied"

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

# Source shared launcher library
source "/usr/lib/$PACKAGE_NAME/launcher-common.sh"

# Setup logging and environment
setup_logging
setup_electron_env

# Log startup info
log_message "--- Claude Desktop Launcher Start ---"
log_message "Timestamp: \$(date)"
log_message "Arguments: \$@"

# Check for display
if ! check_display; then
    log_message "No display detected (TTY session)"
    echo "Error: Claude Desktop requires a graphical desktop environment." >&2
    echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
    exit 1
fi

# Detect display backend
detect_display_backend
if [ "\$IS_WAYLAND" = true ]; then
    log_message "Wayland detected"
fi

# Determine Electron executable path
ELECTRON_EXEC="electron"
LOCAL_ELECTRON_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/electron"
if [ -f "\$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="\$LOCAL_ELECTRON_PATH"
    log_message "Using local Electron: \$ELECTRON_EXEC"
else
    if command -v electron &> /dev/null; then
        log_message "Using global Electron: \$ELECTRON_EXEC"
    else
        log_message "Error: Electron executable not found"
        if command -v zenity &> /dev/null; then
            zenity --error --text="Claude Desktop cannot start because the Electron framework is missing."
        elif command -v kdialog &> /dev/null; then
            kdialog --error "Claude Desktop cannot start because the Electron framework is missing."
        fi
        exit 1
    fi
fi

# App path
APP_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/resources/app.asar"

# Build electron args
build_electron_args "deb"

# Add app path LAST
ELECTRON_ARGS+=("\$APP_PATH")

# Change to application directory
APP_DIR="/usr/lib/$PACKAGE_NAME"
log_message "Changing directory to \$APP_DIR"
cd "\$APP_DIR" || { log_message "Failed to cd to \$APP_DIR"; exit 1; }

# Execute Electron
log_message "Executing: \$ELECTRON_EXEC \${ELECTRON_ARGS[*]} \$*"
"\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EXIT_CODE=\$?
log_message "Electron exited with code: \$EXIT_CODE"
log_message "--- Claude Desktop Launcher End ---"
exit \$EXIT_CODE
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"
echo "✓ Launcher script created"

# --- Create Control File ---
echo "📄 Creating control file..."
# Electron is bundled with its own Node.js runtime, so nodejs/npm are not runtime dependencies.
# p7zip is only used at build time to extract the installer.
# No external dependencies are required at runtime.

cat > "$PACKAGE_ROOT/DEBIAN/control" << EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Description: $DESCRIPTION
 Claude is an AI assistant from Anthropic.
 This package provides the desktop interface for Claude.
 .
 Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.)
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