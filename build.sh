#!/bin/bash
set -euo pipefail

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo "⚙️ Detecting system architecture..."
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64)
        HOST_ARCH="amd64"
        ;;
    aarch64)
        HOST_ARCH="arm64"
        ;;
    *)
        echo "❌ Unsupported architecture: $RAW_ARCH. This script supports x86_64 (amd64) and aarch64 (arm64)."
        exit 1
        ;;
esac
echo "Detected host architecture: $RAW_ARCH (mapped to $HOST_ARCH)"
cat /etc/os-release && uname -m

# Set variables based on detected architecture
if [ "$HOST_ARCH" = "amd64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
    ARCHITECTURE="amd64"
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for amd64 build."
elif [ "$HOST_ARCH" = "arm64" ]; then
    CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe"
    ARCHITECTURE="arm64"
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for arm64 build."
else
    # This case is redundant due to the check above but kept for safety
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE"
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"


if [ ! -f "/etc/redhat-release" ]; then
    echo "❌ This script requires a Red Hat-based Linux distribution (e.g., Fedora, CentOS, RHEL)."
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
   echo "❌ This script should not be run using sudo or as the root user."
   echo "   It will prompt for sudo password when needed for specific actions."
   echo "   Please run as a normal user."
   exit 1
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "❌ Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# Check for NVM and source it if found to ensure npm/npx are available later
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to activate..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source NVM script to set up NVM environment variables temporarily
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Initialize and find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi # End of if [ -d "$ORIGINAL_HOME/.nvm" ] check


echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
echo "Distribution Version: $(cat /etc/redhat-release)"
echo "Target Architecture: $ARCHITECTURE"
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)" WORK_DIR="$PROJECT_ROOT/build" APP_STAGING_DIR="$WORK_DIR/electron-app" VERSION=""
echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="rpm"    CLEANUP_ACTION="yes"  TEST_FLAGS_MODE=false
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        CLEANUP_ACTION="$2"
        shift 2 ;; # Shift past flag and value
        --test-flags)
        TEST_FLAGS_MODE=true
        shift # past argument
        ;;
        -h|--help)
        echo "Usage: $0 [--build rpm|appimage] [--clean yes|no] [--test-flags]"
        echo "  --build: Specify the build format (rpm or appimage). Default: rpm"
        echo "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes"
        echo "  --test-flags: Parse flags, print results, and exit without building."
        exit 0
        ;;
        *)            echo "❌ Unknown option: $1" >&2
        echo "Use -h or --help for usage information." >&2
        exit 1
        ;;
    esac
done

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]') CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')
if [[ "$BUILD_FORMAT" != "rpm" && "$BUILD_FORMAT" != "appimage" ]]; then
    echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'rpm' or 'appimage'." >&2
    exit 1
fi
if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
    echo "❌ Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'." >&2
    exit 1
fi

echo "Selected build format: $BUILD_FORMAT"
echo "Cleanup intermediate files: $CLEANUP_ACTION"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    # Target Architecture is implicitly detected now
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi


check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
COMMON_DEPS="p7zip wget wrestool icotool convert npx"
RPM_DEPS="rpm-build"
APPIMAGE_DEPS=""
ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "rpm" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $RPM_DEPS"
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $APPIMAGE_DEPS"
fi

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip p7zip-plugins" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick" ;;
            "npx") DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs" ;;
            "rpm-build") DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build" ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: $DEPS_TO_INSTALL"
    echo "Attempting to install using sudo..."
        if ! sudo -v; then
        echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
    # Here on purpose no "" to expand the 'list', thus
    # shellcheck disable=SC2086
    if ! sudo dnf install -y $DEPS_TO_INSTALL; then
         echo "❌ Failed to install dependencies using 'sudo dnf install'."
         exit 1
    fi
    echo "✓ System dependencies installed successfully via sudo."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR"
echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH="" ASAR_EXEC=""

echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR"
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
fi

ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
        if ! npm install --no-save electron @electron/asar; then
        echo "❌ Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "✓ Electron and Asar installation command finished."
else
    echo "✓ Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "✓ Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "❌ Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    echo "   Cannot proceed without the Electron distribution files."
    cd "$PROJECT_ROOT"     exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "✓ Found local Asar binary at $ASAR_EXEC."
else
    echo "❌ Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT"
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "❌ Critical error: Could not resolve a valid Electron module path to copy."
     exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"


echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "✓ Download complete: $CLAUDE_EXE_FILENAME"

echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then     echo "❌ Failed to extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE" echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then     echo "❌ Failed to extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Resources extracted from nupkg"

EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then     echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then     echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "✓ Icons processed and copied to $WORK_DIR"

echo "⚙️ Processing app.asar..."
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/"
cd "$APP_STAGING_DIR"
"$ASAR_EXEC" extract app.asar app.asar.contents

echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"* app.asar.contents/resources/
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "##############################################################"
echo "Removing "'!'" from 'if ("'!'"isWindows && isMainWindow) return null;'"
echo "detection flag to to enable title bar"

