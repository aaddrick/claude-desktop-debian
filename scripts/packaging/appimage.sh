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
	run_doctor "$app_exec" 'appimage'
	exit $?
fi

# --version never reaches the terminal via Electron: the launcher
# redirects all app output to the log (#772). Answer it here instead.
if [[ "${1:-}" == '--version' ]]; then
	echo '@@PACKAGE_NAME@@ @@VERSION@@'
	exit 0
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env

cleanup_replaced_desktop_ui
cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_vm_bundle_images
# APPIMAGE is set by the AppImage runtime to the persistent image path;
# an extracted/direct run leaves it unset and the heal no-ops.
heal_autostart_entry "${APPIMAGE:-}"
backup_user_config

# Detect display backend
detect_display_backend
ensure_portal_app_id_entry "${APPIMAGE:-}" \
	'io.github.aaddrick.claude-desktop-debian'

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
# The AppRun heredoc is quoted (runtime expansion), so the build-time
# values for the --version fast-path are stamped in afterwards.
sed -i "s/@@PACKAGE_NAME@@/$package_name/; s/@@VERSION@@/$version/" \
	"$appdir_path/AppRun" || exit 1
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
# appimagetool is a native binary that must run on the HOST machine, not
# the package's target architecture: CI cross-builds (e.g. an arm64
# package on an ubuntu-latest/x86_64 runner) need the x86_64 tool even
# though $architecture says arm64. Select strictly by uname -m here;
# the target architecture is only used later for the embedded ARCH.
host_arch=$(uname -m)
case "$host_arch" in
	x86_64|aarch64) ;;
	*)
		echo "Unsupported host architecture for appimagetool: $host_arch" >&2
		exit 1
		;;
esac

# Pinned AppImage toolchain (#932). The runtime is the stub every
# AppImage starts with: AppImageKit's (the old continuous release) is
# dynamically linked against libfuse.so.2, which Fedora 44 Atomic
# Desktops and stock Ubuntu 24.04 no longer ship. The type2-runtime
# build is static-pie with FUSE linked in, so the AppImage needs no
# libfuse2 on the host. appimagetool comes from the matching
# AppImage/appimagetool project, which also writes the .zsync itself.
# Both are pinned by release and SHA-256 rather than "continuous".
APPIMAGETOOL_VERSION='1.9.1'
APPIMAGETOOL_SHA256_X86_64='ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
APPIMAGETOOL_SHA256_AARCH64='f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158'
TYPE2_RUNTIME_VERSION='20251108'
TYPE2_RUNTIME_SHA256_X86_64='2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'
TYPE2_RUNTIME_SHA256_AARCH64='00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444'

# Download $1 (URL) to $2 unless a copy with SHA-256 $3 is already
# there, then verify it. A cached or downloaded file with the wrong
# hash is removed and the build fails.
fetch_pinned() {
	local url="$1" dest="$2" sha256="$3"
	local checksum_line="$sha256  $dest"
	if [[ -f $dest ]] \
		&& sha256sum -c --status <<< "$checksum_line" 2> /dev/null; then
		echo "Using cached $dest"
		return 0
	fi
	echo "Downloading $url"
	if ! wget -q -O "$dest" "$url"; then
		echo "Failed to download $url" >&2
		rm -f "$dest"
		return 1
	fi
	if ! sha256sum -c --status <<< "$checksum_line"; then
		echo "SHA-256 mismatch for $dest (expected $sha256)" >&2
		rm -f "$dest"
		return 1
	fi
	return 0
}

appimagetool_path=''

# Check system PATH first. The runtime is forced with --runtime-file
# below, so a local tool still produces a FUSE-2-free AppImage.
if command -v appimagetool &> /dev/null; then
	appimagetool_path=$(command -v appimagetool)
	echo "Found appimagetool in PATH: $appimagetool_path"
fi

