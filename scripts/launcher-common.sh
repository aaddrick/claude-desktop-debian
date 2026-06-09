#!/usr/bin/env bash
# Common launcher functions for Claude Desktop (AppImage and deb)
# This file is sourced by both launchers to avoid code duplication

# WM_CLASS / StartupWMClass — must match upstream productName.
# @@WM_CLASS@@ is replaced at build time; see build.sh.
readonly WM_CLASS='@@WM_CLASS@@'

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
		CLAUDE_PASSWORD_STORE \
		CLAUDE_GTK_IM_MODULE \
		CLAUDE_DISABLE_GPU
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

	# Default: Use X11/XWayland on Wayland so upstream's globalShortcut
	# (Quick Entry's Ctrl+Alt+Space) keeps working via an X11 key grab.
	#
	# CLAUDE_USE_WAYLAND is tri-state:
	#   1     - force native Wayland (global shortcuts via XDG portal)
	#   0     - force XWayland, skipping the auto-detect below
	#   unset - auto-detect per compositor
	use_x11_on_wayland=true
	local wayland_override="${CLAUDE_USE_WAYLAND:-}"
	[[ $wayland_override == '1' ]] && use_x11_on_wayland=false

	# Fixes: #226 - Only Niri is auto-forced to native Wayland: it has
	# no XWayland at all, so the X11 backend can't even start.
	#
	# GNOME Wayland is NOT auto-forced. mutter no longer honours
	# XWayland global key grabs (#404), and native Wayland would route
	# Quick Entry's globalShortcut through the XDG GlobalShortcuts portal
	# instead -- but flipping the default session off mature XWayland is
	# a rendering / IME / HiDPI risk, and on GNOME 50 the portal path is
	# a no-op anyway (electron/electron#51875). GNOME users who want the
	# portal route opt in with CLAUDE_USE_WAYLAND=1 (works on GNOME <=49
	# after the one-time portal permission dialog).
	#
	# Sway and Hyprland keep working XWayland grabs and their wlroots
	# portal has no GlobalShortcuts backend, so they also stay on the
	# XWayland default; opt in with CLAUDE_USE_WAYLAND=1 if desired. An
	# explicit CLAUDE_USE_WAYLAND=0 opts out of this auto-detect entirely.
	#
	# XDG_CURRENT_DESKTOP can be colon-separated (e.g. "niri:GNOME"); the
	# *glob* substring match handles this.
	if [[ $is_wayland == true && $use_x11_on_wayland == true \
		&& $wayland_override != '0' ]]; then
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

# Determine the best available Chromium password-store backend.
#
# Electron's safeStorage API and Chromium's cookie encryption both rely
# on the OS credential store selected by --password-store. Without a
# working store safeStorage.isEncryptionAvailable() returns false, OAuth
# tokens are silently discarded on exit, and users must re-authenticate
# on every launch (Cookies file stays 0 bytes). Fixes: #593
#
# Detection order (first match wins):
#   CLAUDE_PASSWORD_STORE env var  — explicit user override
#   kwallet6                        — KDE Plasma 6 keyring
#   gnome-libsecret                 — GNOME Keyring / libsecret bridge
#   basic                           — fixed internal key (always works)
#
# With 'basic' the stored data is encrypted with a fixed key. Tokens
# remain protected by Linux filesystem permissions on ~/.config/Claude/.
#
# Assumes a D-Bus session bus is available; this is true for any
# graphical login session.
_detect_password_store() {
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		echo "$CLAUDE_PASSWORD_STORE"
		return
	fi

	# kwallet6: KDE Plasma 6 keyring
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.kde.kwalletd6 \
		/modules/kwalletd6 \
		org.kde.KWallet.isEnabled 2>/dev/null \
		| grep -q 'boolean true'
	then
		echo 'kwallet6'
		return
	fi

	# gnome-libsecret: GNOME Keyring, KWallet 5 compat bridge, etc.
	if dbus-send --session --print-reply --reply-timeout=1000 \
		--dest=org.freedesktop.secrets \
		/org/freedesktop/secrets \
		org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
	then
		echo 'gnome-libsecret'
		return
	fi

	# No keyring accessible — fall back to fixed-key provider.
	echo 'basic'
}

