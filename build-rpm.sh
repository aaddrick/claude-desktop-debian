#!/bin/bash
set -e

# Update this URL when a new version of Claude Desktop is released
CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"

# Check for RPM-based system
if [ ! -f "/etc/redhat-release" ] && [ ! -f "/etc/fedora-release" ]; then
    echo "❌ This script requires a Red Hat-based Linux distribution (RHEL, Fedora, CentOS, etc.)"
    exit 1
fi

# Check for root/sudo
IS_SUDO=false
if [ "$EUID" -eq 0 ]; then
    IS_SUDO=true
    # Check if running via sudo (and not directly as root)
    if [ -n "$SUDO_USER" ]; then
        ORIGINAL_USER="$SUDO_USER"
        ORIGINAL_HOME=$(eval echo ~$ORIGINAL_USER)
    else
        # Running directly as root, no original user context
        ORIGINAL_USER="root"
        ORIGINAL_HOME="/root"
    fi
else
    echo "Please run with sudo to install dependencies"
    exit 1
fi

# Preserve NVM path if running under sudo and NVM exists for the original user
if [ "$IS_SUDO" = true ] && [ "$ORIGINAL_USER" != "root" ] && [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to preserve npm/npx path..."
    # Source NVM script to set up NVM environment variables temporarily
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm

    # Find the path to the currently active or default Node version's bin directory
    NODE_BIN_PATH=$(find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

    if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
        echo "Adding $NODE_BIN_PATH to PATH"
        export PATH="$NODE_BIN_PATH:$PATH"
    else
        echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
    fi
fi

# Print system information
echo "System Information:"
if [ -f "/etc/fedora-release" ]; then
    echo "Distribution: $(cat /etc/fedora-release)"
else
    echo "Distribution: $(cat /etc/redhat-release)"
fi

# Function to check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
for cmd in p7zip wget icotool convert npx rpmbuild rpmdev-setuptree; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip p7zip-plugins"
                ;;
            "wget")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                ;;
            "icotool")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick"
                ;;
            "npx")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm"
                ;;
            "rpmbuild"|"rpmdev-setuptree")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build rpmdevtools"
                ;;
        esac
    fi
done

