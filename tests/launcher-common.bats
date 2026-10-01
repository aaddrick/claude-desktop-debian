#!/usr/bin/env bats
#
# launcher-common.bats
# Tests for launcher utility functions in scripts/launcher-common.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

load 'test_helper'

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
	unset CLAUDE_FORCE_SANDBOX
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
	unset CLAUDE_TRAY_USE_DARK_ICON

	# Copy to temp dir so we can substitute the build-time placeholder
	# and co-locate doctor.sh (sourced via BASH_SOURCE dirname).
	#
	# The placeholder gets a test-only class, NOT the production
	# com.anthropic.Claude. The UI reapers find their targets with a
	# host-wide `pgrep -u $UID -f -- --class=$WM_CLASS`, so with the
	# production class every real-kill test also targets the user's
	# running Claude Desktop. Once dpkg has replaced its binary, its
	# /proc/PID/exe ends in " (deleted)" and the
	# cleanup_replaced_desktop_ui tests SIGTERM it, the quit guard
	# vetoes the quit, and the 2s escalation SIGKILLs it (exit 137)
	# along with every Claude Code session inside it. $$ keeps
	# concurrent bats runs from reaping each other's stand-ins.
	local test_wm_class="com.anthropic.ClaudeBatsTest$$"
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/launcher-common.sh"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/doctor.sh"
	sed -i "s/@@WM_CLASS@@/$test_wm_class/" "$TEST_TMP/launcher-common.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
}

