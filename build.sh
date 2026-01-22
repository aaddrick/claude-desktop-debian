#!/bin/bash
set -euo pipefail

#===============================================================================
# Claude Desktop Debian Build Script
# Repackages Claude Desktop (Electron app) for Debian/Ubuntu Linux
#===============================================================================

# Global variables (set by functions, used throughout)
ARCHITECTURE=""
CLAUDE_DOWNLOAD_URL=""
CLAUDE_EXE_FILENAME=""
VERSION=""
BUILD_FORMAT="deb"
CLEANUP_ACTION="yes"
PERFORM_CLEANUP=false
TEST_FLAGS_MODE=false
LOCAL_EXE_PATH=""
ORIGINAL_USER=""
ORIGINAL_HOME=""
PROJECT_ROOT=""
WORK_DIR=""
APP_STAGING_DIR=""
CHOSEN_ELECTRON_MODULE_PATH=""
ASAR_EXEC=""
CLAUDE_EXTRACT_DIR=""
ELECTRON_RESOURCES_DEST=""
NODE_PTY_BUILD_DIR=""

# Package metadata
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"

#===============================================================================
# Utility Functions
#===============================================================================

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

section_header() {
    echo -e "\033[1;36m--- $1 ---\033[0m"
}

section_footer() {
    echo -e "\033[1;36m--- End $1 ---\033[0m"
}

#===============================================================================
# Setup Functions
#===============================================================================

detect_architecture() {
    section_header "Architecture Detection"
    echo "⚙️ Detecting system architecture..."

    local host_arch
    host_arch=$(dpkg --print-architecture)
    echo "Detected host architecture: $host_arch"
    cat /etc/os-release && uname -m && dpkg --print-architecture

    case "$host_arch" in
        amd64)
            CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/x64/1.1.381/Claude-c2a39e9c82f5a4d51f511f53f532afd276312731.exe"
            ARCHITECTURE="amd64"
            CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
            echo "Configured for amd64 build."
            ;;
        arm64)
            CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/arm64/1.1.381/Claude-c2a39e9c82f5a4d51f511f53f532afd276312731.exe"
            ARCHITECTURE="arm64"
            CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
            echo "Configured for arm64 build."
            ;;
        *)
            echo "❌ Unsupported architecture: $host_arch. This script currently supports amd64 and arm64."
            exit 1
            ;;
    esac

    echo "Target Architecture (detected): $ARCHITECTURE"
    section_footer "Architecture Detection"
}

check_system_requirements() {
    if [ ! -f "/etc/debian_version" ]; then
        echo "❌ This script requires a Debian-based Linux distribution"
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

    # Check for NVM and source it if found
    if [ -d "$ORIGINAL_HOME/.nvm" ]; then
        echo "Found NVM installation for user $ORIGINAL_USER, checking for Node.js 20+..."
        export NVM_DIR="$ORIGINAL_HOME/.nvm"
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            # shellcheck disable=SC1091
            \. "$NVM_DIR/nvm.sh"
            local node_bin_path=""
            node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

            if [ -n "$node_bin_path" ] && [ -d "$node_bin_path" ]; then
                echo "Adding NVM Node bin path to PATH: $node_bin_path"
                export PATH="$node_bin_path:$PATH"
            else
                echo "Warning: Could not determine NVM Node bin path."
            fi
        else
            echo "Warning: nvm.sh script not found or not sourceable."
        fi
    fi

    echo "System Information:"
    echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
    echo "Debian version: $(cat /etc/debian_version)"
    echo "Target Architecture: $ARCHITECTURE"
}

