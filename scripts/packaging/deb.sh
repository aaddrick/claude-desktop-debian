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

# --- Install AppStream metainfo (App Center / GNOME Software / KDE Discover) ---
echo 'Installing AppStream metainfo...'
metainfo_name='io.github.aaddrick.claude-desktop-debian.metainfo.xml'
install -Dm 644 "$script_dir/$metainfo_name" \
	"$install_dir/share/metainfo/$metainfo_name" || exit 1
echo 'AppStream metainfo installed'

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

# App path
app_path="/usr/lib/$package_name/node_modules/electron/dist/resources/app.asar"

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

# Determine Electron executable path
electron_exec='electron'
using_global_electron=false
local_electron_path="/usr/lib/$package_name/node_modules/electron/dist/electron"
if [[ -f \$local_electron_path ]]; then
	electron_exec="\$local_electron_path"
	log_message "Using local Electron: \$electron_exec"
else
	if command -v electron &> /dev/null; then
		using_global_electron=true
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

# Build electron args
build_electron_args 'deb'

# Bundled Electron: app.asar sits in its default resources/ dir next
# to the binary, so Electron auto-loads it. Passing the path again
# makes Electron treat it as a file-to-open, which the app forwards
# to its file-drop handler, producing a spurious "Attach app.asar?"
# prompt on launch and on every taskbar reopen (the second-instance
# argv path). Omitting it is the root-cause fix. See issue #696.
# Global (PATH) Electron has no co-located app.asar and would boot
# its default_app welcome screen instead — only there the explicit
# app path is load-bearing and must stay.
if [[ \$using_global_electron == true ]]; then
	electron_args+=("\$app_path")
	log_message "App (explicit arg, global Electron): \$app_path"
else
	log_message "App (auto-loaded by Electron): \$app_path"
fi

# Change to application directory
app_dir="/usr/lib/$package_name"
log_message "Changing directory to \$app_dir"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }

# Execute Electron and keep the launcher alive so explicit quit can
# clean up Desktop-owned helpers that outlive the Electron main process.
log_message "Executing: \$electron_exec \${electron_args[*]} \$*"
run_electron_and_cleanup "\$electron_exec" "\${electron_args[@]}" "\$@"
exit \$?
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
    # grep / mkdir + heredoc in the if/elif conditions exempts them from
    # errexit. Debian Policy 10.7.3: a profile without our marker header was
    # hand-created or hand-edited by the admin — preserve it, never overwrite.
    if [ -e "\$APPARMOR_PROFILE" ] \
        && ! grep -qF "managed by the $package_name package" \
            "\$APPARMOR_PROFILE" 2>/dev/null; then
        echo "Preserving locally modified \$APPARMOR_PROFILE (no marker header)"
        apparmor_parser -r "\$APPARMOR_PROFILE" >/dev/null 2>&1 || true
    elif mkdir -p /etc/apparmor.d 2>/dev/null && cat > "\$APPARMOR_PROFILE" <<'APPARMOR_EOF'