# Otherwise use the pinned HOST-arch tool. The versioned name keeps a
# --clean no build from reusing an older AppImageKit download.
if [[ -z $appimagetool_path ]]; then
	case "$host_arch" in
		x86_64) appimagetool_sha256="$APPIMAGETOOL_SHA256_X86_64" ;;
		aarch64) appimagetool_sha256="$APPIMAGETOOL_SHA256_AARCH64" ;;
	esac
	appimagetool_url='https://github.com/AppImage/appimagetool/releases/download/'
	appimagetool_url+="${APPIMAGETOOL_VERSION}/appimagetool-${host_arch}.AppImage"
	appimagetool_path="$work_dir/appimagetool-${APPIMAGETOOL_VERSION}"
	appimagetool_path+="-${host_arch}.AppImage"
	fetch_pinned "$appimagetool_url" "$appimagetool_path" \
		"$appimagetool_sha256" || exit 1
	chmod +x "$appimagetool_path" || exit 1
fi

# Run the tool without mounting it, so the build host needs no FUSE
# either (#932).
export APPIMAGE_EXTRACT_AND_RUN=1

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

# ARCH names the TARGET architecture (canonical uname-style), which can
# differ from the host running the tool during a cross-build. It only
# covers naming/validation: appimagetool ALWAYS embeds the runtime stub
# bundled with the tool itself, which is host-arch. On a cross-build
# that bakes an x86_64 stub into an arm64 AppImage, which then can't
# start on target hardware (caught by test-artifacts on the first
# native-arm64 run). Fetch the pinned TARGET-arch type2 runtime and
# force it in with --runtime-file.
case "$architecture" in
	amd64)
		export ARCH='x86_64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_X86_64"
		;;
	arm64)
		export ARCH='aarch64'
		runtime_sha256="$TYPE2_RUNTIME_SHA256_AARCH64"
		;;
	*)
		echo "Unsupported target architecture for ARCH: $architecture" >&2
		exit 1
		;;
esac
echo "Using ARCH=$ARCH"

runtime_url='https://github.com/AppImage/type2-runtime/releases/download/'
runtime_url+="${TYPE2_RUNTIME_VERSION}/runtime-${ARCH}"
runtime_path="$work_dir/type2-runtime-${TYPE2_RUNTIME_VERSION}-${ARCH}"
fetch_pinned "$runtime_url" "$runtime_path" "$runtime_sha256" || exit 1

# Local build - no update information
if [[ $GITHUB_ACTIONS != 'true' ]]; then
	echo 'Running locally - building AppImage without update information'
	echo '(Update info and zsync files are only generated in GitHub Actions for releases)'

	if ! "$appimagetool_path" --runtime-file "$runtime_path" \
		"$appdir_path" "$output_path"; then
		echo "Failed to build AppImage using $appimagetool_path" >&2
		exit 1
	fi
	echo "AppImage built successfully: $output_path"
	echo '--- AppImage Build Finished ---'
	exit 0
fi

# GitHub Actions build - embed update information
echo 'Running in GitHub Actions - embedding update information for automatic updates...'

# Format: gh-releases-zsync|<username>|<repository>|<tag>|<filename-pattern>
# The 'claude-desktop-*' wildcard is deliberately NOT renamed along with
# $package_name: it matches both the old claude-desktop-* and the new
# claude-desktop-unofficial-* artifact names, so AppImages installed
# before the rename keep self-updating. Do not narrow it.
update_info="gh-releases-zsync|aaddrick|claude-desktop-debian|latest|claude-desktop-*-${architecture}.AppImage.zsync"
echo "Update info: $update_info"

# appimagetool writes the .zsync itself (no zsyncmake needed), into the
# current directory under the AppImage's base name rather than next to
# $output_path. build.sh runs this from the project root, where the
# release upload picks it up. Clear any earlier copy first, so a stale
# file can't pass the check below.
zsync_file="$PWD/${output_filename}.zsync"
rm -f "$zsync_file"

if ! "$appimagetool_path" --runtime-file "$runtime_path" \
	--updateinformation "$update_info" "$appdir_path" "$output_path"; then
	echo "Failed to build AppImage using $appimagetool_path" >&2
	exit 1
fi

echo "AppImage built successfully with embedded update info: $output_path"
# The embedded update info points installed AppImages at this file; a
# release without it breaks in-place updates, so its absence is fatal.
if [[ ! -f $zsync_file ]]; then
	echo "zsync file not found at $zsync_file" >&2
	exit 1
fi
echo "zsync file generated: $zsync_file"

echo '--- AppImage Build Finished ---'

exit 0
