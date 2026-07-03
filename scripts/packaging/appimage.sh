#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"
# MAINTAINER and DESCRIPTION might not be directly used by AppImage tools
# but passed for consistency

echo '--- Starting AppImage Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

component_id='io.github.aaddrick.claude-desktop-debian'
# Define AppDir structure path
appdir_path="$work_dir/${component_id}.AppDir"
rm -rf "$appdir_path"
mkdir -p "$appdir_path/usr/bin" || exit 1
mkdir -p "$appdir_path/usr/lib" || exit 1
mkdir -p "$appdir_path/usr/share/icons/hicolor/256x256/apps" || exit 1
mkdir -p "$appdir_path/usr/share/applications" || exit 1

echo 'Staging application files into AppDir...'
# The staging dir is the extracted official usr/lib/claude-desktop tree
# (Electron ELF, chrome-sandbox, resources/, locales/, ...); ship it as-is.
mkdir -p "$appdir_path/usr/lib/claude-desktop" || exit 1
cp -a "$app_staging_dir/." "$appdir_path/usr/lib/claude-desktop/" || exit 1
echo 'Official application tree copied'

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$(dirname "$script_dir")/launcher-common.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "$appdir_path/usr/lib/claude-desktop/launcher-common.sh"
cp "$(dirname "$script_dir")/doctor.sh" "$appdir_path/usr/lib/claude-desktop/" || exit 1
echo 'Shared launcher library + doctor copied'

# Ensure the official binary made it into the AppDir
bundled_app_path="$appdir_path/usr/lib/claude-desktop/claude-desktop"
echo "Checking for executable at: $bundled_app_path"
if [[ ! -f $bundled_app_path ]]; then
	echo 'Claude Desktop binary not found in staging area.' >&2
	echo "Path checked: $bundled_app_path" >&2
	exit 1
fi
chmod +x "$bundled_app_path" || exit 1

# --- Create AppRun Script ---
echo 'Creating AppRun script...'
cat > "$appdir_path/AppRun" << 'EOF'
#!/usr/bin/env bash

# Find the location of the AppRun script
appdir=$(dirname "$(readlink -f "$0")")

# Source shared launcher library
source "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# The official Electron binary; it auto-loads the co-located
# resources/app.asar, so no app path is ever passed (issue #696).
app_exec="$appdir/usr/lib/claude-desktop/claude-desktop"

# Handle --doctor flag before anything else
if [[ "${1:-}" == '--doctor' ]]; then
	run_doctor "$app_exec"
	exit $?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env

cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_cowork_socket

# Detect display backend
detect_display_backend

# Log startup info
log_message '--- Claude Desktop AppImage Start ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"
log_message "APPDIR: $appdir"
log_session_env

# Build Chromium switches (appimage mode adds --no-sandbox for FUSE)
build_electron_args 'appimage'

# Change to HOME directory before exec'ing the app to avoid CWD permission issues
cd "$HOME" || exit 1

# Execute the official binary and keep AppRun alive so explicit quit can
# clean up Desktop-owned helpers that outlive the main process.
log_message "Executing: $app_exec ${electron_args[*]} $*"
run_electron_and_cleanup "$app_exec" "${electron_args[@]}" "$@"
exit $?
EOF
chmod +x "$appdir_path/AppRun" || exit 1
echo 'AppRun script created'

# --- Create Desktop Entry (Bundled inside AppDir) ---
echo 'Creating bundled desktop entry...'
# This is the desktop file *inside* the AppImage, used by tools like appimaged
cat > "$appdir_path/$component_id.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=AppRun %u
Icon=$component_id
Type=Application
Terminal=false
Categories=Network;Utility;
Comment=Claude Desktop for Linux
MimeType=x-scheme-handler/claude;
StartupWMClass=$WM_CLASS
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop
EOF
# Also place it in the standard location for tools like appimaged and validation
mkdir -p "$appdir_path/usr/share/applications" || exit 1
cp "$appdir_path/$component_id.desktop" "$appdir_path/usr/share/applications/" || exit 1
echo 'Bundled desktop entry created and copied to usr/share/applications/'

# --- Copy Icons ---
echo 'Copying icons...'
# Use the official 256x256 hicolor icon as the main AppImage icon
icon_source_path="${CLAUDE_EXTRACT_DIR:?}/usr/share/icons/hicolor/256x256/apps/claude-desktop.png"
if [[ -f $icon_source_path ]]; then
	# Standard location within AppDir
	cp "$icon_source_path" "$appdir_path/usr/share/icons/hicolor/256x256/apps/${component_id}.png" || exit 1
	# Top-level icon (used by appimagetool) - Should match the Icon field in .desktop
	cp "$icon_source_path" "$appdir_path/${component_id}.png" || exit 1
	# Top-level icon without extension (fallback for some tools)
	cp "$icon_source_path" "$appdir_path/${component_id}" || exit 1
	# Hidden .DirIcon (fallback for some systems/tools)
	cp "$icon_source_path" "$appdir_path/.DirIcon" || exit 1
	echo 'Icon copied to standard path, top-level (.png and no ext), and .DirIcon'
else
	echo "Warning: Missing 256x256 icon at $icon_source_path. AppImage icon might be missing."
fi

# --- Create AppStream Metadata ---
echo 'Creating AppStream metadata...'
metadata_dir="$appdir_path/usr/share/metainfo"
mkdir -p "$metadata_dir" || exit 1

# Use the package name for the appdata file name (seems required by appimagetool warning)
# Use reverse-DNS for component ID and filename, following common practice
appdata_file="$metadata_dir/${component_id}.appdata.xml"

