#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"
maintainer="$6"
description="$7"

echo '--- Starting Debian Package Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

package_root="$work_dir/package"
install_dir="$package_root/usr"

# Clean previous package structure if it exists
rm -rf "$package_root"

# Create Debian package structure
echo "Creating package structure in $package_root..."
mkdir -p "$package_root/DEBIAN" || exit 1
mkdir -p "$install_dir/lib/$package_name" || exit 1
mkdir -p "$install_dir/share/applications" || exit 1
mkdir -p "$install_dir/share/icons" || exit 1
mkdir -p "$install_dir/bin" || exit 1

# --- Icon Installation ---
echo 'Installing icons...'
# Map: size -> filename suffix
declare -A icon_files=(
	[16]=13 [24]=11 [32]=10 [48]=8 [64]=7 [256]=6
)

for size in "${!icon_files[@]}"; do
	icon_dir="$install_dir/share/icons/hicolor/${size}x${size}/apps"
	mkdir -p "$icon_dir" || exit 1
	icon_source_path="$work_dir/claude_${icon_files[$size]}_${size}x${size}x32.png"
	if [[ -f $icon_source_path ]]; then
		echo "Installing ${size}x${size} icon..."
		install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png" || exit 1
	else
		echo "Warning: Missing ${size}x${size} icon at $icon_source_path"
	fi
done
echo 'Icons installed'

# --- Copy Application Files ---
echo "Copying application files from $app_staging_dir..."

# Copy local electron first if it was packaged (check if node_modules exists in staging)
if [[ -d $app_staging_dir/node_modules ]]; then
	echo 'Copying packaged electron...'
	cp -r "$app_staging_dir/node_modules" "$install_dir/lib/$package_name/" || exit 1
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
resources_dir="$install_dir/lib/$package_name/node_modules/electron/dist/resources"
mkdir -p "$resources_dir" || exit 1
cp "$app_staging_dir/app.asar" "$resources_dir/" || exit 1
cp -r "$app_staging_dir/app.asar.unpacked" "$resources_dir/" || exit 1
echo 'Application files copied to Electron resources directory'

# Copy shared launcher library (launcher-common.sh sources doctor.sh
# at runtime, so both must live in the same directory)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$(dirname "$script_dir")/launcher-common.sh" "$install_dir/lib/$package_name/" || exit 1
sed -i "s/@@WM_CLASS@@/$WM_CLASS/" "$install_dir/lib/$package_name/launcher-common.sh"
cp "$(dirname "$script_dir")/doctor.sh" "$install_dir/lib/$package_name/" || exit 1
echo 'Shared launcher library + doctor copied'

# --- Create Desktop Entry ---
echo 'Creating desktop entry...'
cat > "$install_dir/share/applications/claude-desktop.desktop" << EOF
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
echo 'Desktop entry created'

# --- Create Launcher Script ---
echo 'Creating launcher script...'
cat > "$install_dir/bin/claude-desktop" << EOF
#!/usr/bin/env bash

# Source shared launcher library
source "/usr/lib/$package_name/launcher-common.sh"

# Handle --doctor flag before anything else
if [[ "\${1:-}" == '--doctor' ]]; then
	local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
	run_doctor "\$local_electron_path"
	exit \$?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env
cleanup_orphaned_cowork_daemon
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

# Determine Electron executable path
electron_exec='electron'
local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
if [[ -f \$local_electron_path ]]; then
	electron_exec="\$local_electron_path"
	log_message "Using local Electron: \$electron_exec"
else
	if command -v electron &> /dev/null; then
		log_message "Using global Electron: \$electron_exec"
	else
		log_message 'Error: Electron executable not found'
		if command -v zenity &> /dev/null; then
			zenity --error \
				--text='Claude Desktop cannot start because the Electron framework is missing.'
		elif command -v kdialog &> /dev/null; then
			kdialog --error \
				'Claude Desktop cannot start because the Electron framework is missing.'
		fi
		exit 1
	fi
fi

# App path
app_path="/usr/lib/$package_name/node_modules/electron/dist/resources/app.asar"

# Build electron args
build_electron_args 'deb'

# Add app path LAST
electron_args+=("\$app_path")

# Change to application directory
app_dir="/usr/lib/$package_name"
log_message "Changing directory to \$app_dir"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }

