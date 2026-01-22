#!/bin/bash
# Common launcher functions for Claude Desktop (AppImage and deb)
# This file is sourced by both launchers to avoid code duplication

# Setup logging directory and file
# Sets: LOG_DIR, LOG_FILE
setup_logging() {
    LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-debian"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/launcher.log"
}

# Log a message to the log file
# Usage: log_message "message"
log_message() {
    echo "$1" >> "$LOG_FILE"
}

# Detect display backend (Wayland vs X11)
# Sets: IS_WAYLAND, USE_X11_ON_WAYLAND
detect_display_backend() {
    # Detect if Wayland is likely running
    IS_WAYLAND=false
    if [ -n "$WAYLAND_DISPLAY" ]; then
        IS_WAYLAND=true
    fi

    # Determine display backend mode
    # Default: Use X11/XWayland on Wayland sessions for global hotkey support
    # Set CLAUDE_USE_WAYLAND=1 to use native Wayland (global hotkeys won't work)
    USE_X11_ON_WAYLAND=true
    if [ "$CLAUDE_USE_WAYLAND" = "1" ]; then
        USE_X11_ON_WAYLAND=false
    fi
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        return 1
    fi
    return 0
}

# Build Electron arguments array based on display backend
# Requires: IS_WAYLAND, USE_X11_ON_WAYLAND to be set (call detect_display_backend first)
# Sets: ELECTRON_ARGS array
# Arguments: $1 = "appimage" or "deb" (affects --no-sandbox behavior)
build_electron_args() {
    local package_type="${1:-deb}"

    # Initialize args array
    ELECTRON_ARGS=()

    # AppImage always needs --no-sandbox due to FUSE constraints
    if [ "$package_type" = "appimage" ]; then
        ELECTRON_ARGS+=("--no-sandbox")
    fi

    # Disable CustomTitlebar for better Linux integration
    ELECTRON_ARGS+=("--disable-features=CustomTitlebar")

    # Add compatibility flags based on display backend
    if [ "$IS_WAYLAND" = true ]; then
        if [ "$USE_X11_ON_WAYLAND" = true ]; then
            # Default: Use X11 via XWayland for global hotkey support
            log_message "Using X11 backend via XWayland (for global hotkey support)"
            # Deb package needs --no-sandbox for XWayland mode too
            if [ "$package_type" = "deb" ]; then
                ELECTRON_ARGS+=("--no-sandbox")
            fi
            ELECTRON_ARGS+=("--ozone-platform=x11")
        else
            # Native Wayland mode (user opted in via CLAUDE_USE_WAYLAND=1)
            log_message "Using native Wayland backend (global hotkeys may not work)"
            if [ "$package_type" = "deb" ]; then
                ELECTRON_ARGS+=("--no-sandbox")
            fi
            ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations")
            ELECTRON_ARGS+=("--ozone-platform=wayland")
            ELECTRON_ARGS+=("--enable-wayland-ime")
            ELECTRON_ARGS+=("--wayland-text-input-version=3")
        fi
    else
        # X11 session - no special flags needed
        log_message "X11 session detected"
    fi
}

# Set common environment variables
setup_electron_env() {
    export ELECTRON_FORCE_IS_PACKAGED=true
    export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}
