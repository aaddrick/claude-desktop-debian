#!/usr/bin/env bats
#
# launcher-common.bats
# Tests for launcher utility functions in scripts/launcher-common.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

# Check whether a value exists in the electron_args array.
# Supports glob patterns (e.g., '*WaylandWindowDecorations*').
has_electron_arg() {
	local pattern="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		# shellcheck disable=SC2254
		[[ $arg == $pattern ]] && return 0
	done
	return 1
}

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Redirect all filesystem-touching functions to temp dirs
	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	export XDG_RUNTIME_DIR="$TEST_TMP/run"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"

	# Clear display/wayland variables to avoid leaking host state
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset CLAUDE_USE_WAYLAND
	unset NIRI_SOCKET
	unset XDG_CURRENT_DESKTOP
	unset CLAUDE_MENU_BAR
	unset COWORK_VM_BACKEND

	# shellcheck source=scripts/launcher-common.sh
	source "$SCRIPT_DIR/../scripts/launcher-common.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# setup_logging
# =============================================================================

@test "setup_logging: creates log directory and sets log_file" {
	run setup_logging
	[[ $status -eq 0 ]]
	[[ -d "$XDG_CACHE_HOME/claude-desktop-debian" ]]
}

@test "setup_logging: sets log_file under XDG_CACHE_HOME" {
	setup_logging
	[[ $log_file == "$XDG_CACHE_HOME/claude-desktop-debian/launcher.log" ]]
}

@test "setup_logging: falls back to HOME/.cache when XDG_CACHE_HOME unset" {
	unset XDG_CACHE_HOME
	setup_logging
	[[ $log_dir == "$HOME/.cache/claude-desktop-debian" ]]
	[[ -d "$HOME/.cache/claude-desktop-debian" ]]
}

# =============================================================================
# log_message
# =============================================================================

@test "log_message: appends message to log file" {
	setup_logging
	log_message "test message one"
	log_message "test message two"
	[[ -f $log_file ]]
	run cat "$log_file"
	[[ "${lines[0]}" == "test message one" ]]
	[[ "${lines[1]}" == "test message two" ]]
}

# =============================================================================
# check_display
# =============================================================================

@test "check_display: fails when no display variables set" {
	unset DISPLAY
	unset WAYLAND_DISPLAY
	run check_display
	[[ $status -ne 0 ]]
}

