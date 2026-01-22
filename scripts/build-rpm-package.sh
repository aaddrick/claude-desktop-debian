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

echo "--- Starting RPM Package Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

PACKAGE_ROOT="$WORK_DIR/package"
INSTALL_DIR="$PACKAGE_ROOT/usr"

# Clean previous package structure if it exists
rm -rf "$PACKAGE_ROOT"

# Create RPM package structure
echo "Creating package structure in $PACKAGE_ROOT..."
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
cat > "$INSTALL_DIR/bin/claude-desktop" << 'EOF'
#!/bin/bash
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-opensuse"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"
echo "--- Claude Desktop Launcher Start ---" > "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Arguments: $@" >> "$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "$LOG_FILE"
fi

# Check for display issues
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
  echo "No display detected (TTY session) - cannot start graphical application" >> "$LOG_FILE"
  echo "Error: Claude Desktop requires a graphical desktop environment." >&2
  echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
  exit 1
fi

# Determine display backend mode
# Default: Use X11/XWayland on Wayland sessions for global hotkey support
# Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys won't work)
USE_X11_ON_WAYLAND=true
if [ "$CLAUDE_USE_WAYLAND" = "1" ]; then
  USE_X11_ON_WAYLAND=false
  echo "CLAUDE_USE_WAYLAND=1 set, using native Wayland backend" >> "$LOG_FILE"
  echo "Note: Global hotkeys (quick window) may not work in native Wayland mode" >> "$LOG_FILE"
fi

# Determine Electron executable path
ELECTRON_EXEC="electron" # Default to global
LOCAL_ELECTRON_PATH="/usr/lib/claude-desktop/node_modules/electron/dist/electron"
if [ -f "$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="$LOCAL_ELECTRON_PATH"
    echo "Using local Electron: $ELECTRON_EXEC" >> "$LOG_FILE"
else
    # Check if global electron exists before declaring it as the choice
    if command -v electron &> /dev/null; then
        echo "Using global Electron: $ELECTRON_EXEC" >> "$LOG_FILE"
    else
        echo "Error: Electron executable not found (checked local $LOCAL_ELECTRON_PATH and global path)." >> "$LOG_FILE"
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
APP_PATH="/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar"

# Build Chromium flags array - flags MUST come before app path
ELECTRON_ARGS=()

# Disable CustomTitlebar for better Linux integration
# Note: The duplicate tray icon fix (issue #163) is handled via app.asar patching
# (increased delays in tray creation to allow DBus cleanup between destroy/create cycles)
ELECTRON_ARGS+=("--disable-features=CustomTitlebar")

# Add compatibility flags based on display backend
if [ "$IS_WAYLAND" = true ]; then
  if [ "$USE_X11_ON_WAYLAND" = true ]; then
    # Default: Use X11 via XWayland for global hotkey support
    echo "Using X11 backend via XWayland (for global hotkey support)" >> "$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--ozone-platform=x11")
    echo "To use native Wayland instead, set CLAUDE_USE_WAYLAND=1" >> "$LOG_FILE"
  else
    # Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
    echo "Using native Wayland backend" >> "$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations")
    ELECTRON_ARGS+=("--ozone-platform=wayland")
    ELECTRON_ARGS+=("--enable-wayland-ime")
    ELECTRON_ARGS+=("--wayland-text-input-version=3")
    echo "Warning: Global hotkeys may not work in native Wayland mode" >> "$LOG_FILE"
  fi
else
  # X11 session - no special flags needed
  echo "X11 session detected" >> "$LOG_FILE"
fi

# Add app path LAST - Chromium flags must come before this
ELECTRON_ARGS+=("$APP_PATH")
# Try to force native frame
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

# Change to the application directory (not resources dir - app needs this as base)
APP_DIR="/usr/lib/claude-desktop"
echo "Changing directory to $APP_DIR" >> "$LOG_FILE"
cd "$APP_DIR" || { echo "Failed to cd to $APP_DIR" >> "$LOG_FILE"; exit 1; }

# Execute Electron with app path, flags, and script arguments
# Redirect stdout and stderr to the log file
FINAL_CMD="\"$ELECTRON_EXEC\" \"${ELECTRON_ARGS[@]}\" \"$@\""
echo "Executing: $FINAL_CMD" >> "$LOG_FILE"
"$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
echo "Electron exited with code: $EXIT_CODE" >> "$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "$LOG_FILE"
exit $EXIT_CODE
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"
echo "✓ Launcher script created"

# --- Create Post-Install Script ---
echo "⚙️ Creating post-install script..."
POSTINST_SCRIPT="$WORK_DIR/postinst.sh"
cat > "$POSTINST_SCRIPT" << 'EOF'
#!/bin/sh
set -e

# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database /usr/share/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox if electron is installed globally or locally packaged
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
# Electron is always packaged locally now, so only check the local path.
LOCAL_SANDBOX_PATH="/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox"
if [ -f "$LOCAL_SANDBOX_PATH" ]; then
    SANDBOX_PATH="$LOCAL_SANDBOX_PATH"
fi

if [ -n "$SANDBOX_PATH" ] && [ -f "$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: $SANDBOX_PATH"
    chown root:root "$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for $SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found in local package at $LOCAL_SANDBOX_PATH. Sandbox may not function correctly."
fi

exit 0
EOF
chmod +x "$POSTINST_SCRIPT"
echo "✓ Post-install script created"

# --- Create RPM Spec File ---
echo "📄 Creating RPM spec file..."
SPEC_FILE="$WORK_DIR/$PACKAGE_NAME.spec"
RELEASE="1"

cat > "$SPEC_FILE" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        $RELEASE
Summary:        $DESCRIPTION
License:        Proprietary
URL:            https://claude.ai
BuildArch:      $ARCHITECTURE

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on openSUSE Linux distributions.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -r $INSTALL_DIR/* %{buildroot}/

%post
$POSTINST_SCRIPT

%files
%defattr(-,root,root,-)
/usr/bin/claude-desktop
/usr/lib/claude-desktop/*
/usr/share/applications/claude-desktop.desktop
/usr/share/icons/hicolor/*/apps/claude-desktop.png

%changelog
* $(date "+%a %b %d %Y") $MAINTAINER - $VERSION-$RELEASE
- Claude Desktop version $VERSION for openSUSE
EOF

echo "✓ Spec file created at $SPEC_FILE"

# --- Build RPM Package ---
echo "📦 Building RPM package..."
RPM_BUILD_DIR="$WORK_DIR/rpmbuild"
mkdir -p "$RPM_BUILD_DIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Copy spec file to SPECS directory
cp "$SPEC_FILE" "$RPM_BUILD_DIR/SPECS/"

# Build the RPM
echo "Running rpmbuild..."
if ! rpmbuild --define "_topdir $RPM_BUILD_DIR" \
     --define "_rpmdir $WORK_DIR" \
     --buildroot="$PACKAGE_ROOT" \
     -bb "$RPM_BUILD_DIR/SPECS/$PACKAGE_NAME.spec"; then
    echo "❌ Failed to build RPM package"
    exit 1
fi

# Find the built RPM
RPM_FILE=$(find "$WORK_DIR" -maxdepth 2 -name "${PACKAGE_NAME}-${VERSION}-*.${ARCHITECTURE}.rpm" | head -n 1)
if [ -z "$RPM_FILE" ]; then
    echo "❌ RPM file not found after build"
    exit 1
fi

echo "✓ RPM package built successfully: $RPM_FILE"
echo "--- RPM Package Build Finished ---"

exit 0
