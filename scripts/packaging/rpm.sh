#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"
# $6 is maintainer (unused in RPM spec, kept for parameter compatibility with deb)
description="$7"

echo '--- Starting RPM Package Build ---'
echo "Version: $version"

# RPM Version field cannot contain hyphens. If version contains a hyphen,
# split into version (before hyphen) and release (after hyphen).
# e.g., "1.1.799-1.3.3" -> rpm_version="1.1.799", rpm_release="1.3.3"
if [[ $version == *-* ]]; then
	rpm_version="${version%%-*}"
	rpm_release="${version#*-}"
	echo "RPM Version: $rpm_version"
	echo "RPM Release: $rpm_release"
else
	rpm_version="$version"
	rpm_release="1"
fi
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

# Map architecture to RPM naming
case "$architecture" in
	amd64) rpm_arch='x86_64' ;;
	arm64) rpm_arch='aarch64' ;;
	*)
		echo "Unsupported architecture for RPM: $architecture" >&2
		exit 1
		;;
esac

# RPM build directories
rpmbuild_dir="$work_dir/rpmbuild"

# Clean previous RPM build structure if it exists
rm -rf "$rpmbuild_dir"

# Create RPM build directory structure
echo "Creating RPM build structure in $rpmbuild_dir..."
mkdir -p "$rpmbuild_dir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} || exit 1

# Get script directory for accessing launcher-common.sh
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create staging area for files to include
staging_dir="$work_dir/rpm-staging"
rm -rf "$staging_dir"
mkdir -p "$staging_dir" || exit 1

# --- Create Desktop Entry ---
echo 'Creating desktop entry...'
cat > "$staging_dir/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=$WM_CLASS
EOF

# --- Stage AppStream metainfo (installed via %files block below) ---
metainfo_name='io.github.aaddrick.claude-desktop-debian.metainfo.xml'
cp "$script_dir/$metainfo_name" "$staging_dir/$metainfo_name" || exit 1

# --- Create Launcher Script ---
echo 'Creating launcher script...'
cat > "$staging_dir/claude-desktop" << EOF
#!/usr/bin/env bash

# Source shared launcher library
source "/usr/lib/$package_name/launcher-common.sh"

# The official Electron binary; it auto-loads the co-located
# resources/app.asar, so no app path is ever passed (issue #696).
app_exec="/usr/lib/$package_name/claude-desktop"

# Handle --doctor flag before anything else
if [[ "\${1:-}" == '--doctor' ]]; then
	run_doctor "\$app_exec"
	exit \$?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env

cleanup_orphaned_cowork_daemon
cleanup_stale_desktop_helpers
cleanup_stale_lock
cleanup_stale_cowork_socket

# Log startup info
log_message '--- Claude Desktop Launcher Start ---'
log_message "Timestamp: \$(date)"
log_message "Arguments: \$@"
log_session_env

# Check for display
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Claude Desktop requires a graphical desktop environment.' >&2
	echo 'Please run from within an X11 or Wayland session, not from a TTY.' >&2
	exit 1
fi

# Detect display backend
detect_display_backend
if [[ \$is_wayland == true ]]; then
	log_message 'Wayland detected'
fi

if [[ ! -x \$app_exec ]]; then
	log_message "Error: Claude Desktop binary not found at \$app_exec"
	echo "Error: Claude Desktop binary not found at \$app_exec" >&2
	exit 1
fi

# Build Chromium switches - use 'deb' type (same sandbox behavior)
build_electron_args 'deb'

# Change to application directory
app_dir="/usr/lib/$package_name"
log_message "Changing directory to \$app_dir"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }

# Execute the official binary and keep the launcher alive so explicit
# quit can clean up Desktop-owned helpers that outlive the main process.
log_message "Executing: \$app_exec \${electron_args[*]} \$*"
run_electron_and_cleanup "\$app_exec" "\${electron_args[@]}" "\$@"
exit \$?
EOF
chmod +x "$staging_dir/claude-desktop"

# --- Create RPM Spec File ---
echo 'Creating RPM spec file...'

# Build icon installation commands from the official hicolor tree
icon_install_cmds=""
official_hicolor="${CLAUDE_EXTRACT_DIR:?}/usr/share/icons/hicolor"

