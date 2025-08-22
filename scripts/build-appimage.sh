#!/bin/bash
set -e


# Security function: validate download URL to prevent URL injection
validate_download_url() {
    local url="$1"
    
    # Check for valid HTTPS URL from expected sources
    case "$url" in
        https://github.com/AppImage/AppImageKit/releases/download/*)
            return 0
            ;;
        *)
            echo "ERROR: Invalid or suspicious download URL: $url"
            return 1
            ;;
    esac
}

# Security function: secure file download with URL validation
secure_download_appimage_tool() {
    local url="$1"
    local output_path="$2"
    
    # Validate the URL first
    if ! validate_download_url "$url"; then
        echo "ERROR: URL validation failed for $url"
        return 1
    fi
    
    echo "Securely downloading appimagetool from: $url"
    
    # Download with wget using secure options
    if ! wget -q --no-check-certificate --timeout=30 --tries=3 -O "$output_path" "$url"; then
        echo "ERROR: Failed to download from $url"
        rm -f "$output_path" # Clean up partial download
        return 1
    fi
    
    # Verify the downloaded file is not empty
    if [[ ! -s "$output_path" ]]; then
        echo "ERROR: Downloaded file is empty or corrupt"
        rm -f "$output_path"
        return 1
    fi
    
    # Set executable permissions
    if ! chmod +x "$output_path"; then
        echo "ERROR: Failed to set executable permissions on $output_path"
        rm -f "$output_path"
        return 1
    fi
    
    echo "SUCCESS: Downloaded and verified appimagetool"
    return 0
}

# Security function: validate file path to prevent directory traversal
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

# Security function: safely copy files with path validation
secure_copy_file() {
    local source_path="$1"
    local dest_path="$2"
    local base_dir="$3"
    
    # Validate source file exists
    if [[ ! -e "$source_path" ]]; then
        echo "ERROR: Source file does not exist: $source_path"
        return 1
    fi
    
    # Validate destination path is within base directory
    if ! validate_file_path "$dest_path" "$base_dir"; then
        echo "ERROR: Destination path validation failed for $dest_path"
        return 1
    fi
    
    # Create destination directory if needed
    local dest_dir
    dest_dir=$(dirname "$dest_path")
    if [[ ! -d "$dest_dir" ]]; then
        if ! mkdir -p "$dest_dir"; then
            echo "ERROR: Failed to create destination directory: $dest_dir"
            return 1
        fi
    fi
    
    # Perform the copy operation
    if ! cp -a "$source_path" "$dest_path"; then
        echo "ERROR: Failed to copy $source_path to $dest_path"
        return 1
    fi
    
    echo "SUCCESS: Securely copied $source_path to $dest_path"
    return 0
}

# Security function: validate input parameters for AppImage build
validate_appimage_parameters() {
    local version="$1"
    local architecture="$2"
    local work_dir="$3"
    local app_staging_dir="$4"
    local package_name="$5"
    
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
    
    return 0
}

# Security function: sanitize string for safe logging
sanitize_for_logging() {
    local input="$1"
    # Remove or escape potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9._/-]/***/g'
}

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3" # The top-level build directory (e.g., ./build)
APP_STAGING_DIR="$4" # Directory containing the prepared app files (e.g., ./build/electron-app)
PACKAGE_NAME="$5"
# MAINTAINER and DESCRIPTION might not be directly used by AppImage tools but passed for consistency

# Validate all input parameters
if ! validate_appimage_parameters "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
    echo "ERROR: Parameter validation failed"
    exit 1
fi

echo "--- Starting AppImage Build ---"
echo "Version: $(sanitize_for_logging "$VERSION")"
echo "Architecture: $(sanitize_for_logging "$ARCHITECTURE")"
echo "Work Directory: $(sanitize_for_logging "$WORK_DIR")"
echo "App Staging Directory: $(sanitize_for_logging "$APP_STAGING_DIR")"
echo "Package Name: $(sanitize_for_logging "$PACKAGE_NAME")"

COMPONENT_ID="io.github.frost26.claude-linux-desktop"
# Define AppDir structure path
APPDIR_PATH="$WORK_DIR/${COMPONENT_ID}.AppDir"
rm -rf "$APPDIR_PATH"
mkdir -p "$APPDIR_PATH/usr/bin"
mkdir -p "$APPDIR_PATH/usr/lib"
mkdir -p "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$APPDIR_PATH/usr/share/applications"

