#!/usr/bin/env bash
#
# chromium-switch-smoke.sh — regression guard on the launcher's
# effective Chromium switch list.
#
# The launcher is opt-in only (see the LAUNCHER POLICY block above
# build_electron_args in scripts/launcher-common.sh): it must not pass
# any default flag that shadows an official upstream code path. This
# tool sources a host-state-neutralized copy of the launcher, runs
# detect_display_backend + build_electron_args for four canonical
# scenarios, and diffs the emitted switch list against a checked-in
# baseline. Any drift — an upstream Electron bump that shifts a
# default, or a launcher PR that adds/removes a flag — fails loudly
# until the baseline is regenerated deliberately.
#
# Usage:
#   tools/chromium-switch-smoke.sh            compare against baseline
#   tools/chromium-switch-smoke.sh --update   regenerate the baseline

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
launcher_src="$repo_root/scripts/launcher-common.sh"
doctor_src="$repo_root/scripts/doctor.sh"
baseline="$repo_root/tools/chromium-switches.baseline"

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT

# launcher-common.sh sources doctor.sh via a BASH_SOURCE dirname, so
# both must be co-located in the temp dir. Substitute the build-time
# WM_CLASS placeholder the same way build.sh does.
cp "$launcher_src" "$tmp_dir/launcher-common.sh" || exit 1
cp "$doctor_src" "$tmp_dir/doctor.sh" || exit 1
sed -i 's/@@WM_CLASS@@/Claude/' "$tmp_dir/launcher-common.sh"

# Neutralize host state so the switch list is deterministic regardless
# of the developer's session (Wayland/X11), keyring, GPU history, or
# XRDP/loginctl state. Every scenario sets exactly the vars it needs.
_smoke_var=''
for _smoke_var in "${!CLAUDE_@}"; do
	unset "$_smoke_var"
done
unset _smoke_var
unset XRDP_SESSION XDG_SESSION_ID WAYLAND_DISPLAY DISPLAY NIRI_SOCKET \
	XDG_CURRENT_DESKTOP

# shellcheck source=scripts/launcher-common.sh
source "$tmp_dir/launcher-common.sh"

# Point log_file at an empty temp file so the GPU-recovery probe
# (_previous_launch_hit_gpu_fatal) is deterministic — it reads the log,
# and an empty file with no section headers never trips.
log_file="$tmp_dir/launcher.log"

# Render one scenario: reset display state, run the real launcher
# codepaths, and print "<name>: <space-joined args>".
render_scenario() {
	local name="$1"
	local pkg="$2"

	: > "$log_file"
	is_wayland=false
	use_x11_on_wayland=true
	electron_args=()
	detect_display_backend
	build_electron_args "$pkg"
	printf '%s: %s\n' "$name" "${electron_args[*]}"
}

# Emit all four canonical scenarios. Each clears the display vars it
# does not want before setting its own, so scenarios never leak state.
generate() {
	# 1. X11 deb (the minimal-argv case: --class only).
	unset WAYLAND_DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP
	DISPLAY=':0'
	render_scenario 'x11-deb' deb

	# 2. Wayland deb, default XWayland backend.
	unset DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP
	WAYLAND_DISPLAY='wayland-0'
	render_scenario 'wayland-xwayland-deb' deb

	# 3. Wayland deb, native backend forced via CLAUDE_USE_WAYLAND=1.
	unset DISPLAY NIRI_SOCKET XDG_CURRENT_DESKTOP
	WAYLAND_DISPLAY='wayland-0'
	CLAUDE_USE_WAYLAND='1'
	render_scenario 'wayland-native-deb' deb

	# 4. X11 AppImage (FUSE forces --no-sandbox).
	unset WAYLAND_DISPLAY CLAUDE_USE_WAYLAND NIRI_SOCKET XDG_CURRENT_DESKTOP
	DISPLAY=':0'
	render_scenario 'x11-appimage' appimage
}

output=$(generate)

if [[ ${1:-} == '--update' ]]; then
	printf '%s\n' "$output" > "$baseline" || exit 1
	echo "Baseline updated: $baseline"
	exit 0
fi

if [[ ! -f $baseline ]]; then
	echo "Baseline missing: $baseline" >&2
	echo 'Run with --update to generate it.' >&2
	exit 1
fi

if diff_out=$(diff -u "$baseline" <(printf '%s\n' "$output")); then
	echo 'Chromium switch smoke: OK (switch list matches baseline)'
	exit 0
fi

echo 'Chromium switch smoke: DRIFT DETECTED' >&2
echo >&2
printf '%s\n' "$diff_out" >&2
echo >&2
echo 'The launcher is opt-in only: it must not pass any default flag' >&2
echo 'that shadows an official upstream code path. The effective' >&2
echo 'Chromium switch list changed. If this change is deliberate,' >&2
echo 'regenerate the baseline:' >&2
echo '    ./tools/chromium-switch-smoke.sh --update' >&2
exit 1