parse_arguments() {
    section_header "Argument Parsing"

    PROJECT_ROOT="$(pwd)"
    WORK_DIR="$PROJECT_ROOT/build"
    APP_STAGING_DIR="$WORK_DIR/electron-app"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--build)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "❌ Error: Argument for $1 is missing" >&2
                    exit 1
                fi
                BUILD_FORMAT="$2"
                shift 2
                ;;
            -c|--clean)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "❌ Error: Argument for $1 is missing" >&2
                    exit 1
                fi
                CLEANUP_ACTION="$2"
                shift 2
                ;;
            -e|--exe)
                if [[ -z "${2:-}" || "$2" == -* ]]; then
                    echo "❌ Error: Argument for $1 is missing" >&2
                    exit 1
                fi
                LOCAL_EXE_PATH="$2"
                shift 2
                ;;
            --test-flags)
                TEST_FLAGS_MODE=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [--build deb|appimage] [--clean yes|no] [--exe /path/to/installer.exe] [--test-flags]"
                echo "  --build: Specify the build format (deb or appimage). Default: deb"
                echo "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes"
                echo "  --exe:   Use a local Claude installer exe instead of downloading"
                echo "  --test-flags: Parse flags, print results, and exit without building."
                exit 0
                ;;
            *)
                echo "❌ Unknown option: $1" >&2
                echo "Use -h or --help for usage information." >&2
                exit 1
                ;;
        esac
    done

    # Validate arguments
    BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]')
    CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')

    if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" ]]; then
        echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'deb' or 'appimage'." >&2
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

    section_footer "Argument Parsing"
}

check_dependencies() {
    echo "Checking dependencies..."
    local deps_to_install=""
    local common_deps="p7zip wget wrestool icotool convert"
    local deb_deps="dpkg-deb"
    local all_deps="$common_deps"

    if [ "$BUILD_FORMAT" = "deb" ]; then
        all_deps="$all_deps $deb_deps"
    fi

    for cmd in $all_deps; do
        if ! check_command "$cmd"; then
            case "$cmd" in
                "p7zip") deps_to_install="$deps_to_install p7zip-full" ;;
                "wget") deps_to_install="$deps_to_install wget" ;;
                "wrestool"|"icotool") deps_to_install="$deps_to_install icoutils" ;;
                "convert") deps_to_install="$deps_to_install imagemagick" ;;
                "dpkg-deb") deps_to_install="$deps_to_install dpkg-dev" ;;
            esac
        fi
    done

    if [ -n "$deps_to_install" ]; then
        echo "System dependencies needed:$deps_to_install"
        echo "Attempting to install using sudo..."
        if ! sudo -v; then
            echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
            exit 1
        fi
        if ! sudo apt update; then
            echo "❌ Failed to run 'sudo apt update'."
            exit 1
        fi
        # shellcheck disable=SC2086
        if ! sudo apt install -y $deps_to_install; then
            echo "❌ Failed to install dependencies using 'sudo apt install'."
            exit 1
        fi
        echo "✓ System dependencies installed successfully via sudo."
    fi
}

setup_work_directory() {
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$APP_STAGING_DIR"
}

setup_nodejs() {
    section_header "Node.js Setup"
    echo "Checking Node.js version..."

    local node_version_ok=false
    if command -v node &> /dev/null; then
        local node_version node_major
        node_version=$(node --version | cut -d'v' -f2)
        node_major=$(echo "$node_version" | cut -d'.' -f1)
        echo "System Node.js version: v$node_version"

        if [ "$node_major" -ge 20 ]; then
            echo "✓ System Node.js version is adequate (v$node_version)"
            node_version_ok=true
        else
            echo "⚠️ System Node.js version is too old (v$node_version). Need v20+"
        fi
    else
        echo "⚠️ Node.js not found in system"
    fi

    if [ "$node_version_ok" = false ]; then
        echo "Installing Node.js v20 locally in build directory..."

        local node_arch
        case "$ARCHITECTURE" in
            amd64) node_arch="x64" ;;
            arm64) node_arch="arm64" ;;
            *)
                echo "❌ Unsupported architecture for Node.js: $ARCHITECTURE"
                exit 1
                ;;
        esac

        local node_version_to_install="20.18.1"
        local node_tarball="node-v${node_version_to_install}-linux-${node_arch}.tar.xz"
        local node_url="https://nodejs.org/dist/v${node_version_to_install}/${node_tarball}"
        local node_install_dir="$WORK_DIR/node"

        echo "Downloading Node.js v${node_version_to_install} for ${node_arch}..."
        cd "$WORK_DIR"
        if ! wget -O "$node_tarball" "$node_url"; then
            echo "❌ Failed to download Node.js from $node_url"
            cd "$PROJECT_ROOT"
            exit 1
        fi

        echo "Extracting Node.js..."
        if ! tar -xf "$node_tarball"; then
            echo "❌ Failed to extract Node.js tarball"
            cd "$PROJECT_ROOT"
            exit 1
        fi

        mv "node-v${node_version_to_install}-linux-${node_arch}" "$node_install_dir"
        export PATH="$node_install_dir/bin:$PATH"

        if command -v node &> /dev/null; then
            echo "✓ Local Node.js installed successfully: $(node --version)"
        else
            echo "❌ Failed to install local Node.js"
            cd "$PROJECT_ROOT"
            exit 1
        fi

        rm -f "$node_tarball"
        cd "$PROJECT_ROOT"
    fi

    section_footer "Node.js Setup"
}

