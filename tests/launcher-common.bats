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

# Count how many electron_args entries start with --enable-features=.
# Chromium honours only the last such switch, so the launcher must emit
# exactly one; this lets tests assert that invariant.
count_enable_features() {
	local n=0 arg
	for arg in "${electron_args[@]}"; do
		[[ $arg == --enable-features=* ]] && ((n++))
	done
	echo "$n"
}

# Install a dbus-send stub at the front of PATH.
#   kwallet6   — echoes 'boolean true', exits 0 (kwallet6 detectable)
#   secrets-ok — fails for kwalletd6 dest, succeeds for all other dests
#   fail       — always exits 1 with no output (no keyring accessible)
_stub_dbus_send() {
	mkdir -p "$TEST_TMP/bin"
	case "${1:-fail}" in
		kwallet6)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
echo 'boolean true'
STUB
			;;
		secrets-ok)
			cat > "$TEST_TMP/bin/dbus-send" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *kwalletd6* ]] && exit 1
exit 0
STUB
			;;
		*)
			printf '#!/usr/bin/env bash\nexit 1\n' \
				> "$TEST_TMP/bin/dbus-send"
			;;
	esac
	chmod +x "$TEST_TMP/bin/dbus-send"
	export PATH="$TEST_TMP/bin:$PATH"
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
	unset XDG_SESSION_TYPE
	unset CLAUDE_MENU_BAR
	unset CLAUDE_TITLEBAR_STYLE
	unset COWORK_VM_BACKEND
	unset ELECTRON_USE_SYSTEM_TITLE_BAR
	unset GTK_IM_MODULE
	unset XMODIFIERS
	unset QT_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_PASSWORD_STORE
	CLAUDE_PASSWORD_STORE='basic'

	# Copy to temp dir so we can substitute the build-time placeholder
	# and co-locate doctor.sh (sourced via BASH_SOURCE dirname).
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/launcher-common.sh"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/doctor.sh"
	sed -i 's/@@WM_CLASS@@/Claude/' "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
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
# log_session_env
# =============================================================================

