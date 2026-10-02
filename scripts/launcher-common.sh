#!/usr/bin/env bash
# Common launcher functions for Claude Desktop (AppImage and deb)
# This file is sourced by both launchers to avoid code duplication

# WM_CLASS / StartupWMClass — must match the runtime window class,
# which Chromium derives from the asar package.json desktopName (not
# productName, not --class, not the ELF basename). @@WM_CLASS@@ is
# replaced at package time with the value patch_app_asar derives from
# the staged app.asar; see scripts/patches/app-asar.sh (#779).
readonly WM_CLASS='@@WM_CLASS@@'

# Rotate launcher.log when it exceeds a size cap, keeping a couple of
# old copies. Runs at the start of each launch, before the session
# header is written, so _previous_launch_hit_gpu_fatal always scans a
# bounded file and the log can't grow without bound across sessions
# (#747). Every branch returns 0 -- rotation must never block launch.
# $log_file must already be set (setup_logging runs before this).
rotate_log_file() {
	[[ -n ${log_file:-} && -f $log_file ]] || return 0

	# 5 MiB aligns with doctor.sh's existing launcher.log size warning.
	local max_bytes=$((5 * 1024 * 1024))
	local keep=2 size i

	size=$(stat -c '%s' "$log_file" 2>/dev/null) || return 0
	[[ $size =~ ^[0-9]+$ ]] || return 0
	((size > max_bytes)) || return 0

	for (( i = keep - 1; i >= 1; i-- )); do
		[[ -f "$log_file.$i" ]] && \
			mv -f "$log_file.$i" "$log_file.$((i + 1))" 2>/dev/null
	done
	mv -f "$log_file" "$log_file.1" 2>/dev/null || return 0
}

# Setup logging directory and file
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-debian"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
	rotate_log_file
	return 0
}