# Execute Electron (exec replaces the shell process so signals
# like SIGINT, SIGTERM, and SIGHUP reach Electron directly)
log_message "Executing: \$electron_exec \${electron_args[*]} \$*"
exec "\$electron_exec" "\${electron_args[@]}" "\$@" >> "\$log_file" 2>&1
EOF
chmod +x "$install_dir/bin/claude-desktop" || exit 1
echo 'Launcher script created'

# --- Create Control File ---
echo 'Creating control file...'
# Electron is bundled with its own Node.js runtime, so nodejs/npm are not
# runtime dependencies. p7zip is only used at build time to extract the
# installer. bubblewrap is Recommended (not required): it provides the
# default namespace-sandbox isolation for Cowork mode; the app runs without
# it (Cowork falls back to host-direct). apt installs Recommends by default.

cat > "$package_root/DEBIAN/control" << EOF
Package: $package_name
Version: $version
Section: utils
Priority: optional
Architecture: $architecture
Recommends: bubblewrap
Maintainer: $maintainer
Description: $description
 Claude is an AI assistant from Anthropic.
 This package provides the desktop interface for Claude.
 .
 Supported on Debian-based Linux distributions (Debian, Ubuntu, Linux Mint, MX Linux, etc.)
EOF
echo 'Control file created'

# --- Create Postinst Script ---
echo 'Creating postinst script...'
cat > "$package_root/DEBIAN/postinst" << EOF
#!/bin/sh
set -e

# Update desktop database for MIME types
echo "Updating desktop database..."
update-desktop-database /usr/share/applications > /dev/null 2>&1 || true

# Set correct permissions for chrome-sandbox if electron is installed globally
# or locally packaged
echo "Setting chrome-sandbox permissions..."
SANDBOX_PATH=""
# Electron is always packaged locally now, so only check the local path.
LOCAL_SANDBOX_PATH="/usr/lib/$package_name/node_modules/electron/dist/chrome-sandbox"
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

