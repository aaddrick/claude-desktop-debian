#!/usr/bin/env bash
# Common launcher functions for Claude Desktop (AppImage and deb)
# This file is sourced by both launchers to avoid code duplication

# Setup logging directory and file
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-debian"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
}

# Log a message to the log file
# Usage: log_message "message"
log_message() {
	echo "$1" >> "$log_file"
}

# Log the session/IME environment vars that drive display and input
# decisions, so bug reports include enough context to reason about
# them without round-trip env-dump requests (#548).
#
# Emits one block:
#     env={
#       KEY=value
#       ...
#     }
#
# Empty or unset values are emitted as `KEY=` so absence is
# unambiguous (vs. silently omitted). Caller must run setup_logging
# first.
log_session_env() {
	local key
	log_message 'env={'
	for key in \
		XDG_SESSION_TYPE \
		WAYLAND_DISPLAY \
		DISPLAY \
		XDG_CURRENT_DESKTOP \
		GTK_IM_MODULE \
		XMODIFIERS \
		QT_IM_MODULE \
		CLAUDE_USE_WAYLAND \
		CLAUDE_TITLEBAR_STYLE \
		CLAUDE_GTK_IM_MODULE
	do
		log_message "  $key=${!key:-}"
	done
	log_message '}'
}

# Detect display backend (Wayland vs X11)
# Sets: is_wayland, use_x11_on_wayland
detect_display_backend() {
	# Detect if Wayland is running
	is_wayland=false
	[[ -n "${WAYLAND_DISPLAY:-}" ]] && is_wayland=true

	# Default: Use X11/XWayland on Wayland for global hotkey support
	# Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys disabled)
	use_x11_on_wayland=true
	[[ "${CLAUDE_USE_WAYLAND:-}" == '1' ]] && use_x11_on_wayland=false

	# Fixes: #226 - Auto-detect compositors that require native Wayland
	# Only Niri is auto-forced: it has no XWayland support.
	# Sway and Hyprland have working XWayland, so users on those
	# compositors who want native Wayland can set CLAUDE_USE_WAYLAND=1.
	# XDG_CURRENT_DESKTOP can be colon-separated (e.g. "niri:GNOME");
	# glob matching with *niri* handles this correctly.
	if [[ $is_wayland == true && $use_x11_on_wayland == true ]]; then
		local desktop="${XDG_CURRENT_DESKTOP:-}"
		desktop="${desktop,,}"

		if [[ -n "${NIRI_SOCKET:-}" || "$desktop" == *niri* ]]; then
			log_message "Niri detected - forcing native Wayland"
			use_x11_on_wayland=false
		fi
	fi
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
	[[ -n $DISPLAY || -n $WAYLAND_DISPLAY ]]
}