teardown() {
	_kill_stand_ins
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
# rotate_log_file / setup_logging rotation (#747)
# =============================================================================

@test "rotation: log under cap is left untouched" {
	setup_logging
	printf 'small log content\n' > "$log_file"

	rotate_log_file

	[[ -f $log_file ]]
	[[ $(cat "$log_file") == 'small log content' ]]
	[[ ! -f "$log_file.1" ]]
}

@test "rotation: log over cap moves to .1 and clears live file" {
	setup_logging
	printf 'LIVE' > "$log_file"
	truncate -s 6M "$log_file"

	rotate_log_file

	[[ ! -f $log_file ]]
	[[ -f "$log_file.1" ]]
	[[ $(head -c 4 "$log_file.1") == 'LIVE' ]]
}

@test "rotation: keeps at most 2 old copies, drops oldest" {
	setup_logging
	printf 'OLD1' > "$log_file.1"
	printf 'OLD2' > "$log_file.2"
	printf 'LIVE' > "$log_file"
	truncate -s 6M "$log_file"

	rotate_log_file

	[[ $(head -c 4 "$log_file.1") == 'LIVE' ]]
	[[ $(head -c 4 "$log_file.2") == 'OLD1' ]]
	[[ ! -f "$log_file.3" ]]
}

@test "rotation: missing log file is a no-op returning 0" {
	setup_logging
	rm -f "$log_file"

	run rotate_log_file

	[[ $status -eq 0 ]]
	[[ ! -f "$log_file.1" ]]
}

@test "setup_logging: still returns 0 after rotating an over-cap file" {
	log_dir="$XDG_CACHE_HOME/claude-desktop-debian"
	mkdir -p "$log_dir"
	log_file="$log_dir/launcher.log"
	truncate -s 6M "$log_file"

	run setup_logging

	[[ $status -eq 0 ]]
	[[ -f "$log_file.1" ]]
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

@test "log_message: redacts OAuth code from claude://login argv (LOG-1)" {
	setup_logging
	# Both the "Arguments:" and "Executing:" lines carry $* verbatim.
	log_message "Arguments: claude://login/google-auth?code=SECRET123&state=xyz"
	log_message "Executing: /usr/lib/claude-desktop/claude-desktop --class=com.anthropic.Claude claude://login/google-auth?code=SECRET456"
	run cat "$log_file"
	[[ "$output" != *SECRET123* ]]
	[[ "$output" != *SECRET456* ]]
	[[ "$output" != *'code='* ]]
	# Path is kept for context; only the query string is stripped.
	[[ "${lines[0]}" == 'Arguments: claude://login/google-auth?<redacted>' ]]
	[[ "${lines[1]}" == *'--class=com.anthropic.Claude claude://login/google-auth?<redacted>' ]]
}

@test "log_message: leaves non-login messages untouched" {
	setup_logging
	log_message 'Executing: /usr/lib/claude-desktop/claude-desktop --class=com.anthropic.Claude'
	run cat "$log_file"
	[[ "${lines[0]}" == 'Executing: /usr/lib/claude-desktop/claude-desktop --class=com.anthropic.Claude' ]]
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
	CLAUDE_PASSWORD_STORE='basic'
	CLAUDE_GTK_IM_MODULE='xim'
	CLAUDE_DISABLE_GPU='1'
	CLAUDE_TRAY_USE_DARK_ICON='1'
	log_session_env

	run cat "$log_file"
	# Exact-line match locks block structure (open/close braces on
	# their own lines) and per-key formatting in one pass.
	# CLAUDE_TITLEBAR_STYLE is no longer honored (v3.0.0 rebase) and was
	# dropped from the key list.
	[[ "${lines[0]}"  == 'env={' ]]
	[[ "${lines[1]}"  == '  XDG_SESSION_TYPE=wayland' ]]
	[[ "${lines[2]}"  == '  WAYLAND_DISPLAY=wayland-0' ]]
	[[ "${lines[3]}"  == '  DISPLAY=:0' ]]
	[[ "${lines[4]}"  == '  XDG_CURRENT_DESKTOP=KDE' ]]
	[[ "${lines[5]}"  == '  GTK_IM_MODULE=ibus' ]]
	[[ "${lines[6]}"  == '  XMODIFIERS=@im=ibus' ]]
	[[ "${lines[7]}"  == '  QT_IM_MODULE=ibus' ]]
	[[ "${lines[8]}"  == '  CLAUDE_USE_WAYLAND=1' ]]
	[[ "${lines[9]}"  == '  CLAUDE_PASSWORD_STORE=basic' ]]
	[[ "${lines[10]}" == '  CLAUDE_GTK_IM_MODULE=xim' ]]
	[[ "${lines[11]}" == '  CLAUDE_DISABLE_GPU=1' ]]
	[[ "${lines[12]}" == '  CLAUDE_TRAY_USE_DARK_ICON=1' ]]
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
	[[ "${lines[9]}"  == '  CLAUDE_PASSWORD_STORE=' ]]
	[[ "${lines[10]}" == '  CLAUDE_GTK_IM_MODULE=' ]]
	[[ "${lines[11]}" == '  CLAUDE_DISABLE_GPU=' ]]
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
	has_electron_arg "--class=$WM_CLASS"
}

@test "build_electron_args: X11 deb defaults to a minimal argv (opt-in policy)" {
	# The launcher is opt-in only: on a plain X11 deb session with no env
	# overrides it must pass ONLY --class — nothing that shadows an
	# official upstream code path (no titlebar/feature/password-store
	# flag). This is the policy regression test; the switch-list smoke
	# (tools/chromium-switch-smoke.sh) guards the same invariant in CI.
	is_wayland=false
	setup_logging
	build_electron_args deb
	[[ ${#electron_args[@]} -eq 1 ]]
	[[ ${electron_args[0]} == "--class=$WM_CLASS" ]]
}

@test "build_electron_args: CLAUDE_PASSWORD_STORE set - passes flag + logs it" {
	is_wayland=false
	CLAUDE_PASSWORD_STORE='gnome-libsecret'
	setup_logging
	build_electron_args deb
	has_electron_arg '--password-store=gnome-libsecret'
	run cat "$log_file"
	[[ $output == *'Password store: gnome-libsecret (env override)'* ]]
}

@test "build_electron_args: CLAUDE_PASSWORD_STORE unset - no --password-store arg" {
	# Default: the official os_crypt autodetect owns the decision, so the
	# launcher must not emit a --password-store flag at all.
	is_wayland=false
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--password-store=*'
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

@test "build_electron_args: CLAUDE_FORCE_SANDBOX=1 - Wayland deb omits --no-sandbox (#804)" {
	is_wayland=true
	use_x11_on_wayland=true
	CLAUDE_FORCE_SANDBOX=1
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX=1 - Wayland nix omits --no-sandbox (#804)" {
	is_wayland=true
	use_x11_on_wayland=true
	CLAUDE_FORCE_SANDBOX=1
	setup_logging
	build_electron_args nix
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX=1 - appimage still gets --no-sandbox (FUSE, unconditional)" {
	# FUSE constraints apply regardless of the sandbox opt-in — this
	# escape hatch only ever affects the Wayland deb/nix branch.
	is_wayland=true
	use_x11_on_wayland=true
	CLAUDE_FORCE_SANDBOX=1
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: CLAUDE_FORCE_SANDBOX unset - Wayland deb still gets --no-sandbox (default unchanged)" {
	is_wayland=true
	use_x11_on_wayland=true
	unset CLAUDE_FORCE_SANDBOX
	setup_logging
	build_electron_args deb
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
#
# ELECTRON_FORCE_IS_PACKAGED and ELECTRON_USE_SYSTEM_TITLE_BAR were both
# dropped in the v3.0.0 rebase: the official build ships packaged and
# owns its own window frame, so the launcher no longer sets either.
# =============================================================================

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

@test "cleanup_stale_lock: keeps lock held by a running Claude Desktop" {
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	_spawn_claude_desktop_stand_in
	ln -s "myhost-$claude_pid" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock held by a pre-3.0 electron/dist instance" {
	# The lock is shared with whatever Claude Desktop build is still
	# running: across a 2.x -> 3.x upgrade that is the old tree's
	# electron binary, launched with a different --class. Its lock is
	# live; unlinking it would start a second instance on the profile.
	# Pins the executable-PATH test: a basename match on
	# `claude-desktop` turns this red.
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	_spawn_claude_desktop_stand_in \
		'claude-desktop/node_modules/electron/dist/electron'
	ln -s "myhost-$claude_pid" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock held by a replaced (deleted-exe) instance" {
	# A UI whose binary dpkg/rpm replaced underneath it reads
	# " (deleted)" on /proc/PID/exe but still holds the lock;
	# cleanup_replaced_desktop_ui owns that case, this function must
	# not pull the lock out from under a live process.
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	_spawn_claude_desktop_stand_in
	rm "$TEST_TMP/claude-desktop"
	# Precondition: the marker is there.
	readlink "/proc/$claude_pid/exe" | grep -q ' (deleted)$'
	ln -s "myhost-$claude_pid" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: removes lock whose PID was reused by another process" {
	# #784: kill -0 alone kept a stale lock forever once its PID had
	# been recycled by any other process of the same user, which
	# leaves every subsequent launch silently quitting.
	local config_dir="$XDG_CONFIG_HOME/Claude"
	mkdir -p "$config_dir"
	_spawn_plain_sleep
	ln -s "myhost-$plain_pid" "$config_dir/SingletonLock"
	# Precondition: the PID really is signalable, so this test can
	# only pass via the executable check.
	kill -0 "$plain_pid"
	setup_logging
	cleanup_stale_lock
	[[ ! -L "$config_dir/SingletonLock" ]]
	grep -q "PID $plain_pid was reused by another process" "$log_file"
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
# cleanup_stale_vm_bundle_images (#855)
# =============================================================================

@test "cleanup_stale_vm_bundle_images: no vm_bundles dir - returns 0" {
	run cleanup_stale_vm_bundle_images
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_vm_bundle_images: bundle with only rootfs.vhdx is left alone" {
	# Migration hasn't happened yet (no rootfs.img) - don't touch it.
	local bundle="$XDG_CONFIG_HOME/Claude/vm_bundles/claudevm.bundle"
	mkdir -p "$bundle"
	echo vhdx > "$bundle/rootfs.vhdx"
	echo vhdxzst > "$bundle/rootfs.vhdx.zst"

	setup_logging
	cleanup_stale_vm_bundle_images
	[[ -f "$bundle/rootfs.vhdx" ]]
	[[ -f "$bundle/rootfs.vhdx.zst" ]]
}

@test "cleanup_stale_vm_bundle_images: removes stale vhdx pair once rootfs.img exists" {
	local bundle="$XDG_CONFIG_HOME/Claude/vm_bundles/claudevm.bundle"
	mkdir -p "$bundle"
	echo img > "$bundle/rootfs.img"
	echo vhdx > "$bundle/rootfs.vhdx"
	echo vhdxzst > "$bundle/rootfs.vhdx.zst"

	setup_logging
	cleanup_stale_vm_bundle_images
	[[ ! -f "$bundle/rootfs.vhdx" ]]
	[[ ! -f "$bundle/rootfs.vhdx.zst" ]]
	[[ -f "$bundle/rootfs.img" ]]
	grep -q "Removed stale VM image(s)" "$log_file"
}

@test "cleanup_stale_vm_bundle_images: bundle already migrated (no vhdx) - no-op, no log" {
	local bundle="$XDG_CONFIG_HOME/Claude/vm_bundles/claudevm.bundle"
	mkdir -p "$bundle"
	echo img > "$bundle/rootfs.img"

	setup_logging
	cleanup_stale_vm_bundle_images
	[[ -f "$bundle/rootfs.img" ]]
	! grep -q "Removed stale VM image" "$log_file"
}

@test "cleanup_stale_vm_bundle_images: only removes vhdx in bundles with rootfs.img, leaves siblings alone" {
	local bundles="$XDG_CONFIG_HOME/Claude/vm_bundles"
	mkdir -p "$bundles/migrated" "$bundles/not-migrated"
	echo img > "$bundles/migrated/rootfs.img"
	echo vhdx > "$bundles/migrated/rootfs.vhdx"
	echo vhdx > "$bundles/not-migrated/rootfs.vhdx"

	setup_logging
	cleanup_stale_vm_bundle_images
	[[ ! -f "$bundles/migrated/rootfs.vhdx" ]]
	[[ -f "$bundles/not-migrated/rootfs.vhdx" ]]
}

@test "cleanup_stale_vm_bundle_images: log names the bundle without the glob's trailing slash" {
	# The glob yields ".../claudevm.bundle/"; without the strip the log
	# reads "claudevm.bundle/: rootfs.vhdx". Pin the exact tail.
	local bundle="$XDG_CONFIG_HOME/Claude/vm_bundles/claudevm.bundle"
	mkdir -p "$bundle"
	echo img > "$bundle/rootfs.img"
	echo vhdx > "$bundle/rootfs.vhdx"

	setup_logging
	cleanup_stale_vm_bundle_images
	grep -qF "in $bundle: rootfs.vhdx (#855)" "$log_file"
}

# =============================================================================
# _cowork_fallback_daemon_pids (#882)
#
# The reaper SIGKILLs whatever this returns, so it is pinned against REAL
# processes: the argv it checks comes from /proc, which a stubbed pgrep
# returning a made-up PID has no entry for. pgrep is scoped to this
# test's stand-ins (_scope_pgrep_to_stand_ins), so a developer's live
# daemon is never read; bystanders stay inside that scope, so it is the
# argv check that drops them.
# =============================================================================

@test "_cowork_fallback_daemon_pids: matches the spawn-swap-B daemon argv" {
	_scope_pgrep_to_stand_ins
	_spawn_cowork_daemon_stand_in
	run _cowork_fallback_daemon_pids
	[[ $status -eq 0 ]]
	[[ $output == "$cowork_pid" ]]
}

# One test per bystander shape: each is the only thing standing between
# a dropped argv check and a kill, so each needs its own red.
@test "_cowork_fallback_daemon_pids: skips an editor on the script (argv[2] not -socket)" {
	_scope_pgrep_to_stand_ins
	_spawn_cowork_bystander_stand_in editor
	# Precondition: the scoped pgrep does see it, so only the argv
	# check can be what drops it.
	run pgrep -u "$(id -u)" -f 'cowork-vm-service\.js'
	[[ $output == "${bystander_pids[0]}" ]]
	run _cowork_fallback_daemon_pids
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_cowork_fallback_daemon_pids: skips a hand-run relative-path daemon (argv[1] not absolute)" {
	_scope_pgrep_to_stand_ins
	_spawn_cowork_bystander_stand_in relative
	run pgrep -u "$(id -u)" -f 'cowork-vm-service\.js'
	[[ $output == "${bystander_pids[0]}" ]]
	run _cowork_fallback_daemon_pids
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_cowork_fallback_daemon_pids: skips a command line packed into argv[0]" {
	_scope_pgrep_to_stand_ins
	_spawn_cowork_bystander_stand_in packed
	run pgrep -u "$(id -u)" -f 'cowork-vm-service\.js'
	[[ $output == "${bystander_pids[0]}" ]]
	run _cowork_fallback_daemon_pids
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_cowork_fallback_daemon_pids: candidates are scoped to the current user" {
	# Another user's daemon can't be spawned without root, so pin the
	# flag itself by recording pgrep's argv.
	pgrep() { printf '%s\n' "$*" > "$TEST_TMP/pgrep.args"; return 1; }
	_cowork_fallback_daemon_pids
	[[ $(< "$TEST_TMP/pgrep.args") == "-u $(id -u) -f "* ]]
}

# The launcher's own bash (and its parent) is never daemon-shaped in
# practice, so these give it that shape: a script started with the
# daemon's argv runs the predicate and hands it the one PID under test
# as the only candidate. Without the skip the argv check would accept it.
_run_predicate_as_daemon() {
	local script="$1"
	# shellcheck disable=SC2016  # inner shell expands $@
	run env LC="$TEST_TMP/launcher-common.sh" \
		bash -c 'exec -a node bash "$@"' _ "$script" -socket sock
}

@test "_cowork_fallback_daemon_pids: never returns the calling shell (\$\$)" {
	local dir="$TEST_TMP/self"
	mkdir -p "$dir"
	cat > "$dir/cowork-vm-service.js" <<-'EOF'
		source "$LC"
		pgrep() { printf '%s\n' "$$"; }
		_cowork_fallback_daemon_pids
	EOF
	_run_predicate_as_daemon "$dir/cowork-vm-service.js"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_cowork_fallback_daemon_pids: never returns the caller's parent (\$PPID)" {
	local dir="$TEST_TMP/parent"
	mkdir -p "$dir"
	cat > "$dir/child.sh" <<-'EOF'
		source "$LC"
		pgrep() { printf '%s\n' "$PPID"; }
		_cowork_fallback_daemon_pids
	EOF
	# The daemon-shaped parent waits for the child (`; exit $?` rules
	# out any exec-the-last-command shortcut), so the child's $PPID is
	# the daemon-shaped process.
	printf 'bash %q; exit $?\n' "$dir/child.sh" \
		> "$dir/cowork-vm-service.js"
	_run_predicate_as_daemon "$dir/cowork-vm-service.js"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

# =============================================================================
# cleanup_orphaned_cowork_daemon
#
# Reaps a cowork-vm-service daemon left behind by a crashed UI, but only
# when no live Claude UI is running. The daemon and bystanders are real
# processes (see _cowork_fallback_daemon_pids above); the "live UI" case
# also uses a real background process so the /proc cmdline and status
# reads resolve naturally without faking /proc.
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
	bash -c "exec -a '--class=$WM_CLASS' sleep 300" &
	ui_pid=$!
	# Wait for the exec to land before running the reaper: on a loaded
	# runner the child can still carry its pre-exec argv when the UI
	# scan reads /proc cmdline, so the fingerprint misses and the
	# reaper takes the orphan path (flaked CI on 2026-07-10). Poll the
	# reaper's own predicate, not a parallel pattern that can drift —
	# a loose grep matches the pre-exec cmdline (--class=Claude inside
	# the bash -c quoting) that the strict fingerprint still rejects.
	# Fail loudly on timeout: exec lands in ~4ms, so a silent
	# fall-through would reproduce the exact flake signature this
	# poll exists to kill. Plain assignment, not ((i++)), to dodge
	# the errexit trap.
	local _i=0
	while ! _claude_desktop_ui_cmdline_matches \
		"$(tr '\0' ' ' < "/proc/$ui_pid/cmdline" 2>/dev/null)"; do
		if ((_i >= 50)); then
			echo "stand-in UI $ui_pid never matched the reaper's" \
				'fingerprint within 5s' >&2
			return 1
		fi
		sleep 0.1
		_i=$((_i + 1))
	done

	# A real daemon stand-in, so the candidate survives the argv check
	# and only the live-UI short-circuit can be what spares it. Match
	# on "$*", not "$2": the UI scan passes -u <uid> and a `--`
	# end-of-options separator before the pattern, so the pattern is
	# not at a fixed argument position.
	_spawn_cowork_daemon_stand_in
	pgrep() {
		if [[ $* == *cowork-vm-service* ]]; then
			command pgrep "$@" | grep -x -- "$cowork_pid"
		elif [[ $* == *"--class=$WM_CLASS"* ]]; then
			echo "$ui_pid"
		fi
	}

	setup_logging
	cleanup_orphaned_cowork_daemon
	local rc=$?
	builtin kill "$ui_pid" 2>/dev/null

	[[ $rc -eq 0 ]]
	# The daemon must still be alive, and no reap logged.
	kill -0 "$cowork_pid"
	[[ ! -f $log_file ]]
}

# End-to-end reap legs (#369): a REAL fallback daemon reaped by REAL
# kill/sleep (pgrep is scoped to the stand-ins — see
# _scope_pgrep_to_stand_ins — but the signals it drives are real). The
# former stubbed exit/escalate cases fed pgrep a made-up PID, which the
# argv fingerprint (#882) now rightly drops for lack of a /proc entry;
# these legs cover the same ground against real processes. A regression
# that still logs a plausible kill but never reaps the real process — a
# wrong pid resolution, a poll that never fires, the SIGKILL escalation
# dropped — reds here. On this box the reaper SIGTERM-reaps a live
# daemon in well under the 2s grace window.
@test "cleanup_orphaned_cowork_daemon: real orphan is reaped on quit" {
	# kill/sleep are the REAL ones, and only the "is a UI alive?"
	# predicate is stubbed false, to model "the app has quit" without
	# depending on whether a real Claude Desktop happens to be running
	# on the host (its --class scan would otherwise see it and bail —
	# the flake this box actually hit). The kill path under test stays
	# real, so a `kill "$pid"` -> `kill -0 "$pid"` slip still reds here.
	_claude_desktop_ui_is_alive() { return 1; }
	_spawn_cowork_daemon_stand_in
	_scope_pgrep_to_stand_ins

	setup_logging
	# `run` so _kill_pids_escalating's `((waited++))` (returns 1 at
	# waited=0) does not trip bats errexit; the real kills still fire
	# from the subshell. Production has no set -e.
	run cleanup_orphaned_cowork_daemon

	# The real process must be gone. Poll briefly: signal delivery and
	# reaping are near-instant but can lag under a loaded runner.
	local _i=0
	while kill -0 "$cowork_pid" 2>/dev/null; do
		((_i >= 30)) && break
		sleep 0.1
		_i=$((_i + 1))
	done
	run kill -0 "$cowork_pid"
	[[ $status -ne 0 ]]
	grep -qE \
		"Killed orphaned cowork-vm-service daemon .*\\b$cowork_pid\\b" \
		"$log_file"
	# SIGTERM sufficed — escalation must not have fired.
	run grep -q 'SIGKILL' "$log_file"
	[[ $status -ne 0 ]]
}

@test "cleanup_orphaned_cowork_daemon: real stuck orphan escalates to SIGKILL" {
	# The daemon ignores SIGTERM (trap "" TERM), so the grace window
	# elapses and the reaper must escalate to SIGKILL to reap it. A real
	# SIGKILL cannot be trapped, so surviving here means the escalation
	# never actually fired. UI predicate stubbed false, and pgrep scoped
	# to the stand-in, for the same host-isolation reasons as above.
	_claude_desktop_ui_is_alive() { return 1; }
	_spawn_cowork_daemon_stand_in trap
	_scope_pgrep_to_stand_ins

	setup_logging
	# `run` for the same errexit reason as above.
	run cleanup_orphaned_cowork_daemon

	local _i=0
	while kill -0 "$cowork_pid" 2>/dev/null; do
		((_i >= 30)) && break
		sleep 0.1
		_i=$((_i + 1))
	done
	run kill -0 "$cowork_pid"
	[[ $status -ne 0 ]]
	grep -qE \
		"Killed orphaned cowork-vm-service daemon \\(SIGKILL, PIDs: .*\\b$cowork_pid\\b" \
		"$log_file"
}

@test "cleanup_orphaned_cowork_daemon: reaps the daemon, spares processes naming the script (#882)" {
	# The destructive case: on a fresh launch no UI is alive, so the
	# argv fingerprint alone decides who gets SIGTERM then SIGKILL.
	# Every bystander is inside the scoped pgrep, so a substring match
	# would reap them all — as the pre-#882 reaper did.
	_claude_desktop_ui_is_alive() { return 1; }
	_spawn_cowork_daemon_stand_in
	_spawn_cowork_bystander_stand_in editor
	_spawn_cowork_bystander_stand_in relative
	_spawn_cowork_bystander_stand_in packed
	_scope_pgrep_to_stand_ins

	setup_logging
	# `run` for the same errexit reason as above.
	run cleanup_orphaned_cowork_daemon

	local _i=0
	while kill -0 "$cowork_pid" 2>/dev/null; do
		((_i >= 30)) && break
		sleep 0.1
		_i=$((_i + 1))
	done
	run kill -0 "$cowork_pid"
	[[ $status -ne 0 ]]
	local pid
	for pid in "${bystander_pids[@]}"; do
		kill -0 "$pid" || return 1
	done
	# The log names the daemon, and only the daemon.
	grep -qx \
		"Killed orphaned cowork-vm-service daemon (PIDs: $cowork_pid)" \
		"$log_file"
}

@test "cleanup_orphaned_cowork_daemon: several orphans log on one line, space-separated" {
	# pgrep prints one PID per line; interpolating that list straight
	# into the message split the log entry across lines.
	_claude_desktop_ui_is_alive() { return 1; }
	_spawn_cowork_daemon_stand_in
	_spawn_cowork_daemon_stand_in
	_scope_pgrep_to_stand_ins

	setup_logging
	# `run` for the same errexit reason as above.
	run cleanup_orphaned_cowork_daemon

	# pgrep lists by PID, which is spawn order unless PIDs wrapped, so
	# accept either order rather than flake on a wrap.
	local a="${cowork_pids[0]}" b="${cowork_pids[1]}"
	grep -qxE \
		"Killed orphaned cowork-vm-service daemon \\(PIDs: ($a $b|$b $a)\\)" \
		"$log_file"
}

# =============================================================================
# cleanup_stale_desktop_helpers
# =============================================================================

@test "_desktop_helper_cmdline_matches: matches known Desktop helpers only" {
	local config_dir="$XDG_CONFIG_HOME/Claude"

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/claude-desktop --type=utility --user-data-dir=$config_dir"
	[[ $status -eq 0 ]]

	# tr '\0' ' ' joins cmdline args with a trailing space, so the
	# --user-data-dir arm anchors on "$config_dir " — exact dir only.
	run _desktop_helper_cmdline_matches \
		"/tmp/.mount_claudeXXXXXX/electron --type=utility --user-data-dir=$config_dir "
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"/tmp/.mount_claudeXXXXXX/electron --type=utility --user-data-dir=${config_dir}Dev "
	[[ $status -ne 0 ]]

	# No cowork-vm-service.js substring arm (#905): the fallback daemon
	# is matched by argv shape in the reaper, so a pager on the script
	# is not a helper.
	run _desktop_helper_cmdline_matches \
		"less /usr/lib/claude-desktop/resources/cowork-vm-service.js "
	[[ $status -ne 0 ]]

	# Official Rust Cowork helper (spawned via process.resourcesPath).
	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/resources/app.asar.unpacked/cowork-linux-helper --socket /run/user/1000/cowork.sock"
	[[ $status -eq 0 ]]

	# Phase 3 package rename: our helpers now live under
	# /usr/lib/claude-desktop-unofficial/ and must match alongside the
	# official /usr/lib/claude-desktop/ arm above.
	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop-unofficial/claude-desktop --type=utility --user-data-dir=$config_dir"
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"node $config_dir/Claude Extensions/ant.dir.example/server.js"
	[[ $status -eq 0 ]]

	# chrome_crashpad_handler outlives the browser by design and
	# carries no --type= switch (only
	# --monitor-self-annotation=ptype=crashpad-handler), so the arms
	# above miss it. On AppImage that survivor is fatal: the runtime
	# unmounts /tmp/.mount_claude* the moment AppRun exits and crashpad
	# SIGBUSes on its own unmapped text.
	run _desktop_helper_cmdline_matches \
		"/tmp/.mount_claudeXXXXXX/usr/lib/claude-desktop/chrome_crashpad_handler --monitor-self-annotation=ptype=crashpad-handler --database=$config_dir/Crashpad --initial-client-fd=42 --shared-client-connection "
	[[ $status -eq 0 ]]

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop-unofficial/chrome_crashpad_handler --monitor-self-annotation=ptype=crashpad-handler --database=$config_dir/Crashpad "
	[[ $status -eq 0 ]]

	# ...but another Chromium app's crashpad is a bystander, not ours.
	run _desktop_helper_cmdline_matches \
		"/usr/lib/chromium/chrome_crashpad_handler --monitor-self-annotation=ptype=crashpad-handler --database=/home/u/.config/chromium/Crashpad "
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop/claude-desktop /usr/lib/claude-desktop/resources/app.asar"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"claude --dangerously-skip-permissions"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"/home/scott/dev/dude/core/agent-dude/dist/index.js mcp"
	[[ $status -ne 0 ]]

	# Every binary-shaped arm keys on argv[0], so a bystander that only
	# *names* one of our binaries as an argument is not a helper. The
	# debugger cases are the concrete ones: this reaper's own crashpad
	# bug leaves cores lying around, and whoever sits down to debug one
	# must not get SIGTERM'd by the next launch or quit.
	run _desktop_helper_cmdline_matches \
		"gdb /tmp/.mount_claudeXXXXXX/usr/lib/claude-desktop/chrome_crashpad_handler /var/lib/systemd/coredump/core.1234"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"coredumpctl gdb /usr/lib/claude-desktop-unofficial/chrome_crashpad_handler"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"less /usr/lib/claude-desktop/chrome_crashpad_handler"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"strings /usr/lib/claude-desktop-unofficial/claude-desktop --type=foo"
	[[ $status -ne 0 ]]

	run _desktop_helper_cmdline_matches \
		"vim /usr/lib/claude-desktop-unofficial/resources/cowork-linux-helper"
	[[ $status -ne 0 ]]

	# Chrome's native-messaging host lives in our tree but is spawned
	# and owned by the browser, not by Claude Desktop. In-tree argv[0]
	# alone must not be enough to match; the --type= half is what keeps
	# this one out. Captured live from an rpm install.
	run _desktop_helper_cmdline_matches \
		"/usr/lib/claude-desktop-unofficial/resources/chrome-native-host chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"
	[[ $status -ne 0 ]]
}

@test "cleanup_stale_desktop_helpers: reaps the fallback daemon, spares processes naming the script (#905)" {
	# The #882 case again, through the helper reaper: on a fresh launch
	# no UI is alive, and every stand-in below is inside the scoped
	# pgrep, so a cowork-vm-service.js substring arm would reap the
	# bystanders along with the daemon. The daemon is spawned last so
	# its PID is the last one pgrep prints: the scoped stub must exit
	# like pgrep, or the reaper's `pids=$(...) || return 0` bails.
	_claude_desktop_ui_is_alive() { return 1; }
	_spawn_cowork_bystander_stand_in editor
	_spawn_cowork_bystander_stand_in relative
	_spawn_cowork_bystander_stand_in packed
	_spawn_cowork_daemon_stand_in
	_scope_pgrep_to_stand_ins

	setup_logging
	# `run` for the errexit reason given in the cowork daemon tests.
	run cleanup_stale_desktop_helpers

	local _i=0
	while kill -0 "$cowork_pid" 2>/dev/null; do
		((_i >= 30)) && break
		sleep 0.1
		_i=$((_i + 1))
	done
	run kill -0 "$cowork_pid"
	[[ $status -ne 0 ]]
	local pid
	for pid in "${bystander_pids[@]}"; do
		kill -0 "$pid" || return 1
	done
	# The log names the daemon, and only the daemon.
	grep -qx \
		"Killed stale Claude Desktop helpers (PIDs: $cowork_pid)" \
		"$log_file"
}

@test "_claude_desktop_ui_cmdline_matches: keys on the --class fingerprint" {
	# Live UI: launcher argv carries --class=$WM_CLASS (tr '\0' ' '
	# leaves every argument space-terminated). Since #700 app.asar no
	# longer appears in any cmdline, so the --class flag from
	# build_electron_args is the only stable UI signature.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/claude-desktop --class=$WM_CLASS --enable-features=WaylandWindowDecorations "
	[[ $status -eq 0 ]]

	# Another Electron app's asar path must not match.
	run _claude_desktop_ui_cmdline_matches \
		"/opt/other-electron-app/resources/app.asar "
	[[ $status -ne 0 ]]

	# Look-alike WM class is rejected by the trailing-space anchor.
	run _claude_desktop_ui_cmdline_matches \
		"/opt/claude-dev/electron --class=${WM_CLASS}Dev "
	[[ $status -ne 0 ]]

	# Chromium helpers (--type=) never count as the UI, even if a
	# --class flag leaked into their argv.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/claude-desktop --type=utility --user-data-dir=$XDG_CONFIG_HOME/Claude --class=$WM_CLASS "
	[[ $status -ne 0 ]]

	# The cowork daemon never counts as the UI.
	run _claude_desktop_ui_cmdline_matches \
		"/usr/lib/claude-desktop/resources/app.asar.unpacked/cowork-vm-service.js --class=$WM_CLASS "
	[[ $status -ne 0 ]]
}

# #903: Anthropic's official build runs its Electron main without
# --class, so a --class-only gate saw "no UI" while it was up and let
# the reapers kill its helpers. The stand-ins are real processes whose
# exe is named claude-desktop, and pgrep is scoped to them so a real
# Claude Desktop on the host can't satisfy (or be reaped by) any case.

@test "_claude_desktop_ui_is_alive: an official-style main without --class is a live UI (#903)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_claude_main_stand_in
	run _claude_desktop_ui_is_alive
	[[ $status -eq 0 ]]
}

@test "_claude_desktop_ui_is_alive: a --type= helper of that binary is not a UI (#903)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_claude_main_stand_in --type=renderer
	run _claude_desktop_ui_is_alive
	[[ $status -ne 0 ]]
}

@test "_claude_desktop_ui_is_alive: the binary run as Node is not a UI (#903)" {
	_scope_pgrep_to_main_stand_ins
	ELECTRON_RUN_AS_NODE=1 _spawn_claude_main_stand_in
	tr '\0' '\n' < "/proc/$stand_in_pid/environ" \
		| grep -qx 'ELECTRON_RUN_AS_NODE=1'
	run _claude_desktop_ui_is_alive
	[[ $status -ne 0 ]]
}

@test "cleanup_stale_desktop_helpers: an orphaned Node-mode extension can't shield itself (#903)" {
	_scope_pgrep_to_main_stand_ins
	local ext
	ext="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Claude Extensions/ext"
	ELECTRON_RUN_AS_NODE=1 \
		_spawn_claude_main_stand_in "$ext/server/index.js"
	setup_logging
	run cleanup_stale_desktop_helpers
	local i
	for ((i = 0; i < 30; i++)); do
		kill -0 "$stand_in_pid" 2>/dev/null || break
		sleep 0.1
	done
	run kill -0 "$stand_in_pid"
	[[ $status -ne 0 ]]
	grep -q 'Killed stale Claude Desktop helpers' "$log_file"
}

@test "_claude_desktop_ui_is_alive: a stopped official-style main is not a UI (#903)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_claude_main_stand_in
	kill -STOP "$stand_in_pid"
	run _claude_desktop_ui_is_alive
	kill -CONT "$stand_in_pid"
	[[ $status -ne 0 ]]
}

@test "_claude_desktop_ui_is_alive: an upgraded main (deleted exe) is still a live UI (#903)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_claude_main_stand_in
	rm "$(readlink "/proc/$stand_in_pid/exe")"
	readlink "/proc/$stand_in_pid/exe" | grep -q ' (deleted)$'
	run _claude_desktop_ui_is_alive
	[[ $status -eq 0 ]]
}

# The helper stand-in fakes an official in-tree renderer:
# argv[0] /usr/lib/claude-desktop/claude-desktop plus --type=renderer.
_spawn_official_helper_stand_in() {
	local fifo="$TEST_TMP/helper-block"
	mkfifo "$fifo"
	bash -c "exec -a /usr/lib/claude-desktop/claude-desktop \
		bash -c 'read -r _ < \"\$1\"' _ '$fifo' --type=renderer" 3>&- &
	helper_pid=$!
	main_stand_in_pids+=("$helper_pid")
	local i
	for ((i = 0; i < 50; i++)); do
		tr '\0' ' ' < "/proc/$helper_pid/cmdline" 2>/dev/null \
			| grep -q -- '--type=renderer' && return 0
		sleep 0.1
	done
	return 1
}

@test "cleanup_stale_desktop_helpers: spares the official app's helpers while its main runs (#903)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_claude_main_stand_in
	_spawn_official_helper_stand_in
	setup_logging
	run cleanup_stale_desktop_helpers
	sleep 0.3
	run kill -0 "$helper_pid"
	[[ $status -eq 0 ]]
	run grep -q 'Killed stale Claude Desktop helpers' "$log_file"
	[[ $status -ne 0 ]]
}

@test "cleanup_stale_desktop_helpers: still reaps that helper once no main is alive (#903 control)" {
	_scope_pgrep_to_main_stand_ins
	_spawn_official_helper_stand_in
	setup_logging
	run cleanup_stale_desktop_helpers
	local i
	for ((i = 0; i < 30; i++)); do
		kill -0 "$helper_pid" 2>/dev/null || break
		sleep 0.1
	done
	run kill -0 "$helper_pid"
	[[ $status -ne 0 ]]
	grep -q 'Killed stale Claude Desktop helpers' "$log_file"
}

@test "cleanup_replaced_desktop_ui: kills UI with deleted executable" {
	local stale_bin="$TEST_TMP/claude-bash"
	local block_fifo="$TEST_TMP/block"
	local stale_pid

	mkfifo "$block_fifo"
	cp /bin/bash "$stale_bin"
	# fd 3 is bats' run-coordination pipe: a spawned process that
	# inherits it keeps bats waiting for EOF if it ever survives the
	# test, so close it in the child.
	# shellcheck disable=SC2016  # inner shell expands $1
	"$stale_bin" -c 'read -r _ < "$1"' \
		claude-test "$block_fifo" "--class=$WM_CLASS" 3>&- &
	stale_pid=$!
	sleep 0.1
	rm "$stale_bin"

	readlink -f "/proc/$stale_pid/exe" | grep -q ' (deleted)$'

	setup_logging
	run cleanup_replaced_desktop_ui

	[[ $status -eq 0 ]]
	run timeout 2 bash -c \
		"while kill -0 '$stale_pid' 2>/dev/null; do sleep 0.1; done"
	[[ $status -eq 0 ]]
	run kill -0 "$stale_pid"
	[[ $status -ne 0 ]]
	grep -q 'Killed replaced Claude Desktop UI' "$log_file"
}

@test "cleanup_replaced_desktop_ui: leaves an intact-executable UI alone" {
	# The safety claim: the (deleted) marker is the ONLY thing that
	# licenses a kill. A fingerprinted process whose binary is still on
	# disk must survive untouched and produce no "Killed replaced" log
	# line. Replacing _claude_desktop_ui_is_replaced with an
	# unconditional `return 0` turns this red while both positive cases
	# stay green.
	local live_bin="$TEST_TMP/claude-bash-intact"
	local block_fifo="$TEST_TMP/block-intact"
	local live_pid

	mkfifo "$block_fifo"
	cp /bin/bash "$live_bin"
	# shellcheck disable=SC2016  # inner shell expands $1 (3>&-: see the
	# fd-3 note in the deleted-executable test above)
	"$live_bin" -c 'read -r _ < "$1"' \
		claude-test "$block_fifo" "--class=$WM_CLASS" 3>&- &
	live_pid=$!
	sleep 0.1
	# Precondition: intact binary, no marker.
	readlink "/proc/$live_pid/exe" | grep -qv ' (deleted)$'

	setup_logging
	# setup_logging creates the directory, not the file. Make the file
	# exist so the "no log line" assertion below cannot pass vacuously
	# on a missing file (grep would exit 2 either way).
	touch "$log_file"
	run cleanup_replaced_desktop_ui
	[[ $status -eq 0 ]]

	run kill -0 "$live_pid"
	[[ $status -eq 0 ]]
	[[ -f $log_file ]]
	run grep 'Killed replaced Claude Desktop UI' "$log_file"
	[[ $status -eq 1 ]]

	kill "$live_pid" 2>/dev/null || true
}

@test "cleanup_replaced_desktop_ui: still kills when the install dir is gone" {
	# A package migration or layout change removes the whole install
	# directory, not just the binary. `readlink -f` fails on that shape
	# (it canonicalizes through a now-missing parent), so this pins the
	# plain-readlink detection: reverting it turns this red while the
	# file-only-deleted test above stays green.
	local stale_dir="$TEST_TMP/gone-install-dir"
	local block_fifo="$TEST_TMP/block-dirgone"
	local stale_pid

	mkfifo "$block_fifo"
	mkdir -p "$stale_dir"
	cp /bin/bash "$stale_dir/claude-bash"
	# shellcheck disable=SC2016  # inner shell expands $1 (3>&-: see the
	# fd-3 note in the deleted-executable test above)
	"$stale_dir/claude-bash" -c 'read -r _ < "$1"' \
		claude-test "$block_fifo" "--class=$WM_CLASS" 3>&- &
	stale_pid=$!
	sleep 0.1
	rm -rf "$stale_dir"

	# The very failure mode under test: -f cannot resolve this shape.
	run readlink -f "/proc/$stale_pid/exe"
	[[ $status -ne 0 ]]
	readlink "/proc/$stale_pid/exe" | grep -q ' (deleted)$'

	setup_logging
	run cleanup_replaced_desktop_ui

	[[ $status -eq 0 ]]
	run timeout 2 bash -c \
		"while kill -0 '$stale_pid' 2>/dev/null; do sleep 0.1; done"
	[[ $status -eq 0 ]]
	run kill -0 "$stale_pid"
	[[ $status -ne 0 ]]
	grep -q 'Killed replaced Claude Desktop UI' "$log_file"
}

@test "cleanup_replaced_desktop_ui: spares a production-class UI" {
	# Stands in for the user's real Claude Desktop right after an apt
	# upgrade: production --class, binary deleted underneath it. The
	# suite must never reap it. setup() gives the sourced library a
	# test-only WM_CLASS precisely so this process is invisible to the
	# host-wide pgrep; reverting that substitution to
	# com.anthropic.Claude turns this red. (It would also make every
	# kill test above SIGKILL a real, upgraded Claude Desktop, which is
	# how this was found.)
	local stale_bin="$TEST_TMP/claude-bash-prod"
	local block_fifo="$TEST_TMP/block-prod"
	local prod_pid

	[[ $WM_CLASS != 'com.anthropic.Claude' ]]

	mkfifo "$block_fifo"
	cp /bin/bash "$stale_bin"
	# shellcheck disable=SC2016  # inner shell expands $1 (3>&-: see the
	# fd-3 note in the deleted-executable test above)
	"$stale_bin" -c 'read -r _ < "$1"' \
		claude-test "$block_fifo" --class=com.anthropic.Claude 3>&- &
	prod_pid=$!
	sleep 0.1
	rm "$stale_bin"
	readlink "/proc/$prod_pid/exe" | grep -q ' (deleted)$'

	setup_logging
	touch "$log_file"
	run cleanup_replaced_desktop_ui
	[[ $status -eq 0 ]]

	run kill -0 "$prod_pid"
	[[ $status -eq 0 ]]
	run grep 'Killed replaced Claude Desktop UI' "$log_file"
	[[ $status -eq 1 ]]

	kill "$prod_pid" 2>/dev/null || true
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
# run_electron_and_cleanup: bounded session log (#864)
# =============================================================================
#
# Electron's whole stdout/stderr goes into launcher.log for the life of
# the session; a looping Chromium message wrote 32 GB in a morning. The
# filter must collapse repeats, stop writing at the cap, and never
# close the pipe on the child. Each test's stub finishes by touching a
# marker and exiting with a distinct code, so "the child survived and
# ran to completion" is asserted directly rather than inferred.

# Write a stub "electron" that runs $1 as its body, then touches
# $TEST_TMP/done and exits $2.
_stub_electron() {
	local body="$1" code="$2"
	cat > "$TEST_TMP/electron" <<STUB
#!/usr/bin/env bash
$body
touch "$TEST_TMP/done"
exit $code
STUB
	chmod +x "$TEST_TMP/electron"
	cleanup_after_electron_exit() { :; }
}

@test "run_electron_and_cleanup: identical lines collapse to one plus a repeat count" {
	_stub_electron 'for ((i = 0; i < 1000; i++)); do echo "GPU process exited unexpectedly"; done' 5
	setup_logging
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 5 ]]
	[[ -f $TEST_TMP/done ]]
	[[ $(grep -c 'GPU process exited unexpectedly' "$log_file") -eq 1 ]]
	grep -qF '[launcher] last line repeated 999 more times' "$log_file"
}

@test "run_electron_and_cleanup: distinct lines stop at the cap, marker written, child completes" {
	# 1000 distinct ~40-byte lines (~40 KB) against a 4 KiB cap.
	_stub_electron 'for ((i = 0; i < 1000; i++)); do printf "distinct line %06d padding padding\n" "$i"; done' 6
	setup_logging
	ELECTRON_LOG_CAP_BYTES=4096
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 6 ]]
	[[ -f $TEST_TMP/done ]]
	grep -qF '[launcher] output cap (4096 bytes) reached' "$log_file"
	# Nothing after the marker but the launcher's own lines: the size
	# is the cap plus one marker line plus the exit/end lines.
	[[ $(stat -c '%s' "$log_file") -lt 5000 ]]
	[[ $(grep -c 'distinct line' "$log_file") -lt 1000 ]]
}

@test "run_electron_and_cleanup: a child that floods past the cap still runs to completion" {
	_stub_electron 'for ((i = 0; i < 3000; i++)); do printf "flood %06d padding padding padding\n" "$i"; done; echo "still alive after cap"' 8
	setup_logging
	ELECTRON_LOG_CAP_BYTES=2048
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 8 ]]
	[[ -f $TEST_TMP/done ]]
	grep -qF 'output cap (2048 bytes) reached' "$log_file"
	# Dropped, as designed.
	! grep -qF 'still alive after cap' "$log_file" || return 1
}