setup_electron_asar() {
    section_header "Electron & Asar Handling"

    echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
    cd "$WORK_DIR"

    if [ ! -f "package.json" ]; then
        echo "Creating temporary package.json in $WORK_DIR for local install..."
        echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
    fi

    local electron_dist_path="$WORK_DIR/node_modules/electron/dist"
    local asar_bin_path="$WORK_DIR/node_modules/.bin/asar"
    local install_needed=false

    if [ ! -d "$electron_dist_path" ]; then
        echo "Electron distribution not found."
        install_needed=true
    fi
    if [ ! -f "$asar_bin_path" ]; then
        echo "Asar binary not found."
        install_needed=true
    fi

    if [ "$install_needed" = true ]; then
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

    if [ -d "$electron_dist_path" ]; then
        echo "✓ Found Electron distribution directory at $electron_dist_path."
        CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
        echo "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
    else
        echo "❌ Failed to find Electron distribution directory at '$electron_dist_path' after installation attempt."
        cd "$PROJECT_ROOT"
        exit 1
    fi

    if [ -f "$asar_bin_path" ]; then
        ASAR_EXEC="$(realpath "$asar_bin_path")"
        echo "✓ Found local Asar binary at $ASAR_EXEC."
    else
        echo "❌ Failed to find Asar binary at '$asar_bin_path' after installation attempt."
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
    section_footer "Electron & Asar Handling"
}

#===============================================================================
# Download and Extract Functions
#===============================================================================

download_claude_installer() {
    section_header "Download the latest Claude executable"

    local claude_exe_path="$WORK_DIR/$CLAUDE_EXE_FILENAME"

    if [ -n "$LOCAL_EXE_PATH" ]; then
        echo "📁 Using local Claude installer: $LOCAL_EXE_PATH"
        if [ ! -f "$LOCAL_EXE_PATH" ]; then
            echo "❌ Local installer file not found: $LOCAL_EXE_PATH"
            exit 1
        fi
        cp "$LOCAL_EXE_PATH" "$claude_exe_path"
        echo "✓ Local installer copied to build directory"
    else
        echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
        if ! wget -O "$claude_exe_path" "$CLAUDE_DOWNLOAD_URL"; then
            echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
            exit 1
        fi
        echo "✓ Download complete: $CLAUDE_EXE_FILENAME"
    fi

    echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
    CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
    mkdir -p "$CLAUDE_EXTRACT_DIR"

    if ! 7z x -y "$claude_exe_path" -o"$CLAUDE_EXTRACT_DIR"; then
        echo "❌ Failed to extract installer"
        cd "$PROJECT_ROOT" && exit 1
    fi

    cd "$CLAUDE_EXTRACT_DIR"
    local nupkg_path_relative
    nupkg_path_relative=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)

    if [ -z "$nupkg_path_relative" ]; then
        echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "Found nupkg: $nupkg_path_relative (in $CLAUDE_EXTRACT_DIR)"

    VERSION=$(echo "$nupkg_path_relative" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
    if [ -z "$VERSION" ]; then
        echo "❌ Could not extract version from nupkg filename: $nupkg_path_relative"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "✓ Detected Claude version: $VERSION"

    if ! 7z x -y "$nupkg_path_relative"; then
        echo "❌ Failed to extract nupkg"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "✓ Resources extracted from nupkg"

    cd "$PROJECT_ROOT"
}