for icon_source_path in "$official_hicolor"/*/apps/claude-desktop.png; do
	[[ -f $icon_source_path ]] || continue
	size_dir=$(basename "$(dirname "$(dirname "$icon_source_path")")")
	icon_install_cmds+="install -Dm 644 $icon_source_path %{buildroot}/usr/share/icons/hicolor/${size_dir}/apps/claude-desktop.png
"
done

cat > "$rpmbuild_dir/SPECS/$package_name.spec" << SPECEOF
Name:           $package_name
Version:        $rpm_version
Release:        $rpm_release%{?dist}
Summary:        $description

License:        Proprietary
URL:            https://claude.ai

# Disable automatic dependency scanning (we bundle everything)
AutoReqProv:    no

# Disable debug package generation
%define debug_package %{nil}

# Disable binary stripping (Electron binaries don't like it)
%define __strip /bin/true

# Disable build ID generation (avoids issues with Electron binaries)
%define _build_id_links none

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on RPM-based Linux distributions (Fedora, RHEL, CentOS, etc.)

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/lib/$package_name
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/bin

# Install icons
$icon_install_cmds

# Copy application files (the extracted official usr/lib/claude-desktop
# tree: Electron ELF, chrome-sandbox, resources/, locales/, ...)
cp -a $app_staging_dir/. %{buildroot}/usr/lib/$package_name/

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
cp $(dirname "$script_dir")/launcher-common.sh %{buildroot}/usr/lib/$package_name/
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "%{buildroot}/usr/lib/$package_name/launcher-common.sh"
cp $(dirname "$script_dir")/doctor.sh %{buildroot}/usr/lib/$package_name/

# Install desktop entry
install -Dm 644 $staging_dir/claude-desktop.desktop %{buildroot}/usr/share/applications/claude-desktop.desktop

# Install AppStream metainfo (GNOME Software / KDE Discover)
install -Dm 644 $staging_dir/$metainfo_name %{buildroot}/usr/share/metainfo/$metainfo_name

# Install launcher script
install -Dm 755 $staging_dir/claude-desktop %{buildroot}/usr/bin/claude-desktop

# Normalize file modes — the cp -r above honors the build umask, and
# the "-" first field of %defattr ships buildroot *file* modes verbatim
# (only directory modes are forced to 0755), so a umask-077 build would
# package an unreadable app.asar and a non-executable electron binary.
# Must run before the chrome-sandbox chmod below so 4755 survives.
find %{buildroot}/usr/lib/$package_name -type f -exec chmod u=rwX,go=rX {} +

# Set the chrome-sandbox suid bit in the buildroot so the /usr/lib
# directory walk in %files records 4755 in the payload (preserves #539
# without the "File listed twice" warning #609 — see %files block).
# The official data.tar records the bit, but our non-root ar|tar
# extraction strips it.
chmod 4755 %{buildroot}/usr/lib/$package_name/chrome-sandbox

%post
# Update desktop database for MIME types
update-desktop-database /usr/share/applications > /dev/null 2>&1 || true

%postun
# Update desktop database after removal
update-desktop-database /usr/share/applications > /dev/null 2>&1 || true

%files
%defattr(-, root, root, 0755)
%attr(755, root, root) /usr/bin/claude-desktop
/usr/lib/$package_name
/usr/share/applications/claude-desktop.desktop
/usr/share/metainfo/$metainfo_name
/usr/share/icons/hicolor/*/apps/claude-desktop.png
SPECEOF

echo 'RPM spec file created'

# --- Build RPM Package ---
echo 'Building RPM package...'

rpmbuild_log="$work_dir/rpmbuild.log"
rpmbuild --define "_topdir $rpmbuild_dir" \
	--define "_rpmdir $work_dir" \
	--target "$rpm_arch" \
	-bb "$rpmbuild_dir/SPECS/$package_name.spec" 2>&1 |
	tee "$rpmbuild_log"
if (( PIPESTATUS[0] != 0 )); then
	echo 'Failed to build RPM package' >&2
	exit 1
fi

# Guard against re-introducing #609. The "File listed twice" warning
# means %files has overlapping listings, and on modern rpmbuild any
# %exclude workaround silently strips the file from the payload.
if grep -qF 'File listed twice' "$rpmbuild_log"; then
	echo 'rpmbuild emitted "File listed twice" — %files has overlapping listings (see #609)' >&2
	grep -F 'File listed twice' "$rpmbuild_log" >&2
	exit 1
fi

# Find and move the built RPM (it will be in a subdirectory)
rpm_file=$(find "$work_dir" -name "${package_name}-${rpm_version}*.rpm" -type f | head -n 1)
if [[ -z $rpm_file ]]; then
	echo 'Could not find built RPM file' >&2
	exit 1
fi

# Rename to consistent format at work_dir root
# Use original $version to maintain filename compatibility with DEB and AppImage
final_rpm="$work_dir/${package_name}-${version}-1.${rpm_arch}.rpm"
if [[ $rpm_file != "$final_rpm" ]]; then
	mv "$rpm_file" "$final_rpm" || exit 1
fi

echo "RPM package built successfully: $final_rpm"
echo '--- RPM Package Build Finished ---'

exit 0