@test "_electron_output_filter: never closes its stdin after the cap" {
	# The property that keeps Electron off SIGPIPE/EPIPE. Tested on
	# the filter itself with an endless writer through a plain pipe:
	# a filter that keeps reading holds the pipeline open until
	# `timeout` kills it (rc 124); one that exits at the cap breaks
	# the pipe and the pipeline ends at once with some other status.
	# (Not tested through the fifo on purpose: mawk lingers in
	# pipe_read after `exit` when its stdin is a fifo, which would
	# hide a closed-pipe regression behind an implementation quirk.)
	# Distinct lines, or the dedupe would swallow them before the cap.
	run timeout 1 bash -c '
		source "'"$TEST_TMP"'/launcher-common.sh"
		awk "BEGIN { for (i = 0; ; i++) print \"flood \" i \" padding padding\" }" \
			| ELECTRON_LOG_CAP_BYTES=2048 _electron_output_filter \
			> /dev/null'
	[[ $status -eq 124 ]]
}

@test "run_electron_and_cleanup: child's last output lands before the exit line" {
	_stub_electron 'echo "first"; echo "last line from electron"' 0
	setup_logging
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 0 ]]
	local last exit_line
	last=$(grep -n 'last line from electron' "$log_file" | cut -d: -f1)
	exit_line=$(grep -n 'Electron exited with code: 0' "$log_file" | cut -d: -f1)
	[[ -n $last && -n $exit_line ]]
	(( last < exit_line ))
}