# Detect whether the previous launch ended in Chromium's
# "GPU process isn't usable" crash signature (#583).
#
# setup_logging() must have run first so $log_file is available. The
# launcher writes the current session header before build_electron_args()
# runs, so the previous launch lives in the penultimate log section.
#
# A recovered launch (running with --disable-gpu) produces no GPU
# output, so the crash signature alone would re-enable GPU on launch
# N+2 and oscillate crash/work/crash on permanently broken hardware.
# The launcher's own "disabling GPU" marker therefore also counts as
# a trigger, making recovery sticky once tripped. CLAUDE_DISABLE_GPU=0
# remains the escape hatch for retesting hardware acceleration.
#
# Section headers vary by package format: deb/rpm write "Launcher
# Start", AppImage writes "AppImage Start", and Nix writes "Launcher
# Start (NixOS)" (nix/claude-desktop.nix).
_previous_launch_hit_gpu_fatal() {
	[[ -f ${log_file:-} ]] || return 1

	awk '
		/^--- Claude Desktop (Launcher|AppImage) Start( \(NixOS\))? ---$/ {
			section++
			next
		}
		{
			sections[section] = sections[section] $0 "\n"
		}
		END {
			target = section > 1 ? section - 1 : section
			if (target < 1) {
				exit 1
			}
			text = sections[target]
			if (index(text,
				"GPU process launch failed: error_code=") &&
				index(text,
				"GPU process isn'\''t usable. Goodbye.")) {
				exit 0
			}
			if (index(text,
				"Previous launch hit GPU process FATAL")) {
				exit 0
			}
			exit 1
		}
	' "$log_file"
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# Arguments: $1 = "appimage" or "deb" (affects --no-sandbox behavior)
build_electron_args() {
	local package_type="${1:-deb}"

	electron_args=()

	# Chromium ignores all but the LAST --enable-features switch on a
	# command line, so every feature we want must end up in ONE
	# comma-joined flag. Accumulate them here and emit a single
	# --enable-features=... at the end of the function.
	local enable_features=()

	# AppImage always needs --no-sandbox due to FUSE constraints
	[[ $package_type == 'appimage' ]] && electron_args+=('--no-sandbox')

	# CLAUDE_TITLEBAR_STYLE selects between:
	#   hybrid (default) / native: --disable-features=CustomTitlebar
	#           so Chromium's drawn CSD titlebar doesn't compete with
	#           the DE-drawn one. Both modes use frame:true.
	#   hidden: WindowControlsOverlay because WCO is off by default on
	#           Linux Chromium (Win/macOS have it on by default).
	#           Without it, titleBarOverlay is silently ignored at the
	#           page level.
	local _tb
	_tb=$(_resolve_titlebar_style)
	if [[ $_tb == 'hidden' ]]; then
		enable_features+=('WindowControlsOverlay')
	else
		electron_args+=('--disable-features=CustomTitlebar')
	fi

	# WM_CLASS must match the .desktop StartupWMClass and upstream's
	# productName. Ref: #647, #652
	electron_args+=("--class=$WM_CLASS")

	# Chromium's safeStorage API and cookie encryption both require a
	# system keyring selected by --password-store. Without an explicit
	# value, Electron may silently report encryption unavailable even
	# when a keyring daemon is running, discarding OAuth tokens on exit
	# and forcing re-authentication on every launch. We probe for the
	# best available store at startup. Fixes: #593
	local pw_store
	pw_store=$(_detect_password_store)
	electron_args+=("--password-store=${pw_store}")
	log_message "Password store: ${pw_store}"

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
	# Track GPU-disable decision so XRDP and CLAUDE_DISABLE_GPU don't
	# stack duplicate flags. Either signal is sufficient.
	local _disable_gpu=false
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		_disable_gpu=true
		log_message 'XRDP session detected - GPU compositing disabled'
	fi
	# CLAUDE_DISABLE_GPU=1: opt-in workaround for users hitting the
	# Chromium GPU process FATAL exhaustion (#583). The same upstream
	# behaviour is reachable via Settings → disable hardware
	# acceleration; this lets users persist it via the env without
	# having to reach the Settings UI through repeated crashes.
	if [[ -v CLAUDE_DISABLE_GPU ]]; then
		if [[ ${CLAUDE_DISABLE_GPU} == '1' ]]; then
			_disable_gpu=true
			log_message \
				'CLAUDE_DISABLE_GPU=1 - hardware acceleration disabled'
		fi
	elif _previous_launch_hit_gpu_fatal; then
		_disable_gpu=true
		log_message \
			'Previous launch hit GPU process FATAL - disabling GPU'
	fi
	[[ $_disable_gpu == true ]] \
		&& electron_args+=('--disable-gpu' '--disable-software-rasterizer')

	# X11 session - no display-backend flags needed.
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
	else
		# Wayland: deb/nix packages need --no-sandbox in both modes
		[[ $package_type == 'deb' || $package_type == 'nix' ]] \
			&& electron_args+=('--no-sandbox')

		if [[ $use_x11_on_wayland == true ]]; then
			# Use X11 via XWayland; globalShortcut uses an X11 key grab.
			log_message 'Using X11 backend via XWayland (for global hotkey support)'
			electron_args+=('--ozone-platform=x11')
		else
			# Native Wayland: route globalShortcut through the XDG
			# GlobalShortcutsPortal instead of an X11 key grab. Needs
			# the wayland ozone platform (the feature is inert under
			# XWayland) and Electron >= 35. Fixes #404 on GNOME, where
			# mutter no longer honours XWayland grabs. On compositors
			# whose portal lacks a GlobalShortcuts backend (e.g.
			# wlroots) the feature is a harmless no-op.
			log_message 'Using native Wayland backend (global shortcuts via XDG portal)'
			enable_features+=(
				'UseOzonePlatform'
				'WaylandWindowDecorations'
				'GlobalShortcutsPortal'
			)
			electron_args+=('--ozone-platform=wayland')
			electron_args+=('--enable-wayland-ime')
			electron_args+=('--wayland-text-input-version=3')
			# Override any system-wide GDK_BACKEND=x11 that would silently
			# prevent GTK from connecting to the Wayland compositor, causing
			# blurry rendering or launch failures on HiDPI displays.
			export GDK_BACKEND=wayland
		fi
	fi

	# Emit all accumulated Chromium features as a single switch (see the
	# enable_features declaration above for why a single switch matters).
	if [[ ${#enable_features[@]} -gt 0 ]]; then
		local IFS=','
		electron_args+=("--enable-features=${enable_features[*]}")
	fi
}

# Does a /proc/PID/cmdline (joined with spaces) belong to the Claude
# Desktop Electron UI main process?
#
# We can NOT fingerprint on `app.asar`: since #700 the launchers no
# longer pass it as an argument (Electron auto-loads it from
# resources/), so it never appears in any cmdline.  The stable
# signature across deb/rpm/AppImage/nix is the `--class=$WM_CLASS`
# flag every launcher passes via build_electron_args; Chromium keeps
# the exec'd argv in /proc/PID/cmdline and does not propagate --class
# to its --type=... helper children (verified empirically).
#
# Callers join /proc/PID/cmdline with `tr '\0' ' '`, which leaves
# every argument space-terminated, so anchoring on the trailing space
# rejects look-alike classes (e.g. ClaudeDev).
_claude_desktop_ui_cmdline_matches() {
	local cmdline="$1"

	# Never the cowork daemon (defensive; it carries no --class) and
	# never a Chromium helper: zygote, renderer, gpu, utility, etc.
	[[ $cmdline == *cowork-vm-service* ]] && return 1
	[[ $cmdline == *--type=* ]] && return 1

	[[ $cmdline == *"--class=$WM_CLASS "* ]]
}

# Is a live Claude Desktop UI running for this user?
#
# We can NOT use `pgrep -f 'claude-desktop'` on its own for this: it
# matches the launcher's own bash process (this script's cmdline
# contains "/usr/bin/claude-desktop"), any stale launcher bash left
# stopped/zombie after a previous crash, and the cowork daemon
# itself.  Counting any of those as "the UI is alive" causes false
# negatives in the cleanup functions below.  The reliable definition
# is: a process whose cmdline carries our --class fingerprint (see
# _claude_desktop_ui_cmdline_matches) and is actually runnable (not
# stopped/zombie), excluding our own launcher bash and its parent.
_claude_desktop_ui_is_alive() {
	local pid cmdline state
	for pid in \
		$(pgrep -u "$(id -u)" -f -- "--class=$WM_CLASS" 2>/dev/null); do
		# Skip our own launcher bash and its parent.
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_claude_desktop_ui_cmdline_matches "$cmdline" || continue
		# Skip stopped (T/t) and zombie (Z) processes — not a live UI.
		state=$(awk '/^State:/ {print $2; exit}' \
			"/proc/$pid/status" 2>/dev/null) || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# Found a genuine live Electron UI.
		return 0
	done
	return 1
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
	local cowork_pids pid
	cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| return 0

	# A live Claude Desktop UI process means the daemon is expected;
	# leave it alone.  See _claude_desktop_ui_is_alive for why neither
	# `pgrep -f 'claude-desktop'` nor an app.asar fingerprint works.
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

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

_desktop_helper_cmdline_matches() {
	local cmdline="$1"
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"

	case "$cmdline" in
		*cowork-vm-service.js*)
			return 0
			;;
		*"--user-data-dir=$config_dir "*)
			return 0
			;;
		*"$config_dir/Claude Extensions/"*)
			return 0
			;;
		*/usr/lib/claude-desktop/*--type=*)
			return 0
			;;
	esac

	return 1
}

_desktop_helper_candidate_pids() {
	pgrep -u "$(id -u)" -f 'cowork-vm-service\.js|--user-data-dir=.*[/]Claude|Claude Extensions|/usr/lib/claude-desktop/' 2>/dev/null
}

cleanup_stale_desktop_helpers() {
	# A live UI (any instance) suppresses all cleanup. We don't scope
	# helpers per-instance. Safe, not complete.
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	local pids pid cmdline
	pids=$(_desktop_helper_candidate_pids) || return 0

	local matched=()
	for pid in $pids; do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		[[ ${_electron_child_pid:-} == "$pid" ]] && continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_desktop_helper_cmdline_matches "$cmdline" || continue
		matched+=("$pid")
	done

	[[ ${#matched[@]} -gt 0 ]] || return 0

	for pid in "${matched[@]}"; do
		kill "$pid" 2>/dev/null || true
	done

	local wait_count=0 alive
	while ((wait_count < 20)); do
		alive=false
		for pid in "${matched[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				alive=true
				break
			fi
		done
		[[ $alive == false ]] && break
		sleep 0.1
		wait_count=$((wait_count + 1))
	done

	if [[ $alive == true ]]; then
		for pid in "${matched[@]}"; do
			kill -KILL "$pid" 2>/dev/null || true
		done
		log_message \
			"Killed stale Claude Desktop helpers (SIGKILL, PIDs: ${matched[*]})"
	else
		log_message "Killed stale Claude Desktop helpers (PIDs: ${matched[*]})"
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

cleanup_after_electron_exit() {
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
}

_electron_launcher_forward_signal() {
	local signal="$1"

	if [[ -n ${_electron_child_pid:-} ]]; then
		kill "-$signal" "$_electron_child_pid" 2>/dev/null || true
	fi
}

run_electron_and_cleanup() {
	local status

	"$@" >> "$log_file" 2>&1 &
	_electron_child_pid=$!

	trap '_electron_launcher_forward_signal TERM' TERM
	trap '_electron_launcher_forward_signal INT' INT
	trap '_electron_launcher_forward_signal HUP' HUP

	wait "$_electron_child_pid"
	status=$?
	while kill -0 "$_electron_child_pid" 2>/dev/null; do
		wait "$_electron_child_pid"  # reap only; keep status
	done

	trap - TERM INT HUP

	log_message "Electron exited with code: $status"
	cleanup_after_electron_exit
	_electron_child_pid=''
	log_message '--- Claude Desktop Launcher End ---'

	return "$status"
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
	# CLAUDE_GTK_IM_MODULE: opt-in override for users hit by broken
	# IBus integration on Linux (#549). Propagated to GTK_IM_MODULE
	# so e.g. `xim` can be persisted without wrapping every launch.
	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		local prev="${GTK_IM_MODULE:-<unset>}"
		export GTK_IM_MODULE="$CLAUDE_GTK_IM_MODULE"
		log_message \
			"GTK_IM_MODULE override: $prev -> $GTK_IM_MODULE (via CLAUDE_GTK_IM_MODULE)"
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