# Resolve CLAUDE_TITLEBAR_STYLE to one of {hybrid,native,hidden},
# defaulting to 'hybrid' when unset or invalid. Echoed (not exported)
# so callers can branch on it without polluting the environment.
# 'hybrid' is the recommended Linux experience: native OS frame +
# in-app topbar via the wco-shim. 'hidden' is upstream's frameless
# WCO config; broken on Linux X11 (clicks unresponsive) but kept for
# Wayland/diagnostic comparison.
_resolve_titlebar_style() {
	local raw="${CLAUDE_TITLEBAR_STYLE:-hybrid}"
	raw="${raw,,}"
	case "$raw" in
		hybrid|hidden|native) echo "$raw" ;;
		*) echo 'hybrid' ;;
	esac
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# Arguments: $1 = "appimage" or "deb" (affects --no-sandbox behavior)
build_electron_args() {
	local package_type="${1:-deb}"

	electron_args=()

	# AppImage always needs --no-sandbox due to FUSE constraints
	[[ $package_type == 'appimage' ]] && electron_args+=('--no-sandbox')

	# CLAUDE_TITLEBAR_STYLE selects between:
	#   hybrid (default) / native: --disable-features=CustomTitlebar
	#           so Chromium's drawn CSD titlebar doesn't compete with
	#           the DE-drawn one. Both modes use frame:true.
	#   hidden: --enable-features=WindowControlsOverlay because WCO
	#           is off by default on Linux Chromium (Win/macOS have
	#           it on by default). Without this flag, titleBarOverlay
	#           is silently ignored at the page level.
	local _tb
	_tb=$(_resolve_titlebar_style)
	if [[ $_tb == 'hidden' ]]; then
		electron_args+=('--enable-features=WindowControlsOverlay')
	else
		electron_args+=('--disable-features=CustomTitlebar')
	fi

	# Remote XRDP sessions lack GPU acceleration and render a blank
	# window when GPU compositing is enabled. Detect via XRDP_SESSION
	# (set by xrdp's session init) and loginctl session Type. We do
	# not probe xrdp-sesman via pgrep because that daemon also runs
	# on hosts where the user is on a local (non-XRDP) session.
	# Fixes: #319
	local rdp_session_type=''
	[[ -n ${XDG_SESSION_ID:-} ]] && rdp_session_type=$(
		loginctl show-session "$XDG_SESSION_ID" \
			-p Type --value 2>/dev/null
	)
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		electron_args+=('--disable-gpu' '--disable-software-rasterizer')
		log_message 'XRDP session detected - GPU compositing disabled'
	fi

	# X11 session - no special flags needed
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
		return
	fi

	# Wayland: deb/nix packages need --no-sandbox in both modes
	[[ $package_type == 'deb' || $package_type == 'nix' ]] \
		&& electron_args+=('--no-sandbox')

	if [[ $use_x11_on_wayland == true ]]; then
		# Default: Use X11 via XWayland for global hotkey support
		log_message 'Using X11 backend via XWayland (for global hotkey support)'
		electron_args+=('--ozone-platform=x11')
	else
		# Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
		log_message 'Using native Wayland backend (global hotkeys may not work)'
		electron_args+=('--enable-features=UseOzonePlatform,WaylandWindowDecorations')
		electron_args+=('--ozone-platform=wayland')
		electron_args+=('--enable-wayland-ime')
		electron_args+=('--wayland-text-input-version=3')
		# Override any system-wide GDK_BACKEND=x11 that would silently
		# prevent GTK from connecting to the Wayland compositor, causing
		# blurry rendering or launch failures on HiDPI displays.
		export GDK_BACKEND=wayland
	fi
}

# Kill orphaned cowork-vm-service daemon processes.
# After a crash or unclean shutdown the cowork daemon may outlive the
# main Electron UI process.  The orphaned daemon holds LevelDB locks
# in ~/.config/Claude/Local Storage/ AND keeps the Unix socket at
# $XDG_RUNTIME_DIR/cowork-vm-service.sock bound, which causes a new
# launch to either silently quit (LevelDB) or connect to the stale
# daemon (socket) and hang with a blank window.
# Must run BEFORE cleanup_stale_lock / cleanup_stale_cowork_socket
# so that stale files left behind by the daemon can be cleaned up.
cleanup_orphaned_cowork_daemon() {
	local cowork_pids
	cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| return 0

	# Check if a live Claude Desktop UI process is also running.
	#
	# We can NOT use `pgrep -f 'claude-desktop'` on its own for this:
	# it matches the launcher's own bash process (this script's
	# cmdline contains "/usr/bin/claude-desktop"), any stale launcher
	# bash left stopped/zombie after a previous crash, and the cowork
	# daemon itself.  Counting any of those as "the UI is alive"
	# causes a false negative and the orphan survives.
	#
	# The reliable definition of "UI is alive" is: an Electron main
	# process whose cmdline references app.asar and is NOT a Chromium
	# helper (--type=...) and NOT the cowork daemon, and is actually
	# runnable (not stopped/zombie).
	local pid cmdline state
	for pid in $(pgrep -f 'app\.asar' 2>/dev/null); do
		# Skip our own launcher bash and its parent.
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) \
			|| continue
		# Skip the cowork daemon (matches app.asar.unpacked path).
		[[ $cmdline == *cowork-vm-service* ]] && continue
		# Skip Chromium helpers: zygote, renderer, gpu, utility, etc.
		[[ $cmdline == *--type=* ]] && continue
		# Skip stopped (T/t) and zombie (Z) processes — not a live UI.
		state=$(awk '/^State:/ {print $2; exit}' \
			"/proc/$pid/status" 2>/dev/null) || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# Found a genuine live Electron UI — daemon is expected
		return 0
	done

	# No UI process found — daemon is orphaned, terminate it.
	# Escalate to SIGKILL if a daemon is stuck and does not exit
	# after SIGTERM within ~2s, so cleanup_stale_cowork_socket
	# (which runs next) reliably sees no daemon.
	for pid in $cowork_pids; do
		kill "$pid" 2>/dev/null || true
	done
	local _wait=0
	while ((_wait < 20)); do
		pgrep -f 'cowork-vm-service\.js' &>/dev/null || break
		sleep 0.1
		((_wait++))
	done
	if pgrep -f 'cowork-vm-service\.js' &>/dev/null; then
		for pid in $cowork_pids; do
			kill -KILL "$pid" 2>/dev/null || true
		done
		log_message "Killed orphaned cowork-vm-service daemon (SIGKILL, PIDs: $cowork_pids)"
	else
		log_message "Killed orphaned cowork-vm-service daemon (PIDs: $cowork_pids)"
	fi
}

