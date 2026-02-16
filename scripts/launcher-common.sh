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
		local desktop
		desktop="${XDG_CURRENT_DESKTOP:-}"
		desktop="${desktop,,}"

		local compositor=""
		if [[ -n "${NIRI_SOCKET:-}" ]] \
			|| [[ "$desktop" == *"niri"* ]]; then
			compositor="Niri"
		fi

		if [[ -n "$compositor" ]]; then
			log_message \
				"$compositor detected - forcing native Wayland"
			use_x11_on_wayland=false
		fi
	fi
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
	[[ -n $DISPLAY || -n $WAYLAND_DISPLAY ]]
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

	# Disable CustomTitlebar for better Linux integration
	electron_args+=('--disable-features=CustomTitlebar')

	# X11 session - no special flags needed
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
		return
	fi

	# Wayland: deb package needs --no-sandbox in both modes
	[[ $package_type == 'deb' ]] && electron_args+=('--no-sandbox')

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
	fi
}

# Set common environment variables
setup_electron_env() {
	export ELECTRON_FORCE_IS_PACKAGED=true
	export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}