# Log a message to the log file
# Usage: log_message "message"
#
# Joins all arguments with spaces ("$*"), so a wrapped call site that
# passes continuation fragments as separate words logs the full
# message, not just the first fragment. No-ops before setup_logging —
# the --doctor path loads the launcher config without a log file.
#
# LOG-1: never persist OAuth authorization codes. A relaunch through the
# login redirect carries claude://login/...?code=<secret> in argv, which
# reaches both the "Arguments:" and "Executing:" lines. Strip the query
# string of any claude://login token before writing, keeping the path for
# context. Guarded so the common case pays no subprocess.
log_message() {
	[[ -n ${log_file:-} ]] || return 0
	local msg="$*"
	if [[ "$msg" == *claude://login* ]]; then
		msg=$(printf '%s' "$msg" \
			| sed -E 's#(claude://login[^ ?]*)\?[^ ]*#\1?<redacted>#g')
	fi
	echo "$msg" >> "$log_file"
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
		CLAUDE_PASSWORD_STORE \
		CLAUDE_GTK_IM_MODULE \
		CLAUDE_DISABLE_GPU \
		CLAUDE_TRAY_USE_DARK_ICON
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
	# a rendering / IME / HiDPI risk. GNOME users who want the portal
	# route opt in with CLAUDE_USE_WAYLAND=1 (works after the one-time
	# portal permission dialog; GNOME 50 / portal >= 1.20 also needs the
	# app-id entry ensure_portal_app_id_entry writes, #805).
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
#
# Single-pass, constant-memory scan (#747): no section text is ever
# accumulated. Three crash-signature booleans are tracked for the
# section currently being read (cur_*); on each header line the
# just-finished section's flags shift into prev_*, so at EOF prev_*
# always holds the *penultimate* section's flags -- the same target
# the old string-accumulating version selected via section-1. This
# fixes the O(n^2) cost of growing an awk string per line: the cost
# was dominated by the largest single section, not the number of
# sections -- a GPU-crash-looping session can spew megabytes into one
# section, and that giant section was re-scanned on every subsequent
# launch, hanging the launcher before Electron ever started.
_previous_launch_hit_gpu_fatal() {
	[[ -f ${log_file:-} ]] || return 1

	awk '
		/^--- Claude Desktop (Launcher|AppImage) Start( \(NixOS\))? ---$/ {
			section++
			prev_failed = cur_failed
			prev_notusable = cur_notusable
			prev_prevfatal = cur_prevfatal
			cur_failed = 0
			cur_notusable = 0
			cur_prevfatal = 0
			next
		}
		{
			if (index($0,
				"GPU process launch failed: error_code=")) {
				cur_failed = 1
			}
			if (index($0,
				"GPU process isn'\''t usable. Goodbye.")) {
				cur_notusable = 1
			}
			if (index($0,
				"Previous launch hit GPU process FATAL")) {
				cur_prevfatal = 1
			}
		}
		END {
			if (section >= 2) {
				t_failed = prev_failed
				t_notusable = prev_notusable
				t_prevfatal = prev_prevfatal
			} else if (section == 1) {
				t_failed = cur_failed
				t_notusable = cur_notusable
				t_prevfatal = cur_prevfatal
			} else {
				exit 1
			}
			if ((t_failed && t_notusable) || t_prevfatal) {
				exit 0
			}
			exit 1
		}
	' "$log_file"
}

# Build Electron arguments array based on display backend.
#
# LAUNCHER POLICY — opt-in only. Since the v3.0.0 rebase the packaged
# app is Anthropic's official Linux build, so the launcher must NOT
# pass any default flag that shadows an official upstream code path
# (window frame, titlebar, password store, feature flags). Every
# default flag that remains has to justify itself against a concrete
# Linux-environment gap; the tools/chromium-switch-smoke.sh guard
# fails loudly if the effective switch list drifts without a
# deliberate baseline update. Kept defaults, each with its reason:
#   --class=$WM_CLASS         cmdline UI fingerprint (#647, #652, #779)
#   XRDP auto GPU-off         blank window on remote GPU (#319)
#   GPU-crash sticky recovery GPU process FATAL exhaustion (#583)
#   Wayland backend selection CLAUDE_USE_WAYLAND tri-state (#226, #404)
#   --no-sandbox              only where structurally required
#                             (AppImage FUSE; deb/nix on Wayland unless
#                             CLAUDE_FORCE_SANDBOX=1, see #804)
# --password-store is passed ONLY when CLAUDE_PASSWORD_STORE is set;
# otherwise the official os_crypt autodetection owns the decision.
#
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

	# Chromium ignores --class for the window class (it reads the asar
	# desktopName instead — WM_CLASS is derived from the same field),
	# but the flag is load-bearing as the /proc cmdline UI fingerprint:
	# _claude_desktop_ui_cmdline_matches keys on it. Ref: #647, #652,
	# #779
	electron_args+=("--class=$WM_CLASS")

	# Password store: the official build's os_crypt autodetection owns
	# this decision by default (it deliberately declines weak persistence
	# on some sessions rather than storing tokens unsafely). We only pass
	# --password-store when the user sets CLAUDE_PASSWORD_STORE, the
	# documented escape hatch — never a launcher-chosen default that would
	# shadow the upstream autodetect. History: #593.
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		electron_args+=("--password-store=$CLAUDE_PASSWORD_STORE")
		log_message "Password store: $CLAUDE_PASSWORD_STORE (env override)"
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
	# Keep Chromium's software rasterizer available. Disabling both
	# hardware GPU and the software fallback can make Electron abort
	# with "GPU process isn't usable" instead of recovering.
	[[ $_disable_gpu == true ]] && electron_args+=('--disable-gpu')

	# X11 session - no display-backend flags needed.
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
	else
		# Wayland: deb/nix packages need --no-sandbox in both modes
		# (see #804: this default isn't universally required -- the AppArmor
		# userns profile #687 installs for deb/Ubuntu-family systems already
		# covers the one documented real blocker, and isn't Wayland-specific
		# -- but rpm and nix have no equivalent profile, so it isn't safe to
		# drop by default across all three package types yet).
		# CLAUDE_FORCE_SANDBOX=1: opt-in escape hatch, symmetrical to
		# CLAUDE_DISABLE_GPU above, for users who know their system doesn't
		# need this workaround and want the sandbox kept on regardless.
		if [[ ${CLAUDE_FORCE_SANDBOX:-} == '1' ]]; then
			log_message \
				'CLAUDE_FORCE_SANDBOX=1 - keeping Chromium sandbox enabled on Wayland'
		elif [[ $package_type == 'deb' || $package_type == 'nix' ]]; then
			electron_args+=('--no-sandbox')
		fi

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

	# Never a cowork helper (defensive; neither carries --class) — the
	# 2.x cowork-vm-service daemon nor the official Rust
	# cowork-linux-helper — and never a Chromium helper: zygote,
	# renderer, gpu, utility, etc.
	[[ $cmdline == *cowork-vm-service* ]] && return 1
	[[ $cmdline == *cowork-linux-helper* ]] && return 1
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
#
# _claude_desktop_ui_pids prints the fingerprint-matching PIDs, one per
# line; _claude_desktop_ui_is_alive adds the runnable check on top.
_claude_desktop_ui_pids() {
	local pid cmdline
	for pid in \
		$(pgrep -u "$(id -u)" -f -- "--class=$WM_CLASS" 2>/dev/null); do
		# Skip our own launcher bash and its parent.
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_claude_desktop_ui_cmdline_matches "$cmdline" || continue
		printf '%s\n' "$pid"
	done
}

# Process state letter from /proc/PID/status (R, S, T, t, Z, ...).
_proc_state() {
	local key value rest
	while read -r key value rest; do
		if [[ $key == 'State:' ]]; then
			printf '%s' "$value"
			return 0
		fi
	done 2>/dev/null < "/proc/$1/status"
	return 1
}

# Is a live (runnable) Claude Desktop UI running for this user?
#
# Two fingerprints, because the answer gates the reapers: a "no" lets
# them kill helpers. Our own UI carries --class=$WM_CLASS
# (_claude_desktop_own_ui_is_alive). Anthropic's official build, which
# D-002 lets users install side by side, runs its main process without
# --class, so on the --class check alone our launcher saw "no UI" and
# reaped the official app's renderers (#903). Any Claude Desktop main
# process therefore also counts; this only makes the reapers skip more.
_claude_desktop_ui_is_alive() {
	_claude_desktop_own_ui_is_alive || _claude_desktop_any_main_is_alive
}

# Is OUR launcher's UI (--class=$WM_CLASS) up and runnable? Only it can
# be the parent of the bwrap fallback daemon, which the official build
# never spawns, so the doctor asks this rather than the reapers' gate
# (#907).
_claude_desktop_own_ui_is_alive() {
	local pid state
	for pid in $(_claude_desktop_ui_pids); do
		# Skip stopped (T/t) and zombie (Z) processes — not a live UI.
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		# Found a genuine live Electron UI.
		return 0
	done
	return 1
}

# Is any runnable Claude Desktop Electron main process up for this user,
# whoever launched it (#903)? Every build ships the Electron ELF as
# `claude-desktop` (official deb, ours, the AppImage mount, Nix), and
# Chromium's helpers are the same binary with --type=, so: exe basename
# `claude-desktop` (" (deleted)" stripped, for an upgraded binary) and
# no --type= and not run as Node (ELECTRON_RUN_AS_NODE=1). A launcher
# script is excluded by its exe (bash).
_claude_desktop_any_main_is_alive() {
	local pid exe cmdline state
	for pid in $(pgrep -u "$(id -u)" -x claude-desktop 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
		exe=${exe% (deleted)}
		[[ ${exe##*/} == claude-desktop ]] || continue
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		[[ $cmdline == *--type=* ]] && continue
		# Electron run as Node (a fork or MCP server): same exe, no
		# --type=, but not a main. Counting it would let an orphan
		# hold the gate open and shield itself from the reapers.
		# An unreadable environ falls through to "alive" (safe side).
		tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
			| grep -qx 'ELECTRON_RUN_AS_NODE=1' && continue
		state=$(_proc_state "$pid") || continue
		[[ $state == T || $state == t || $state == Z ]] && continue
		return 0
	done
	return 1
}

# SIGTERM every PID, wait up to ~2s for all of them to go, then
# escalate to SIGKILL for whatever is left.  Logs "$label (PIDs: ...)",
# or "$label (SIGKILL, PIDs: ...)" when escalation was needed.
_kill_pids_escalating() {
	local label="$1"
	shift
	local pid alive=false waited=0

	for pid in "$@"; do
		kill "$pid" 2>/dev/null || true
	done

	while ((waited < 20)); do
		alive=false
		for pid in "$@"; do
			if kill -0 "$pid" 2>/dev/null; then
				alive=true
				break
			fi
		done
		[[ $alive == false ]] && break
		sleep 0.1
		((waited++))
	done

	if [[ $alive == true ]]; then
		for pid in "$@"; do
			kill -KILL "$pid" 2>/dev/null || true
		done
		log_message "$label (SIGKILL, PIDs: $*)"
	else
		log_message "$label (PIDs: $*)"
	fi
}

# Was this process's executable replaced (unlinked) underneath it?
# The kernel appends " (deleted)" to /proc/PID/exe once the binary
# behind a running process is gone, which is exactly what dpkg/rpm do
# when they upgrade a package while its UI is still running.
#
# Plain readlink, NOT readlink -f: -f canonicalizes, so it fails when
# the install DIRECTORY is gone too (a package migration or layout
# change, not just a file replace) and the replaced UI would be
# silently missed. The raw link content carries the marker either way.
_claude_desktop_ui_is_replaced() {
	local exe_path

	exe_path=$(readlink "/proc/$1/exe" 2>/dev/null) || return 1
	[[ $exe_path == *' (deleted)' ]]
}

# Is PID a Claude Desktop browser process, one that can legitimately
# hold the SingletonLock in ~/.config/Claude?
#
# Keyed on the executable's path, NOT on the --class UI fingerprint
# above. That fingerprint exists to find OUR instances for cleanup and
# deliberately rejects everything else, but the lock is shared by every
# Claude Desktop build on the machine: the official Anthropic .deb
# (/usr/lib/claude-desktop/claude-desktop, launched without --class),
# this project's deb/rpm/AppImage/Nix (.../claude-desktop/claude-desktop
# or .../claude-desktop-unofficial/claude-desktop), and a pre-3.0 tree
# still running across an upgrade
# (/usr/lib/claude-desktop/node_modules/electron/dist/electron, with
# --class=Claude). Each of them is a live holder, so the test is the one
# thing they all share, `claude-desktop` somewhere in the path. A
# basename set (claude-desktop, electron) would cover the same holders
# but also count every unrelated node_modules/.../electron on a
# developer machine as live. The " (deleted)" marker of a replaced
# binary needs no special case: the path still carries the name, and
# that process still holds the lock until cleanup_replaced_desktop_ui
# reaps it.
#
# Errs toward "live" when /proc/PID/exe cannot be read (a zombie, or a
# process that exec'd a setuid binary and is no longer dumpable):
# keeping a stale lock costs nothing, Electron unlinks it itself on the
# next start, while a wrong "stale" turns into a `Fix: rm` on a live
# lock in the doctor.
_pid_is_claude_desktop() {
	local exe
	exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 0
	[[ $exe == *claude-desktop* ]]
}

# Terminate a live Claude Desktop UI whose executable was replaced
# underneath it by dpkg/rpm. If left alive, the next launcher loses
# Electron's single-instance lock to the old process and appears to
# do nothing instead of starting the newly-installed build.
#
# A no-op on AppImage by construction: the binary lives inside the
# FUSE mount, which stays valid after the .AppImage file itself is
# replaced, so /proc/PID/exe never carries the marker there.
cleanup_replaced_desktop_ui() {
	local pids=() pid
	for pid in $(_claude_desktop_ui_pids); do
		_claude_desktop_ui_is_replaced "$pid" || continue
		pids+=("$pid")
	done

	[[ ${#pids[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed replaced Claude Desktop UI' \
		"${pids[@]}"
}

# Is PID the bwrap-fallback cowork daemon?
#
# Fingerprinted by argv shape, not by a `cowork-vm-service.js`
# substring: the substring also matches an editor, `tail -f` or a
# shell that merely names the file, and both reapers SIGKILL what
# this accepts (#882 and #905, the #534 host-wide pgrep -f class).
# cowork-bwrap.sh spawn swap B starts the daemon as exactly
#   <node> <resourcesPath>/cowork-vm-service.js -socket <sock>
# so argv[1] ends in /cowork-vm-service.js and argv[2] is -socket.
# The official Rust helper (cowork-linux-helper) never matches.
#
# cmdline is read NUL-split into an array because `tr '\0' ' '`
# would lose the argument boundaries.
_is_cowork_fallback_daemon() {
	local -a argv
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1
	[[ ${argv[1]:-} == */cowork-vm-service.js ]] || return 1
	[[ ${argv[2]:-} == -socket ]]
}

# PIDs of this user's bwrap-fallback cowork daemon, one per line.
#
# pgrep only narrows the candidates; _is_cowork_fallback_daemon
# decides. Scoped to this user and skipping our own launcher bash and
# its parent, like _claude_desktop_ui_pids.
_cowork_fallback_daemon_pids() {
	local pid
	for pid in \
		$(pgrep -u "$(id -u)" -f 'cowork-vm-service\.js' 2>/dev/null); do
		[[ $pid == "$$" || $pid == "$PPID" ]] && continue
		_is_cowork_fallback_daemon "$pid" || continue
		printf '%s\n' "$pid"
	done
}

# Kill orphaned cowork-vm-service daemon processes.
# After a crash or unclean shutdown the cowork daemon may outlive the
# main Electron UI process.  The orphaned daemon holds LevelDB locks
# in ~/.config/Claude/Local Storage/ AND keeps the Unix socket the
# client passed it (-socket $XDG_RUNTIME_DIR/claude-cowork-vm.sock)
# bound, which causes a new launch to either silently quit (LevelDB)
# or connect to the stale daemon (socket) and hang with a blank window.
# Must run BEFORE cleanup_stale_lock so that stale files left behind
# by the daemon can be cleaned up.
cleanup_orphaned_cowork_daemon() {
	local -a pids
	mapfile -t pids < <(_cowork_fallback_daemon_pids)
	[[ ${#pids[@]} -gt 0 ]] || return 0

	# A live Claude Desktop UI process means the daemon is expected;
	# leave it alone.  See _claude_desktop_ui_is_alive for why neither
	# `pgrep -f 'claude-desktop'` nor an app.asar fingerprint works.
	if _claude_desktop_ui_is_alive; then
		return 0
	fi

	# No UI process found — daemon is orphaned, terminate it.
	# _kill_pids_escalating SIGKILLs a daemon still alive ~2s after
	# SIGTERM. The socket it leaves behind needs no launcher cleanup:
	# the client respawns on ECONNREFUSED and the next daemon unlinks
	# the stale path before it binds (#888).
	_kill_pids_escalating 'Killed orphaned cowork-vm-service daemon' \
		"${pids[@]}"
}

# No cowork-vm-service.js arm: a substring here would also match an
# editor or `tail -f` on the script (#905). The fallback daemon is
# matched by argv shape (_is_cowork_fallback_daemon) in
# cleanup_stale_desktop_helpers instead.
_desktop_helper_cmdline_matches() {
	local cmdline="$1"
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"

	# /proc/PID/cmdline is NUL-joined and rendered with tr, so argv[0] is
	# everything up to the first space. Every arm that identifies a
	# process by the *binary it is running* tests argv[0], never the whole
	# string: a bystander that merely names one of our binaries as an
	# argument -- `gdb .../chrome_crashpad_handler core`, `coredumpctl
	# gdb`, an editor, a `less` -- must not land in the reaper's kill
	# list. That scenario is not hypothetical: this reaper's own bug
	# leaves crashpad cores lying around to be debugged.
	#
	# Argv[0] carrying a space degrades to a miss, never a false match.
	# Our install prefixes and the AppImage mount point have none.
	local argv0="${cmdline%% *}"

	case "$argv0" in
		*cowork-linux-helper*)
			# Official Rust Cowork helper, spawned via
			# process.resourcesPath (relocation-safe, so no
			# fixed path).
			return 0
			;;
		*/usr/lib/claude-desktop/*chrome_crashpad_handler*|\
		*/usr/lib/claude-desktop-unofficial/*chrome_crashpad_handler*)
			# Crashpad is built to outlive the browser it
			# monitors, so it is the survivor the --type= arm
			# below cannot catch: it is spawned with
			# --monitor-self-annotation=ptype=crashpad-handler
			# and carries no --type= switch at all.
			#
			# Harmless on deb/rpm, fatal on AppImage. The
			# runtime unmounts /tmp/.mount_claude* as soon as
			# AppRun exits, and crashpad's own text pages are
			# mmap'd from that mount, so it faults on its next
			# instruction and dies SIGBUS (si_code BUS_ADRERR)
			# once per quit, dumping a core.
			#
			# The path prefix keeps this scoped to our tree: a
			# bystander /usr/lib/chromium/chrome_crashpad_handler
			# must not match.
			return 0
			;;
	esac

	# Chromium's own helpers: an in-tree argv[0] *and* a --type=
	# switch. Both halves are load-bearing -- the tree alone would
	# also match resources/chrome-native-host, which Chrome (not
	# Claude Desktop) spawns and owns the lifetime of.
	#
	# The claude-desktop-unofficial prefix is our package, renamed in
	# v3.0.0; the claude-desktop one keeps matching Anthropic's own
	# install and the AppImage internal tree.
	case "$argv0" in
		*/usr/lib/claude-desktop/*|\
		*/usr/lib/claude-desktop-unofficial/*)
			case "$cmdline" in
				*--type=*)
					return 0
					;;
			esac
			;;
	esac

	# A Claude Desktop Chromium helper carrying our profile: argv[0]
	# named claude-desktop, a --type= switch and our --user-data-dir.
	# This is the only arm that reaps helpers outside /usr/lib, such as
	# the Nix store tree. Live gpu, utility and renderer helpers carry
	# all three; a bystander handed the same profile dir, such as
	# `chromium --user-data-dir=~/.config/Claude`, does not (#908).
	if [[ ${argv0##*/} == claude-desktop && $cmdline == *--type=* \
		&& $cmdline == *"--user-data-dir=$config_dir "* ]]; then
		return 0
	fi

	# Extension servers are matched by argv shape in
	# cleanup_stale_desktop_helpers (_is_claude_extension_server), not
	# here: a `$config_dir/Claude Extensions/` substring also matches a
	# pager, an editor or `rg` on an extension's files (#908).
	return 1
}

# Is PID an MCP server of an installed Claude Desktop extension?
#
# Fingerprinted by argv shape, not by a `Claude Extensions/` substring
# (#908, the #905 class): argv[0]'s basename is an interpreter, and
# argv[1], or a --directory value, sits under the extensions dir. That
# is how the app starts a server on a system runtime (`node
# <ext>/server/index.js`, `uv run --directory <ext> ...`). With the
# built-in Node it is a utilityProcess (--type=utility), which the
# in-tree arm of _desktop_helper_cmdline_matches already covers, or
# the claude-desktop binary run with ELECTRON_RUN_AS_NODE=1, counted
# here as an interpreter (#903). An unreadable environ is no match.
#
# Known gap, not a regression: a server started with the extension dir
# as its cwd and only relative arguments (`dynamic-uv`, `python -m`)
# names no extension path in argv and is not matched. /proc/PID/cwd
# would close that if it ever matters.
#
# cmdline is read NUL-split into an array: the dir name has a space.
_is_claude_extension_server() {
	local ext_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/Claude Extensions/"
	local -a argv
	local i
	mapfile -d '' argv 2>/dev/null < "/proc/$1/cmdline" || return 1

	case ${argv[0]##*/} in
		node|python*|uv|uvx|bun|deno)
			;;
		claude-desktop)
			tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" \
				| grep -qx 'ELECTRON_RUN_AS_NODE=1' || return 1
			;;
		*)
			return 1
			;;
	esac

	[[ ${argv[1]:-} == "$ext_dir"* ]] && return 0
	for ((i = 1; i < ${#argv[@]}; i++)); do
		case ${argv[i]} in
			--directory=*)
				[[ ${argv[i]#--directory=} == "$ext_dir"* ]] && return 0
				;;
			--directory)
				[[ ${argv[i + 1]:-} == "$ext_dir"* ]] && return 0
				;;
		esac
	done
	return 1
}

_desktop_helper_candidate_pids() {
	pgrep -u "$(id -u)" -f 'cowork-vm-service\.js|cowork-linux-helper|--user-data-dir=.*[/]Claude|Claude Extensions|/usr/lib/claude-desktop(-unofficial)?/' 2>/dev/null
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
		if _is_cowork_fallback_daemon "$pid" \
			|| _is_claude_extension_server "$pid"; then
			matched+=("$pid")
			continue
		fi
		cmdline=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") \
			|| continue
		_desktop_helper_cmdline_matches "$cmdline" || continue
		matched+=("$pid")
	done

	[[ ${#matched[@]} -gt 0 ]] || return 0

	_kill_pids_escalating 'Killed stale Claude Desktop helpers' \
		"${matched[@]}"
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
		# Signalable is not enough (#784): PIDs are recycled, so any
		# other same-user process that inherits the number makes a
		# dead instance's lock look held. Electron would unlink it
		# itself on start; doing it here keeps the log honest.
		_pid_is_claude_desktop "$lock_pid" && return 0

		rm -f "$lock_file"
		log_message "Removed stale SingletonLock (PID $lock_pid was" \
			'reused by another process)'
		return 0
	fi

	rm -f "$lock_file"
	log_message "Removed stale SingletonLock (PID $lock_pid no longer running)"
}

# #855: reclaim disk space left behind when a vm_bundles bundle
# migrated from the pre-3.0 win32-manifest-repurposed rootfs.vhdx
# format to the official unix-native rootfs.img format.
#
# Before the v3.0.0 official-deb rebase, Linux Cowork worked by
# repurposing the win32 manifest's VHDX entries (no native "unix"
# manifest existed yet) and converting them to qcow2 on first use.
# Anthropic's manifest has since grown a real "unix" platform entry
# serving rootfs.img directly, and the official coworkd uses that
# format without ever touching the old VHDX pair again once it
# exists. Nothing deletes the superseded files, so a bundle that
# predates the switch keeps ~11 GB of dead rootfs.vhdx /
# rootfs.vhdx.zst forever.
#
# rootfs.img present is treated as proof the migration completed; a
# bundle still on the old format alone (no rootfs.img yet) is left
# untouched so an in-progress or vhdx-only install isn't disturbed.
# The only code that ever read rootfs.vhdx on Linux is the 2.x KVM
# backend in scripts/cowork-fallback/cowork-vm-service.js (vhdx ->
# qcow2 on first use). It still exists but is unreachable in 3.x:
# the daemon only spawns behind the asar gate
# COWORK_VM_BACKEND=bwrap, and that value selects the bwrap backend
# inside it. So no reachable path needs the vhdx once img exists.
#
# Fail-safe: never blocks launch.
cleanup_stale_vm_bundle_images() {
	local bundles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude/vm_bundles"
	[[ -d $bundles_dir ]] || return 0

	local bundle f removed
	for bundle in "$bundles_dir"/*/; do
		bundle=${bundle%/}
		[[ -f "$bundle/rootfs.img" ]] || continue

		removed=()
		for f in "$bundle/rootfs.vhdx" "$bundle/rootfs.vhdx.zst"; do
			[[ -f $f ]] || continue
			rm -f "$f" 2>/dev/null && removed+=("${f##*/}")
		done

		if ((${#removed[@]} > 0)); then
			log_message \
				"Removed stale VM image(s) in ${bundle}: ${removed[*]} (#855)"
		fi
	done
}

# P1 (#768): rotate out-of-band backups of the user config and the
# per-account Cowork store index files before launch, so the
# poisoned-cache / corrupt-load wipe class is recoverable. Upstream's
# config loader silently falls back to {} on a failed cold-start read
# and then serializes the whole cached object over the file on the next
# settings write; the Cowork stores (spaces / remote-session-spaces /
# scheduled-tasks) share the same rewrite-from-memory shape. See
# anthropics/claude-code #32345 / #59640 / #63651 and
# docs/learnings/config-wipe-guard.md.
#
# We cannot fix upstream's write path from the launcher, but this keeps
# the last few good copies out of band. It runs BEFORE Electron starts,
# so it captures the previous session's (good) state; after an
# in-session wipe the good copy is still down the rotation. This is the
# patch-zero-clean primary fix — it covers every wipe mode (corrupt
# JSON, ENOENT, single-bad-entry Zod) that an in-band asar guard would
# miss. Rotation keeps $keep copies per file and only rotates on a
# real change, so it neither churns nor evicts the pre-wipe copy on
# every launch. Fail-safe: never blocks launch.
backup_user_config() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local backup_dir
	backup_dir="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-debian"
	backup_dir="$backup_dir/config-backups"
	local keep=5

	mkdir -p "$backup_dir" 2>/dev/null || return 0

	local -a sources=("$config_dir/claude_desktop_config.json")

	# The Cowork stores live under nested account/org UUID dirs. An
	# unmatched glob stays literal and is filtered by the -f test.
	local lam="$config_dir/local-agent-mode-sessions"
	if [[ -d $lam ]]; then
		local f
		for f in "$lam"/*/*/spaces.json \
			"$lam"/*/*/remote-session-spaces.json \
			"$lam"/*/*/scheduled-tasks.json; do
			[[ -f $f ]] && sources+=("$f")
		done
	fi

	local src flat newest i
	for src in "${sources[@]}"; do
		[[ -f $src ]] || continue

		# Flatten the path under config_dir into one backup filename.
		flat="${src#"$config_dir"/}"
		flat="${flat//\//__}"
		newest="$backup_dir/$flat.1"

		# Unchanged since the newest backup: nothing to rotate.
		[[ -f $newest ]] && cmp -s "$src" "$newest" && continue

		# Shift .1..(keep-1) down one slot, dropping the oldest.
		for (( i = keep - 1; i >= 1; i-- )); do
			[[ -f "$backup_dir/$flat.$i" ]] && \
				mv -f "$backup_dir/$flat.$i" \
					"$backup_dir/$flat.$((i + 1))" 2>/dev/null
		done
		cp -f "$src" "$newest" 2>/dev/null && \
			log_message "Backed up $flat (keep $keep)"
	done
}

# Print $1 as a double-quoted desktop-entry Exec token, mirroring the
# escaping upstream applies to its own execPath: backslash-escape
# \ " ` $, then % -> %%.
_desktop_exec_quote() {
	local escaped="$1"
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//\"/\\\"}
	escaped=${escaped//\`/\\\`}
	escaped=${escaped//\$/\\\$}
	escaped=${escaped//%/%%}
	printf '"%s"' "$escaped"
}

# AUTO-1: when "Run on startup" is enabled, the official app writes
# its own XDG autostart entry with Exec=<process.execPath> --startup —
# the raw Electron ELF (or, under AppImage, the ephemeral
# /tmp/.mount_claude* path). Login launches would bypass every launcher
# policy (Wayland opt-in, GPU recovery, --class, CLAUDE_PASSWORD_STORE),
# and the AppImage path rots on unmount. Rewrite the Exec command to
# the launcher on every start.
#
# Safe against the Settings toggle: upstream's is-enabled check reads
# only file existence plus Hidden/X-GNOME-Autostart-enabled — never the
# Exec content (verified on 1.18286.0 bytes). The app rewrites the
# entry on each toggle-on, so the heal has to repeat per launch.
#
# $1 = absolute launcher path to point the entry at. Callers pass
# /usr/bin/claude-desktop-unofficial (deb/rpm) or "$APPIMAGE" (AppRun;
# empty when the AppImage runtime did not set it — no-op then).
heal_autostart_entry() {
	local launcher="$1"
	local entry_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
	local entry="$entry_dir/claude-desktop.desktop"
	local exec_line current args rest new_line tmp line
	local replaced=false

	[[ -n $launcher && -f $entry ]] || return 0

	exec_line=$(LC_ALL=C grep -m1 '^Exec=' "$entry") || return 0

	# The command token: upstream writes it double-quoted; fall back to
	# the first unquoted word for hand-edited entries.
	if [[ $exec_line =~ ^Exec=\"([^\"]*)\"(.*)$ ]]; then
		current="${BASH_REMATCH[1]}"
		args="${BASH_REMATCH[2]}"
	else
		rest="${exec_line#Exec=}"
		current="${rest%%[[:space:]]*}"
		args="${rest#"$current"}"
	fi

	# Already healed, or pointing at something that is not the app
	# itself (a hand-rolled wrapper): leave it alone.
	[[ $current == "$launcher" ]] && return 0
	case "$current" in
		*/claude-desktop) ;;
		*) return 0 ;;
	esac

	new_line="Exec=$(_desktop_exec_quote "$launcher")$args"

	# Rewrite only the first Exec line; keep everything else verbatim.
	tmp="$entry.tmp.$$"
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $replaced == false && $line == Exec=* ]]; then
			printf '%s\n' "$new_line"
			replaced=true
		else
			printf '%s\n' "$line"
		fi
	done < "$entry" > "$tmp" || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$entry" || { rm -f "$tmp"; return 0; }

	if [[ -n ${log_file:-} ]]; then
		log_message \
			"Healed autostart Exec: $current -> $launcher (AUTO-1)"
	fi
	return 0
}

# Marker line identifying the hidden entry written by
# ensure_portal_app_id_entry, so the launcher only ever rewrites or
# removes its own file, never a user-authored one.
readonly PORTAL_ENTRY_MARKER='X-Claude-Desktop-Debian-Portal-Alias=true'

# The official app writes its own copy of <id>.desktop to the user data
# dir (marked X-Claude-Generated=true, TryExec = the official Exec), but
# only while the official system entry exists. That copy outlives the
# official package: once TryExec stops resolving, GLib rejects the
# entry and the portal refuses the app id again. Such a copy is
# app-owned and dead, so ensure_portal_app_id_entry may replace it.
# Returns 0 for a stale copy, 1 otherwise.
_portal_entry_is_stale_generated() {
	local entry="$1" try_exec
	grep -qxF 'X-Claude-Generated=true' "$entry" 2>/dev/null \
		|| return 1
	try_exec=$(grep -m1 '^TryExec=' "$entry" 2>/dev/null) || return 1
	try_exec="${try_exec#TryExec=}"
	[[ -n $try_exec ]] || return 1
	if [[ $try_exec == /* ]]; then
		[[ ! -x $try_exec ]]
	else
		! command -v -- "$try_exec" > /dev/null 2>&1
	fi
}

# #805: xdg-desktop-portal >= 1.20 identifies a host (non-Flatpak) app
# by the id it passes to org.freedesktop.host.portal.Registry.Register,
# and refuses any id without an installed <id>.desktop ("Could not
# register app ID: App info not found"). GlobalShortcuts CreateSession
# then fails with "An app id is required", so Quick Entry's hotkey is
# never bound. Chromium (Electron >= 44) registers the asar desktopName
# minus ".desktop" -- $WM_CLASS -- but our packages install
# <package>.desktop: the official package owns
# /usr/share/applications/$WM_CLASS.desktop and we install side-by-side
# with it (D-002), so shipping that path would be a file conflict.
#
# So on native Wayland, the only backend that talks to the portal,
# write a hidden (NoDisplay) user-level entry under that id when no
# system one exists. Once one does (the official package got
# installed), remove ours so it stops shadowing the official menu
# entry. An entry without PORTAL_ENTRY_MARKER is left in place (and
# logged), except the official app's own stale copy -- see
# _portal_entry_is_stale_generated.
#
# $1 = absolute launcher path for Exec (/usr/bin/<package> or
#      "$APPIMAGE"; empty -> no-op, like heal_autostart_entry)
# $2 = icon name
# Requires: is_wayland, use_x11_on_wayland (detect_display_backend)
ensure_portal_app_id_entry() {
	local launcher="$1"
	local icon="${2:-}"
	local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
	local entry="$data_home/applications/$WM_CLASS.desktop"
	local ours=false stale=false dir tmp
	local -a data_dirs

	# Unsubstituted build-time placeholder: no real id to register.
	[[ $WM_CLASS == *@@* ]] && return 0

	if [[ -f $entry ]]; then
		if grep -qxF "$PORTAL_ENTRY_MARKER" "$entry"; then
			ours=true
		elif _portal_entry_is_stale_generated "$entry"; then
			stale=true
		fi
	fi

	IFS=: read -r -a data_dirs \
		<<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
	for dir in "${data_dirs[@]}"; do
		[[ -n $dir && -f $dir/applications/$WM_CLASS.desktop ]] \
			|| continue
		# A system entry already satisfies the portal.
		if [[ $ours == true ]] && rm -f "$entry"; then
			log_message "Removed portal app-id entry $entry" \
				"(system entry $dir/applications/$WM_CLASS.desktop)"
		fi
		return 0
	done

	[[ $is_wayland == true && $use_x11_on_wayland == false ]] \
		|| return 0
	[[ -n $launcher ]] || return 0
	# Any other entry is not ours to replace. Log it: if it is invalid,
	# the portal keeps refusing the app id and nothing else says why.
	if [[ -f $entry && $ours == false && $stale == false ]]; then
		log_message "Left portal app-id entry $entry in place" \
			'(not written by the launcher)'
		return 0
	fi

	mkdir -p "${entry%/*}" 2>/dev/null || return 0
	tmp="$entry.tmp.$$"
	{
		echo '[Desktop Entry]'
		echo 'Type=Application'
		echo 'Name=Claude'
		echo "Exec=$(_desktop_exec_quote "$launcher")"
		[[ -n $icon ]] && echo "Icon=$icon"
		echo 'NoDisplay=true'
		echo "$PORTAL_ENTRY_MARKER"
	} > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }

	if [[ $ours == true ]] && cmp -s "$tmp" "$entry"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$entry" 2>/dev/null || { rm -f "$tmp"; return 0; }
	[[ $stale == true ]] && log_message \
		'Replacing stale app-generated entry (TryExec not found)'
	log_message "Wrote portal app-id entry $entry (#805)"
	return 0
}

cleanup_after_electron_exit() {
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
}

_electron_launcher_forward_signal() {
	local signal="$1"

	if [[ -n ${_electron_child_pid:-} ]]; then
		kill "-$signal" "$_electron_child_pid" 2>/dev/null || true
	fi
}

# Bound what a session can write to launcher.log (#864). Electron's
# whole stdout/stderr lands in the log for the life of the session,
# and a Chromium message stuck in a loop wrote 32 GB in a morning on
# one machine: the launch-time rotation (#747) only ever sees the
# file at the next start. Two defences, in order:
#
#   1. Runs of identical lines collapse to the line plus one
#      "[launcher] last line repeated N more times" summary, so a
#      single-line loop costs two lines however long it spins.
#   2. After ELECTRON_LOG_CAP_BYTES of output (20 MiB default) the
#      filter stops WRITING but keeps READING: a marker line records
#      the cap, and every later line is consumed and dropped. The
#      pipe is never closed, so Electron never sees SIGPIPE.
#
# fflush() per line keeps the log live for `tail -f`. mawk and gawk
# both support it. Reads stdin, writes stdout; the caller aims stdout
# at the log.
_electron_output_filter() {
	local max="${ELECTRON_LOG_CAP_BYTES:-$((20 * 1024 * 1024))}"

	awk -v max="$max" '
		function emit(line) {
			print line
			fflush()
			written += length(line) + 1
		}
		function end_run() {
			if (repeat > 1) {
				emit("[launcher] last line repeated " (repeat - 1) \
					" more times")
			}
			repeat = 0
		}
		{
			if (have_prev && $0 == prev) {
				repeat++
				next
			}
			if (have_prev) end_run()
			prev = $0
			have_prev = 1
			repeat = 1
			if (written >= max) {
				if (!capped) {
					emit("[launcher] output cap (" max " bytes) reached;" \
						" further output dropped this session (#864)")
					capped = 1
				}
				next
			}
			emit($0)
		}
		END { end_run() }
	'
}

run_electron_and_cleanup() {
	local status fifo_dir fifo filter_pid=''

	# A named pipe rather than > >(...) so the filter pid is known and
	# the log can be drained before the exit line is written. Fail-safe:
	# if the pipe cannot be made, fall back to the bare redirect rather
	# than block launch.
	if fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/claude-launcher.XXXXXX" \
		2>/dev/null) && mkfifo "$fifo_dir/electron.out" 2>/dev/null; then
		fifo="$fifo_dir/electron.out"
		_electron_output_filter < "$fifo" >> "$log_file" &
		filter_pid=$!
		"$@" > "$fifo" 2>&1 &
		_electron_child_pid=$!
	else
		[[ -n ${fifo_dir:-} ]] && rm -rf "$fifo_dir"
		"$@" >> "$log_file" 2>&1 &
		_electron_child_pid=$!
	fi

	trap '_electron_launcher_forward_signal TERM' TERM
	trap '_electron_launcher_forward_signal INT' INT
	trap '_electron_launcher_forward_signal HUP' HUP

	wait "$_electron_child_pid"
	status=$?
	while kill -0 "$_electron_child_pid" 2>/dev/null; do
		wait "$_electron_child_pid"  # reap only; keep status
	done

	trap - TERM INT HUP

	# Drain the filter so Electron's last lines land before the exit
	# line. Bounded: a helper that inherited the pipe's write end and
	# outlives the main process would keep it open, and the cleanup
	# below is what reaps those; the filter finishes on its own once
	# the last writer closes.
	if [[ -n $filter_pid ]]; then
		local i
		for (( i = 0; i < 20; i++ )); do
			kill -0 "$filter_pid" 2>/dev/null || break
			sleep 0.1
		done
		rm -rf "$fifo_dir"
	fi

	log_message "Electron exited with code: $status"
	cleanup_after_electron_exit
	_electron_child_pid=''
	log_message '--- Claude Desktop Launcher End ---'

	return "$status"
}

# Set common environment variables
# Load persistent launcher env from a per-user config file. The
# generated .desktop Exec line can't carry per-user environment, so a
# GUI launch has no way to set e.g. COWORK_VM_BACKEND=bwrap (#772). This
# file fills that gap: KEY=value lines, honored only for a fixed
# allowlist of launcher variables, and only when the variable is not
# already set — an explicit terminal env or `Exec=env VAR=... ` still
# wins. Values are read literally; the file is never executed as shell.
#
#   ${XDG_CONFIG_HOME:-~/.config}/claude-desktop-debian/environment
#
# Callable before setup_logging: log_message no-ops without $log_file,
# which is what lets run_doctor load the config without a log.
load_launcher_config() {
	local cfg
	cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-desktop-debian/environment"
	[[ -r $cfg ]] || return 0

	# Built with += — a \-continuation inside single quotes embeds a
	# literal backslash+newline, which silently breaks the
	# space-delimited match for the key that follows it.
	local allowlist=' CLAUDE_USE_WAYLAND CLAUDE_PASSWORD_STORE'
	allowlist+=' CLAUDE_GTK_IM_MODULE CLAUDE_DISABLE_GPU'
	allowlist+=' CLAUDE_FORCE_SANDBOX'
	allowlist+=' CLAUDE_TRAY_USE_DARK_ICON'
	allowlist+=' COWORK_VM_BACKEND COWORK_NODE_PATH '
	local line key val
	while IFS= read -r line || [[ -n $line ]]; do
		# Skip blanks and comments.
		[[ -z ${line//[[:space:]]/} || ${line#"${line%%[![:space:]]*}"} == '#'* ]] \
			&& continue
		[[ $line == *=* ]] || continue
		key="${line%%=*}"
		key="${key//[[:space:]]/}"
		val="${line#*=}"
		# Trim surrounding whitespace ("KEY = value" is a config file,
		# not shell — an untrimmed value would export " 1" and fail the
		# consuming comparison while the log still reports it as set).
		val="${val#"${val%%[![:space:]]*}"}"
		val="${val%"${val##*[![:space:]]}"}"
		# Allowlist only — anything else in the file is ignored.
		[[ $allowlist == *" $key "* ]] || {
			log_message "Config: ignoring unrecognized key '$key' in $cfg"
			continue
		}
		# Environment wins: never override an already-set variable.
		[[ -n ${!key:-} ]] && continue
		# Strip one layer of surrounding quotes, if present.
		val="${val#[\"\']}"
		val="${val%[\"\']}"
		export "$key=$val"
		log_message "Config: $key=$val (from $cfg)"
	done < "$cfg"
}

# Cinnamon can use a dark panel (org.cinnamon.theme) while GTK's colour
# scheme stays light, so Electron's shouldUseDarkColors picks the black
# tray PNG on a dark gray panel (#604). Export CLAUDE_TRAY_USE_DARK_ICON
# for the asar patch; set it yourself to 0/1 to override auto-detect.
setup_tray_icon_env() {
	if [[ -n ${CLAUDE_TRAY_USE_DARK_ICON:-} ]]; then
		export CLAUDE_TRAY_USE_DARK_ICON
		log_message \
			"Tray icon: CLAUDE_TRAY_USE_DARK_ICON=$CLAUDE_TRAY_USE_DARK_ICON (preset)"
		if [[ $CLAUDE_TRAY_USE_DARK_ICON != 0 \
			&& $CLAUDE_TRAY_USE_DARK_ICON != 1 ]]; then
			log_message \
				'Tray icon: preset is not 0/1 — the app ignores it,' \
				'and Cinnamon auto-detect stays off'
		fi
		return 0
	fi

	local desktop="${XDG_CURRENT_DESKTOP:-}"
	[[ ${desktop,,} == *cinnamon* ]] || return 0

	if ! command -v gsettings &>/dev/null; then
		return 0
	fi

	local cinnamon_theme
	cinnamon_theme=$(gsettings get org.cinnamon.theme name 2>/dev/null) \
		|| return 0
	cinnamon_theme=${cinnamon_theme//[\'\"]/}
	[[ ${cinnamon_theme,,} == *dark* ]] || return 0

	export CLAUDE_TRAY_USE_DARK_ICON=1
	log_message \
		"Tray icon: cinnamon theme '$cinnamon_theme' has a dark panel;" \
		'using TrayIconLinux-Dark.png (CLAUDE_TRAY_USE_DARK_ICON=1)'
}

setup_electron_env() {
	# Persistent per-user launcher env (GUI launches can't set env via
	# the .desktop Exec line) — load before anything reads these vars.
	load_launcher_config

	# The official Linux build ships packaged, so ELECTRON_FORCE_IS_PACKAGED
	# is dropped (forcing it would shadow upstream's own isPackaged logic),
	# and the official build owns its window frame, so the
	# ELECTRON_USE_SYSTEM_TITLE_BAR export is gone too. See the launcher
	# policy note above build_electron_args.
	#
	# CLAUDE_GTK_IM_MODULE: opt-in override for users hit by broken
	# IBus integration on Linux (#549). Propagated to GTK_IM_MODULE
	# so e.g. `xim` can be persisted without wrapping every launch.
	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		local prev="${GTK_IM_MODULE:-<unset>}"
		export GTK_IM_MODULE="$CLAUDE_GTK_IM_MODULE"
		log_message \
			"GTK_IM_MODULE override: $prev -> $GTK_IM_MODULE (via CLAUDE_GTK_IM_MODULE)"
	fi

	setup_tray_icon_env
	setup_cowork_bwrap_env
}

# Opt-in Cowork bubblewrap backend (COWORK_VM_BACKEND=bwrap) for hosts
# without KVM/vhost-vsock (ChromeOS Crostini, #772). The asar patch
# (patch_cowork_bwrap) swaps the native Cowork helper for the Node
# daemon shipped at resources/cowork-vm-service.js — but the official
# Electron binary ships with the RunAsNode fuse OFF, so it can't run the
# daemon itself. Resolve a system node here and hand its path to the
# patched spawn via COWORK_NODE_PATH. Only touches the environment when
# the user actually opts in; unflagged launches are untouched.
setup_cowork_bwrap_env() {
	[[ ${COWORK_VM_BACKEND:-} == 'bwrap' ]] || return 0

	# Respect an explicit override; otherwise probe PATH for node then
	# nodejs (Debian/Ubuntu ship the interpreter as `nodejs`).
	if [[ -z ${COWORK_NODE_PATH:-} ]]; then
		local node_bin
		node_bin=$(command -v node 2>/dev/null) \
			|| node_bin=$(command -v nodejs 2>/dev/null) || node_bin=''
		if [[ -n $node_bin ]]; then
			export COWORK_NODE_PATH="$node_bin"
		fi
	fi

	if [[ -z ${COWORK_NODE_PATH:-} ]]; then
		log_message \
			'Cowork backend: bwrap requested but no system node/nodejs' \
			'found on PATH — the fallback daemon cannot start. Install' \
			'Node.js (>= 18.15, e.g. sudo apt install nodejs) or set' \
			'COWORK_NODE_PATH.'
		return 0
	fi

	# Warn when the node lacks the daemon's required capability. The
	# daemon needs fs.statfsSync (added in Node 18.15 / 16.19), so probe
	# the call directly rather than compare a major — 18.0-18.14 has
	# major 18 but not the call. The daemon self-guards on the same
	# capability; this surfaces it in the launcher log where the user
	# looks first. Kept in lock-step with cowork_node_has_features
	# (doctor) and nodeHasRequiredFeatures (daemon).
	# cowork_node_has_features is defined in doctor.sh, which this file
	# sources; both it and the daemon check the same capability.
	if cowork_node_has_features "$COWORK_NODE_PATH"; then
		log_message \
			"Cowork backend: bwrap (daemon node: $COWORK_NODE_PATH)"
	else
		log_message \
			"Cowork backend: bwrap node $COWORK_NODE_PATH lacks" \
			'fs.statfsSync (needs Node >= 18.15) — the daemon will' \
			'refuse to start. Install a newer Node.js or set' \
			'COWORK_NODE_PATH.'
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
