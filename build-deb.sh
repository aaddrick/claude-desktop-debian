#!/bin/bash
set -e

# Try to load NVM regardless of user
if [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    . "$NVM_DIR/nvm.sh"
elif [ -s "/home/$(logname)/.nvm/nvm.sh" ]; then
    # Try to load original user's NVM when running as root
    export NVM_DIR="/home/$(logname)/.nvm"
    . "$NVM_DIR/nvm.sh"
fi

# Update this URL when a new version of Claude Desktop is released
CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"

# Handle privilege escalation while preserving environment
if [ "$EUID" -ne 0 ]; then
    echo "Elevating privileges to install system dependencies..."
    exec sudo --preserve-env=NVM_DIR,PATH,HOME "$0" "$@"
    exit $?
fi

# Check for Debian-based system
if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

# Print system information
echo "System Information:"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Node.js version: $(node --version 2>/dev/null || echo 'Not installed')"
echo "NPM version: $(npm --version 2>/dev/null || echo 'Not installed')"
echo "NVM version: $(nvm --version 2>/dev/null || echo 'Not available')"

# Function to check if a command exists (with NVM awareness)
check_command() {
    # Try directly
    if command -v "$1" &> /dev/null; then
        echo "✓ $1 found"
        return 0
    # Check in NVM paths if NVM is installed
    elif [ -d "$NVM_DIR" ] && find "$NVM_DIR" -name "$1" -type f 2>/dev/null | grep -q .; then
        echo "✓ $1 found (via NVM)"
        NPX_PATH=$(find "$NVM_DIR" -name "$1" -type f | head -1)
        export PATH="$(dirname "$NPX_PATH"):$PATH"
        return 0
    else
        echo "❌ $1 not found"
        return 1
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
DEPS_TO_INSTALL=""

# Check system package dependencies
for cmd in p7zip wget wrestool icotool convert dpkg-deb; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full"
                ;;
            "wget")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                ;;
            "wrestool"|"icotool")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                ;;
            "convert")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick"
                ;;
            "dpkg-deb")
                DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev"
                ;;
        esac
    fi
done

# Special handling for Node.js related commands
# Check for Node.js first
if ! check_command "node"; then
    DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs"
fi

# Then check for npm and npx (if node is available)
if check_command "node"; then
    if ! check_command "npm"; then
        if [ -n "$(command -v node)" ]; then
            echo "Node.js found but npm is missing. Installing npm..."
            DEPS_TO_INSTALL="$DEPS_TO_INSTALL npm"
        fi
    fi
    
    # Check for npx - if npm is available, we'll use npm to install it if needed
    if ! check_command "npx"; then
        if check_command "npm"; then
            echo "Installing npx via npm..."
            npm install -g npx
            check_command "npx"
        else
            echo "Cannot install npx without npm"
        fi
    fi
fi

# Install system dependencies if any
if [ ! -z "$DEPS_TO_INSTALL" ]; then
    echo "Installing system dependencies: $DEPS_TO_INSTALL"
    apt update
    apt install  $DEPS_TO_INSTALL
    echo "System dependencies installed successfully"
fi

# Re-check Node.js related commands after potential installations
if ! check_command "node"; then
    echo "❌ Node.js installation failed. Please install Node.js manually."
    exit 1
fi

if ! check_command "npm"; then
    echo "❌ npm installation failed. Please install npm manually."
    exit 1
fi

if ! check_command "npx"; then
    echo "Installing npx via npm..."
    npm install -g npx
    if ! check_command "npx"; then
        echo "❌ npx installation failed. Please install npx manually."
        exit 1
    fi
fi

# Install electron globally via npm if not present
if ! check_command "electron"; then
    echo "Installing electron via npm..."
    npm install -g electron
    if ! check_command "electron"; then
        echo "Failed to install electron. Please install it manually:"
        echo "npm install -g electron"
        exit 1
    fi
    echo "Electron installed successfully"
fi

# Extract version from the installer filename
VERSION=$(basename "$CLAUDE_DOWNLOAD_URL" | grep -oP 'Claude-Setup-x64\.exe' | sed 's/Claude-Setup-x64\.exe/0.8.0/')
PACKAGE_NAME="claude-desktop"
ARCHITECTURE="amd64"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"

# Create working directories
WORK_DIR="$(pwd)/build"
DEB_ROOT="$WORK_DIR/deb-package"
INSTALL_DIR="$DEB_ROOT/usr"

# Clean previous build
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$DEB_ROOT/DEBIAN"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

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

if ! 7z x -y "AnthropicClaude-$VERSION-full.nupkg"; then
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

# Install icons
for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
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

cd electron-app
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
cp ../lib/net45/resources/*-*.json app.asar.contents/resources/i18n/

# Repackage app.asar
npx asar pack app.asar.contents app.asar

# Create native module with keyboard constants
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
cat > "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
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
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Create desktop entry
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

# Create launcher script
cat > "$INSTALL_DIR/bin/claude-desktop" << EOF
#!/bin/bash
# Source NVM if available
if [ -f "\$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="\$HOME/.nvm"
    . "\$NVM_DIR/nvm.sh"
fi

# Find and use electron from either system or NVM
if command -v electron > /dev/null; then
    electron /usr/lib/claude-desktop/app.asar "\$@"
elif [ -d "\$NVM_DIR" ] && [ -n "\$(find "\$NVM_DIR" -name "electron" -type f 2>/dev/null)" ]; then
    ELECTRON_PATH=\$(find "\$NVM_DIR" -name "electron" -type f | head -1)
    \$ELECTRON_PATH /usr/lib/claude-desktop/app.asar "\$@"
else
    echo "Error: electron not found. Please install it with 'npm install -g electron' or using NVM"
    exit 1
fi
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# Create control file
cat > "$DEB_ROOT/DEBIAN/control" << EOF
Package: claude-desktop
Version: $VERSION
Architecture: $ARCHITECTURE
Maintainer: $MAINTAINER
Depends: p7zip-full
Recommends: nodejs, npm
Description: $DESCRIPTION
 Claude is an AI assistant from Anthropic.
 This package provides the desktop interface for Claude.
 .
 Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.)
 Requires Node.js (>= 12.0.0) which can be provided through NVM
EOF

# Build .deb package
echo "📦 Building .deb package..."
DEB_FILE="$(pwd)/claude-desktop_${VERSION}_${ARCHITECTURE}.deb"
if ! dpkg-deb --build "$DEB_ROOT" "$DEB_FILE"; then
    echo "❌ Failed to build .deb package"
    exit 1
fi

if [ -f "$DEB_FILE" ]; then
    echo "✓ Package built successfully at: $DEB_FILE"
    echo "🎉 Done! You can now install the package with: sudo dpkg -i $DEB_FILE"
else
    echo "❌ Package file not found at expected location: $DEB_FILE"
    exit 1
fi
