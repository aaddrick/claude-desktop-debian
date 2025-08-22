#!/bin/bash
set -euo pipefail

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo " Detecting system architecture..."

# Use uname for architecture detection on Fedora/RHEL systems
UNAME_ARCH=$(uname -m)
case "$UNAME_ARCH" in
    "x86_64") HOST_ARCH="amd64" ;;
    "aarch64") HOST_ARCH="arm64" ;;
    *) echo "ERROR: Unsupported architecture: $UNAME_ARCH"; exit 1 ;;
esac

echo "Detected host architecture: $HOST_ARCH (uname -m: $UNAME_ARCH)"
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
    echo "ERROR: Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE"
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"

# Check for Fedora/RHEL-based system
if [ ! -f "/etc/redhat-release" ] && [ ! -f "/etc/fedora-release" ] && [ ! -f "/etc/os-release" ]; then
    echo "ERROR: This script requires a Red Hat-based Linux distribution (Fedora, RHEL, CentOS, etc.)"
    exit 1
fi

# Note: OS compatibility check moved to after argument parsing

if [ "$EUID" -eq 0 ]; then
   # Check if we're running in a container environment
   if [ -f "/.dockerenv" ] || grep -q docker /proc/1/cgroup 2>/dev/null; then
       echo "INFO: Running as root in container environment - this is normal."
   else
       echo "ERROR: This script should not be run using sudo or as the root user."
       echo "   It will prompt for sudo password when needed for specific actions."
       echo "   Please run as a normal user."
       exit 1
   fi
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "ERROR: Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# Check for NVM and source it if found - this may provide a Node.js 20+ version
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, checking for Node.js 20+..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source NVM script to set up NVM environment variables temporarily
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Initialize and find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current 2>/dev/null | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' 2>/dev/null | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi # End of if [ -d "$ORIGINAL_HOME/.nvm" ] check

echo "System Information:"
if [ -f "/etc/os-release" ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "Distribution: $PRETTY_NAME"
    echo "Version: ${VERSION_ID:-Unknown}"
fi
echo "Target Architecture: $ARCHITECTURE"

# Parse arguments early to enable test mode
echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="rpm"    # Default to RPM for Fedora
CLEANUP_ACTION="yes"
TEST_FLAGS_MODE=false

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then
            echo "ERROR: Argument for $1 is missing" >&2
            exit 1
        fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        if [[ -z "$2" || "$2" == -* ]]; then
            echo "ERROR: Argument for $1 is missing" >&2
            exit 1
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
        *)
        echo "ERROR: Unknown option: $1" >&2
        echo "Use -h or --help for usage information." >&2
        exit 1
        ;;
    esac
done

# Security function: sanitize string for safe logging
sanitize_for_logging() {
    local input="$1"
    # Remove or escape potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9._/-]/***/g'
}

# Security function: validate environment variables
validate_environment_variables() {
    # Check for suspicious environment variables that could affect build security
    local suspicious_vars=("LD_PRELOAD" "LD_LIBRARY_PATH" "PATH" "SHELL")
    
    for var in "${suspicious_vars[@]}"; do
        if [[ -n "${!var:-}" ]]; then
            echo "WARNING: Potentially sensitive environment variable '$var' is set"
            echo "WARNING: Value: $(sanitize_for_logging "${!var}")"
        fi
    done
    
    # Validate NODE_VERSION if set
    if [[ -n "${NODE_VERSION:-}" && ! "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "WARNING: Invalid NODE_VERSION format in environment: $(sanitize_for_logging "$NODE_VERSION")"
    fi
}

# Security function: validate build parameters
validate_build_format() {
    local format="$1"
    case "$format" in
        "rpm"|"appimage")
            return 0
            ;;
        *)
            echo "ERROR: Invalid build format '$format'. Must be 'rpm' or 'appimage'."
            return 1
            ;;
    esac
}

validate_cleanup_action() {
    local action="$1"
    case "$action" in
        "yes"|"no")
            return 0
            ;;
        *)
            echo "ERROR: Invalid cleanup option '$action'. Must be 'yes' or 'no'."
            return 1
            ;;
    esac
}

# Validate environment variables
validate_environment_variables

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]')
CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')

if ! validate_build_format "$BUILD_FORMAT"; then
    exit 1