echo "Current working directory: '$PWD'"

SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
TARGET_PATTERN="MainWindowPage-*.js"

echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
# Find the target file recursively (ensure only one matches)
TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
# Count non-empty lines to get the number of files found
NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)

if [ "$NUM_FILES" -eq 0 ]; then
  echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
  exit 1
elif [ "$NUM_FILES" -gt 1 ]; then
  echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
  echo "Found files:" >&2
  echo "$TARGET_FILES" >&2
  exit 1
else
  # Exactly one file found
  TARGET_FILE="$TARGET_FILES" # Assign the found file path
  echo "Found target file: $TARGET_FILE"
  echo "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."
  # Use character classes [a-zA-Z]+ to match minified variable names
  # Capture group 1: first variable name
  # Capture group 2: second variable name
  sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$TARGET_FILE"

  # Verification: Check if the original pattern structure still exists
  if ! grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$TARGET_FILE"; then
    echo "Successfully replaced patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE"
  else
    echo "Error: Failed to replace patterns like 'if(!VAR1 && VAR2)' in $TARGET_FILE. Check file contents." >&2
    exit 1
  fi
fi
echo "##############################################################"

"$ASAR_EXEC" pack app.asar.contents app.asar

mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

echo "Copying chosen electron installation to staging area..."
mkdir -p "$APP_STAGING_DIR/node_modules/"
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/"
STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH="" FINAL_DESKTOP_FILE_PATH=""
if [ "$BUILD_FORMAT" = "rpm" ]; then
    echo "📦 Calling RPM packaging script for $ARCHITECTURE..."
    # IMPORTANT: Assumes you have a 'build-rpm-package.sh' script in the 'scripts' directory
    # This script must be created to handle creating a .spec file and running rpmbuild.
    chmod +x scripts/build-rpm-package.sh
    if ! scripts/build-rpm-package.sh \
        "$VERSION" "$RAW_ARCH" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "❌ RPM packaging script failed."
        exit 1
    fi
    # Find the generated RPM. The architecture in the filename will be x86_64 or aarch64.
    RPM_FILE=$(find "$WORK_DIR" -name "${PACKAGE_NAME}-${VERSION}*.${RAW_ARCH}.rpm" | head -n 1)
    echo "✓ RPM Build complete!"
    if [ -n "$RPM_FILE" ] && [ -f "$RPM_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$RPM_FILE")"
        mv "$RPM_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .rpm file path from $WORK_DIR for ${RAW_ARCH}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

elif [ "$BUILD_FORMAT" = "appimage" ]; then
    echo "📦 Calling AppImage packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-appimage.sh
    if ! scripts/build-appimage.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
        echo "❌ AppImage packaging script failed."
        exit 1
    fi
    APPIMAGE_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
    echo "✓ AppImage Build complete!"
    if [ -n "$APPIMAGE_FILE" ] && [ -f "$APPIMAGE_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$APPIMAGE_FILE")"
        mv "$APPIMAGE_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"

        echo -e "\033[1;36m--- Generate .desktop file for AppImage ---\033[0m"
        FINAL_DESKTOP_FILE_PATH="./${PACKAGE_NAME}-appimage.desktop"
        echo "📝 Generating .desktop file for AppImage at $FINAL_DESKTOP_FILE_PATH..."
        cat > "$FINAL_DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$(basename "$FINAL_OUTPUT_PATH") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop (AppImage)
EOF
        echo "✓ .desktop file generated."

    else
        echo "Warning: Could not determine final .AppImage file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi


echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then     echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
        if rm -rf "$WORK_DIR"; then
        echo "✓ Cleanup complete ($WORK_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $WORK_DIR) failed."
    fi
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
fi


echo "✅ Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "rpm" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the RPM package, run:"
        echo -e "   \033[1;32msudo dnf install $FINAL_OUTPUT_PATH\033[0m"
    else
        echo -e "⚠️ RPM package file not found. Cannot provide installation instructions."
    fi
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "✅ AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
        echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mAppImageLauncher\033[0m for proper desktop integration"
        echo -e "and to handle the \`claude://\` login process correctly."
        echo -e "\n🚀 To install AppImageLauncher (v2.2.0 for x86_64):"
        echo -e "   1. Download:"
        echo -e "      \033[1;32mwget https://github.com/TheAssassin/AppImageLauncher/releases/download/v2.2.0/appimagelauncher-2.2.0-travis995.0f91801.x86_64.rpm -O /tmp/appimagelauncher.rpm\033[0m"
        echo -e "       - or appropriate package from here: \033[1;34mhttps://github.com/TheAssassin/AppImageLauncher/releases/latest\033[0m"
        echo -e "   2. Install the package:"
        echo -e "      \033[1;32msudo dnf install /tmp/appimagelauncher.rpm\033[0m"
        echo -e "\n   After installation, simply double-click \033[1;36m$FINAL_OUTPUT_PATH\033[0m and choose 'Integrate and run'."
    else
        echo -e "⚠️ AppImage file not found. Cannot provide usage instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

exit 0