# This profile is managed by the $package_name package (postinst); direct
# edits will be overwritten on upgrade. Put local changes in
# /etc/apparmor.d/local/$package_name instead.
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
        # A failed write may leave a truncated profile behind; clear it.
        # The || true is mandatory: this branch is errexit-live, and a bare
        # rm fails the upgrade on a read-only /etc.
        rm -f "\$APPARMOR_PROFILE" 2>/dev/null || true
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
# Gate on the kernel knob, exactly like the Electron block above: only a
# kernel that can enforce the restriction exposes the knob, and a userspace
# parser that merely accepts the userns rule (AppArmor 4) is not
# enforcement — without the knob the profile is dead weight on a binary
# this package does not own. There is deliberately no [ -x /usr/bin/bwrap ]
# gate: a profile attaching to a nonexistent binary is inert, and dpkg
# gives Recommends no ordering edge, so gating on the binary races a
# same-transaction bubblewrap install. Static checks only: postinst runs as
# root, which is exempt from the unprivileged-userns restriction, so a
# behavioral bwrap probe here would falsely pass — the behavioral probe
# lives in 'claude-desktop --doctor' instead (runs as the user).
BWRAP_PROFILE="/etc/apparmor.d/${package_name}-bwrap"
if command -v apparmor_parser >/dev/null 2>&1 \
    && [ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
    echo "Configuring AppArmor profile for the Cowork bwrap sandbox..."
    # Writing the profile is best-effort: a read-only or atypical /etc must
    # never abort the install (this postinst runs under set -e). Keeping the
    # grep / mkdir + heredoc in the if/elif conditions exempts them from
    # errexit. Debian Policy 10.7.3: a profile without our marker header was
    # hand-created or hand-edited by the admin — preserve it, never overwrite.
    if [ -e "\$BWRAP_PROFILE" ] \
        && ! grep -qF "managed by the $package_name package" \
            "\$BWRAP_PROFILE" 2>/dev/null; then
        echo "Preserving locally modified \$BWRAP_PROFILE (no marker header)"
        apparmor_parser -r "\$BWRAP_PROFILE" >/dev/null 2>&1 || true
    elif grep -rl '/usr/bin/bwrap' /etc/apparmor.d/ 2>/dev/null \
        | grep -vxF "\$BWRAP_PROFILE" | grep -q .; then
        # Another profile already attaches to /usr/bin/bwrap — a hand-made
        # /etc/apparmor.d/bwrap, apparmor-profiles' bwrap-userns-restrict,
        # or any other filename. Identical attachment strings have no
        # specificity tiebreak, and shadowing a restrictive profile with our
        # unconfined-mode one would silently undo distro hardening, so defer
        # to the existing profile. (A false grep hit in a comment fails
        # safe: we merely skip our profile.)
        echo "An existing AppArmor profile already covers /usr/bin/bwrap; leaving it in charge."
    elif mkdir -p /etc/apparmor.d 2>/dev/null && cat > "\$BWRAP_PROFILE" <<'BWRAP_APPARMOR_EOF'
# This profile is managed by the $package_name package (postinst); direct
# edits will be overwritten on upgrade. Put local changes in
# /etc/apparmor.d/local/${package_name}-bwrap instead.
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
        # A failed write may leave a truncated profile behind; clear it.
        # The || true is mandatory: this branch is errexit-live, and a bare
        # rm fails the upgrade on a read-only /etc.
        rm -f "\$BWRAP_PROFILE" 2>/dev/null || true
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
# Per Debian Policy 10.7.3 the profiles are configuration: unload them
# whenever the confined binaries go away, but delete the files only on
# purge — a profile for an absent binary is a harmless no-op (google-chrome
# leaves its profile behind the same way).
cat > "$package_root/DEBIAN/postrm" << EOF
#!/bin/sh
set -e

case "\$1" in
    remove|purge|abort-install)
        for _profile in "/etc/apparmor.d/$package_name" \
            "/etc/apparmor.d/${package_name}-bwrap"; do
            if [ -e "\$_profile" ] \
                && command -v apparmor_parser >/dev/null 2>&1; then
                apparmor_parser -R "\$_profile" >/dev/null 2>&1 || true
            fi
            # Policy 10.7.3: config survives remove; delete on purge only.
            if [ "\$1" = purge ]; then
                rm -f "\$_profile" 2>/dev/null || true
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

# Normalize the installed tree before building. A restrictive build umask
# can leave directories at 0700, and dpkg-deb records file ownership
# verbatim unless told otherwise. Both bite at runtime: the launcher runs
# as the desktop user, who then can't traverse into app.asar.unpacked/ —
# silently breaking Cowork's daemon auto-launch (the fork is guarded by
# fs.existsSync(), which returns false on a directory it can't read, so
# the symptom is an endless connect ENOENT on the VM-service socket with
# no daemon log and no [cowork-autolaunch] line). Canonical modes: dirs
# and already-executable files 755, every other file 644. The blanket
# pass clears chrome-sandbox's setuid bit, but postinst re-asserts 4755
# after install, so the net result is unchanged.
echo 'Normalizing installed tree permissions...'
find "$install_dir" -type d -exec chmod 755 {} + || exit 1
find "$install_dir" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# --root-owner-group forces root:root in the archive so a leaked build
# uid can't deny access on the installed system (the build does not run
# under fakeroot).
if ! dpkg-deb --root-owner-group --build "$package_root" "$deb_file"; then
	echo 'Failed to build .deb package' >&2
	exit 1
fi

echo "Deb package built successfully: $deb_file"
echo '--- Debian Package Build Finished ---'

exit 0