#===============================================================================
# Patching Functions
#===============================================================================

patch_app_asar() {
    echo "⚙️ Processing app.asar..."
    cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
    cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/"
    cd "$APP_STAGING_DIR"
    "$ASAR_EXEC" extract app.asar app.asar.contents

    # Frame fix wrapper
    echo "Creating BrowserWindow frame fix wrapper..."
    local original_main
    original_main=$(node -e "const pkg = require('./app.asar.contents/package.json'); console.log(pkg.main);")
    echo "Original main entry: $original_main"

    cp "$PROJECT_ROOT/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js

    cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

    # Patch BrowserWindow creation
    echo "Searching and patching BrowserWindow creation in main process files..."
    find app.asar.contents/.vite/build -type f -name "*.js" -exec grep -l "BrowserWindow" {} \; > /tmp/bw-files.txt

    while IFS= read -r file; do
        if [ -f "$file" ]; then
            echo "Patching $file for native frames..."
            sed -i 's/frame[[:space:]]*:[[:space:]]*false/frame:true/g' "$file"
            sed -i 's/frame[[:space:]]*:[[:space:]]*!0/frame:true/g' "$file"
            sed -i 's/frame[[:space:]]*:[[:space:]]*!1/frame:true/g' "$file"
            sed -i 's/titleBarStyle[[:space:]]*:[[:space:]]*[^,}]*/titleBarStyle:""/g' "$file"
            echo "✓ Patched $file"
        fi
    done < /tmp/bw-files.txt
    rm -f /tmp/bw-files.txt

    # Update package.json
    echo "Modifying package.json to load frame fix and add node-pty..."
    node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry and node-pty dependency');
"

    # Create stub native module
    echo "Creating stub native module..."
    mkdir -p app.asar.contents/node_modules/@ant/claude-native
    cp "$PROJECT_ROOT/scripts/claude-native-stub.js" app.asar.contents/node_modules/@ant/claude-native/index.js

    mkdir -p app.asar.contents/resources/i18n
    cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

    # Patch title bar detection
    patch_titlebar_detection

    # Patch tray menu handler
    patch_tray_menu_handler

    # Patch tray icon selection
    patch_tray_icon_selection

    # Patch quick window
    patch_quick_window

    # Add Linux Claude Code support
    patch_linux_claude_code
}

patch_titlebar_detection() {
    echo "##############################################################"
    echo "Removing '!' from 'if (\"!\"isWindows && isMainWindow) return null;'"
    echo "detection flag to enable title bar"

    local search_base="app.asar.contents/.vite/renderer/main_window/assets"
    local target_pattern="MainWindowPage-*.js"

    echo "Searching for '$target_pattern' within '$search_base'..."
    local target_files
    target_files=$(find "$search_base" -type f -name "$target_pattern")
    local num_files
    num_files=$(echo "$target_files" | grep -c . || echo "0")

    if [ "$num_files" -eq 0 ]; then
        echo "Error: No file matching '$target_pattern' found within '$search_base'." >&2
        exit 1
    elif [ "$num_files" -gt 1 ]; then
        echo "Error: Expected exactly one file matching '$target_pattern' within '$search_base', but found $num_files." >&2
        exit 1
    else
        local target_file="$target_files"
        echo "Found target file: $target_file"
        sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$target_file"

        if ! grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$target_file"; then
            echo "Successfully replaced patterns in $target_file"
        else
            echo "Error: Failed to replace patterns in $target_file." >&2
            exit 1
        fi
    fi
    echo "##############################################################"
}