@test "run_electron_and_cleanup: falls back to a plain redirect when the pipe can't be made" {
	# Point TMPDIR at a file so mktemp -d fails; launch must still work
	# and still log, just unbounded (the pre-#864 behaviour).
	_stub_electron 'echo "fallback path output"' 4
	setup_logging
	: > "$TEST_TMP/not-a-dir"
	TMPDIR="$TEST_TMP/not-a-dir"
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 4 ]]
	[[ -f $TEST_TMP/done ]]
	grep -qF 'fallback path output' "$log_file"
	grep -qF 'Electron exited with code: 4' "$log_file"
}

@test "run_electron_and_cleanup: leaves no fifo directory behind" {
	_stub_electron 'echo hi' 0
	setup_logging
	TMPDIR="$TEST_TMP"
	run run_electron_and_cleanup "$TEST_TMP/electron"
	[[ $status -eq 0 ]]
	[[ -z $(ls -d "$TEST_TMP"/claude-launcher.* 2>/dev/null) ]]
}

@test "_electron_output_filter: default cap is 20 MiB" {
	# Pin the default so a stray edit can't quietly make it 20 KiB or
	# unbounded: 21 MiB of distinct input must trip the marker with
	# the documented byte count.
	unset ELECTRON_LOG_CAP_BYTES
	local last
	last=$(yes '0123456789012345678901234567890123456789012345678901234567890123' \
		| head -c $((21 * 1024 * 1024)) | awk '{ print NR ": " $0 }' \
		| _electron_output_filter | tail -n 1)
	[[ $last == *'output cap (20971520 bytes) reached'* ]]
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
# backup_user_config (P1 #768): rotate out-of-band copies of the user
# config and the Cowork stores before launch, so the config-wipe class
# stays recoverable (docs/learnings/config-wipe-guard.md)
# =============================================================================

# Absolute path of rotation slot $2 for the flattened backup name $1.
# The literal cache-relative path is the pin: moving the backup tree
# has to turn these tests red, so this must not re-derive it from the
# function under test.
_backup_slot() {
	echo "$XDG_CACHE_HOME/claude-desktop-debian/config-backups/$1.$2"
}

# Contents of rotation slot $2 for the flattened backup name $1.
_backup_body() {
	cat "$(_backup_slot "$1" "$2")"
}

# Write $1 verbatim (no trailing newline) into the user config.
_write_user_config() {
	mkdir -p "$XDG_CONFIG_HOME/Claude"
	printf '%s' "$1" \
		> "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
}

@test "backup_user_config: no user config - returns 0 and stays quiet" {
	# First-ever launch. Dropping the per-source existence test leaves
	# cp failing on a missing file, which both fails the function (it
	# is the last command in the loop) and, without the redirect,
	# prints cp's diagnostic over the launcher's own output.
	run backup_user_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
	[[ ! -e "$(_backup_slot claude_desktop_config.json 1)" ]]
}

@test "backup_user_config: first launch - slot .1 is a byte-identical copy" {
	local cfg="$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
	_write_user_config '{"mcpServers":{"fs":{"command":"npx"}}}'

	setup_logging
	backup_user_config

	# Recovery is a plain file copy, so the bytes have to round-trip.
	cmp -s "$cfg" "$(_backup_slot claude_desktop_config.json 1)"
	grep -q 'Backed up claude_desktop_config.json (keep 5)' "$log_file"
}

@test "backup_user_config: changed config rotates the previous copy to .2" {
	_write_user_config '{"mcpServers":{"fs":{"command":"npx"}}}'
	setup_logging
	backup_user_config

	# The wipe mode: the live file comes back as an empty object.
	_write_user_config '{}'
	backup_user_config

	local name=claude_desktop_config.json
	[[ $(_backup_body "$name" 1) == '{}' ]]
	[[ $(_backup_body "$name" 2) == \
		'{"mcpServers":{"fs":{"command":"npx"}}}' ]]
}

@test "backup_user_config: unchanged config does not rotate or log" {
	_write_user_config '{"mcpServers":{}}'
	setup_logging
	backup_user_config
	: > "$log_file"

	backup_user_config

	# Rotating on every launch would walk the last good copy off the
	# end of the five slots after four idle starts.
	[[ ! -e "$(_backup_slot claude_desktop_config.json 2)" ]]
	! grep -q 'Backed up' "$log_file"
}

@test "backup_user_config: keeps five slots and drops the oldest" {
	setup_logging
	local i
	for i in {1..7}; do
		_write_user_config "{\"n\":$i}"
		backup_user_config
	done

	local name=claude_desktop_config.json
	[[ $(_backup_body "$name" 1) == '{"n":7}' ]]
	[[ $(_backup_body "$name" 5) == '{"n":3}' ]]
	[[ ! -e "$(_backup_slot "$name" 6)" ]]
}

@test "backup_user_config: nested Cowork stores flatten into one name" {
	local store="$XDG_CONFIG_HOME/Claude/local-agent-mode-sessions"
	store="$store/acct-uuid/org-uuid"
	mkdir -p "$store"
	echo spaces > "$store/spaces.json"
	echo remote > "$store/remote-session-spaces.json"
	echo tasks > "$store/scheduled-tasks.json"
	echo other > "$store/history.json"

	setup_logging
	backup_user_config

	local base='local-agent-mode-sessions__acct-uuid__org-uuid'
	[[ $(_backup_body "${base}__spaces.json" 1) == spaces ]]
	[[ $(_backup_body "${base}__remote-session-spaces.json" 1) == remote ]]
	[[ $(_backup_body "${base}__scheduled-tasks.json" 1) == tasks ]]

	# Flattening, not basename: two accounts' spaces.json must not
	# collide in one slot.
	[[ ! -e "$(_backup_slot spaces.json 1)" ]]
	# Only the three known stores are rotated.
	[[ ! -e "$(_backup_slot "${base}__history.json" 1)" ]]
}

@test "backup_user_config: falls back to HOME/.cache when XDG unset" {
	# The function re-derives the cache root rather than reusing
	# setup_logging's, so the fallback needs its own case.
	unset XDG_CACHE_HOME
	_write_user_config '{"mcpServers":{}}'

	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	backup_user_config

	local slot="$HOME/.cache/claude-desktop-debian/config-backups"
	slot="$slot/claude_desktop_config.json.1"
	[[ $(cat "$slot") == '{"mcpServers":{}}' ]]
}

@test "backup_user_config: unwritable backup dir - returns 0 silently" {
	local jail="$TEST_TMP/readonly"
	mkdir -p "$jail"
	chmod 500 "$jail"
	# Fail-safe: the rotation must never block launch. Root,
	# CAP_DAC_OVERRIDE and mode-ignoring mounts all leave the jail
	# writable, and then there is no failure to be fail-safe about;
	# one predicate covers all three.
	[[ -w $jail ]] && skip 'directory mode not enforced here'

	_write_user_config '{"mcpServers":{}}'
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	export XDG_CACHE_HOME="$jail/cache"

	run backup_user_config
	[[ $status -eq 0 ]]
	# mkdir's own diagnostic must not reach the launch output either.
	[[ -z $output ]]
	! grep -q 'Backed up' "$log_file"
}

# =============================================================================
# heal_autostart_entry (AUTO-1): repoint the app-written XDG autostart
# entry from the raw ELF / ephemeral AppImage mount to the launcher
# =============================================================================

_write_autostart() {
	# $1 = Exec line; remaining upstream-shaped lines are fixed
	mkdir -p "$XDG_CONFIG_HOME/autostart"
	{
		echo '[Desktop Entry]'
		echo 'Type=Application'
		echo 'Name=Claude'
		echo "$1"
		echo 'X-GNOME-Autostart-enabled=true'
	} > "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
}

_autostart_exec() {
	grep '^Exec=' "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
}

@test "heal_autostart_entry: rewrites the raw-ELF Exec to the launcher" {
	_write_autostart 'Exec="/usr/lib/claude-desktop/claude-desktop" --startup'
	heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(_autostart_exec) == \
		'Exec="/usr/bin/claude-desktop-unofficial" --startup' ]]
}