# --- AppArmor profile for Chromium's user-namespace sandbox ---
# Ubuntu 24.04+ sets kernel.apparmor_restrict_unprivileged_userns=1, which
# blocks the unprivileged user namespaces Chromium's sandbox relies on,
# crashing the app on launch with a sandbox/.../credentials.cc FATAL.
# Grant userns to our Electron binary via a scoped AppArmor profile, exactly
# as the google-chrome, code, and slack packages do. Gate on the kernel knob
# (not just apparmor_parser): only Ubuntu-family systems impose the
# restriction, so on stock Debian/others the knob is absent and we skip the
# profile entirely rather than installing one they never need. The knob may
# read 0 now and flip to 1 later, so existence — not value — is the gate.
APPARMOR_PROFILE="/etc/apparmor.d/$package_name"
if command -v apparmor_parser >/dev/null 2>&1 \
    && [ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo "Configuring AppArmor profile for Chromium sandbox..."
    # Writing the profile is best-effort: a read-only or atypical /etc must
    # never abort the install (this postinst runs under set -e). Keeping the
    # mkdir + heredoc in the if-condition exempts them from errexit.
    if mkdir -p /etc/apparmor.d 2>/dev/null && cat > "\$APPARMOR_PROFILE" <<'APPARMOR_EOF'
abi <abi/4.0>,
include <tunables/global>

profile $package_name /usr/lib/$package_name/node_modules/electron/dist/electron flags=(unconfined) {
    userns,

    include if exists <local/$package_name>
}
APPARMOR_EOF
    then
        if apparmor_parser -Q "\$APPARMOR_PROFILE" >/dev/null 2>&1; then
            apparmor_parser -r "\$APPARMOR_PROFILE" >/dev/null 2>&1 || echo "Note: AppArmor profile staged but not loaded now; it will apply on the next AppArmor reload or reboot."
            echo "AppArmor profile installed at \$APPARMOR_PROFILE"
        else
            rm -f "\$APPARMOR_PROFILE"
            echo "AppArmor on this system does not support the userns rule; skipping profile (not required here)."
        fi
    else
        echo "Warning: could not write \$APPARMOR_PROFILE; skipping AppArmor profile."
    fi
fi

# --- AppArmor profile for the Cowork bwrap sandbox helper ---
# Cowork's "bwrap backend" runs the agent's Claude Code process inside a
# bubblewrap sandbox, which itself needs unprivileged user namespaces — the
# same thing Ubuntu 24.04+ blocks (apparmor_restrict_unprivileged_userns=1).
# bwrap is a SEPARATE binary from the Electron app, so the claude-desktop
# profile above (which scopes the Electron binary) does not cover it; it
# needs its own profile on /usr/bin/bwrap. Without this, Cowork silently
# falls back to host-direct (no isolation).
#
# Discovery-led, not distro-led: install when AppArmor can parse the userns
# rule (4.0+) AND bwrap is present AND no other profile already owns bwrap.
# This also covers a hardened Debian (restriction enabled) and is a harmless
# no-op where the restriction is off. Static checks only: postinst runs as
# root, which is exempt from the unprivileged-userns restriction, so a
# behavioral bwrap probe here would falsely pass — the behavioral probe
# lives in 'claude-desktop --doctor' instead (runs as the user).
BWRAP_PROFILE="/etc/apparmor.d/${package_name}-bwrap"
if command -v apparmor_parser >/dev/null 2>&1 \
    && [ -x /usr/bin/bwrap ] \
    && [ ! -e /etc/apparmor.d/bwrap ]; then
    echo "Configuring AppArmor profile for the Cowork bwrap sandbox..."
    # Writing the profile is best-effort: a read-only or atypical /etc must
    # never abort the install (this postinst runs under set -e). Keeping the
    # mkdir + heredoc in the if-condition exempts them from errexit.
    if mkdir -p /etc/apparmor.d 2>/dev/null && cat > "\$BWRAP_PROFILE" <<'BWRAP_APPARMOR_EOF'
abi <abi/4.0>,
include <tunables/global>

profile ${package_name}-bwrap /usr/bin/bwrap flags=(unconfined) {
    userns,

    include if exists <local/${package_name}-bwrap>
}
BWRAP_APPARMOR_EOF
    then
        if apparmor_parser -Q "\$BWRAP_PROFILE" >/dev/null 2>&1; then
            apparmor_parser -r "\$BWRAP_PROFILE" >/dev/null 2>&1 || echo "Note: bwrap AppArmor profile staged but not loaded now; it will apply on the next AppArmor reload or reboot."
            echo "Cowork bwrap AppArmor profile installed at \$BWRAP_PROFILE"
        else
            rm -f "\$BWRAP_PROFILE"
            echo "AppArmor on this system does not support the userns rule; skipping bwrap profile (not required here)."
        fi
    else
        echo "Warning: could not write \$BWRAP_PROFILE; skipping bwrap AppArmor profile."
    fi
fi

exit 0
EOF
chmod +x "$package_root/DEBIAN/postinst" || exit 1
echo 'Postinst script created'

# --- Create Postrm Script ---
echo 'Creating postrm script...'
# The AppArmor profiles are generated by postinst, not tracked by dpkg, so we
# unload and delete them ourselves. Cleanup lives in postrm (not prerm) so it
# also fires on purge and abort-install. Skip on upgrade — the incoming
# postinst rewrites and reloads them. 'disappear' is deliberately not handled:
# matching it would also clean during the overwrite-by-another-package flow.
# Two profiles: the Electron one (Chromium sandbox, #687) and the bwrap one
# (Cowork sandbox helper, #694).
cat > "$package_root/DEBIAN/postrm" << EOF
#!/bin/sh
set -e

case "\$1" in
    remove|purge|abort-install)
        for _profile in "/etc/apparmor.d/$package_name" "/etc/apparmor.d/${package_name}-bwrap"; do
            if [ -e "\$_profile" ]; then
                if command -v apparmor_parser >/dev/null 2>&1; then
                    apparmor_parser -R "\$_profile" >/dev/null 2>&1 || true
                fi
                rm -f "\$_profile"
            fi
        done
        ;;
esac

exit 0
EOF
chmod +x "$package_root/DEBIAN/postrm" || exit 1
echo 'Postrm script created'

# --- Build .deb Package ---
echo 'Building .deb package...'
deb_file="$work_dir/${package_name}_${version}_${architecture}.deb"

# Fix DEBIAN directory permissions (must be 755 for dpkg-deb)
echo 'Setting DEBIAN directory permissions...'
chmod 755 "$package_root/DEBIAN" || exit 1

# Fix script permissions in DEBIAN directory
echo 'Setting script permissions...'
chmod 755 "$package_root/DEBIAN/postinst" || exit 1
chmod 755 "$package_root/DEBIAN/postrm" || exit 1

if ! dpkg-deb --build "$package_root" "$deb_file"; then
	echo 'Failed to build .deb package' >&2
	exit 1
fi

echo "Deb package built successfully: $deb_file"
echo '--- Debian Package Build Finished ---'

exit 0