patch_tray_menu_handler() {
    echo "Patching tray menu handler function to prevent concurrent calls and add DBus cleanup delay..."

    local tray_func tray_var first_const
    tray_func=$(grep -oP 'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' app.asar.contents/.vite/build/index.js)
    if [ -z "$tray_func" ]; then
        echo "❌ Failed to extract tray menu function name"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "  Found tray function: $tray_func"

    tray_var=$(grep -oP "\}\);let \K\w+(?==null;(?:async )?function ${tray_func})" app.asar.contents/.vite/build/index.js)
    if [ -z "$tray_var" ]; then
        echo "❌ Failed to extract tray variable name"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "  Found tray variable: $tray_var"

    sed -i "s/function ${tray_func}(){/async function ${tray_func}(){/g" app.asar.contents/.vite/build/index.js

    first_const=$(grep -oP "async function ${tray_func}\(\)\{.*?const \K\w+(?==)" app.asar.contents/.vite/build/index.js | head -1)
    if [ -z "$first_const" ]; then
        echo "❌ Failed to extract first const variable name in function"
        cd "$PROJECT_ROOT" && exit 1
    fi
    echo "  Found first const variable: $first_const"

    if ! grep -q "${tray_func}._running" app.asar.contents/.vite/build/index.js; then
        sed -i "s/async function ${tray_func}(){/async function ${tray_func}(){if(${tray_func}._running)return;${tray_func}._running=true;setTimeout(()=>${tray_func}._running=false,1500);/g" app.asar.contents/.vite/build/index.js
        echo "  ✓ Added mutex guard to ${tray_func}()"
    fi

    if ! grep -q "await new Promise.*setTimeout" app.asar.contents/.vite/build/index.js | grep -q "${tray_var}"; then
        sed -i "s/${tray_var}\&\&(${tray_var}\.destroy(),${tray_var}=null)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" app.asar.contents/.vite/build/index.js
        echo "  ✓ Added DBus cleanup delay after ${tray_var}.destroy()"
    fi

    echo "✓ Tray menu handler patched"
    echo "##############################################################"

    # Patch nativeTheme handler
    echo "Patching nativeTheme handler to skip tray updates during startup..."
    if ! grep -q "_trayStartTime" app.asar.contents/.vite/build/index.js; then
        sed -i -E 's/(oe\.nativeTheme\.on\(\s*"updated"\s*,\s*\(\)\s*=>\s*\{)/let _trayStartTime=Date.now();\1/g' app.asar.contents/.vite/build/index.js
        sed -i -E "s/\((\w+)\(\)\s*,\s*${tray_func}\(\)\s*,/(\1(),Date.now()-_trayStartTime>3e3\&\&${tray_func}(),/g" app.asar.contents/.vite/build/index.js
        echo "  ✓ Added startup delay check to nativeTheme handler (3 second window)"
    fi
    echo "##############################################################"
}

patch_tray_icon_selection() {
    echo "Patching tray icon selection for Linux visibility..."
    if grep -qP ':\w="TrayIconTemplate\.png"' app.asar.contents/.vite/build/index.js; then
        sed -i -E 's/:(\w)="TrayIconTemplate\.png"/:\1=oe.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"/g' app.asar.contents/.vite/build/index.js
        echo "✓ Patched tray icon selection for Linux theme support"
    else
        echo "ℹ️  Tray icon selection pattern not found or already patched"
    fi
    echo "##############################################################"
}

patch_quick_window() {
    if ! grep -q 'e.blur(),e.hide()' app.asar.contents/.vite/build/index.js; then
        sed -i 's/e.hide()/e.blur(),e.hide()/' app.asar.contents/.vite/build/index.js
        echo "✓ Added blur() call to fix quick window submit issue"
    fi
}