@test "heal_autostart_entry: rewrites an ephemeral AppImage mount path" {
	_write_autostart \
		'Exec="/tmp/.mount_claudeXYZ/usr/lib/claude-desktop/claude-desktop" --startup'
	heal_autostart_entry "$HOME/Apps/Claude.AppImage"
	[[ $(_autostart_exec) == "Exec=\"$HOME/Apps/Claude.AppImage\" --startup" ]]
}

@test "heal_autostart_entry: idempotent when already pointing at the launcher" {
	_write_autostart 'Exec="/usr/bin/claude-desktop-unofficial" --startup'
	local before after
	before=$(cat "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop")
	heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	after=$(cat "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop")
	[[ $before == "$after" ]]
}

@test "heal_autostart_entry: leaves a hand-rolled wrapper Exec alone" {
	_write_autostart 'Exec="/home/user/bin/my-claude-wrapper" --startup'
	heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(_autostart_exec) == 'Exec="/home/user/bin/my-claude-wrapper" --startup' ]]
}

@test "heal_autostart_entry: handles an unquoted hand-edited Exec" {
	_write_autostart 'Exec=/usr/lib/claude-desktop/claude-desktop --startup --foo'
	heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(_autostart_exec) == \
		'Exec="/usr/bin/claude-desktop-unofficial" --startup --foo' ]]
}