echo " Staging application files into AppDir..."
# Copy the core application files (asar, unpacked resources, node_modules if present)
# Explicitly copy required components to ensure hidden files/dirs like .bin are included
if [ -f "$APP_STAGING_DIR/app.asar" ]; then
    if ! secure_copy_file "$APP_STAGING_DIR/app.asar" "$APPDIR_PATH/usr/lib/app.asar" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy app.asar"
        exit 1
    fi
fi
if [ -d "$APP_STAGING_DIR/app.asar.unpacked" ]; then
    if ! secure_copy_file "$APP_STAGING_DIR/app.asar.unpacked" "$APPDIR_PATH/usr/lib/app.asar.unpacked" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy app.asar.unpacked"
        exit 1
    fi
fi
if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying node_modules from staging to AppDir..."
    if ! secure_copy_file "$APP_STAGING_DIR/node_modules" "$APPDIR_PATH/usr/lib/node_modules" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy node_modules"
        exit 1
    fi
fi

# Ensure Electron is bundled within the AppDir for portability
# Check if electron was copied into the staging dir's node_modules
# The actual executable is usually inside the 'dist' directory
BUNDLED_ELECTRON_PATH="$APPDIR_PATH/usr/lib/node_modules/electron/dist/electron"
echo "Checking for executable at: $BUNDLED_ELECTRON_PATH"
if [ ! -x "$BUNDLED_ELECTRON_PATH" ]; then # Check if it exists and is executable
    echo "ERROR: Electron executable not found or not executable in staging area ($BUNDLED_ELECTRON_PATH)."
    echo "   AppImage requires Electron to be bundled. Ensure the main script copies it correctly."
    exit 1
fi
# Ensure the bundled electron is executable (redundant check, but safe)
chmod +x "$BUNDLED_ELECTRON_PATH"

# --- Create AppRun Script ---
echo " Creating AppRun script..."
# Note: We use $VERSION and $PACKAGE_NAME from the build script environment here
# They will be embedded into the AppRun script.
cat > "$APPDIR_PATH/AppRun" << EOF
#!/bin/bash
set -e

# Find the location of the AppRun script and the AppImage file itself
APPDIR=\$(dirname "\$0")
# Try to get the absolute path of the AppImage file being run
# $APPIMAGE is often set by the AppImage runtime, otherwise try readlink
APPIMAGE_PATH="\${APPIMAGE:-}"
if [ -z "\$APPIMAGE_PATH" ]; then
    # Find the AppRun script itself, which should be $0
    # Use readlink -f to get the absolute path, handling symlinks
    # Go up one level from AppRun's dir to get the AppImage path (usually)
    # This might be fragile if AppRun is not at the root, but it's standard.
    APPIMAGE_PATH=\$(readlink -f "\$APPDIR/../$(basename "$APPDIR_PATH" .AppDir).AppImage" 2>/dev/null || readlink -f "\$0" 2>/dev/null)
    # As a final fallback, just use $0, hoping it's the AppImage path
    if [ -z "\$APPIMAGE_PATH" ] || [ ! -f "\$APPIMAGE_PATH" ]; then
        APPIMAGE_PATH="\$0"
    fi
fi

# --- Desktop Integration (Handled by Gear Lever) ---
# The bundled .desktop file (claude-desktop-appimage.desktop) inside the AppImage
# contains the necessary MimeType=x-scheme-handler/claude; entry.
# Gear Lever (or similar tools) will use this file to integrate
# the AppImage with the system, including setting up the URI scheme handler,
# if the user chooses to integrate. No manual registration is needed here.
# --- End Desktop Integration ---


# Set up environment variables if needed (e.g., LD_LIBRARY_PATH)
# export LD_LIBRARY_PATH="\$APPDIR/usr/lib:\$LD_LIBRARY_PATH"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ -n "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
fi

# Path to the bundled Electron executable
# Use the path relative to AppRun within the 'electron/dist' module directory
ELECTRON_EXEC="\$APPDIR/usr/lib/node_modules/electron/dist/electron"
APP_PATH="\$APPDIR/usr/lib/app.asar"