@test "check_display: succeeds with DISPLAY set" {
	DISPLAY=":0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with WAYLAND_DISPLAY set" {
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with both set" {
	DISPLAY=":0"
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

# =============================================================================
# detect_display_backend
# =============================================================================

@test "detect_display_backend: X11 session sets is_wayland=false" {
	DISPLAY=":0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == false ]]
}

@test "detect_display_backend: Wayland session sets is_wayland=true" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
}

@test "detect_display_backend: defaults to XWayland on Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: CLAUDE_USE_WAYLAND=1 forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via NIRI_SOCKET forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri detected via XDG_CURRENT_DESKTOP forces native Wayland" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri in colon-separated XDG_CURRENT_DESKTOP" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="niri:GNOME"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: Niri case-insensitive detection" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="NIRI"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: non-Niri Wayland keeps XWayland default" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="sway"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: Niri not forced when CLAUDE_USE_WAYLAND already set" {
	# CLAUDE_USE_WAYLAND=1 already forces native, Niri detection shouldn't conflict
	WAYLAND_DISPLAY="wayland-0"
	CLAUDE_USE_WAYLAND=1
	NIRI_SOCKET="/tmp/niri.sock"
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

# =============================================================================
# build_electron_args
# =============================================================================

@test "build_electron_args: X11 deb - only CustomTitlebar disabled" {
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: X11 appimage - includes --no-sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland XWayland deb - includes x11 platform and no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args deb
	has_electron_arg '--ozone-platform=x11'
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native deb - includes wayland platform flags" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--ozone-platform=wayland'
	has_electron_arg '--enable-wayland-ime'
	has_electron_arg '*WaylandWindowDecorations*'
}

@test "build_electron_args: Wayland appimage - always includes --no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native nix - includes --no-sandbox" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args nix
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: Wayland native includes text-input-version=3" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--wayland-text-input-version=3'
}

# =============================================================================
# setup_electron_env
# =============================================================================

@test "setup_electron_env: sets ELECTRON_FORCE_IS_PACKAGED" {
	setup_electron_env
	[[ $ELECTRON_FORCE_IS_PACKAGED == 'true' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR" {
	setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

# =============================================================================
# cleanup_stale_lock
# =============================================================================

@test "cleanup_stale_lock: no lock file - returns 0" {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_lock: removes stale lock (dead PID)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# Use PID 99999999 which almost certainly doesn't exist
	ln -s "myhost-99999999" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ ! -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock for running process" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	# Use our own PID (guaranteed to be running)
	ln -s "myhost-$$" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	# Lock should still exist
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: handles non-numeric PID in lock target" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	ln -s "myhost-notanumber" "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# Lock should still exist (function returns early on non-numeric)
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: handles regular file (not symlink)" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	echo "not a symlink" > "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	# Regular file should not be touched
	[[ -f "$config_dir/SingletonLock" ]]
}

# =============================================================================
# cleanup_stale_cowork_socket
# =============================================================================

@test "cleanup_stale_cowork_socket: no socket - returns 0" {
	run cleanup_stale_cowork_socket
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_cowork_socket: removes stale socket file" {
	# Create a socket-like file (not a real socket, but -S check needs a socket)
	# Use python to create a real unix socket for the test
	local sock="$XDG_RUNTIME_DIR/cowork-vm-service.sock"
	python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()
" "$sock" 2>/dev/null || skip "Cannot create test unix socket"

	setup_logging
	# socat connection should fail since nothing is listening
	cleanup_stale_cowork_socket
	[[ ! -S "$sock" ]]
}

# =============================================================================
# Doctor helper functions
# =============================================================================

@test "_doctor_colors: sets color vars when stdout is a terminal" {
	# Force non-terminal to test the else branch
	_doctor_colors
	# When not a terminal, all should be empty
	[[ -z $_green ]]
	[[ -z $_red ]]
	[[ -z $_yellow ]]
	[[ -z $_bold ]]
	[[ -z $_reset ]]
}

@test "_pass: outputs PASS with message" {
	_doctor_colors
	run _pass "test passed"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"test passed"* ]]
}

@test "_fail: outputs FAIL with message and increments counter" {
	_doctor_colors
	_doctor_failures=0
	_fail "something broke"
	[[ $_doctor_failures -eq 1 ]]
}

@test "_warn: outputs WARN with message" {
	_doctor_colors
	run _warn "warning message"
	[[ $output == *"[WARN]"* ]]
	[[ $output == *"warning message"* ]]
}

@test "_info: outputs indented message" {
	_doctor_colors
	run _info "info message"
	[[ $output == *"info message"* ]]
}

# =============================================================================
# _cowork_distro_id
# =============================================================================

@test "_cowork_distro_id: reads ID from /etc/os-release" {
	# This test uses the real /etc/os-release on the test system
	[[ -f /etc/os-release ]] || skip "No /etc/os-release"
	local result
	result=$(_cowork_distro_id)
	# Should return something non-empty
	[[ -n $result ]]
	[[ $result != 'unknown' ]]
}

# =============================================================================
# _cowork_pkg_hint
# =============================================================================

@test "_cowork_pkg_hint: debian uses apt" {
	local result
	result=$(_cowork_pkg_hint debian bubblewrap)
	[[ $result == "sudo apt install bubblewrap" ]]
}

@test "_cowork_pkg_hint: ubuntu uses apt" {
	local result
	result=$(_cowork_pkg_hint ubuntu socat)
	[[ $result == "sudo apt install socat" ]]
}

@test "_cowork_pkg_hint: fedora uses dnf" {
	local result
	result=$(_cowork_pkg_hint fedora bubblewrap)
	[[ $result == "sudo dnf install bubblewrap" ]]
}

@test "_cowork_pkg_hint: arch uses pacman" {
	local result
	result=$(_cowork_pkg_hint arch socat)
	[[ $result == "sudo pacman -S socat" ]]
}

@test "_cowork_pkg_hint: qemu maps to distro-specific packages" {
	local result
	result=$(_cowork_pkg_hint debian qemu)
	[[ $result == "sudo apt install qemu-system-x86 qemu-utils" ]]

	result=$(_cowork_pkg_hint fedora qemu)
	[[ $result == "sudo dnf install qemu-kvm qemu-img" ]]

	result=$(_cowork_pkg_hint arch qemu)
	[[ $result == "sudo pacman -S qemu-full" ]]
}

@test "_cowork_pkg_hint: unknown distro gives generic message" {
	local result
	result=$(_cowork_pkg_hint gentoo bubblewrap)
	[[ $result == "Install bubblewrap using your package manager" ]]
}

# =============================================================================
# _electron_version
# =============================================================================

@test "_electron_version: reads version from file beside binary" {
	mkdir -p "$TEST_TMP/electron"
	echo "33.4.0" > "$TEST_TMP/electron/version"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron")
	[[ $result == "33.4.0" ]]
}

@test "_electron_version: returns empty when version file missing" {
	mkdir -p "$TEST_TMP/electron"
	touch "$TEST_TMP/electron/electron"
	local result
	result=$(_electron_version "$TEST_TMP/electron/electron") || true
	[[ -z $result ]]
}