@test "heal_autostart_entry: no-op when the entry file is absent" {
	rm -rf "$XDG_CONFIG_HOME/autostart"
	run heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	[[ $status -eq 0 ]]
	[[ ! -e "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop" ]]
}

@test "heal_autostart_entry: no-op when the launcher path is empty" {
	_write_autostart 'Exec="/usr/lib/claude-desktop/claude-desktop" --startup'
	run heal_autostart_entry ''
	[[ $status -eq 0 ]]
	[[ $(_autostart_exec) == 'Exec="/usr/lib/claude-desktop/claude-desktop" --startup' ]]
}

@test "heal_autostart_entry: preserves non-Exec lines and escapes % in the path" {
	_write_autostart 'Exec="/usr/lib/claude-desktop/claude-desktop" --startup'
	heal_autostart_entry '/opt/100%/claude-desktop'
	[[ $(_autostart_exec) == 'Exec="/opt/100%%/claude-desktop" --startup' ]]
	grep -q '^X-GNOME-Autostart-enabled=true$' \
		"$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
	grep -q '^Name=Claude$' \
		"$XDG_CONFIG_HOME/autostart/claude-desktop.desktop"
}

@test "heal_autostart_entry: logs the heal when logging is set up" {
	setup_logging
	_write_autostart 'Exec="/usr/lib/claude-desktop/claude-desktop" --startup'
	heal_autostart_entry '/usr/bin/claude-desktop-unofficial'
	grep -q 'Healed autostart Exec' "$log_file"
	grep -q 'AUTO-1' "$log_file"
}

# =============================================================================
# ensure_portal_app_id_entry (#805): hidden <WM_CLASS>.desktop so the
# xdg-desktop-portal Registry.Register call for the app id succeeds
# =============================================================================

# Isolate both XDG data locations: the host's /usr/share/applications
# may well hold the official com.anthropic.Claude.desktop, and the
# host's data home must never be written by a test.
_portal_setup() {
	export XDG_DATA_HOME="$TEST_TMP/data-home"
	export XDG_DATA_DIRS="$TEST_TMP/sys-a:$TEST_TMP/sys-b"
	portal_entry="$XDG_DATA_HOME/applications/$WM_CLASS.desktop"
	# Native Wayland, as detect_display_backend leaves it for =1.
	is_wayland=true
	use_x11_on_wayland=false
}

_write_system_entry() {
	mkdir -p "$TEST_TMP/sys-b/applications"
	printf '[Desktop Entry]\nName=Claude\n' \
		> "$TEST_TMP/sys-b/applications/$WM_CLASS.desktop"
}

@test "ensure_portal_app_id_entry: writes the hidden entry on native Wayland" {
	_portal_setup
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial' \
		'claude-desktop-unofficial'
	[[ -f $portal_entry ]]
	grep -qxF 'Exec="/usr/bin/claude-desktop-unofficial"' "$portal_entry"
	grep -qxF 'Icon=claude-desktop-unofficial' "$portal_entry"
	grep -qxF 'NoDisplay=true' "$portal_entry"
	grep -qxF "$PORTAL_ENTRY_MARKER" "$portal_entry"
}