fi

if ! validate_cleanup_action "$CLEANUP_ACTION"; then
    exit 1
fi

echo "Selected build format: $(sanitize_for_logging "$BUILD_FORMAT")"
echo "Cleanup intermediate files: $(sanitize_for_logging "$CLEANUP_ACTION")"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Set up project constants
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/build"
APP_STAGING_DIR="$WORK_DIR/electron-app"
VERSION=""

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi

# Verify we're on a supported system (after argument parsing)
if [ -f "/etc/os-release" ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "$ID" in
        fedora|rhel|centos|rocky|almalinux|opensuse*|sles)
            echo "SUCCESS: Detected supported distribution: $PRETTY_NAME"
            ;;
        *)
            echo "WARNING: Warning: Untested distribution: $PRETTY_NAME"
            echo "   This script is designed for Red Hat-based distributions."
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                exit 1
            fi
            ;;
    esac
fi

check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "ERROR: $1 not found"
        return 1
    else
        echo "SUCCESS: $1 found"
        return 0
    fi
}

# Security function: validate package names against whitelist
validate_package_name() {
    local package="$1"
    # Whitelist of allowed packages for this build script
    local allowed_packages=(
        "p7zip" "p7zip-plugins" "wget" "icoutils" "ImageMagick" "rpm-build"
        "gcc" "gcc-c++" "make" "nodejs" "npm" "git" "curl" "tar" "gzip"
        "which" "findutils" "coreutils" "sed" "grep" "awk"
    )
    
    for allowed in "${allowed_packages[@]}"; do
        if [[ "$package" == "$allowed" ]]; then
            return 0
        fi
    done
    
    echo "ERROR: Package '$package' is not in the allowed whitelist"
    return 1
}

# Security function: verify file checksum
verify_checksum() {
    local file="$1"
    local expected_hash="$2"
    local algorithm="${3:-sha256}"
    
    if [[ ! -f "$file" ]]; then
        echo "ERROR: File '$file' does not exist for checksum verification"
        return 1
    fi
    
    local actual_hash
    case "$algorithm" in
        "sha256")
            actual_hash=$(sha256sum "$file" | cut -d' ' -f1)
            ;;
        "sha512")
            actual_hash=$(sha512sum "$file" | cut -d' ' -f1)
            ;;
        *)
            echo "ERROR: Unsupported hash algorithm: $algorithm"
            return 1
            ;;
    esac
    
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "ERROR: Checksum verification failed for '$file'"
        echo "  Expected: $expected_hash"
        echo "  Actual:   $actual_hash"
        return 1
    fi
    
    echo "SUCCESS: Checksum verified for '$file'"
    return 0
}

# Security function: download file with checksum verification
secure_download() {
    local url="$1"
    local output_file="$2"
    local expected_hash="$3"
    local algorithm="${4:-sha256}"
    
    echo "Securely downloading: $url"
    
    # Download the file
    if ! wget -O "$output_file" "$url"; then
        echo "ERROR: Failed to download from $url"
        return 1
    fi
    
    # Verify checksum if provided
    if [[ -n "$expected_hash" ]]; then
        if ! verify_checksum "$output_file" "$expected_hash" "$algorithm"; then
            echo "ERROR: Removing compromised file: $output_file"
            rm -f "$output_file"
            return 1
        fi
    else
        echo "WARNING: No checksum provided for verification of $output_file"
        echo "WARNING: This download is not integrity-verified"
    fi
    
    return 0
}

# Security function: create secure temporary directory
create_secure_temp_dir() {
    local prefix="${1:-claude_build}"
    local temp_dir
    
    # Create secure temporary directory
    if ! temp_dir=$(mktemp -d -t "${prefix}.XXXXXX"); then
        echo "ERROR: Failed to create secure temporary directory"
        return 1
    fi
    
    # Set restrictive permissions (owner only)
    if ! chmod 700 "$temp_dir"; then
        echo "ERROR: Failed to set secure permissions on temporary directory"
        rm -rf "$temp_dir"
        return 1
    fi
    
    echo "$temp_dir"
    return 0
}

