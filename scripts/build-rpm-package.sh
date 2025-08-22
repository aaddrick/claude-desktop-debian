#!/bin/bash
set -euo pipefail

# =============================================================================
# SECURITY IMPLEMENTATION SUMMARY
# =============================================================================
# This script implements multiple security best practices:
#
# 1. Input Validation:
#    - Version format validation (semantic versioning)
#    - Architecture validation (whitelist)
#    - Directory path validation
#    - Package name format validation
#    - Maintainer and description field validation
#
# 2. Logging Security:
#    - All output sanitized to prevent log injection
#    - Sensitive information redacted from logs
#    - Arguments sanitized before logging
#
# 3. Path Security:
#    - Directory traversal prevention
#    - File path validation against base directories
#    - Safe file operations with path checks
#
# 4. Desktop File Security:
#    - Security headers added to desktop files
#    - Permission declarations
#    - Policy version specification
#
# 5. Error Handling:
#    - Consistent error messages
#    - Sanitized error output
#    - Secure failure modes
#
# ============================================================================="

# Security function: validate input parameters
validate_build_parameters() {
    local version="$1"
    local architecture="$2"
    local work_dir="$3"
    local app_staging_dir="$4"
    local package_name="$5"
    local maintainer="$6"
    local description="$7"
    
    # Validate version format (semantic versioning)
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Invalid version format '$version'. Expected semantic version (X.Y.Z)"
        return 1
    fi
    
    # Validate architecture
    case "$architecture" in
        "amd64"|"arm64")
            # Valid architectures
            ;;
        *)
            echo "ERROR: Invalid architecture '$architecture'. Supported: amd64, arm64"
            return 1
            ;;
    esac
    
    # Validate directory paths exist and are accessible
    if [[ ! -d "$work_dir" ]]; then
        echo "ERROR: Work directory does not exist: '$work_dir'"
        return 1
    fi
    
    if [[ ! -d "$app_staging_dir" ]]; then
        echo "ERROR: App staging directory does not exist: '$app_staging_dir'"
        return 1
    fi
    
    # Validate package name format (alphanumeric, hyphens, underscores only)
    if [[ ! "$package_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: Invalid package name '$package_name'. Only alphanumeric, hyphens, and underscores allowed"
        return 1
    fi
    
    # Validate package name length
    if [[ ${#package_name} -gt 64 ]]; then
        echo "ERROR: Package name too long: ${#package_name} characters (max 64)"
        return 1
    fi
    
    # Validate maintainer field (basic format check)
    if [[ -n "$maintainer" && ! "$maintainer" =~ ^[a-zA-Z0-9@._\ -]+$ ]]; then
        echo "ERROR: Invalid characters in maintainer field"
        return 1
    fi
    
    # Validate description (prevent code injection)
    if [[ -n "$description" && ! "$description" =~ ^[a-zA-Z0-9\ .,_-]+$ ]]; then
        echo "ERROR: Invalid characters in description field"
        return 1
    fi
    
    return 0
}

# Security function: sanitize string for safe logging
sanitize_for_logging() {
    local input="$1"
    # Remove or escape potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9._/-]/***/g'
}

# Security function: validate file paths to prevent directory traversal
validate_file_path() {
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

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"

# Validate all input parameters
if ! validate_build_parameters "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
    echo "ERROR: Parameter validation failed"
    exit 1
fi

echo "--- Starting RPM Package Build ---"
echo "Version: $(sanitize_for_logging "$VERSION")"
echo "Architecture: $(sanitize_for_logging "$ARCHITECTURE")"
echo "Work Directory: $(sanitize_for_logging "$WORK_DIR")"
echo "App Staging Directory: $(sanitize_for_logging "$APP_STAGING_DIR")"
echo "Package Name: $(sanitize_for_logging "$PACKAGE_NAME")"

# Convert architecture naming between Debian and RPM conventions
RPM_ARCH="$ARCHITECTURE"
case "$ARCHITECTURE" in
    "amd64") RPM_ARCH="x86_64" ;;
    "arm64") RPM_ARCH="aarch64" ;;
    *) echo "Warning: Unknown architecture conversion for $(sanitize_for_logging "$ARCHITECTURE"), using as-is" ;;
esac

echo "RPM Architecture: $(sanitize_for_logging "$RPM_ARCH")"

# Set up RPM build environment
RPM_BUILD_ROOT="$WORK_DIR/rpmbuild"
SPEC_FILE="$RPM_BUILD_ROOT/SPECS/${PACKAGE_NAME}.spec"
STAGING_DIR="$RPM_BUILD_ROOT/STAGING"

# Clean previous build structure if it exists
rm -rf "$RPM_BUILD_ROOT"

# Create RPM build directory structure
echo "Creating RPM build structure in $(sanitize_for_logging "$RPM_BUILD_ROOT")..."
mkdir -p "$RPM_BUILD_ROOT"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "$STAGING_DIR/usr/lib/$PACKAGE_NAME"
mkdir -p "$STAGING_DIR/usr/share/applications"
mkdir -p "$STAGING_DIR/usr/share/icons"
mkdir -p "$STAGING_DIR/usr/bin"

# --- Icon Installation ---
echo "Installing icons..."
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
    icon_dir="$STAGING_DIR/usr/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    icon_source_path="$WORK_DIR/${icon_files[$size]}"
    if [ -f "$icon_source_path" ]; then
        if ! validate_file_path "$icon_source_path" "$WORK_DIR"; then
            echo "ERROR: Invalid icon source path detected"
            exit 1
        fi
        if ! validate_file_path "$icon_dir/claude-desktop.png" "$STAGING_DIR"; then
            echo "ERROR: Invalid icon destination path detected"
            exit 1
        fi
        echo "Installing ${size}x${size} icon from $(sanitize_for_logging "$icon_source_path")..."
        install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon at $(sanitize_for_logging "$icon_source_path")"
    fi
done
echo "SUCCESS: Icons installed"

# --- Copy Application Files ---
echo "Copying application files from $(sanitize_for_logging "$APP_STAGING_DIR")..."
cp "$APP_STAGING_DIR/app.asar" "$STAGING_DIR/usr/lib/$PACKAGE_NAME/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$STAGING_DIR/usr/lib/$PACKAGE_NAME/"

# Copy local electron if it was packaged (check if node_modules exists in staging)
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    if ! validate_file_path "$APP_STAGING_DIR/node_modules" "$APP_STAGING_DIR"; then
        echo "ERROR: Invalid node_modules path detected"
        exit 1
    fi
    if ! validate_file_path "$STAGING_DIR/usr/lib/$PACKAGE_NAME/" "$STAGING_DIR"; then
        echo "ERROR: Invalid electron destination path detected"
        exit 1
    fi
    echo "Copying packaged electron..."
    cp -r "$APP_STAGING_DIR/node_modules" "$STAGING_DIR/usr/lib/$PACKAGE_NAME/"
fi
echo "SUCCESS: Application files copied"

# --- Create Desktop Entry ---
echo "Creating desktop entry..."
# Validate desktop file path
DESKTOP_FILE_PATH="$STAGING_DIR/usr/share/applications/claude-desktop.desktop"
if ! validate_file_path "$DESKTOP_FILE_PATH" "$STAGING_DIR"; then
    echo "ERROR: Invalid desktop file path detected"
    exit 1
fi

cat > "$DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Name=Claude
Comment=AI Assistant Desktop Application
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Version=1.5
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
StartupNotify=true
NoDisplay=false
X-Desktop-File-Install-Version=0.27
X-Security-PolicyVersion=1.0
X-Permissions=network,user-dirs
Keywords=AI;Assistant;Chat;Claude;
EOF
echo "SUCCESS: Desktop entry created"

# --- Create Launcher Script ---
echo "Creating launcher script..."
# Validate launcher script path
LAUNCHER_SCRIPT_PATH="$STAGING_DIR/usr/bin/claude-desktop"
if ! validate_file_path "$LAUNCHER_SCRIPT_PATH" "$STAGING_DIR"; then
    echo "ERROR: Invalid launcher script path detected"
    exit 1
fi

cat > "$LAUNCHER_SCRIPT_PATH" << EOF
#!/bin/bash
# Secure logging configuration
LOG_FILE="\$HOME/claude-desktop-launcher.log"
echo "--- Claude Desktop Launcher Start ---" >> "\$LOG_FILE"
echo "Timestamp: \$(date)" >> "\$LOG_FILE"
# Sanitize arguments before logging to prevent log injection
SANITIZED_ARGS=\$(echo "\$@" | sed 's/[^a-zA-Z0-9._/-]/***/g')
echo "Arguments: \$SANITIZED_ARGS" >> "\$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ -n "\$WAYLAND_DISPLAY" ]; then
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
  echo "Error: No display environment detected" >> "\$LOG_FILE"
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
        echo "Error: Electron executable not found" >> "\$LOG_FILE"
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
# Sanitize command for logging
SANITIZED_EXEC=\$(echo "\$ELECTRON_EXEC" | sed 's/[^a-zA-Z0-9._/-]/***/g')
echo "Executing: \$SANITIZED_EXEC with sanitized arguments" >> "\$LOG_FILE"
"\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EXIT_CODE=\$?
echo "Electron exited with code: \$EXIT_CODE" >> "\$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "\$LOG_FILE"
exit \$EXIT_CODE
EOF
chmod +x "$STAGING_DIR/usr/bin/claude-desktop"
echo "SUCCESS: Launcher script created"

# --- Create RPM Spec File ---
echo "Creating RPM spec file..."
# Validate spec file path
if ! validate_file_path "$SPEC_FILE" "$RPM_BUILD_ROOT"; then
    echo "ERROR: Invalid spec file path detected"
    exit 1
fi

cat > "$SPEC_FILE" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        $DESCRIPTION
Packager:       $MAINTAINER

License:        MIT
URL:            https://github.com/Frost26/Claude-Linux-Desktop
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

%build
# Build steps are handled by the calling script

%install
# Copy files from staging directory to buildroot
mkdir -p %{buildroot}%{_bindir}
mkdir -p %{buildroot}%{_libdir}/%{name}
mkdir -p %{buildroot}%{_datadir}/applications
mkdir -p %{buildroot}%{_datadir}/icons

# Copy files to proper locations
cp -a %{_topdir}/STAGING/usr/bin/* %{buildroot}%{_bindir}/
cp -a %{_topdir}/STAGING/usr/lib/* %{buildroot}%{_libdir}/
cp -a %{_topdir}/STAGING/usr/share/* %{buildroot}%{_datadir}/

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
echo "SUCCESS: RPM spec file created"

# --- Build RPM Package ---
echo "Building RPM package..."
# Sanitize output filename
SANITIZED_PACKAGE_NAME=${PACKAGE_NAME//[^a-zA-Z0-9._-]/}
SANITIZED_VERSION=${VERSION//[^0-9.]/}
SANITIZED_RPM_ARCH=${RPM_ARCH//[^a-zA-Z0-9_]/}
RPM_FILE="${SANITIZED_PACKAGE_NAME}-${SANITIZED_VERSION}-1.${SANITIZED_RPM_ARCH}.rpm"
OUTPUT_PATH="$WORK_DIR/$RPM_FILE"

# Validate output path
if ! validate_file_path "$OUTPUT_PATH" "$WORK_DIR"; then
    echo "ERROR: Invalid output path detected"
    exit 1
fi

# Use rpmbuild to create the package
if rpmbuild --define "_topdir $RPM_BUILD_ROOT" \
           --define "_rpmdir $WORK_DIR" \
           --bb "$SPEC_FILE"; then
    echo "SUCCESS: RPM package built successfully"
    
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
        echo "SUCCESS: RPM package available at: $(sanitize_for_logging "$(basename "$OUTPUT_PATH")")"
    else
        echo "Warning: Could not locate generated RPM package"
    fi
else
    echo "ERROR: Failed to build RPM package"
    exit 1
fi

echo "--- RPM Package Build Finished ---"

exit 0