@test "ensure_portal_app_id_entry: no-op under XWayland" {
	_portal_setup
	use_x11_on_wayland=true
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: no-op on X11" {
	_portal_setup
	is_wayland=false
	use_x11_on_wayland=true
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: no-op when the launcher path is empty" {
	_portal_setup
	run ensure_portal_app_id_entry ''
	[[ $status -eq 0 ]]
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: skips when a system entry exists" {
	_portal_setup
	_write_system_entry
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: removes its own entry once a system entry exists" {
	_portal_setup
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ -f $portal_entry ]]
	_write_system_entry
	# Removal must not depend on the backend: a later XWayland launch
	# still stops the stale entry shadowing the official menu entry.
	use_x11_on_wayland=true
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ ! -e $portal_entry ]]
}

@test "ensure_portal_app_id_entry: never touches a user-authored entry" {
	_portal_setup
	mkdir -p "${portal_entry%/*}"
	printf '[Desktop Entry]\nName=Mine\nExec=/opt/mine\n' > "$portal_entry"
	local before
	before=$(cat "$portal_entry")

	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(cat "$portal_entry") == "$before" ]]

	# Not even when a system entry would make ours redundant.
	_write_system_entry
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(cat "$portal_entry") == "$before" ]]
}

# The official app's own copy of the entry, as its desktop-entry writer
# emits it: the system entry's keys plus TryExec (the Exec command) and
# X-Claude-Generated=true. $1 = TryExec value.
_write_app_generated_entry() {
	mkdir -p "${portal_entry%/*}"
	{
		echo '[Desktop Entry]'
		echo 'Name=Claude'
		echo 'Exec=claude-desktop %U'
		echo 'Type=Application'
		echo "TryExec=$1"
		echo 'Actions=NewChat;'
		echo 'X-Claude-Generated=true'
	} > "$portal_entry"
}

@test "ensure_portal_app_id_entry: replaces the app's stale copy (TryExec gone)" {
	_portal_setup
	_write_app_generated_entry "$TEST_TMP/gone/claude-desktop"
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	grep -qxF "$PORTAL_ENTRY_MARKER" "$portal_entry"
	! grep -q '^X-Claude-Generated=' "$portal_entry"
	! grep -q '^TryExec=' "$portal_entry"
}

@test "ensure_portal_app_id_entry: replaces a stale copy whose TryExec is a bare name" {
	_portal_setup
	# A PATH with only the tools the helper runs, so a host that has
	# a real claude-desktop on PATH cannot make the name resolve.
	local tool
	mkdir -p "$TEST_TMP/min-path"
	for tool in grep cmp mv rm mkdir; do
		ln -s "$(command -v "$tool")" "$TEST_TMP/min-path/$tool"
	done
	_write_app_generated_entry 'claude-desktop'
	PATH="$TEST_TMP/min-path" ensure_portal_app_id_entry \
		'/usr/bin/claude-desktop-unofficial'
	grep -qxF "$PORTAL_ENTRY_MARKER" "$portal_entry"
}

@test "ensure_portal_app_id_entry: never replaces a user entry with a dead TryExec" {
	# Only the app's own copy is replaceable; a dead TryExec alone
	# does not make someone else's file ours.
	_portal_setup
	mkdir -p "${portal_entry%/*}"
	printf '[Desktop Entry]\nName=Mine\nExec=/opt/mine\nTryExec=%s\n' \
		"$TEST_TMP/gone/mine" > "$portal_entry"
	local before
	before=$(cat "$portal_entry")
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(cat "$portal_entry") == "$before" ]]
}

@test "ensure_portal_app_id_entry: keeps the app's copy while TryExec resolves" {
	_portal_setup
	mkdir -p "$TEST_TMP/bin"
	printf '#!/bin/sh\n' > "$TEST_TMP/bin/claude-desktop"
	chmod +x "$TEST_TMP/bin/claude-desktop"
	_write_app_generated_entry "$TEST_TMP/bin/claude-desktop"
	local before
	before=$(cat "$portal_entry")
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	[[ $(cat "$portal_entry") == "$before" ]]
}

@test "ensure_portal_app_id_entry: logs when it leaves a foreign entry in place" {
	_portal_setup
	setup_logging
	mkdir -p "${portal_entry%/*}"
	printf '[Desktop Entry]\nName=Mine\nExec=/opt/mine\n' > "$portal_entry"
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	grep -qF "Left portal app-id entry $portal_entry in place" "$log_file"
}

@test "ensure_portal_app_id_entry: logs when it replaces a stale app copy" {
	_portal_setup
	setup_logging
	_write_app_generated_entry "$TEST_TMP/gone/claude-desktop"
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	grep -qF 'Replacing stale app-generated entry' "$log_file"
	grep -qF 'Wrote portal app-id entry' "$log_file"
}

@test "ensure_portal_app_id_entry: repoints its own entry at a moved AppImage" {
	_portal_setup
	ensure_portal_app_id_entry "$HOME/Old/Claude.AppImage"
	ensure_portal_app_id_entry "$HOME/Apps/Claude.AppImage"
	grep -qxF "Exec=\"$HOME/Apps/Claude.AppImage\"" "$portal_entry"
	[[ $(grep -c '^Exec=' "$portal_entry") -eq 1 ]]
}

@test "ensure_portal_app_id_entry: logs the write when logging is set up" {
	_portal_setup
	setup_logging
	ensure_portal_app_id_entry '/usr/bin/claude-desktop-unofficial'
	grep -q 'Wrote portal app-id entry' "$log_file"
}

# =============================================================================
# log_message
# =============================================================================

@test "log_message: joins multiple arguments into one line" {
	setup_logging
	log_message 'Cowork backend: bwrap requested' 'but no node found'
	grep -q 'Cowork backend: bwrap requested but no node found' "$log_file"
}

@test "log_message: no-ops before setup_logging" {
	run log_message 'orphan message'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

# =============================================================================
# load_launcher_config
# =============================================================================

_write_launcher_cfg() {
	mkdir -p "$XDG_CONFIG_HOME/claude-desktop-debian"
	printf '%s\n' "$@" \
		> "$XDG_CONFIG_HOME/claude-desktop-debian/environment"
}

@test "load_launcher_config: every allowlisted key round-trips" {
	# Locks the full allowlist: a \-continuation inside the
	# single-quoted list once silently dropped CLAUDE_GTK_IM_MODULE.
	unset CLAUDE_DISABLE_GPU COWORK_NODE_PATH
	_write_launcher_cfg \
		'CLAUDE_USE_WAYLAND=1' \
		'CLAUDE_PASSWORD_STORE=gnome-libsecret' \
		'CLAUDE_GTK_IM_MODULE=xim' \
		'CLAUDE_DISABLE_GPU=1' \
		'COWORK_VM_BACKEND=bwrap' \
		'COWORK_NODE_PATH=/usr/bin/node'
	load_launcher_config
	[[ $CLAUDE_USE_WAYLAND == '1' ]]
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
	[[ $CLAUDE_GTK_IM_MODULE == 'xim' ]]
	[[ $CLAUDE_DISABLE_GPU == '1' ]]
	[[ $COWORK_VM_BACKEND == 'bwrap' ]]
	[[ $COWORK_NODE_PATH == '/usr/bin/node' ]]
}

@test "load_launcher_config: non-allowlisted key is never exported" {
	unset LD_PRELOAD
	_write_launcher_cfg 'LD_PRELOAD=/tmp/evil.so'
	load_launcher_config
	[[ -z ${LD_PRELOAD:-} ]]
}

@test "load_launcher_config: sandbox override reaches Wayland launch args" {
	_write_launcher_cfg 'CLAUDE_FORCE_SANDBOX=1'
	setup_logging
	is_wayland=true
	# RPM uses the deb argument builder. Exercise both Wayland backends.
	local package_type backend
	for package_type in deb nix; do
		for backend in true false; do
			unset CLAUDE_FORCE_SANDBOX
			load_launcher_config
			use_x11_on_wayland="$backend"
			build_electron_args "$package_type"
			run has_electron_arg '--no-sandbox'
			[[ $status -eq 1 ]]
		done
	done
}

@test "load_launcher_config: sandbox environment overrides config" {
	setup_logging
	is_wayland=true
	use_x11_on_wayland=false
	_write_launcher_cfg 'CLAUDE_FORCE_SANDBOX=1'
	export CLAUDE_FORCE_SANDBOX=0
	load_launcher_config
	build_electron_args deb
	has_electron_arg '--no-sandbox'
	_write_launcher_cfg 'CLAUDE_FORCE_SANDBOX=0'
	export CLAUDE_FORCE_SANDBOX=1
	load_launcher_config
	build_electron_args deb
	run has_electron_arg '--no-sandbox'
	[[ $status -eq 1 ]]
}

@test "load_launcher_config: sandbox override preserves AppImage args" {
	_write_launcher_cfg 'CLAUDE_FORCE_SANDBOX=1'
	setup_logging
	load_launcher_config
	[[ $CLAUDE_FORCE_SANDBOX == 1 ]]
	is_wayland=true
	use_x11_on_wayland=false
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "load_launcher_config: environment wins over the config file" {
	_write_launcher_cfg 'COWORK_VM_BACKEND=bwrap'
	export COWORK_VM_BACKEND='kvm'
	load_launcher_config
	[[ $COWORK_VM_BACKEND == 'kvm' ]]
}

@test "load_launcher_config: strips one layer of surrounding quotes" {
	_write_launcher_cfg "CLAUDE_PASSWORD_STORE='gnome-libsecret'"
	load_launcher_config
	[[ $CLAUDE_PASSWORD_STORE == 'gnome-libsecret' ]]
}

@test "load_launcher_config: trims whitespace around key and value" {
	unset CLAUDE_DISABLE_GPU
	_write_launcher_cfg 'CLAUDE_DISABLE_GPU = 1'
	load_launcher_config
	[[ $CLAUDE_DISABLE_GPU == '1' ]]
}

@test "load_launcher_config: skips comments and blank lines" {
	_write_launcher_cfg '# a comment' '' '   ' 'COWORK_VM_BACKEND=bwrap'
	load_launcher_config
	[[ $COWORK_VM_BACKEND == 'bwrap' ]]
}

@test "load_launcher_config: missing file is a silent no-op" {
	run load_launcher_config
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "load_launcher_config: file is never executed as shell" {
	_write_launcher_cfg "COWORK_VM_BACKEND=\$(touch $TEST_TMP/pwned)"
	load_launcher_config
	[[ ! -e "$TEST_TMP/pwned" ]]
	[[ $COWORK_VM_BACKEND == *'touch'* ]]
}

@test "run_doctor: reads the launcher config file (config-only bwrap flag)" {
	# The #772 persona: COWORK_VM_BACKEND=bwrap lives ONLY in the config
	# file (GUI launches can't carry env). Doctor must see the same
	# environment a launch would and run the bwrap diagnostics.
	_write_launcher_cfg 'COWORK_VM_BACKEND=bwrap'
	# Fail-fast curl stub: the drift check is best-effort and must not
	# slow or flake the suite on a networkless runner.
	mkdir -p "$TEST_TMP/bin"
	printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/bin/curl"
	chmod +x "$TEST_TMP/bin/curl"
	export PATH="$TEST_TMP/bin:$PATH"
	run run_doctor ''
	[[ $output == *'COWORK_VM_BACKEND=bwrap'* ]]
	[[ $output == *'bwrap daemon runtime'* ]]
}

# =============================================================================
# _doctor_check_effective_sandbox (#804)
# =============================================================================

@test "_doctor_check_effective_sandbox: X11 - PASS, sandbox enabled" {
	is_wayland=false
	setup_logging
	run _doctor_check_effective_sandbox deb
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'enabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: Wayland deb, no override - WARN, sandbox disabled" {
	is_wayland=true
	use_x11_on_wayland=true
	unset CLAUDE_FORCE_SANDBOX
	setup_logging
	run _doctor_check_effective_sandbox deb
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'disabled at runtime'* ]]
	[[ $output == *'CLAUDE_FORCE_SANDBOX=1'* ]]
}

@test "_doctor_check_effective_sandbox: Wayland deb, CLAUDE_FORCE_SANDBOX=1 - PASS" {
	is_wayland=true
	use_x11_on_wayland=true
	CLAUDE_FORCE_SANDBOX=1
	setup_logging
	run _doctor_check_effective_sandbox deb
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'enabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: Wayland nix, no override - WARN" {
	is_wayland=true
	use_x11_on_wayland=true
	unset CLAUDE_FORCE_SANDBOX
	setup_logging
	run _doctor_check_effective_sandbox nix
	[[ $output == *'[WARN]'* ]]
}

@test "_doctor_check_effective_sandbox: Wayland rpm, no override - WARN (normalized to deb)" {
	# rpm reuses the deb argv-building path verbatim (see rpm.sh); the
	# literal 'rpm' must be normalized to 'deb' before build_electron_args
	# is called, otherwise it falls through the deb/nix-only --no-sandbox
	# branch and this incorrectly reports PASS.
	is_wayland=true
	use_x11_on_wayland=true
	unset CLAUDE_FORCE_SANDBOX
	setup_logging
	run _doctor_check_effective_sandbox rpm
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'disabled at runtime'* ]]
}