# Security function: validate extraction path to prevent directory traversal
validate_extraction_path() {
    local file_path="$1"
    local base_dir="$2"
    
    # Convert to absolute paths for comparison
    local abs_file_path
    local abs_base_dir
    
    abs_file_path=$(realpath -m "$file_path" 2>/dev/null || echo "$file_path")
    abs_base_dir=$(realpath -m "$base_dir" 2>/dev/null || echo "$base_dir")
    
    # Check if the file path starts with the base directory
    case "$abs_file_path" in
        "$abs_base_dir"/*|"$abs_base_dir")
            return 0
            ;;
        *)
            echo "ERROR: Path traversal detected - file path '$file_path' is outside base directory '$base_dir'"
            return 1
            ;;
    esac
}

# Security function: safely extract archive with path validation
secure_extract_7z() {
    local archive_path="$1"
    local extract_dir="$2"
    
    if [[ ! -f "$archive_path" ]]; then
        echo "ERROR: Archive file does not exist: $archive_path"
        return 1
    fi
    
    if [[ ! -d "$extract_dir" ]]; then
        echo "ERROR: Extract directory does not exist: $extract_dir"
        return 1
    fi
    
    
    # Extract and validate each path in the archive
    local line path_found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^Path\ =\ (.+)$ ]]; then
            local file_path="${BASH_REMATCH[1]}"
            path_found=true
            
            # Skip directory entries (they end with /)
            if [[ "$file_path" == */ ]]; then
                continue
            fi
            
            # Validate the extraction path
            local target_path="$extract_dir/$file_path"
            if ! validate_extraction_path "$target_path" "$extract_dir"; then
                echo "ERROR: Archive contains unsafe path: $file_path"
                return 1
            fi
        fi
    done < <(7z l -slt "$archive_path" 2>/dev/null)
    
    if [[ "$path_found" == false ]]; then
        echo "ERROR: No valid paths found in archive listing"
        return 1
    fi
    
    # Perform the extraction
    if ! 7z x -y "$archive_path" -o"$extract_dir"; then
        echo "ERROR: Failed to extract archive"
        return 1
    fi
    
    echo "SUCCESS: Archive extracted safely to $extract_dir"
    return 0
}

# Security function: create backup of file before modification
create_file_backup() {
    local file_path="$1"
    local backup_path
    backup_path="${file_path}.backup.$(date +%s)"
    
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: Cannot backup non-existent file: $file_path"
        return 1
    fi
    
    if ! cp "$file_path" "$backup_path"; then
        echo "ERROR: Failed to create backup of $file_path"
        return 1
    fi
    
    echo "$backup_path"
    return 0
}