# Base command arguments array
# Add --no-sandbox flag to avoid sandbox issues within AppImage
ELECTRON_ARGS=("--no-sandbox" "\$APP_PATH")

# Add Wayland flags if Wayland is detected
if [ "\$IS_WAYLAND" = true ]; then
  echo "AppRun: Wayland detected, adding flags."
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
fi

# Change to the application resources directory (where app.asar is)
cd "\$APPDIR/usr/lib" || exit 1

# Define log file path in user's home directory
LOG_FILE="\$HOME/claude-desktop-launcher.log"

# Change to HOME directory before exec'ing Electron to avoid CWD permission issues
cd "\$HOME" || exit 1

# Execute Electron with app path, flags, and script arguments passed to AppRun
# Redirect stdout and stderr to the log file (append)
echo "AppRun: Executing \$ELECTRON_EXEC \${ELECTRON_ARGS[@]} \$@ >> \$LOG_FILE 2>&1"
exec "\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EOF
chmod +x "$APPDIR_PATH/AppRun"
echo "SUCCESS: AppRun script created (with logging to \$HOME/claude-desktop-launcher.log, --no-sandbox, and CWD set to \$HOME)"

# --- Create Desktop Entry (Bundled inside AppDir) ---
echo " Creating bundled desktop entry..."
# This is the desktop file *inside* the AppImage, used by tools like appimaged
cat > "$APPDIR_PATH/$COMPONENT_ID.desktop" << EOF
[Desktop Entry]
Name=Claude
Comment=AI Assistant Desktop Application
Exec=AppRun %u
Icon=$COMPONENT_ID
Type=Application
Version=1.5
Terminal=false
Categories=Network;Utility;Office;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
StartupNotify=true
NoDisplay=false
X-Desktop-File-Install-Version=0.27
X-Security-PolicyVersion=1.0
X-Permissions=network,user-dirs
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop
Keywords=AI;Assistant;Chat;Claude;
EOF
# Also place it in the standard location for tools like appimaged and validation
mkdir -p "$APPDIR_PATH/usr/share/applications"
if ! secure_copy_file "$APPDIR_PATH/$COMPONENT_ID.desktop" "$APPDIR_PATH/usr/share/applications/${COMPONENT_ID}.desktop" "$APPDIR_PATH"; then
    echo "ERROR: Failed to securely copy desktop file to usr/share/applications"
    exit 1
fi
echo "SUCCESS: Bundled desktop entry created and securely copied to usr/share/applications/"

# --- Copy Icons ---
echo " Copying icons..."
# Use the 256x256 icon as the main AppImage icon
ICON_SOURCE_PATH="$WORK_DIR/claude_6_256x256x32.png"
if [ -f "$ICON_SOURCE_PATH" ]; then
    # Standard location within AppDir
    if ! secure_copy_file "$ICON_SOURCE_PATH" "$APPDIR_PATH/usr/share/icons/hicolor/256x256/apps/${COMPONENT_ID}.png" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy icon to standard location"
        exit 1
    fi
    # Top-level icon (used by appimagetool) - Should match the Icon field in the .desktop file
    if ! secure_copy_file "$ICON_SOURCE_PATH" "$APPDIR_PATH/${COMPONENT_ID}.png" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy top-level icon (.png)"
        exit 1
    fi
    # Top-level icon without extension (fallback for some tools)
    if ! secure_copy_file "$ICON_SOURCE_PATH" "$APPDIR_PATH/${COMPONENT_ID}" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy top-level icon (no ext)"
        exit 1
    fi
    # Hidden .DirIcon (fallback for some systems/tools)
    if ! secure_copy_file "$ICON_SOURCE_PATH" "$APPDIR_PATH/.DirIcon" "$APPDIR_PATH"; then
        echo "ERROR: Failed to securely copy .DirIcon"
        exit 1
    fi
    echo "SUCCESS: Icons securely copied to all required locations"
else
    echo "Warning: Missing 256x256 icon at $ICON_SOURCE_PATH. AppImage icon might be missing."
fi