patch_linux_claude_code() {
    if ! grep -q 'process.arch==="arm64"?"linux-arm64":"linux-x64"' app.asar.contents/.vite/build/index.js; then
        sed -i 's/if(process.platform==="win32")return"win32-x64";/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' app.asar.contents/.vite/build/index.js
        echo "✓ Added support for linux claude code binary"
    else
        echo "ℹ️  Linux claude code binary support already present"
    fi
}

install_node_pty() {
    section_header "Installing node-pty for terminal support"

    NODE_PTY_BUILD_DIR="$WORK_DIR/node-pty-build"
    mkdir -p "$NODE_PTY_BUILD_DIR"
    cd "$NODE_PTY_BUILD_DIR"
    echo '{"name":"node-pty-build","version":"1.0.0","private":true}' > package.json

    echo "Installing node-pty (this will compile native module for Linux)..."
    if npm install node-pty 2>&1; then
        echo "✓ node-pty installed successfully"

        if [ -d "$NODE_PTY_BUILD_DIR/node_modules/node-pty" ]; then
            echo "Copying node-pty JavaScript files into app.asar.contents..."
            mkdir -p "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty"
            cp -r "$NODE_PTY_BUILD_DIR/node_modules/node-pty/lib" "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty/"
            cp "$NODE_PTY_BUILD_DIR/node_modules/node-pty/package.json" "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty/"
            echo "✓ node-pty JavaScript files copied"
        else
            echo "⚠️ node-pty installation directory not found"
        fi
    else
        echo "⚠️ Failed to install node-pty - terminal features may not work"
    fi

    cd "$APP_STAGING_DIR"
    section_footer "node-pty installation"
}

finalize_app_asar() {
    "$ASAR_EXEC" pack app.asar.contents app.asar

    mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/@ant/claude-native"
    cp "$PROJECT_ROOT/scripts/claude-native-stub.js" "$APP_STAGING_DIR/app.asar.unpacked/node_modules/@ant/claude-native/index.js"

    # Copy node-pty native binaries
    if [ -d "$NODE_PTY_BUILD_DIR/node_modules/node-pty/build/Release" ]; then
        echo "Copying node-pty native binaries to unpacked directory..."
        mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release"
        cp -r "$NODE_PTY_BUILD_DIR/node_modules/node-pty/build/Release/"* "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release/"
        chmod +x "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release/"* 2>/dev/null || true
        echo "✓ node-pty native binaries copied"
    else
        echo "⚠️ node-pty native binaries not found - terminal features may not work"
    fi
}

#===============================================================================
# Staging Functions
#===============================================================================

