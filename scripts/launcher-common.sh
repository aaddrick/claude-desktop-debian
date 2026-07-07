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
#
# LOG-1: never persist OAuth authorization codes. A relaunch through the
# login redirect carries claude://login/...?code=<secret> in argv, which
# reaches both the "Arguments:" and "Executing:" lines. Strip the query
# string of any claude://login token before writing, keeping the path for
# context. Guarded so the common case pays no subprocess.
log_message() {
	local msg="$1"
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
#   --class=$WM_CLASS         WM_CLASS/.desktop contract (#647, #652)
#   XRDP auto GPU-off         blank window on remote GPU (#319)
#   GPU-crash sticky recovery GPU process FATAL exhaustion (#583)
#   Wayland backend selection CLAUDE_USE_WAYLAND tri-state (#226, #404)
#   --no-sandbox              only where structurally required
#                             (AppImage FUSE; deb/nix on Wayland)
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

	# WM_CLASS must match the .desktop StartupWMClass and upstream's
	# productName. Ref: #647, #652
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
		*cowork-linux-helper*)
			# Official Rust Cowork helper, spawned via
			# process.resourcesPath (relocation-safe, so no fixed path).
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
		*/usr/lib/claude-desktop-unofficial/*--type=*)
			# Phase 3 package rename, landing in v3.0.0: our package
			# installs to /usr/lib/claude-desktop-unofficial while the
			# official arm above keeps matching Anthropic's install
			# (and the AppImage internal tree).
			return 0
			;;
	esac

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
	local exec_line current args rest escaped new_line tmp line
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

	# Desktop-entry escaping, mirroring what upstream applies to its
	# own execPath: backslash-escape \ " ` $, then % -> %%.
	escaped="$launcher"
	escaped=${escaped//\\/\\\\}
	escaped=${escaped//\"/\\\"}
	escaped=${escaped//\`/\\\`}
	escaped=${escaped//\$/\\\$}
	escaped=${escaped//%/%%}
	new_line="Exec=\"$escaped\"$args"

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
# setup_logging() must have run first (log_message needs $log_file).
load_launcher_config() {
	local cfg
	cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-desktop-debian/environment"
	[[ -r $cfg ]] || return 0

	local allowlist=' CLAUDE_USE_WAYLAND CLAUDE_PASSWORD_STORE \
CLAUDE_GTK_IM_MODULE CLAUDE_DISABLE_GPU COWORK_VM_BACKEND COWORK_NODE_PATH '
	local line key val
	while IFS= read -r line || [[ -n $line ]]; do
		# Skip blanks and comments.
		[[ -z ${line//[[:space:]]/} || ${line#"${line%%[![:space:]]*}"} == '#'* ]] \
			&& continue
		[[ $line == *=* ]] || continue
		key="${line%%=*}"
		key="${key//[[:space:]]/}"
		val="${line#*=}"
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
			'Node.js (>= v18, e.g. sudo apt install nodejs) or set' \
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