# --- Create AppStream Metadata ---
echo " Creating AppStream metadata..."
METADATA_DIR="$APPDIR_PATH/usr/share/metainfo"
mkdir -p "$METADATA_DIR"

# Use the package name for the appdata file name (seems required by appimagetool warning)
# Use reverse-DNS for component ID and filename, following common practice
APPDATA_FILE="$METADATA_DIR/${COMPONENT_ID}.appdata.xml" # Filename matches component ID

# Generate the AppStream XML file
# Use MIT license based on LICENSE-MIT file in repo
# ID follows reverse DNS convention
cat > "$APPDATA_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$COMPONENT_ID</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer id="io.github.frost26">
    <name>Frost26</name>
  </developer>

  <name>Claude Desktop</name>
  <summary>Unofficial desktop client for Claude AI</summary>

  <description>
    <p>
      Provides a desktop experience for interacting with Claude AI, wrapping the web interface.
    </p>
  </description>

  <launchable type="desktop-id">${COMPONENT_ID}.desktop</launchable> <!-- Reference the actual .desktop file -->

  <icon type="stock">${COMPONENT_ID}</icon> <!-- Use the icon name from .desktop -->
  <url type="homepage">https://github.com/Frost26/Claude-Linux-Desktop</url>
  <screenshots>
      <screenshot type="default">
          <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>
      </screenshot>
  </screenshots>
  <provides>
    <binary>AppRun</binary> <!-- Provide the actual binary -->
  </provides>

  <categories>
    <category>Network</category>
    <category>Utility</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$VERSION" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $VERSION.</p>
      </description>
    </release>
  </releases>

</component>
EOF
echo "SUCCESS: AppStream metadata created at $APPDATA_FILE"


# --- Get appimagetool ---
APPIMAGETOOL_PATH=""
if command -v appimagetool &> /dev/null; then
    APPIMAGETOOL_PATH=$(command -v appimagetool)
    echo "SUCCESS: Found appimagetool in PATH: $(sanitize_for_logging "$APPIMAGETOOL_PATH")"
elif [ -f "$WORK_DIR/appimagetool-x86_64.AppImage" ]; then # Check for specific arch first
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-x86_64.AppImage"
    echo "SUCCESS: Found downloaded x86_64 appimagetool: $(sanitize_for_logging "$APPIMAGETOOL_PATH")"
elif [ -f "$WORK_DIR/appimagetool-aarch64.AppImage" ]; then # Check for other arch
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-aarch64.AppImage"
    echo "SUCCESS: Found downloaded aarch64 appimagetool: $(sanitize_for_logging "$APPIMAGETOOL_PATH")"
else
    echo "Downloading appimagetool..."
    # Determine architecture for download URL
    TOOL_ARCH=""
    case "$ARCHITECTURE" in # Use target ARCHITECTURE passed to script
        "amd64") TOOL_ARCH="x86_64" ;;
        "arm64") TOOL_ARCH="aarch64" ;;
        *) echo "ERROR: Unsupported architecture for appimagetool download: $ARCHITECTURE"; exit 1 ;;
    esac

    APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${TOOL_ARCH}.AppImage"
    APPIMAGETOOL_PATH="$WORK_DIR/appimagetool-${TOOL_ARCH}.AppImage"

    if secure_download_appimage_tool "$APPIMAGETOOL_URL" "$APPIMAGETOOL_PATH"; then
        echo "SUCCESS: Securely downloaded appimagetool to $(sanitize_for_logging "$APPIMAGETOOL_PATH")"
    else
        echo "ERROR: Failed to securely download appimagetool from $(sanitize_for_logging "$APPIMAGETOOL_URL")"
        exit 1
    fi
fi

# --- Build AppImage ---
echo " Building AppImage..."
OUTPUT_FILENAME="${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage"
OUTPUT_PATH="$WORK_DIR/$OUTPUT_FILENAME"