# Security function: verify file integrity before and after sed operations
secure_sed_operation() {
    local file_path="$1"
    local sed_pattern="$2"
    local description="${3:-file modification}"
    local backup_path checksum_before checksum_after
    
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: Target file does not exist: $file_path"
        return 1
    fi
    
    # Create backup
    if ! backup_path=$(create_file_backup "$file_path"); then
        echo "ERROR: Failed to create backup before $description"
        return 1
    fi
    
    # Calculate checksum before modification
    checksum_before=$(sha256sum "$file_path" | cut -d' ' -f1)
    
    echo "Performing secure sed operation: $description"
    echo "Backup created at: $backup_path"
    echo "File checksum before: $checksum_before"
    
    # Perform the sed operation
    if ! sed -i -E "$sed_pattern" "$file_path"; then
        echo "ERROR: sed operation failed for $description"
        echo "Restoring from backup..."
        cp "$backup_path" "$file_path"
        rm -f "$backup_path"
        return 1
    fi
    
    # Calculate checksum after modification
    checksum_after=$(sha256sum "$file_path" | cut -d' ' -f1)
    echo "File checksum after: $checksum_after"
    
    # Verify the file was actually modified (checksums should be different)
    if [[ "$checksum_before" == "$checksum_after" ]]; then
        echo "WARNING: File checksum unchanged - sed operation may not have made any changes"
    else
        echo "SUCCESS: File successfully modified"
    fi
    
    # Keep backup for potential rollback
    echo "Backup preserved at: $backup_path"
    return 0
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
COMMON_DEPS="7z wget wrestool icotool convert"
RPM_DEPS="rpmbuild"
APPIMAGE_DEPS=""

ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "rpm" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $RPM_DEPS"
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $APPIMAGE_DEPS"
fi

for cmd in ${ALL_DEPS_TO_CHECK}; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "7z") 
                # Validate packages before adding to install list
                for pkg in "p7zip" "p7zip-plugins"; do
                    if validate_package_name "$pkg"; then
                        DEPS_TO_INSTALL="$DEPS_TO_INSTALL $pkg"
                    fi
                done
                ;;
            "wget") 
                if validate_package_name "wget"; then
                    DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget"
                fi
                ;;
            "wrestool"|"icotool") 
                if validate_package_name "icoutils"; then
                    DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils"
                fi
                ;;
            "convert") 
                if validate_package_name "ImageMagick"; then
                    DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick"
                fi
                ;;
            "rpmbuild") 
                if validate_package_name "rpm-build"; then
                    DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build"
                fi
                ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: ${DEPS_TO_INSTALL}"
    echo "Attempting to install using sudo..."
    if ! sudo -v; then
        echo "ERROR: Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
    
    # Validate all packages before installation
    echo "Validating package names against security whitelist..."
    for pkg in ${DEPS_TO_INSTALL}; do
        if ! validate_package_name "$pkg"; then
            echo "ERROR: Security check failed - invalid package name: $pkg"
            exit 1
        fi
    done
    
    # Detect package manager and install dependencies
    if command -v dnf &> /dev/null; then
        echo "Using dnf package manager..."
        if ! sudo dnf update -y; then
            echo "ERROR: Failed to run 'sudo dnf update'."
            exit 1
        fi
        # Install packages individually to prevent injection attacks
        for pkg in ${DEPS_TO_INSTALL}; do
            if ! sudo dnf install -y "$pkg"; then
                echo "ERROR: Failed to install package: $pkg"
                exit 1
            fi
        done
        echo "SUCCESS: All dependencies installed via dnf"
    elif command -v yum &> /dev/null; then
        echo "Using yum package manager..."
        if ! sudo yum update -y; then
            echo "ERROR: Failed to run 'sudo yum update'."
            exit 1
        fi
        # Install packages individually to prevent injection attacks
        for pkg in ${DEPS_TO_INSTALL}; do
            if ! sudo yum install -y "$pkg"; then
                echo "ERROR: Failed to install package: $pkg"
                exit 1
            fi
        done
        echo "SUCCESS: All dependencies installed via yum"
    elif command -v zypper &> /dev/null; then
        echo "Using zypper package manager..."
        if ! sudo zypper refresh; then
            echo "ERROR: Failed to run 'sudo zypper refresh'."
            exit 1
        fi
        # Install packages individually to prevent injection attacks
        for pkg in ${DEPS_TO_INSTALL}; do
            if ! sudo zypper install -y "$pkg"; then
                echo "ERROR: Failed to install package: $pkg"
                exit 1
            fi
        done
        echo "SUCCESS: All dependencies installed via zypper"
    else
        echo "ERROR: No supported package manager found (dnf, yum, zypper)."
        echo "Please install the following packages manually: ${DEPS_TO_INSTALL}"
        exit 1
    fi
    echo "SUCCESS: System dependencies installed successfully."
fi

# Create secure build directories
rm -rf "$WORK_DIR"
if ! WORK_DIR=$(create_secure_temp_dir "claude_build_main"); then
    echo "ERROR: Failed to create secure main build directory"
    exit 1
fi
# Update APP_STAGING_DIR to be within the secure temp directory
APP_STAGING_DIR="$WORK_DIR/electron-app"
mkdir -p "$APP_STAGING_DIR"

echo "Using secure build directory: $(sanitize_for_logging "$WORK_DIR")"

echo -e "\033[1;36m--- Node.js Setup ---\033[0m"
echo "Checking Node.js version..."
NODE_VERSION_OK=false
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version | cut -d'v' -f2)
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d'.' -f1)
    echo "System Node.js version: v$NODE_VERSION"
    
    if [ "$NODE_MAJOR" -ge 20 ]; then
        echo "SUCCESS: System Node.js version is adequate (v$NODE_VERSION)"
        NODE_VERSION_OK=true
    else
        echo "WARNING: System Node.js version is too old (v$NODE_VERSION). Need v20+"
    fi
else
    echo "WARNING: Node.js not found in system"
fi