# Generate the AppStream XML file
# project_license describes the app the user launches (the proprietary
# Claude binary), not the MIT packaging scripts
# ID follows reverse DNS convention
cat > "$appdata_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$component_id</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <developer id="io.github.aaddrick">
    <name>aaddrick</name>
  </developer>

  <name>Claude Desktop</name>
  <summary>Unofficial desktop client for Claude AI</summary>

  <description>
    <p>
      Provides a desktop experience for interacting with Claude AI, wrapping the web interface.
    </p>
  </description>

  <launchable type="desktop-id">${component_id}.desktop</launchable>

  <icon type="stock">${component_id}</icon>
  <url type="homepage">https://github.com/aaddrick/claude-desktop-debian</url>
  <screenshots>
      <screenshot type="default">
          <image>https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45</image>
      </screenshot>
  </screenshots>
  <provides>
    <binary>AppRun</binary>
  </provides>

  <categories>
    <category>Network</category>
    <category>Utility</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$version" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $version.</p>
      </description>
    </release>
  </releases>

</component>
EOF
echo "AppStream metadata created at $appdata_file"


# --- Get appimagetool ---
appimagetool_path=''

# Check system PATH first
if command -v appimagetool &> /dev/null; then
	appimagetool_path=$(command -v appimagetool)
	echo "Found appimagetool in PATH: $appimagetool_path"
fi

# Check for previously downloaded versions
for arch in x86_64 aarch64; do
	[[ -n $appimagetool_path ]] && break
	local_path="$work_dir/appimagetool-${arch}.AppImage"
	if [[ -f $local_path ]]; then
		appimagetool_path="$local_path"
		echo "Found downloaded ${arch} appimagetool: $appimagetool_path"
	fi
done

# Download if not found
if [[ -z $appimagetool_path ]]; then
	echo 'Downloading appimagetool...'
	case "$architecture" in
		amd64) tool_arch='x86_64' ;;
		arm64) tool_arch='aarch64' ;;
		*)
			echo "Unsupported architecture for appimagetool download: $architecture" >&2
			exit 1
			;;
	esac

	appimagetool_url="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${tool_arch}.AppImage"
	appimagetool_path="$work_dir/appimagetool-${tool_arch}.AppImage"

	if wget -q -O "$appimagetool_path" "$appimagetool_url"; then
		chmod +x "$appimagetool_path" || exit 1
		echo "Downloaded appimagetool to $appimagetool_path"
	else
		echo "Failed to download appimagetool from $appimagetool_url" >&2
		rm -f "$appimagetool_path"
		exit 1
	fi
fi

# Normalize AppDir permissions before squashing. The staging copy above
# uses `cp -a`, which preserves source modes, and a restrictive build
# umask can leave directories at 0700. mksquashfs records those verbatim,
# so a user who later runs the AppImage can't traverse into
# app.asar.unpacked/ — silently breaking Cowork's daemon auto-launch (the
# fork is guarded by fs.existsSync(), false on a directory it can't read).
# Canonical modes: dirs and already-executable files 755, the rest 644.
echo 'Normalizing AppDir permissions...'
find "$appdir_path" -type d -exec chmod 755 {} + || exit 1
find "$appdir_path" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# --- Build AppImage ---
echo 'Building AppImage...'
output_filename="${package_name}-${version}-${architecture}.AppImage"
output_path="$work_dir/$output_filename"
export ARCH="$architecture"
echo "Using ARCH=$ARCH"

# Local build - no update information
if [[ $GITHUB_ACTIONS != 'true' ]]; then
	echo 'Running locally - building AppImage without update information'
	echo '(Update info and zsync files are only generated in GitHub Actions for releases)'

	if ! "$appimagetool_path" "$appdir_path" "$output_path"; then
		echo "Failed to build AppImage using $appimagetool_path" >&2
		exit 1
	fi
	echo "AppImage built successfully: $output_path"
	echo '--- AppImage Build Finished ---'
	exit 0
fi

# GitHub Actions build - embed update information
echo 'Running in GitHub Actions - embedding update information for automatic updates...'

# Install zsync if needed for .zsync file generation
if ! command -v zsyncmake &> /dev/null; then
	echo 'zsyncmake not found. Installing zsync package for .zsync file generation...'
	if command -v apt-get &> /dev/null; then
		sudo apt-get update && sudo apt-get install -y zsync
	elif command -v dnf &> /dev/null; then
		sudo dnf install -y zsync
	elif command -v zypper &> /dev/null; then
		sudo zypper install -y zsync
	else
		echo 'Cannot install zsync automatically. .zsync files may not be generated.'
	fi
fi

# Format: gh-releases-zsync|<username>|<repository>|<tag>|<filename-pattern>
update_info="gh-releases-zsync|aaddrick|claude-desktop-debian|latest|claude-desktop-*-${architecture}.AppImage.zsync"
echo "Update info: $update_info"

if ! "$appimagetool_path" --updateinformation "$update_info" "$appdir_path" "$output_path"; then
	echo "Failed to build AppImage using $appimagetool_path" >&2
	exit 1
fi

echo "AppImage built successfully with embedded update info: $output_path"
zsync_file="${output_path}.zsync"
if [[ -f $zsync_file ]]; then
	echo "zsync file generated: $zsync_file"
	echo 'zsync file will be included in release artifacts'
else
	echo 'zsync file not generated (zsyncmake may not be installed)'
fi

echo '--- AppImage Build Finished ---'

exit 0
