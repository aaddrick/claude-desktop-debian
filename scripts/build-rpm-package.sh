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

# Convert architecture naming between Debian and RPM conventions
RPM_ARCH="$ARCHITECTURE"
case "$ARCHITECTURE" in
    "amd64") RPM_ARCH="x86_64" ;;
    "arm64") RPM_ARCH="aarch64" ;;
    *) echo "Warning: Unknown architecture conversion for $ARCHITECTURE, using as-is" ;;
esac

echo "RPM Architecture: $RPM_ARCH"

# Set up RPM build environment
RPM_BUILD_ROOT="$WORK_DIR/rpmbuild"
SPEC_FILE="$RPM_BUILD_ROOT/SPECS/${PACKAGE_NAME}.spec"
INSTALL_DIR="$RPM_BUILD_ROOT/BUILDROOT/${PACKAGE_NAME}-${VERSION}-1.${RPM_ARCH}/usr"

# Clean previous build structure if it exists
rm -rf "$RPM_BUILD_ROOT"

# Create RPM build directory structure
echo "Creating RPM build structure in $RPM_BUILD_ROOT..."
mkdir -p "$RPM_BUILD_ROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
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
cp "$APP_STAGING_DIR/app.asar" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Copy local electron if it was packaged (check if node_modules exists in staging)
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying packaged electron..."
    cp -r "$APP_STAGING_DIR/node_modules" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
fi
echo "✓ Application files copied"

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
LOG_FILE="\$HOME/claude-desktop-launcher.log"
echo "--- Claude Desktop Launcher Start ---" >> "\$LOG_FILE"
echo "Timestamp: \$(date)" >> "\$LOG_FILE"
echo "Arguments: \$@" >> "\$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "\$LOG_FILE"
fi

# Check for display issues and set compatibility mode if needed
if [ "\$IS_WAYLAND" = true ]; then
  echo "Setting Wayland compatibility mode..." >> "\$LOG_FILE"
  # Use native Wayland backend with GlobalShortcuts Portal support
  export ELECTRON_OZONE_PLATFORM_HINT=wayland
  # Keep GPU acceleration enabled for better performance
  echo "Wayland compatibility mode enabled (using native Wayland backend)" >> "\$LOG_FILE"
elif [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ]; then
  echo "No display detected (TTY session) - cannot start graphical application" >> "\$LOG_FILE"
  # No graphical environment detected; display error message in TTY session
  echo "Error: Claude Desktop requires a graphical desktop environment." >&2
  echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
  exit 1
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
        echo "Error: Electron executable not found (checked local \$LOCAL_ELECTRON_PATH and global path)." >> "\$LOG_FILE"
        # Optionally, display an error to the user via zenity or kdialog if available
        if command -v zenity &> /dev/null; then
            zenity --error --text="Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        elif command -v kdialog &> /dev/null; then
            kdialog --error "Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        fi
        exit 1
    fi
fi

# Base command arguments array, starting with app path
APP_PATH="/usr/lib/$PACKAGE_NAME/app.asar"
ELECTRON_ARGS=("\$APP_PATH")

# Add compatibility flags
if [ "\$IS_WAYLAND" = true ]; then
  echo "Adding compatibility flags for Wayland session" >> "\$LOG_FILE"
  ELECTRON_ARGS+=("--no-sandbox")
  # Enable Wayland features for Electron 37+
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
  echo "Enabled native Wayland support with GlobalShortcuts Portal" >> "\$LOG_FILE"
fi

# Change to the application directory
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

# --- Create RPM Spec File ---
echo "📄 Creating RPM spec file..."
cat > "$SPEC_FILE" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        $DESCRIPTION
Packager:       $MAINTAINER

License:        MIT
URL:            https://github.com/Frost26/Claude-Linux-Desktop
Source0:        %{name}-%{version}.tar.gz
BuildArch:      $RPM_ARCH

# Build dependencies
BuildRequires:  nodejs >= 20.0.0
BuildRequires:  npm
BuildRequires:  p7zip
BuildRequires:  p7zip-plugins
BuildRequires:  wget
BuildRequires:  icoutils
BuildRequires:  ImageMagick

# Runtime dependencies
Requires:       nodejs >= 20.0.0
Requires:       npm

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on Red Hat-based Linux distributions (Fedora, RHEL, CentOS, openSUSE, etc.)
Requires: nodejs (>= 20.0.0), npm

%prep
%setup -q

%build
# Build steps are handled by the calling script

%install
# Copy the pre-built files from the BUILDROOT
# The files are already in place from the calling script

%post
# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database %{_datadir}/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox if electron is packaged locally
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
LOCAL_SANDBOX_PATH="/usr/lib/%{name}/node_modules/electron/dist/chrome-sandbox"
if [ -f "\$LOCAL_SANDBOX_PATH" ]; then
    SANDBOX_PATH="\$LOCAL_SANDBOX_PATH"
fi

if [ -n "\$SANDBOX_PATH" ] && [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found in local package at \$LOCAL_SANDBOX_PATH. Sandbox may not function correctly."
fi

%postun
if [ \$1 -eq 0 ]; then
    # Complete removal
    update-desktop-database %{_datadir}/applications &> /dev/null || true
fi

%files
%{_bindir}/claude-desktop
%{_libdir}/%{name}/
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.png

%changelog
* $(date +'%a %b %d %Y') Automated Build <noreply@github.com> - $VERSION-1
- Automated build of Claude Desktop version $VERSION

EOF
echo "✓ RPM spec file created"

# --- Build RPM Package ---
echo "📦 Building RPM package..."
RPM_FILE="${PACKAGE_NAME}-${VERSION}-1.${RPM_ARCH}.rpm"
OUTPUT_PATH="$WORK_DIR/$RPM_FILE"

# Use rpmbuild to create the package
if rpmbuild --define "_topdir $RPM_BUILD_ROOT" \
           --define "_rpmdir $WORK_DIR" \
           --bb "$SPEC_FILE"; then
    echo "✓ RPM package built successfully"
    
    # Find the generated RPM file
    GENERATED_RPM=$(find "$WORK_DIR" -name "*.rpm" -not -path "*/RPMS/*" | head -n 1)
    if [ -z "$GENERATED_RPM" ]; then
        # Look in the RPMS subdirectory
        GENERATED_RPM=$(find "$RPM_BUILD_ROOT/RPMS" -name "*.rpm" | head -n 1)
        if [ -n "$GENERATED_RPM" ]; then
            mv "$GENERATED_RPM" "$OUTPUT_PATH"
        fi
    fi
    
    if [ -f "$OUTPUT_PATH" ] || [ -f "$GENERATED_RPM" ]; then
        echo "✓ RPM package available at: $(basename "$OUTPUT_PATH")"
    else
        echo "Warning: Could not locate generated RPM package"
    fi
else
    echo "❌ Failed to build RPM package"
    exit 1
fi

echo "--- RPM Package Build Finished ---"

exit 0