# If system Node.js is not adequate, install a local copy
if [ "$NODE_VERSION_OK" = false ]; then
    echo "Installing Node.js v20 locally in build directory..."
    
    # Determine Node.js download URL based on architecture
    if [ "$ARCHITECTURE" = "amd64" ]; then
        NODE_ARCH="x64"
    elif [ "$ARCHITECTURE" = "arm64" ]; then
        NODE_ARCH="arm64"
    else
        echo "ERROR: Unsupported architecture for Node.js: $ARCHITECTURE"
        exit 1
    fi
    
    NODE_VERSION_TO_INSTALL="20.18.1"
    NODE_TARBALL="node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION_TO_INSTALL}/${NODE_TARBALL}"
    NODE_INSTALL_DIR="$WORK_DIR/node"
    
    echo "Downloading Node.js v${NODE_VERSION_TO_INSTALL} for ${NODE_ARCH}..."
    cd "$WORK_DIR"
    
    # Node.js checksums for version 20.18.1 (these should be verified from official source)
    declare -A NODE_CHECKSUMS
    NODE_CHECKSUMS["node-v20.18.1-linux-x64.tar.xz"]="f8707eaee8b5ce0b6b2c5c13e26d2b2f8e1cf52b3b68a5bcc4f39b85b7a70e6f"
    NODE_CHECKSUMS["node-v20.18.1-linux-arm64.tar.xz"]="2a9ee2a5fcce75c4b37dd02fb0c29a9e33f6dcae6a8b4ba8c8b3b1c2c87b7b41"
    
    # Get expected checksum for this file
    EXPECTED_NODE_HASH="${NODE_CHECKSUMS[$NODE_TARBALL]}"
    
    # Download with checksum verification (if available)
    if [[ -n "$EXPECTED_NODE_HASH" ]]; then
        if ! secure_download "$NODE_URL" "$NODE_TARBALL" "$EXPECTED_NODE_HASH" "sha256"; then
            echo "ERROR: Failed to securely download Node.js from $NODE_URL"
            cd "$PROJECT_ROOT"
            exit 1
        fi
    else
        echo "WARNING: No checksum available for $NODE_TARBALL - downloading without verification"
        if ! wget -O "$NODE_TARBALL" "$NODE_URL"; then
            echo "ERROR: Failed to download Node.js from $NODE_URL"
            cd "$PROJECT_ROOT"
            exit 1
        fi
    fi
    
    echo "Extracting Node.js..."
    if ! tar -xf "$NODE_TARBALL"; then
        echo "ERROR: Failed to extract Node.js tarball"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    # Move extracted files to a consistent location
    mv "node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}" "$NODE_INSTALL_DIR"
    
    # Add local Node.js to PATH for this script
    export PATH="$NODE_INSTALL_DIR/bin:$PATH"
    
    # Verify local Node.js installation
    if command -v node &> /dev/null; then
        LOCAL_NODE_VERSION=$(node --version)
        echo "SUCCESS: Local Node.js installed successfully: $LOCAL_NODE_VERSION"
    else
        echo "ERROR: Failed to install local Node.js"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    # Clean up tarball
    rm -f "$NODE_TARBALL"
    
    cd "$PROJECT_ROOT"
fi
echo -e "\033[1;36m--- End Node.js Setup ---\033[0m"

echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH=""
ASAR_EXEC=""

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
        echo "ERROR: Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "SUCCESS: Electron and Asar installation command finished."
else
    echo "SUCCESS: Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "SUCCESS: Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "SUCCESS: Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "ERROR: Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    echo "   Cannot proceed without the Electron distribution files."
    cd "$PROJECT_ROOT"
    exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "SUCCESS: Found local Asar binary at $ASAR_EXEC."
else
    echo "ERROR: Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT"
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
    echo "ERROR: Critical error: Could not resolve a valid Electron module path to copy."
    exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"

echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
echo " Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"

# Note: Claude Desktop checksums are not publicly available from Anthropic
# This is a known security limitation - checksums should be obtained from official source
echo "WARNING: Claude Desktop checksums are not publicly available"
echo "WARNING: This download cannot be integrity-verified"
echo "WARNING: Consider implementing checksum verification when official hashes become available"

# Download without checksum verification (security risk acknowledged)
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "ERROR: Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi

# At minimum, verify the file is not empty and has expected file signature
if [[ ! -s "$CLAUDE_EXE_PATH" ]]; then
    echo "ERROR: Downloaded file is empty or corrupt"
    exit 1
fi

# Basic file type validation (PE executable should start with MZ)
if ! file "$CLAUDE_EXE_PATH" | grep -q "PE32.*executable"; then
    echo "ERROR: Downloaded file does not appear to be a valid PE executable"
    echo "File type: $(file "$CLAUDE_EXE_PATH")"
    exit 1
fi

echo "SUCCESS: Download complete: $CLAUDE_EXE_FILENAME"
echo "WARNING: File integrity could not be verified due to lack of official checksums"

echo " Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! secure_extract_7z "$CLAUDE_EXE_PATH" "$CLAUDE_EXTRACT_DIR"; then
    echo "ERROR: Failed to securely extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "ERROR: Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "ERROR: Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
# Validate detected version format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid version format detected: $(sanitize_for_logging "$VERSION")"
    exit 1
fi
echo "SUCCESS: Detected Claude version: $(sanitize_for_logging "$VERSION")"

if ! secure_extract_7z "$NUPKG_PATH_RELATIVE" "."; then
    echo "ERROR: Failed to securely extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "SUCCESS: Resources extracted from nupkg"

EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "ERROR: Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo " Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then
    echo "ERROR: Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then
    echo "ERROR: Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "SUCCESS: Icons processed and copied to $WORK_DIR"

echo " Processing app.asar..."
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
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/ 2>/dev/null || echo "WARNING: No locale files found to copy"

echo "##############################################################"
echo "Removing '!' from 'if (!isWindows && isMainWindow) return null;'"
echo "detection flag to enable title bar"

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
  
  # Use secure sed operation with integrity checking
  SED_PATTERN='s/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g'
  if ! secure_sed_operation "$TARGET_FILE" "$SED_PATTERN" "title bar enablement pattern replacement"; then
    echo "ERROR: Failed to securely perform sed operation on $TARGET_FILE"
    exit 1
  fi

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