# --- Prepare Update Information (GitHub Actions only) ---
# Check if running in GitHub Actions workflow
if [ "$GITHUB_ACTIONS" = "true" ]; then
    echo " Running in GitHub Actions - embedding update information for automatic updates..."
    
    # Check if zsyncmake is available (required for generating .zsync files)
    if ! command -v zsyncmake &> /dev/null; then
        echo "WARNING: zsyncmake not found. Installing zsync package for .zsync file generation..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y zsync
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y zsync
        elif command -v zypper &> /dev/null; then
            sudo zypper install -y zsync
        else
            echo "WARNING: Cannot install zsync automatically. .zsync files may not be generated."
        fi
    fi

    # Format: gh-releases-zsync|<username>|<repository>|<tag>|<filename-pattern>
    # Using 'latest' tag to always point to the most recent release
    UPDATE_INFO="gh-releases-zsync|Frost26|Claude-Linux-Desktop|latest|claude-desktop-*-${ARCHITECTURE}.AppImage.zsync"
    echo "Update info: $(sanitize_for_logging "$UPDATE_INFO")"

    # Execute appimagetool with update information
    export ARCH="$ARCHITECTURE"
    echo "Using ARCH=$ARCH" # Debug output
    # Use --appimage-extract-and-run if appimagetool is an AppImage (for Docker/FUSE-less environments)
    if [[ "$APPIMAGETOOL_PATH" == *.AppImage ]]; then
        if "$APPIMAGETOOL_PATH" --appimage-extract-and-run --updateinformation "$UPDATE_INFO" "$APPDIR_PATH" "$OUTPUT_PATH"; then
            echo "SUCCESS: AppImage built successfully with embedded update info: $(sanitize_for_logging "$OUTPUT_PATH")"
            # Check if zsync file was generated
            ZSYNC_FILE="${OUTPUT_PATH}.zsync"
            if [ -f "$ZSYNC_FILE" ]; then
                echo "SUCCESS: zsync file generated: $(sanitize_for_logging "$ZSYNC_FILE")"
                echo "zsync file will be included in release artifacts"
            else
                echo "WARNING: zsync file not generated (zsyncmake may not be installed)"
            fi
        else
            echo "ERROR: Failed to build AppImage using $APPIMAGETOOL_PATH --appimage-extract-and-run"
            exit 1
        fi
    else
        # Use regular execution for system-installed appimagetool
        if "$APPIMAGETOOL_PATH" --updateinformation "$UPDATE_INFO" "$APPDIR_PATH" "$OUTPUT_PATH"; then
            echo "SUCCESS: AppImage built successfully with embedded update info: $(sanitize_for_logging "$OUTPUT_PATH")"
            # Check if zsync file was generated
            ZSYNC_FILE="${OUTPUT_PATH}.zsync"
            if [ -f "$ZSYNC_FILE" ]; then
                echo "SUCCESS: zsync file generated: $(sanitize_for_logging "$ZSYNC_FILE")"
                echo "zsync file will be included in release artifacts"
            else
                echo "WARNING: zsync file not generated (zsyncmake may not be installed)"
            fi
        else
            echo "ERROR: Failed to build AppImage using $APPIMAGETOOL_PATH"
            exit 1
        fi
    fi
else
    echo " Running locally - building AppImage without update information"
    echo "   (Update info and zsync files are only generated in GitHub Actions for releases)"
    
    # Execute appimagetool without update information
    export ARCH="$ARCHITECTURE"
    echo "Using ARCH=$ARCH" # Debug output
    # Use --appimage-extract-and-run if appimagetool is an AppImage (for Docker/FUSE-less environments)
    if [[ "$APPIMAGETOOL_PATH" == *.AppImage ]]; then
        if "$APPIMAGETOOL_PATH" --appimage-extract-and-run "$APPDIR_PATH" "$OUTPUT_PATH"; then
            echo "SUCCESS: AppImage built successfully: $(sanitize_for_logging "$OUTPUT_PATH")"
        else
            echo "ERROR: Failed to build AppImage using $APPIMAGETOOL_PATH --appimage-extract-and-run"
            exit 1
        fi
    else
        # Use regular execution for system-installed appimagetool
        if "$APPIMAGETOOL_PATH" "$APPDIR_PATH" "$OUTPUT_PATH"; then
            echo "SUCCESS: AppImage built successfully: $(sanitize_for_logging "$OUTPUT_PATH")"
        else
            echo "ERROR: Failed to build AppImage using $APPIMAGETOOL_PATH"
            exit 1
        fi
    fi
fi

echo "--- AppImage Build Finished ---"

exit 0