stage_electron() {
    echo "Copying chosen electron installation to staging area..."
    mkdir -p "$APP_STAGING_DIR/node_modules/"
    local electron_dir_name
    electron_dir_name=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
    echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
    cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/"

    local staged_electron_bin="$APP_STAGING_DIR/node_modules/$electron_dir_name/dist/electron"
    if [ -f "$staged_electron_bin" ]; then
        echo "Setting executable permission on staged Electron binary: $staged_electron_bin"
        chmod +x "$staged_electron_bin"
    else
        echo "Warning: Staged Electron binary not found at expected path: $staged_electron_bin"
    fi

    # Copy Electron locale files
    local electron_resources_src="$CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
    ELECTRON_RESOURCES_DEST="$APP_STAGING_DIR/node_modules/$electron_dir_name/dist/resources"
    if [ -d "$electron_resources_src" ]; then
        echo "Copying Electron locale resources..."
        mkdir -p "$ELECTRON_RESOURCES_DEST"
        cp -a "$electron_resources_src"/* "$ELECTRON_RESOURCES_DEST/"
        echo "✓ Electron locale resources copied"
    else
        echo "⚠️  Warning: Electron resources directory not found at $electron_resources_src"
    fi
}

process_icons() {
    section_header "Icon Processing"

    cd "$CLAUDE_EXTRACT_DIR"
    local exe_path="lib/net45/claude.exe"
    if [ ! -f "$exe_path" ]; then
        echo "❌ Cannot find claude.exe at expected path: $CLAUDE_EXTRACT_DIR/$exe_path"
        cd "$PROJECT_ROOT" && exit 1
    fi

    echo "🎨 Extracting application icons from $exe_path..."
    if ! wrestool -x -t 14 "$exe_path" -o claude.ico; then
        echo "❌ Failed to extract icons from exe"
        cd "$PROJECT_ROOT" && exit 1
    fi

    if ! icotool -x claude.ico; then
        echo "❌ Failed to convert icons"
        cd "$PROJECT_ROOT" && exit 1
    fi
    cp claude_*.png "$WORK_DIR/"
    echo "✓ Application icons extracted and copied to $WORK_DIR"

    cd "$PROJECT_ROOT"

    # Process tray icons
    local claude_locale_src="$CLAUDE_EXTRACT_DIR/lib/net45/resources"
    echo "🖼️  Copying and processing tray icon files for Linux..."
    if [ -d "$claude_locale_src" ]; then
        cp "$claude_locale_src/Tray"* "$ELECTRON_RESOURCES_DEST/" 2>/dev/null || echo "⚠️  Warning: No tray icon files found"

        local magick_cmd=""
        if command -v magick &> /dev/null; then
            magick_cmd="magick"
        elif command -v convert &> /dev/null; then
            magick_cmd="convert"
        fi

        if [ -n "$magick_cmd" ]; then
            echo "Processing tray icons for Linux visibility (using $magick_cmd)..."
            for icon_file in "$ELECTRON_RESOURCES_DEST"/TrayIconTemplate*.png; do
                if [ -f "$icon_file" ]; then
                    local icon_name
                    icon_name=$(basename "$icon_file")
                    "$magick_cmd" "$icon_file" \
                        -channel A -fx "a>0?1:0" +channel \
                        "PNG32:$icon_file" 2>/dev/null && \
                        echo "  ✓ Processed $icon_name (100% opaque)" || \
                        echo "  ⚠️ Failed to process $icon_name"
                fi
            done
            echo "✓ Tray icon files copied and processed"
        else
            echo "⚠️  Warning: ImageMagick not found - tray icons may appear invisible"
            echo "✓ Tray icon files copied (unprocessed)"
        fi
    else
        echo "⚠️  Warning: Claude resources directory not found at $claude_locale_src"
    fi

    section_footer "Icon Processing"
}

copy_locale_files() {
    local claude_locale_src="$CLAUDE_EXTRACT_DIR/lib/net45/resources"
    echo "Copying Claude locale JSON files to Electron resources directory..."
    if [ -d "$claude_locale_src" ]; then
        cp "$claude_locale_src/"*-*.json "$ELECTRON_RESOURCES_DEST/"
        echo "✓ Claude locale JSON files copied to Electron resources directory"
    else
        echo "⚠️  Warning: Claude locale source directory not found at $claude_locale_src"
    fi

    echo "✓ app.asar processed and staged in $APP_STAGING_DIR"
}

#===============================================================================
# Packaging Functions
#===============================================================================

run_packaging() {
    section_header "Call Packaging Script"

    local final_output_path=""

    if [ "$BUILD_FORMAT" = "deb" ]; then
        echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
        chmod +x scripts/build-deb-package.sh
        if ! scripts/build-deb-package.sh \
            "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
            "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
            echo "❌ Debian packaging script failed."
            exit 1
        fi

        local deb_file
        deb_file=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)
        echo "✓ Debian Build complete!"
        if [ -n "$deb_file" ] && [ -f "$deb_file" ]; then
            final_output_path="./$(basename "$deb_file")"
            mv "$deb_file" "$final_output_path"
            echo "Package created at: $final_output_path"
        else
            echo "Warning: Could not determine final .deb file path."
            final_output_path="Not Found"
        fi

    elif [ "$BUILD_FORMAT" = "appimage" ]; then
        echo "📦 Calling AppImage packaging script for $ARCHITECTURE..."
        chmod +x scripts/build-appimage.sh
        if ! scripts/build-appimage.sh \
            "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
            echo "❌ AppImage packaging script failed."
            exit 1
        fi

        local appimage_file
        appimage_file=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
        echo "✓ AppImage Build complete!"
        if [ -n "$appimage_file" ] && [ -f "$appimage_file" ]; then
            final_output_path="./$(basename "$appimage_file")"
            mv "$appimage_file" "$final_output_path"
            echo "Package created at: $final_output_path"

            section_header "Generate .desktop file for AppImage"
            local desktop_file="./${PACKAGE_NAME}-appimage.desktop"
            echo "📝 Generating .desktop file for AppImage at $desktop_file..."
            cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$(basename "$final_output_path") %u
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
            echo "Warning: Could not determine final .AppImage file path."
            final_output_path="Not Found"
        fi
    fi

    # Store for print_next_steps
    FINAL_OUTPUT_PATH="$final_output_path"
}

cleanup_build() {
    section_header "Cleanup"
    if [ "$PERFORM_CLEANUP" = true ]; then
        echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
        if rm -rf "$WORK_DIR"; then
            echo "✓ Cleanup complete ($WORK_DIR removed)."
        else
            echo "⚠️ Cleanup command failed."
        fi
    else
        echo "Skipping cleanup of intermediate build files in $WORK_DIR."
    fi
}

print_next_steps() {
    echo -e "\n\033[1;34m====== Next Steps ======\033[0m"

    if [ "$BUILD_FORMAT" = "deb" ]; then
        if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
            echo -e "📦 To install the Debian package, run:"
            echo -e "   \033[1;32msudo apt install $FINAL_OUTPUT_PATH\033[0m"
            echo -e "   (or \`sudo dpkg -i $FINAL_OUTPUT_PATH\`)"
        else
            echo -e "⚠️ Debian package file not found. Cannot provide installation instructions."
        fi
    elif [ "$BUILD_FORMAT" = "appimage" ]; then
        if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
            echo -e "✅ AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
            echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration"
            echo -e "and to handle the \`claude://\` login process correctly."
            echo -e "\n🚀 To install Gear Lever:"
            echo -e "   1. Install via Flatpak:"
            echo -e "      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m"
            echo -e "   2. Integrate your AppImage with just one click:"
            echo -e "      - Open Gear Lever"
            echo -e "      - Drag and drop \033[1;36m$FINAL_OUTPUT_PATH\033[0m into Gear Lever"
            echo -e "      - Click 'Integrate' to add it to your app menu"
            if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
                echo -e "\n   \033[1;32m✓\033[0m This AppImage includes embedded update information!"
            else
                echo -e "\n   \033[1;33mℹ\033[0m This locally-built AppImage does not include update information."
                echo -e "   \033[1;34m→\033[0m For automatic updates, download release versions: https://github.com/aaddrick/claude-desktop-debian/releases"
            fi
        else
            echo -e "⚠️ AppImage file not found. Cannot provide usage instructions."
        fi
    fi

    echo -e "\033[1;34m======================\033[0m"
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
    # Phase 1: Setup
    detect_architecture
    check_system_requirements
    parse_arguments "$@"

    # Early exit for test mode
    if [ "$TEST_FLAGS_MODE" = true ]; then
        echo "--- Test Flags Mode Enabled ---"
        echo "Build Format: $BUILD_FORMAT"
        echo "Clean Action: $CLEANUP_ACTION"
        echo "Exiting without build."
        exit 0
    fi

    check_dependencies
    setup_work_directory
    setup_nodejs
    setup_electron_asar

    # Phase 2: Download and extract
    download_claude_installer

    # Phase 3: Patch and prepare
    patch_app_asar
    install_node_pty
    finalize_app_asar
    stage_electron
    process_icons
    copy_locale_files

    cd "$PROJECT_ROOT"

    # Phase 4: Package
    run_packaging

    # Phase 5: Cleanup and finish
    cleanup_build

    echo "✅ Build process finished."
    print_next_steps
}

# Run main with all script arguments
main "$@"

exit 0