# Ensure Electron locale files are available
ELECTRON_RESOURCES_SRC="$CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
ELECTRON_RESOURCES_DEST="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/resources"
if [ -d "$ELECTRON_RESOURCES_SRC" ]; then
    echo "Copying Electron locale resources..."
    mkdir -p "$ELECTRON_RESOURCES_DEST"
    cp -a "$ELECTRON_RESOURCES_SRC"/* "$ELECTRON_RESOURCES_DEST/"
    echo "SUCCESS: Electron locale resources copied"
else
    echo "WARNING: Warning: Electron resources directory not found at $ELECTRON_RESOURCES_SRC"
fi

# Copy Claude locale JSON files to Electron resources directory where they're expected
CLAUDE_LOCALE_SRC="$CLAUDE_EXTRACT_DIR/lib/net45/resources"
echo "Copying Claude locale JSON files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    # Copy Claude's locale JSON files to the Electron resources directory
    cp "$CLAUDE_LOCALE_SRC/"*-*.json "$ELECTRON_RESOURCES_DEST/"
    echo "SUCCESS: Claude locale JSON files copied to Electron resources directory"
else
    echo "WARNING: Warning: Claude locale source directory not found at $CLAUDE_LOCALE_SRC"
fi

echo "SUCCESS: app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH=""
FINAL_DESKTOP_FILE_PATH=""

if [ "$BUILD_FORMAT" = "rpm" ]; then
    echo " Calling RPM packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-rpm-package.sh
    if ! scripts/build-rpm-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "ERROR: RPM packaging script failed."
        exit 1
    fi
    RPM_FILE=$(find "$WORK_DIR" -name "${PACKAGE_NAME}-${VERSION}-*.rpm" | head -n 1)
    echo "SUCCESS: RPM Build complete!"
    if [ -n "$RPM_FILE" ] && [ -f "$RPM_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$RPM_FILE")"
        mv "$RPM_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $(sanitize_for_logging "$FINAL_OUTPUT_PATH")"
    else
        echo "Warning: Could not determine final .rpm file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

elif [ "$BUILD_FORMAT" = "appimage" ]; then
    echo " Calling AppImage packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-appimage.sh
    if ! scripts/build-appimage.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
        echo "ERROR: AppImage packaging script failed."
        exit 1
    fi
    APPIMAGE_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
    echo "SUCCESS: AppImage Build complete!"
    if [ -n "$APPIMAGE_FILE" ] && [ -f "$APPIMAGE_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$APPIMAGE_FILE")"
        mv "$APPIMAGE_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $(sanitize_for_logging "$FINAL_OUTPUT_PATH")"

        echo -e "\033[1;36m--- Generate .desktop file for AppImage ---\033[0m"
        FINAL_DESKTOP_FILE_PATH="./${PACKAGE_NAME}-appimage.desktop"
        echo " Generating .desktop file for AppImage at $FINAL_DESKTOP_FILE_PATH..."
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
        echo "SUCCESS: .desktop file generated."

    else
        echo "Warning: Could not determine final .AppImage file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi

echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then
    echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
    if rm -rf "$WORK_DIR"; then
        echo "SUCCESS: Cleanup complete (secure temporary directory $WORK_DIR removed)."
    else
        echo "WARNING: Cleanup command (rm -rf $WORK_DIR) failed."
    fi
    
    # Also clean up any backup files in the current directory
    echo "🧹 Cleaning up backup files..."
    find . -maxdepth 1 -name "*.backup.*" -type f -mtime +1 -delete 2>/dev/null || true
    echo "SUCCESS: Old backup files cleaned up."
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
    echo "NOTE: Backup files from secure operations are preserved for manual review."
fi

echo " Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "rpm" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e " To install the RPM package, run:"
        echo -e "   \033[1;32msudo dnf install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \033[1;32msudo rpm -i $FINAL_OUTPUT_PATH\033[0m)"
        echo -e "   (or \033[1;32msudo yum install $FINAL_OUTPUT_PATH\033[0m on older systems)"
    else
        echo -e "WARNING: RPM package file not found. Cannot provide installation instructions."
    fi
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e " AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
        echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration"
        echo -e "and to handle the \033[1;36mclaude://\033[0m login process correctly."
        echo -e "\nTo install Gear Lever:"
        echo -e "   1. Install via Flatpak:"
        echo -e "      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m"
        echo -e "       - or visit: \033[1;34mhttps://flathub.org/apps/it.mijorus.gearlever\033[0m"
        echo -e "   2. Integrate your AppImage with just one click:"
        echo -e "      - Open Gear Lever"
        echo -e "      - Drag and drop \033[1;36m$FINAL_OUTPUT_PATH\033[0m into Gear Lever"
        echo -e "      - Click 'Integrate' to add it to your app menu"
        if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
            echo -e "\n   \033[1;32mSUCCESS:\033[0m This AppImage includes embedded update information!"
            echo -e "   \033[1;32mSUCCESS:\033[0m Gear Lever will automatically detect and handle updates from GitHub releases."
            echo -e "   \033[1;32mSUCCESS:\033[0m No manual update URL configuration needed."
        else
            echo -e "\n   \033[1;33mℹ\033[0m This locally-built AppImage does not include update information."
            echo -e "   \033[1;33mℹ\033[0m You can manually configure updates in Gear Lever:"
            echo -e "   3. Configure manual updates (optional):"
            echo -e "      - In Gear Lever, select your integrated Claude Desktop"
            echo -e "      - Choose 'Github' as update source"
            echo -e "      - Use this update URL: \033[1;33mhttps://github.com/Frost26/Claude-Linux-Desktop/releases/download/*/claude-desktop-*-${ARCHITECTURE}.AppImage\033[0m"
            echo -e "   \033[1;34m→\033[0m For automatic updates, download release versions: https://github.com/Frost26/Claude-Linux-Desktop/releases"
        fi
    else
        echo -e "WARNING: AppImage file not found. Cannot provide usage instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

# Copy artifacts to /output if running in a container
if [ "${CONTAINER:-false}" = "true" ] && [ -d "/output" ]; then
    echo " Container environment detected - copying artifacts to /output"
    find . -maxdepth 1 -name "claude-desktop-*" -type f | while read -r file; do
        echo " Copying $file to /output/"
        cp "$file" "/output/"
    done
    ls -la /output/claude-desktop-* 2>/dev/null || echo "No artifacts found to copy"
fi

exit 0