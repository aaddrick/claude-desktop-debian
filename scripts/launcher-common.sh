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
	# Detect if Wayland is likely running
	is_wayland=false
	if [[ -n $WAYLAND_DISPLAY ]]; then
		is_wayland=true
	fi

	# Determine display backend mode
	# Default: Use X11/XWayland on Wayland sessions for global hotkey support
	# Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys won't work)
	use_x11_on_wayland=true
	if [[ $CLAUDE_USE_WAYLAND == '1' ]]; then
		use_x11_on_wayland=false
	fi
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
	if [[ -z $DISPLAY && -z $WAYLAND_DISPLAY ]]; then
		return 1
	fi
	return 0
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# Arguments: $1 = "appimage" or "deb" (affects --no-sandbox behavior)
build_electron_args() {
	local package_type="${1:-deb}"

	# Initialize args array
	electron_args=()

	# AppImage always needs --no-sandbox due to FUSE constraints
	if [[ $package_type == 'appimage' ]]; then
		electron_args+=('--no-sandbox')
	fi

	# Disable CustomTitlebar for better Linux integration
	electron_args+=('--disable-features=CustomTitlebar')

	# Add compatibility flags based on display backend
	if [[ $is_wayland == true ]]; then
		if [[ $use_x11_on_wayland == true ]]; then
			# Default: Use X11 via XWayland for global hotkey support
			log_message 'Using X11 backend via XWayland (for global hotkey support)'
			# Deb package needs --no-sandbox for XWayland mode too
			if [[ $package_type == 'deb' ]]; then
				electron_args+=('--no-sandbox')
			fi
			electron_args+=('--ozone-platform=x11')
		else
			# Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
			log_message 'Using native Wayland backend (global hotkeys may not work)'
			if [[ $package_type == 'deb' ]]; then
				electron_args+=('--no-sandbox')
			fi
			electron_args+=('--enable-features=UseOzonePlatform,WaylandWindowDecorations')
			electron_args+=('--ozone-platform=wayland')
			electron_args+=('--enable-wayland-ime')
			electron_args+=('--wayland-text-input-version=3')
		fi
	else
		# X11 session - no special flags needed
		log_message 'X11 session detected'
	fi
}

# Set common environment variables
setup_electron_env() {
	export ELECTRON_FORCE_IS_PACKAGED=true
	export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}