@test "_doctor_check_effective_sandbox: appimage - always a silent no-op (unconditional --no-sandbox, covered by the permissions check)" {
	is_wayland=true
	use_x11_on_wayland=true
	unset CLAUDE_FORCE_SANDBOX
	setup_logging
	run _doctor_check_effective_sandbox appimage
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_effective_sandbox: standalone doctor.sh (no launcher-common.sh in scope) is a silent no-op" {
	# Mirrors the load_launcher_config guard doctor.bats already relies
	# on: detect_display_backend/build_electron_args don't exist when
	# doctor.sh is sourced on its own, so the check must not error.
	unset -f detect_display_backend build_electron_args
	run _doctor_check_effective_sandbox deb
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "run_doctor: package_type defaults to deb when omitted" {
	# The existing single-arg call sites (and this test's own call
	# pattern predating #804) must keep working -- verifies the new
	# second parameter's default rather than requiring every caller to
	# be updated. Drives the real detect_display_backend path (not a
	# manually pre-set is_wayland) via WAYLAND_DISPLAY, same as the
	# check_display/detect_display_backend tests elsewhere in this file.
	WAYLAND_DISPLAY='wayland-0'
	unset CLAUDE_USE_WAYLAND CLAUDE_FORCE_SANDBOX
	mkdir -p "$TEST_TMP/bin"
	printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/bin/curl"
	chmod +x "$TEST_TMP/bin/curl"
	export PATH="$TEST_TMP/bin:$PATH"
	run run_doctor ''
	[[ $output == *'disabled at runtime'* ]]
}

# =============================================================================
# setup_cowork_bwrap_env: resolve the bwrap daemon's node runtime (#772)
# =============================================================================

# The launcher resolves a system node for the bwrap fallback daemon
# (the official Electron ships with the RunAsNode fuse off) and exports
# COWORK_NODE_PATH for the patched spawn. Only the flagged path may
# touch the environment.

# Write an executable node stub at $1 that fails the statfsSync
# capability probe (any invocation exits 1, so --version fails too —
# matching a runtime too old to matter).
_stub_featureless_node() {
	printf '#!/bin/sh\nexit 1\n' > "$1"
	chmod +x "$1"
}

@test "setup_cowork_bwrap_env: no-op when the backend flag is not bwrap" {
	unset COWORK_VM_BACKEND COWORK_NODE_PATH
	setup_cowork_bwrap_env
	[[ -z ${COWORK_NODE_PATH:-} ]]
}

@test "setup_cowork_bwrap_env: explicit COWORK_NODE_PATH is honored" {
	command -v node >/dev/null || skip 'node not installed'
	# A symlinked copy in TEST_TMP is distinguishable from what the
	# PATH probe would resolve, so this proves precedence (the
	# explicit path survives the call), not just the log line.
	ln -s "$(command -v node)" "$TEST_TMP/pinned-node"
	export COWORK_VM_BACKEND=bwrap
	export COWORK_NODE_PATH="$TEST_TMP/pinned-node"
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_cowork_bwrap_env
	[[ $COWORK_NODE_PATH == "$TEST_TMP/pinned-node" ]]
	grep -qF "daemon node: $TEST_TMP/pinned-node" "$log_file"
}

@test "setup_cowork_bwrap_env: auto-detects node from PATH and exports it" {
	command -v node >/dev/null || skip 'node not installed'
	export COWORK_VM_BACKEND=bwrap
	unset COWORK_NODE_PATH
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_cowork_bwrap_env
	[[ ${COWORK_NODE_PATH:-} == "$(command -v node)" ]]
}

@test "setup_cowork_bwrap_env: no node anywhere logs cannot-start, exports nothing" {
	# Shadow `command` so -v node/nodejs both miss (the _skip_gtk_query
	# pattern) — emptying PATH would break log_message's own tooling.
	command() {
		if [[ $1 == '-v' && ( $2 == 'node' || $2 == 'nodejs' ) ]]; then
			return 1
		fi
		builtin command "$@"
	}
	export COWORK_VM_BACKEND=bwrap
	unset COWORK_NODE_PATH
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_cowork_bwrap_env
	[[ -z ${COWORK_NODE_PATH:-} ]]
	grep -q 'cannot start' "$log_file"
}

@test "setup_cowork_bwrap_env: statfsSync-less node logs the capability warning" {
	_stub_featureless_node "$TEST_TMP/oldnode"
	export COWORK_VM_BACKEND=bwrap
	export COWORK_NODE_PATH="$TEST_TMP/oldnode"
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_cowork_bwrap_env
	grep -q 'lacks fs.statfsSync' "$log_file"
	grep -q 'refuse to start' "$log_file"
}

# =============================================================================
# setup_tray_icon_env: Cinnamon dark-panel tray PNG selection (#604)
# =============================================================================

@test "setup_tray_icon_env: preset value is exported unchanged" {
	export CLAUDE_TRAY_USE_DARK_ICON=0
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == 0 ]]
	grep -q 'CLAUDE_TRAY_USE_DARK_ICON=0 (preset)' "$log_file"
	# A valid preset must not draw the not-0/1 note
	run grep -q 'not 0/1' "$log_file"
	[[ $status -ne 0 ]]
}

@test "setup_tray_icon_env: non-0/1 preset logs that the app ignores it" {
	export CLAUDE_TRAY_USE_DARK_ICON=true
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == true ]]
	grep -q 'CLAUDE_TRAY_USE_DARK_ICON=true (preset)' "$log_file"
	grep -q 'not 0/1' "$log_file"
}

@test "setup_tray_icon_env: cinnamon dark theme sets CLAUDE_TRAY_USE_DARK_ICON=1" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=X-Cinnamon
	mkdir -p "$TEST_TMP/bin"
	# bash shebang, not sh: the stub body uses [[ ]], and CI's /bin/sh
	# is dash — under sh the stub exits 127 and the test lies
	cat > "$TEST_TMP/bin/gsettings" << 'EOF'
#!/usr/bin/env bash
if [[ $1 == get && $3 == name ]]; then
	printf "'Mint-Y-Dark-Aqua'\n"
fi
EOF
	chmod +x "$TEST_TMP/bin/gsettings"
	PATH="$TEST_TMP/bin:$PATH"
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"
	setup_tray_icon_env
	[[ $CLAUDE_TRAY_USE_DARK_ICON == 1 ]]
	grep -q 'TrayIconLinux-Dark.png' "$log_file"
}

@test "setup_tray_icon_env: cinnamon light theme leaves env unset" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=X-Cinnamon
	mkdir -p "$TEST_TMP/bin"
	# The stub records that it ran: a broken stub returning early is
	# otherwise indistinguishable from the theme check working
	cat > "$TEST_TMP/bin/gsettings" << EOF
#!/usr/bin/env bash
touch "$TEST_TMP/gsettings-called"
if [[ \$1 == get && \$3 == name ]]; then
	printf "'Mint-Y'\n"
fi
EOF
	chmod +x "$TEST_TMP/bin/gsettings"
	PATH="$TEST_TMP/bin:$PATH"
	setup_tray_icon_env
	[[ -e $TEST_TMP/gsettings-called ]]
	[[ -z ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]
}

@test "setup_tray_icon_env: non-cinnamon desktop is a no-op" {
	unset CLAUDE_TRAY_USE_DARK_ICON
	export XDG_CURRENT_DESKTOP=KDE
	setup_tray_icon_env
	[[ -z ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]
}