# Clean up stale SingletonLock if the owning process is no longer running.
# Electron uses requestSingleInstanceLock() which silently quits if the lock
# is held. A stale lock (from a crash or unclean update) blocks all launches
# with no user-facing error message.
# The lock is a symlink whose target is "hostname-PID".
cleanup_stale_lock() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local lock_file="$config_dir/SingletonLock"

	[[ -L $lock_file ]] || return 0

	local lock_target
	lock_target="$(readlink "$lock_file" 2>/dev/null)" || return 0

	local lock_pid="${lock_target##*-}"

	# Validate that we extracted a numeric PID
	[[ $lock_pid =~ ^[0-9]+$ ]] || return 0

	if kill -0 "$lock_pid" 2>/dev/null; then
		# Process is still running — lock is valid
		return 0
	fi

	rm -f "$lock_file"
	log_message "Removed stale SingletonLock (PID $lock_pid no longer running)"
}

# Clean up stale cowork-vm-service socket if no daemon is listening.
# The service daemon creates a Unix socket at
# $XDG_RUNTIME_DIR/cowork-vm-service.sock. After a crash or unclean
# shutdown, the socket file persists but nothing is listening, causing
# ECONNREFUSED instead of ENOENT when the app tries to connect.
#
# NOTE: this function MUST run after cleanup_orphaned_cowork_daemon,
# which is responsible for killing any orphaned daemon.  Given that
# ordering, the presence of a live daemon proves the socket is in
# use; the absence of a daemon proves the socket is stale.
# We use that invariant directly instead of depending on socat (not
# shipped by default on Debian/Ubuntu) or an age heuristic (the old
# 24h fallback effectively disabled the cleanup for any recent
# crash).
cleanup_stale_cowork_socket() {
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

	[[ -S $sock ]] || return 0

	# If a cowork daemon is alive, it owns this socket; leave it.
	# cleanup_orphaned_cowork_daemon has already run and removed any
	# orphan (with SIGKILL escalation), so anything still alive here
	# is a non-orphaned, live daemon.
	if pgrep -f 'cowork-vm-service\.js' &>/dev/null; then
		return 0
	fi

	# No daemon — the socket file is left over from a crash.
	rm -f "$sock"
	log_message "Removed stale cowork-vm-service socket (no daemon running)"
}

# Set common environment variables
setup_electron_env() {
	# ELECTRON_FORCE_IS_PACKAGED makes app.isPackaged return true, which
	# causes the Claude app to resolve resources via process.resourcesPath.
	# The Nix derivation creates a custom Electron tree with the binary
	# copied and app resources co-located in resources/, so resourcesPath
	# naturally points to the right place on all package types.
	export ELECTRON_FORCE_IS_PACKAGED=true
	# ELECTRON_USE_SYSTEM_TITLE_BAR=1 forces a system titlebar at the
	# Electron level. Set in 'native' and 'hybrid' modes (both use
	# frame:true); skipped in 'hidden' mode (frame:false + WCO config).
	if [[ $(_resolve_titlebar_style) != 'hidden' ]]; then
		export ELECTRON_USE_SYSTEM_TITLE_BAR=1
	fi
}

#===============================================================================
# Doctor Diagnostics
#
# run_doctor and its helpers live in doctor.sh alongside this file. Sourced
# here so any consumer of launcher-common.sh gets the full run_doctor entry
# point without needing to know about the split. Each packaging target
# (deb/rpm/AppImage/Nix) installs doctor.sh next to launcher-common.sh.
#===============================================================================
# shellcheck source=scripts/doctor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doctor.sh"