@test "log_session_env: emits env={ ... } block with all required keys" {
	setup_logging
	XDG_SESSION_TYPE='wayland'
	WAYLAND_DISPLAY='wayland-0'
	DISPLAY=':0'
	XDG_CURRENT_DESKTOP='KDE'
	GTK_IM_MODULE='ibus'
	XMODIFIERS='@im=ibus'
	QT_IM_MODULE='ibus'
	CLAUDE_USE_WAYLAND='1'
	CLAUDE_TITLEBAR_STYLE='hybrid'
	CLAUDE_PASSWORD_STORE='basic'
	CLAUDE_GTK_IM_MODULE='xim'
	CLAUDE_DISABLE_GPU='1'
	log_session_env

	run cat "$log_file"
	# Exact-line match locks block structure (open/close braces on
	# their own lines) and per-key formatting in one pass.
	[[ "${lines[0]}"  == 'env={' ]]
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=wayland' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=wayland-0' ]]
	[[ "${lines[3]}"  == '  DISPLAY=:0' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=KDE' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=ibus' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=@im=ibus' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=ibus' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=1' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=hybrid' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=basic' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=xim' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=1' ]]
	[[ "${lines[13]}" == '}' ]]
}

@test "log_session_env: unset/empty values render as 'KEY=' (no value)" {
	setup_logging
	# All vars unset by setup() except this one, which exercises the
	# empty-string branch (must be indistinguishable from unset).
	GTK_IM_MODULE=''
	unset CLAUDE_PASSWORD_STORE
	log_session_env

	run cat "$log_file"
	# Exact-line match proves the line ends right after '=' — a
	# substring like *'KEY='* would also match 'KEY=value'.
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=' ]]
	[[ "${lines[3]}"  == '  DISPLAY=' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=' ]]
	[[ "${lines[9]}"  == '  CLAUDE_TITLEBAR_STYLE=' ]]
	[[ "${lines[10]}" == '  CLAUDE_PASSWORD_STORE=' ]]
	[[ "${lines[11]}" == '  CLAUDE_GTK_IM_MODULE=' ]]
	[[ "${lines[12]}" == '  CLAUDE_DISABLE_GPU=' ]]
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

@test "detect_display_backend: non-Niri non-GNOME Wayland keeps XWayland default" {
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

@test "detect_display_backend: GNOME Wayland keeps XWayland default (not auto-flipped)" {
	# GNOME native+portal is opt-in only; the default session stays on
	# mature XWayland to avoid rendering/IME regressions (#404 portal
	# route is opt-in via CLAUDE_USE_WAYLAND=1).
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="GNOME"
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: GNOME Wayland + CLAUDE_USE_WAYLAND=1 opts into native" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="ubuntu:GNOME"
	CLAUDE_USE_WAYLAND=1
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == false ]]
}

@test "detect_display_backend: GNOME on X11 (not Wayland) stays X11" {
	DISPLAY=":0"
	XDG_CURRENT_DESKTOP="GNOME"
	setup_logging
	detect_display_backend
	[[ $is_wayland == false ]]
	# use_x11_on_wayland is the default true; the auto-detect block is
	# guarded by is_wayland so it never flips it on an X11 session.
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: CLAUDE_USE_WAYLAND=0 forces XWayland on GNOME" {
	WAYLAND_DISPLAY="wayland-0"
	XDG_CURRENT_DESKTOP="GNOME"
	CLAUDE_USE_WAYLAND=0
	setup_logging
	detect_display_backend
	[[ $is_wayland == true ]]
	[[ $use_x11_on_wayland == true ]]
}

@test "detect_display_backend: CLAUDE_USE_WAYLAND=0 forces XWayland on Niri" {
	WAYLAND_DISPLAY="wayland-0"
	NIRI_SOCKET="/tmp/niri.sock"
	CLAUDE_USE_WAYLAND=0
	setup_logging
	detect_display_backend
	[[ $use_x11_on_wayland == true ]]
}

# =============================================================================
# build_electron_args
# =============================================================================

@test "build_electron_args: includes --class matching upstream productName" {
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--class=Claude'
}

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

@test "build_electron_args: Wayland XWayland deb - no GlobalShortcutsPortal feature" {
	# The portal feature is inert under XWayland, so it must not be
	# emitted on the X11-via-XWayland path.
	is_wayland=true
	use_x11_on_wayland=true
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '*GlobalShortcutsPortal*'
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

@test "build_electron_args: Wayland native deb - enables GlobalShortcutsPortal (#404)" {
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '*GlobalShortcutsPortal*'
}

@test "build_electron_args: Wayland native deb - portal + ozone share one --enable-features" {
	# Chromium honours only the last --enable-features switch, so the
	# portal feature, UseOzonePlatform and WaylandWindowDecorations must
	# all live in a single comma-joined flag — not separate switches.
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args deb
	# Exactly one --enable-features switch (Chromium honours only the
	# last), carrying both features. Order inside the value is irrelevant
	# to Chromium, so assert each subkey independently rather than with an
	# ordered glob.
	[[ $(count_enable_features) -eq 1 ]]
	has_electron_arg '--enable-features=*UseOzonePlatform*'
	has_electron_arg '--enable-features=*GlobalShortcutsPortal*'
}

@test "build_electron_args: hidden titlebar + native Wayland - one merged --enable-features" {
	# WindowControlsOverlay (hidden titlebar) and the wayland/portal
	# features must coexist in a single flag rather than clobber.
	CLAUDE_TITLEBAR_STYLE=hidden
	is_wayland=true
	use_x11_on_wayland=false
	setup_logging
	build_electron_args deb
	[[ $(count_enable_features) -eq 1 ]]
	has_electron_arg '*WindowControlsOverlay*'
	has_electron_arg '*GlobalShortcutsPortal*'
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

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in hybrid mode (default)" {
	setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: sets ELECTRON_USE_SYSTEM_TITLE_BAR in native mode" {
	CLAUDE_TITLEBAR_STYLE=native setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR in hidden mode" {
	CLAUDE_TITLEBAR_STYLE=hidden setup_electron_env
	[[ -z ${ELECTRON_USE_SYSTEM_TITLE_BAR:-} ]]
}

@test "setup_electron_env: skips ELECTRON_USE_SYSTEM_TITLE_BAR for invalid value (falls back to hybrid)" {
	CLAUDE_TITLEBAR_STYLE=garbage setup_electron_env
	[[ $ELECTRON_USE_SYSTEM_TITLE_BAR == '1' ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set propagates to GTK_IM_MODULE" {
	setup_logging
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	[[ $GTK_IM_MODULE == 'xim' ]]
	# Override is logged so users can verify it took effect
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: ibus -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE set logs <unset> when GTK_IM_MODULE was unset" {
	setup_logging
	# GTK_IM_MODULE unset by setup()
	CLAUDE_GTK_IM_MODULE='xim'
	setup_electron_env
	[[ $GTK_IM_MODULE == 'xim' ]]
	run cat "$log_file"
	[[ $output == *'GTK_IM_MODULE override: <unset> -> xim (via CLAUDE_GTK_IM_MODULE)'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE unset leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	# CLAUDE_GTK_IM_MODULE unset by setup()
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	# No override line should appear in the log
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

@test "setup_electron_env: CLAUDE_GTK_IM_MODULE empty leaves GTK_IM_MODULE alone" {
	setup_logging
	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE=''
	setup_electron_env
	[[ $GTK_IM_MODULE == 'ibus' ]]
	run cat "$log_file"
	[[ $output != *'GTK_IM_MODULE override'* ]]
}

# =============================================================================
# _resolve_titlebar_style
# =============================================================================

@test "_resolve_titlebar_style: returns 'hybrid' when unset" {
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'hybrid' for hybrid" {
	CLAUDE_TITLEBAR_STYLE=hybrid
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: returns 'native' for native" {
	CLAUDE_TITLEBAR_STYLE=native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: returns 'hidden' for hidden" {
	CLAUDE_TITLEBAR_STYLE=hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: case-insensitive (HYBRID)" {
	CLAUDE_TITLEBAR_STYLE=HYBRID
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Native)" {
	CLAUDE_TITLEBAR_STYLE=Native
	[[ $(_resolve_titlebar_style) == 'native' ]]
}

@test "_resolve_titlebar_style: case-insensitive (Hidden)" {
	CLAUDE_TITLEBAR_STYLE=Hidden
	[[ $(_resolve_titlebar_style) == 'hidden' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for invalid value" {
	CLAUDE_TITLEBAR_STYLE=garbage
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

@test "_resolve_titlebar_style: falls back to hybrid for empty value" {
	CLAUDE_TITLEBAR_STYLE=''
	[[ $(_resolve_titlebar_style) == 'hybrid' ]]
}

# =============================================================================
# build_electron_args: titlebar mode flag selection
# =============================================================================

@test "build_electron_args: hybrid mode (default) disables CustomTitlebar" {
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: native mode disables CustomTitlebar" {
	CLAUDE_TITLEBAR_STYLE=native
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--disable-features=CustomTitlebar'
	# shellcheck disable=SC2314
	! has_electron_arg '--enable-features=WindowControlsOverlay'
}

@test "build_electron_args: hidden mode enables WindowControlsOverlay" {
	CLAUDE_TITLEBAR_STYLE=hidden
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--enable-features=WindowControlsOverlay'
	# shellcheck disable=SC2314
	! has_electron_arg '--disable-features=CustomTitlebar'
}

@test "build_electron_args: invalid titlebar value falls back to hybrid flags" {
	CLAUDE_TITLEBAR_STYLE=garbage
	is_wayland=false
	setup_logging
	build_electron_args deb
	has_electron_arg '--disable-features=CustomTitlebar'
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

	# Stub pgrep so the test is isolated from host process state:
	# a real cowork-vm-service daemon on the developer machine would
	# trip the function's "daemon alive, leave socket alone" branch.
	pgrep() { return 1; }

	setup_logging
	cleanup_stale_cowork_socket
	[[ ! -S "$sock" ]]
}

# =============================================================================
# cleanup_orphaned_cowork_daemon
#
# Reaps a cowork-vm-service daemon left behind by a crashed UI, but only
# when no live Claude UI is running. pgrep/kill/sleep are stubbed; the
# "live UI" case uses a real background process so the /proc cmdline and
# status reads resolve naturally without faking /proc.
# =============================================================================

@test "cleanup_orphaned_cowork_daemon: no daemon running — no action, no log" {
	# Daemon pgrep finds nothing, so the function returns before any
	# UI scan or kill.
	pgrep() { return 1; }
	kill() { echo "kill $*" >> "$TEST_TMP/kills"; }

	setup_logging
	run cleanup_orphaned_cowork_daemon
	[[ $status -eq 0 ]]
	[[ ! -f "$TEST_TMP/kills" ]]
	[[ ! -f $log_file ]]
}

@test "cleanup_orphaned_cowork_daemon: live UI present — daemon left running" {
	# A real background process stands in for the live Electron UI so
	# the /proc cmdline and status reads resolve naturally. The UI
	# scan fingerprints on the launcher-passed --class flag (since
	# #700 app.asar no longer appears in any cmdline), so the
	# stand-in's argv[0] is renamed to carry it via exec -a. Its state
	# is sleeping (not T/t/Z), so the function treats it as a live UI
	# and must NOT kill the daemon.
	bash -c 'exec -a "--class=Claude" sleep 300' &
	ui_pid=$!

	# Match on "$*", not "$2": the UI scan passes -u <uid> and a `--`
	# end-of-options separator before the pattern, so the pattern is
	# not at a fixed argument position.
	pgrep() {
		if [[ $* == *cowork-vm-service* ]]; then
			echo 4242
		elif [[ $* == *--class=Claude* ]]; then
			echo "$ui_pid"
		fi
	}
	kill() { echo "kill $*" >> "$TEST_TMP/kills"; }

	setup_logging
	cleanup_orphaned_cowork_daemon
	local rc=$?
	builtin kill "$ui_pid" 2>/dev/null

	[[ $rc -eq 0 ]]
	# Daemon kill must never have been attempted.
	[[ ! -f "$TEST_TMP/kills" ]]
}

@test "cleanup_orphaned_cowork_daemon: orphan exits on SIGTERM — no SIGKILL" {
	# Daemon present, no live UI. The daemon disappears once SIGTERM is
	# sent, so the escalation to SIGKILL must not fire.
	local term_sent="$TEST_TMP/term_sent"
	pgrep() {
		if [[ $* == *cowork-vm-service* ]]; then
			[[ -f $term_sent ]] && return 1
			echo 4242
		else
			# UI scan (--class fingerprint): no live UI.
			return 1
		fi
	}
	kill() {
		echo "kill $*" >> "$TEST_TMP/kills"
		# A plain SIGTERM ($1 is the PID, not -KILL) reaps the daemon.
		[[ $1 == -KILL ]] || : > "$term_sent"
	}
	sleep() { :; }

	setup_logging
	# Via `run` so the function's internal `((_wait++))` (which returns 1
	# when _wait starts at 0) doesn't trip bats' errexit. Production has
	# no set -e, so this is a harness concern, not a code defect.
	run cleanup_orphaned_cowork_daemon

	grep -q 'Killed orphaned cowork-vm-service daemon (PIDs: 4242)' \
		"$log_file"
	# Negative assertions via `run` + status: a bare `! grep` that isn't
	# the last command does not fail a bats test (SC2314), so it would be
	# a hollow check.
	run grep -q 'SIGKILL' "$log_file"
	[[ $status -ne 0 ]]
	grep -q '^kill 4242$' "$TEST_TMP/kills"
	run grep -qF -- '-KILL' "$TEST_TMP/kills"
	[[ $status -ne 0 ]]
}

@test "cleanup_orphaned_cowork_daemon: orphan survives SIGTERM — escalates to SIGKILL" {
	# Daemon never dies, so after the SIGTERM grace window the function
	# escalates to SIGKILL and logs the SIGKILL variant.
	pgrep() {
		if [[ $* == *cowork-vm-service* ]]; then
			echo 4242
		else
			# UI scan (--class fingerprint): no live UI.
			return 1
		fi
	}
	kill() { echo "kill $*" >> "$TEST_TMP/kills"; }
	sleep() { :; }

	setup_logging
	# `run` for the same errexit reason as the SIGTERM test above.
	run cleanup_orphaned_cowork_daemon

	grep -q 'Killed orphaned cowork-vm-service daemon (SIGKILL, PIDs: 4242)' \
		"$log_file"
	grep -q '^kill 4242$' "$TEST_TMP/kills"
	grep -q '^kill -KILL 4242$' "$TEST_TMP/kills"
}

# =============================================================================
# cleanup_stale_desktop_helpers
# =============================================================================

@test "_desktop_helper_cmdline_matches: matches known Desktop helpers only" {
	local config_dir="$XDG_CONFIG_HOME/Claude"

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/electron --type=utility --user-data-dir=$config_dir"
	[[ $status -eq 0 ]]

	# tr '\0' ' ' joins cmdline args with a trailing space, so the
	# --user-data-dir arm anchors on "$config_dir " — exact dir only.
	run _desktop_helper_cmdline_matches \
		"/tmp/.mount_claudeXXXXXX/electron --type=utility --user-data-dir=$config_dir "
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"/tmp/.mount_claudeXXXXXX/electron --type=utility --user-data-dir=${config_dir}Dev "
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar.unpacked/cowork-vm-service.js"
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"node $config_dir/Claude Extensions/ant.dir.example/server.js"
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/electron /usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"claude --dangerously-skip-permissions"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"/home/scott/dev/dude/core/agent-dude/dist/index.js mcp"
	[[ $status -ne 0 ]]
}

@test "_claude_desktop_ui_cmdline_matches: keys on the --class fingerprint" {
	# Live UI: launcher argv carries --class=$WM_CLASS (tr '\0' ' '
	# leaves every argument space-terminated). Since #700 app.asar no
	# longer appears in any cmdline, so the --class flag from
	# build_electron_args is the only stable UI signature.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/electron --class=Claude --enable-features=WaylandWindowDecorations "
	[[ $status -eq 0 ]]

	# Another Electron app's asar path must not match.
	run _claude_desktop_ui_cmdline_matches \
		"/opt/other-electron-app/resources/app.asar "
	[[ $status -ne 0 ]]

	# Look-alike WM class is rejected by the trailing-space anchor.
	run _claude_desktop_ui_cmdline_matches \
		"/opt/claude-dev/electron --class=ClaudeDev "
	[[ $status -ne 0 ]]

	# Chromium helpers (--type=) never count as the UI, even if a
	# --class flag leaked into their argv.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/electron --type=utility --user-data-dir=$XDG_CONFIG_HOME/Claude --class=Claude "
	[[ $status -ne 0 ]]

	# The cowork daemon never counts as the UI.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar.unpacked/cowork-vm-service.js --class=Claude "
	[[ $status -ne 0 ]]
}

@test "run_electron_and_cleanup: runs cleanup after Electron exits and preserves status" {
	local marker="$TEST_TMP/cleanup-ran"
	local electron="$TEST_TMP/electron"

	cat > "$electron" <<'STUB'
#!/usr/bin/env bash
echo "electron argv: $*"
exit 7
STUB
	chmod +x "$electron"

	cleanup_after_electron_exit() {
		touch "$marker"
	}

	setup_logging
	run run_electron_and_cleanup "$electron" '--flag' 'value'
	[[ $status -eq 7 ]]
	[[ -f $marker ]]
	run cat "$log_file"
	[[ $output == *'electron argv: --flag value'* ]]
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

# =============================================================================
# _detect_password_store
# =============================================================================

@test "_detect_password_store: CLAUDE_PASSWORD_STORE env var wins without calling dbus-send" {
	CLAUDE_PASSWORD_STORE='mystore'
	# Stub dbus-send to fail — the early-return path must not reach it.
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'mystore' ]]
}

@test "_detect_password_store: falls back to kwallet6 when kwallet6 dbus-send call succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send kwallet6
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'kwallet6' ]]
}

@test "_detect_password_store: falls back to gnome-libsecret when kwallet6 fails but secrets ping succeeds" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send secrets-ok
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'gnome-libsecret' ]]
}

@test "_detect_password_store: falls back to basic when both dbus-send calls fail" {
	unset CLAUDE_PASSWORD_STORE
	_stub_dbus_send fail
	run _detect_password_store
	[[ $status -eq 0 ]]
	[[ $output == 'basic' ]]
}