# Install system dependencies if any
if [ ! -z "$DEPS_TO_INSTALL" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    if command -v dnf &> /dev/null; then
        dnf install -y $DEPS_TO_INSTALL
    elif command -v yum &> /dev/null; then
        yum install -y $DEPS_TO_INSTALL
    else
        echo "Unable to install dependencies. Please install manually: $DEPS_TO_INSTALL"
        exit 1
    fi
    echo "System dependencies installed successfully"
fi

# Check for electron - first local, then global
# Check for local electron in node_modules
if [ -f "$(pwd)/node_modules/.bin/electron" ]; then
    echo "✓ local electron found in node_modules"
    LOCAL_ELECTRON="$(pwd)/node_modules/.bin/electron"
    export PATH="$(pwd)/node_modules/.bin:$PATH"
elif ! check_command "electron"; then
    echo "Installing electron via npm..."
    # Try local installation first
    if [ -f "package.json" ]; then
        echo "Found package.json, installing electron locally..."
        npm install --save-dev electron
        if [ -f "$(pwd)/node_modules/.bin/electron" ]; then
            echo "✓ Local electron installed successfully"
            LOCAL_ELECTRON="$(pwd)/node_modules/.bin/electron"
            export PATH="$(pwd)/node_modules/.bin:$PATH"
        else
            # Fall back to global installation if local fails
            echo "Local electron install failed or not possible, trying global..."
            npm install -g electron
            if check_command "electron"; then
                ELECTRON_PATH=$(command -v electron)
                echo "Attempting to fix permissions for global electron at $ELECTRON_PATH..."
                chmod -R a+rx "$(dirname "$ELECTRON_PATH")/../lib/node_modules/electron" || echo "Warning: Failed to chmod global electron installation directory. Permissions might be incorrect."
            fi
            if ! check_command "electron"; then
                echo "Failed to install electron globally. Please install it manually:"
                echo "npm install -g electron # or npm install --save-dev electron in project root"
                exit 1
            fi
            echo "Global electron installed successfully"
        fi
    else
        # No package.json, try global installation
        echo "No package.json found, trying global electron installation..."
        npm install -g electron
        if check_command "electron"; then
            ELECTRON_PATH=$(command -v electron)
            echo "Attempting to fix permissions for global electron at $ELECTRON_PATH..."
            chmod -R a+rx "$(dirname "$ELECTRON_PATH")/../lib/node_modules/electron" || echo "Warning: Failed to chmod global electron installation directory. Permissions might be incorrect."
        fi
        if ! check_command "electron"; then
            echo "Failed to install electron globally. Please install it manually:"
            echo "npm install -g electron"
            exit 1
        fi
        echo "Global electron installed successfully"
    fi
fi

PACKAGE_NAME="claude-desktop"
ARCHITECTURE="x86_64"  # RPM uses x86_64 instead of amd64
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"

# Create working directories
WORK_DIR="$(pwd)/build"
RPM_ROOT="$HOME/rpmbuild"

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# Setup RPM build environment if not already set up
if [ ! -d "$RPM_ROOT" ]; then
    echo "Setting up RPM build environment..."
    rpmdev-setuptree
fi

# Create build directories
mkdir -p "$RPM_ROOT/SOURCES"
mkdir -p "$RPM_ROOT/SPECS"
mkdir -p "$RPM_ROOT/BUILD"
mkdir -p "$RPM_ROOT/BUILD/$PACKAGE_NAME-build"

# Install asar if needed
if ! npm list -g asar > /dev/null 2>&1; then
    echo "Installing asar package globally..."
    npm install -g asar
fi

# Download Claude Windows installer
echo "📥 Downloading Claude Desktop installer..."
CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
if ! wget -O "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer"
    exit 1
fi
echo "✓ Download complete"

# Extract resources
echo "📦 Extracting resources..."
cd "$WORK_DIR"
if ! 7z x -y "$CLAUDE_EXE"; then
    echo "❌ Failed to extract installer"
    exit 1
fi

# Extract nupkg filename and version
NUPKG_PATH=$(find . -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file"
    exit 1
fi

# Extract version from the nupkg filename (using LC_ALL=C for locale compatibility)
VERSION=$(echo "$NUPKG_PATH" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH"
    exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH"; then
    echo "❌ Failed to extract nupkg"
    exit 1
fi
echo "✓ Resources extracted"

# Extract and convert icons
echo "🎨 Processing icons..."
if ! wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico; then
    echo "❌ Failed to extract icons from exe"
    exit 1
fi

if ! icotool -x claude.ico; then
    echo "❌ Failed to convert icons"
    exit 1
fi
echo "✓ Icons processed"

# Map icon sizes to their corresponding extracted files
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

# Prepare RPM build directory
RPM_BUILD_DIR="$RPM_ROOT/BUILD/$PACKAGE_NAME-build"
mkdir -p "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME"
mkdir -p "$RPM_BUILD_DIR/usr/share/applications"
mkdir -p "$RPM_BUILD_DIR/usr/bin"

# Install icons
for size in 16 24 32 48 64 256; do
    icon_dir="$RPM_BUILD_DIR/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    if [ -f "${icon_files[$size]}" ]; then
        echo "Installing ${size}x${size} icon..."
        install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon"
    fi
done

# Process app.asar
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd "$WORK_DIR/electron-app"
npx asar extract app.asar app.asar.contents

# Replace native module with stub implementation
echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n

cp ../lib/net45/resources/Tray* app.asar.contents/resources/
# Copy only the language-specific JSON files (e.g., en-US.json)
cp ../lib/net45/resources/*-*.json app.asar.contents/resources/i18n/

echo "Downloading Main Window Fix Assets"
cd app.asar.contents
wget -O- https://github.com/emsi/claude-desktop/raw/refs/heads/main/assets/main_window.tgz | tar -zxvf -
cd ..

# Repackage app.asar
npx asar pack app.asar.contents app.asar

# Create native module with keyboard constants
mkdir -p "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
cat > "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = {
  Backspace: 43,
  Tab: 280,
  Enter: 261,
  Shift: 272,
  Control: 61,
  Alt: 40,
  CapsLock: 56,
  Escape: 85,
  Space: 276,
  PageUp: 251,
  PageDown: 250,
  End: 83,
  Home: 154,
  LeftArrow: 175,
  UpArrow: 282,
  RightArrow: 262,
  DownArrow: 81,
  Delete: 79,
  Meta: 187
};

Object.freeze(KeyboardKey);

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy app files
cp app.asar "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME/"

# Copy local electron if available
if [ ! -z "$LOCAL_ELECTRON" ]; then
    echo "Copying local electron to package..."
    cp -r "$(dirname "$LOCAL_ELECTRON")/.." "$RPM_BUILD_DIR/usr/lib/$PACKAGE_NAME/node_modules/"
fi

# Create desktop entry
cat > "$RPM_BUILD_DIR/usr/share/applications/claude-desktop.desktop" << EOF
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

# Create launcher script with Wayland flags and logging
cat > "$RPM_BUILD_DIR/usr/bin/claude-desktop" << EOF
#!/bin/bash
LOG_FILE="\$HOME/claude-desktop-launcher.log"
echo "--- Claude Desktop Launcher Start ---" >> "\$LOG_FILE"
echo "Timestamp: \$(date)" >> "\$LOG_FILE"
echo "Arguments: \$@" >> "\$LOG_FILE"

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "\$LOG_FILE"
fi

# Determine Electron executable path
ELECTRON_EXEC="electron" # Default to global
LOCAL_ELECTRON_PATH="/usr/lib/claude-desktop/node_modules/.bin/electron"
if [ -f "\$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="\$LOCAL_ELECTRON_PATH"
    echo "Using local Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
else
    echo "Using global Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
fi

# Base command arguments array, starting with app path
APP_PATH="/usr/lib/claude-desktop/app.asar"
ELECTRON_ARGS=("\$APP_PATH")

# Add Wayland flags if Wayland is detected
if [ "\$IS_WAYLAND" = true ]; then
  echo "Adding Wayland flags" >> "\$LOG_FILE"
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations" "--ozone-platform=wayland")
fi

# Change to the application directory
echo "Changing directory to /usr/lib/claude-desktop" >> "\$LOG_FILE"
cd /usr/lib/claude-desktop || { echo "Failed to cd to /usr/lib/claude-desktop" >> "\$LOG_FILE"; exit 1; }

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
chmod +x "$RPM_BUILD_DIR/usr/bin/claude-desktop"

# Create tarball for RPM source
cd "$RPM_ROOT/BUILD"
tar -czf "$RPM_ROOT/SOURCES/$PACKAGE_NAME-$VERSION.tar.gz" "$PACKAGE_NAME-build"

# Create spec file
cat > "$RPM_ROOT/SPECS/$PACKAGE_NAME.spec" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        Claude Desktop for Linux
License:        Proprietary
URL:            https://www.anthropic.com/claude
Source0:        %{name}-%{version}.tar.gz
BuildArch:      $ARCHITECTURE
Requires:       nodejs >= 12.0.0, npm, p7zip, p7zip-plugins

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on Red Hat-based Linux distributions (RHEL, Fedora, CentOS, etc.)
Requires: nodejs (>= 12.0.0), npm

%prep
%setup -q -n %{name}-build

%install
cp -r * %{buildroot}

%post
# Update desktop database for MIME types
update-desktop-database /usr/share/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox
SANDBOX_PATH=""
# Check for sandbox in locally packaged electron first
if [ -f "/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox" ]; then
    SANDBOX_PATH="/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox"
# If not found, try to find it in the path of the globally installed electron
elif command -v electron >/dev/null 2>&1; then
    ELECTRON_PATH=\$(command -v electron)
    # Try to find sandbox relative to the electron binary path
    POTENTIAL_SANDBOX="\$(dirname "\$ELECTRON_PATH")/../lib/node_modules/electron/dist/chrome-sandbox"
    if [ -f "\$POTENTIAL_SANDBOX" ]; then
        SANDBOX_PATH="\$POTENTIAL_SANDBOX"
    fi
fi

if [ -n "\$SANDBOX_PATH" ] && [ -f "\$SANDBOX_PATH" ]; then
    echo "Found chrome-sandbox at: \$SANDBOX_PATH"
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
    echo "Permissions set for \$SANDBOX_PATH"
else
    echo "Warning: chrome-sandbox binary not found. Sandbox may not function correctly."
fi

%files
%defattr(-,root,root,-)
%attr(755,root,root) /usr/bin/claude-desktop
/usr/lib/%{name}/
/usr/share/applications/claude-desktop.desktop
/usr/share/icons/hicolor/*/apps/claude-desktop.png

%changelog
* $(date +"%a %b %d %Y") $MAINTAINER <maintainer@example.com> - $VERSION-1
- Initial package
EOF

# Build RPM package with debug package disabled
echo "🖹 Building RPM package..."
cd "$RPM_ROOT/SPECS"
rpmbuild -ba --define "_enable_debug_packages 0" --define "debug_package %{nil}" "$PACKAGE_NAME.spec"

# Check if the package was built successfully
RPM_FILE="$RPM_ROOT/RPMS/$ARCHITECTURE/$PACKAGE_NAME-$VERSION-1.$(rpm --eval '%{?dist}').$ARCHITECTURE.rpm"
if [ -f "$RPM_FILE" ]; then
    echo "✓ Package built successfully at: $RPM_FILE"
    # Copy the RPM file to the current directory for convenience
    cp "$RPM_FILE" "$(pwd)/../$PACKAGE_NAME-$VERSION.$ARCHITECTURE.rpm"
    echo "🎉 Done! You can now install the package with: sudo dnf install $(pwd)/../$PACKAGE_NAME-$VERSION.$ARCHITECTURE.rpm"
else
    echo "❌ Package file not found at expected location: $RPM_FILE"
    exit 1
fi
