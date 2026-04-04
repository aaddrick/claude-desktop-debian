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
	fi
}

# Kill orphaned cowork-vm-service daemon processes.
# After a crash or unclean shutdown the cowork daemon may outlive the
# main Electron UI process.  The orphaned daemon holds LevelDB locks
# in ~/.config/Claude/Local Storage/ which cause new launches to
# detect a "main instance" and silently quit.
# Must run BEFORE cleanup_stale_lock / cleanup_stale_cowork_socket
# so that stale files left behind by the daemon can be cleaned up.
cleanup_orphaned_cowork_daemon() {
	local cowork_pids
	cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| return 0

	# Check if a Claude Desktop UI process is also running.
	# Any claude-desktop electron process that is NOT the cowork
	# daemon indicates the app is alive and the daemon is expected.
	local pid cmdline
	for pid in $(pgrep -f 'claude-desktop' 2>/dev/null); do
		cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) \
			|| continue
		[[ $cmdline == *cowork-vm-service* ]] && continue
		# Found a non-daemon claude-desktop process — not orphaned
		return 0
	done

	# No UI process found — daemon is orphaned, terminate it
	for pid in $cowork_pids; do
		kill "$pid" 2>/dev/null || true
	done
	log_message "Killed orphaned cowork-vm-service daemon (PIDs: $cowork_pids)"
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
cleanup_stale_cowork_socket() {
	local sock="${XDG_RUNTIME_DIR:-/tmp}/cowork-vm-service.sock"

	[[ -S $sock ]] || return 0

	if command -v socat &>/dev/null; then
		# Try connecting — if refused, the socket is stale
		if socat -u OPEN:/dev/null UNIX-CONNECT:"$sock" 2>/dev/null; then
			return 0
		fi
	else
		# No socat: fall back to age-based check (>24h = stale)
		if [[ -z $(find "$sock" -mmin +1440 2>/dev/null) ]]; then
			return 0
		fi
		log_message "No socat available; removing old socket (>24h)"
	fi

	rm -f "$sock"
	log_message "Removed stale cowork-vm-service socket"
}

# Set common environment variables
setup_electron_env() {
	# ELECTRON_FORCE_IS_PACKAGED makes app.isPackaged return true, which
	# causes the Claude app to resolve resources via process.resourcesPath.
	# The Nix derivation creates a custom Electron tree with the binary
	# copied and app resources co-located in resources/, so resourcesPath
	# naturally points to the right place on all package types.
	export ELECTRON_FORCE_IS_PACKAGED=true
	export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}

#===============================================================================
# Doctor Diagnostics
#===============================================================================

# Color helpers (disabled when stdout is not a terminal)
_doctor_colors() {
	if [[ -t 1 ]]; then
		_green='\033[0;32m'
		_red='\033[0;31m'
		_yellow='\033[0;33m'
		_bold='\033[1m'
		_reset='\033[0m'
	else
		_green='' _red='' _yellow='' _bold='' _reset=''
	fi
}

# Return the distro ID from /etc/os-release
_cowork_distro_id() {
	local id='unknown'
	if [[ -f /etc/os-release ]]; then
		local line
		while IFS= read -r line; do
			if [[ $line == ID=* ]]; then
				id="${line#ID=}"
				id="${id//\"/}"
				break
			fi
		done < /etc/os-release
	fi
	printf '%s' "$id"
}

# Return a distro-specific install command for a cowork tool
# Usage: _cowork_pkg_hint <distro_id> <tool_name>
_cowork_pkg_hint() {
	local distro="$1"
	local tool="$2"
	local pkg_cmd

	# Determine package manager command
	case "$distro" in
		debian|ubuntu) pkg_cmd='sudo apt install' ;;
		fedora)        pkg_cmd='sudo dnf install' ;;
		arch)          pkg_cmd='sudo pacman -S' ;;
		*)
			printf '%s' "Install $tool using your package manager"
			return
			;;
	esac

	# Map tool name to distro-specific package(s)
	local pkg
	case "$tool" in
		qemu)
			case "$distro" in
				debian|ubuntu) pkg='qemu-system-x86 qemu-utils' ;;
				fedora)        pkg='qemu-kvm qemu-img' ;;
				arch)          pkg='qemu-full' ;;
			esac
			;;
		*) pkg="$tool" ;;
	esac

	printf '%s' "$pkg_cmd $pkg"
}

# Read the version string from the version file beside an Electron binary.
# Prints the raw version string, or nothing if unavailable.
_electron_version() {
	local version_file
	version_file="$(dirname "$1")/version"
	[[ -r $version_file ]] && printf '%s' "$(< "$version_file")"
}

_pass() { echo -e "${_green}[PASS]${_reset} $*"; }
_fail() {
	echo -e "${_red}[FAIL]${_reset} $*"
	_doctor_failures=$((_doctor_failures + 1))
}
_warn() { echo -e "${_yellow}[WARN]${_reset} $*"; }
_info() { echo -e "       $*"; }

# Run all diagnostic checks and print results
# Arguments: $1 = electron path (optional, for package-specific checks)
run_doctor() {
	local electron_path="${1:-}"
	local _doctor_failures=0
	_doctor_colors

	echo -e "${_bold}Claude Desktop Diagnostics${_reset}"
	echo '================================'
	echo

	# -- Installed package version --
	if command -v dpkg-query &>/dev/null; then
		local pkg_version
		pkg_version=$(dpkg-query -W -f='${Version}' \
			claude-desktop 2>/dev/null) || true
		if [[ -n $pkg_version ]]; then
			_pass "Installed version: $pkg_version"
		else
			_warn 'claude-desktop not found via dpkg (AppImage?)'
		fi
	fi

	# -- Display server --
	if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
		_pass "Display server: Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
		local desktop="${XDG_CURRENT_DESKTOP:-unknown}"
		_info "Desktop: $desktop"
		if [[ "${CLAUDE_USE_WAYLAND:-}" == '1' ]]; then
			_info 'Mode: native Wayland (CLAUDE_USE_WAYLAND=1)'
		else
			_info 'Mode: X11 via XWayland (default, for global hotkey support)'
			_info 'Tip: Set CLAUDE_USE_WAYLAND=1 for native Wayland'
			_info '     (disables global hotkeys)'
		fi
	elif [[ -n "${DISPLAY:-}" ]]; then
		_pass "Display server: X11 (DISPLAY=$DISPLAY)"
	else
		_fail "No display server detected" \
			"(DISPLAY and WAYLAND_DISPLAY are unset)"
		_info 'Fix: Run from within an X11 or Wayland session, not a TTY'
	fi

	# -- Menu bar mode --
	local menu_bar_mode="${CLAUDE_MENU_BAR:-}"
	if [[ -n $menu_bar_mode ]]; then
		local resolved_mode="${menu_bar_mode,,}"
		# Resolve boolean-style aliases
		case "$resolved_mode" in
			1|true|yes|on) resolved_mode='visible' ;;
			0|false|no|off) resolved_mode='hidden' ;;
		esac
		case "$resolved_mode" in
			auto|visible|hidden)
				_pass "Menu bar mode: $resolved_mode" \
					"(CLAUDE_MENU_BAR=$menu_bar_mode)"
				;;
			*)
				_warn "Unknown CLAUDE_MENU_BAR: '$menu_bar_mode'"
				_info 'Will fall back to auto'
				_info 'Valid values: auto, visible, hidden' \
					'(or 0/1/true/false/yes/no/on/off)'
				;;
		esac
	else
		_info 'Menu bar mode: auto (default, Alt toggles visibility)'
	fi

	# -- Electron binary --
	# Version is read from the file next to the binary rather than
	# launching Electron, which can hang (see #371).
	if [[ -n $electron_path && -x $electron_path ]]; then
		local ver
		ver=$(_electron_version "$electron_path")
		if [[ $ver =~ ^v?[0-9]+\.[0-9]+ ]]; then
			_pass "Electron: v${ver#v} ($electron_path)"
		else
			_pass "Electron: found at $electron_path"
		fi
	elif [[ -n $electron_path ]]; then
		_fail "Electron binary not found at $electron_path"
		_info 'Fix: Reinstall claude-desktop package'
	elif command -v electron &>/dev/null; then
		local ver
		ver=$(_electron_version "$(command -v electron)")
		_pass "Electron: ${ver:+v${ver#v} }(system)"
	else
		_fail 'Electron binary not found'
		_info 'Fix: Reinstall claude-desktop package'
	fi

	# -- Chrome sandbox permissions --
	local sandbox_paths=(
		'/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'
	)
	# Also check relative to the provided electron path
	if [[ -n $electron_path ]]; then
		local electron_dir
		electron_dir=$(dirname "$electron_path")
		sandbox_paths+=("$electron_dir/chrome-sandbox")
	fi
	local sandbox_checked=false
	for sandbox_path in "${sandbox_paths[@]}"; do
		if [[ -f $sandbox_path ]]; then
			sandbox_checked=true
			local sandbox_perms sandbox_owner
			sandbox_perms=$(stat -c '%a' "$sandbox_path" 2>/dev/null) || true
			sandbox_owner=$(stat -c '%U' "$sandbox_path" 2>/dev/null) || true
			if [[ $sandbox_perms == '4755' && $sandbox_owner == 'root' ]]; then
				_pass "Chrome sandbox: permissions OK ($sandbox_path)"
			else
				_fail "Chrome sandbox: perms=${sandbox_perms:-?},\
 owner=${sandbox_owner:-?}"
				_info "Fix: sudo chown root:root $sandbox_path"
				_info "     sudo chmod 4755 $sandbox_path"
			fi
			break
		fi
	done
	if [[ $sandbox_checked == false ]]; then
		_warn 'Chrome sandbox not found (expected for AppImage)'
	fi

	# -- SingletonLock --
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local lock_file="$config_dir/SingletonLock"
	if [[ -L $lock_file ]]; then
		local lock_target lock_pid
		lock_target="$(readlink "$lock_file" 2>/dev/null)" || true
		lock_pid="${lock_target##*-}"
		if [[ $lock_pid =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
			_pass "SingletonLock: held by running process (PID $lock_pid)"
		else
			_warn "SingletonLock: stale lock found" \
				"(PID $lock_pid is not running)"
			_info "Fix: rm '$lock_file'"
		fi
	else
		_pass 'SingletonLock: no lock file (OK)'
	fi

	# -- MCP config --
	local mcp_config="$config_dir/claude_desktop_config.json"
	if [[ -f $mcp_config ]]; then
		if command -v python3 &>/dev/null; then
			if python3 -c \
			"import json,sys; json.load(open(sys.argv[1]))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
				# Check if any MCP servers are configured
				local server_count
				server_count=$(python3 -c "
import json,sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
servers = cfg.get('mcpServers', {})
print(len(servers))
" "$mcp_config" 2>/dev/null) || server_count='0'
				_info "MCP servers configured: $server_count"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
				_info "Tip: python3 -m json.tool '$mcp_config' to see the error"
			fi
		elif command -v node &>/dev/null; then
			if node -e \
			"JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" \
			"$mcp_config" 2>/dev/null; then
				_pass "MCP config: valid JSON ($mcp_config)"
			else
				_fail "MCP config: invalid JSON"
				_info "Fix: Check $mcp_config for syntax errors"
			fi
		else
			_warn "MCP config: exists but cannot validate" \
				"(no python3 or node available)"
		fi
	else
		_info "MCP config: not found at $mcp_config (OK if not using MCP)"
	fi

	# -- Node.js (needed by MCP servers) --
	if command -v node &>/dev/null; then
		local node_version
		node_version=$(node --version 2>/dev/null) || true
		local node_major="${node_version#v}"
		node_major="${node_major%%.*}"
		if ((node_major >= 20)); then
			_pass "Node.js: $node_version"
		elif ((node_major >= 1)); then
			_warn "Node.js: $node_version (v20+ recommended for MCP servers)"
			_info 'Fix: Update Node.js to v20 or later'
		fi
		_info "Path: $(command -v node)"
	else
		_warn 'Node.js: not found (required for MCP servers)'
		_info 'Fix: Install Node.js v20+ from https://nodejs.org'
	fi

	# -- Desktop integration --
	local desktop_file='/usr/share/applications/claude-desktop.desktop'
	if [[ -f $desktop_file ]]; then
		_pass "Desktop entry: $desktop_file"
	else
		_warn 'Desktop entry not found (expected for AppImage installs)'
	fi

	# -- Disk space --
	local config_disk_avail
	config_disk_avail=$(df -BM --output=avail "$config_dir" 2>/dev/null \
		| tail -1 | tr -d ' M') || true
	if [[ -n $config_disk_avail ]]; then
		if ((config_disk_avail < 100)); then
			_fail "Disk space: ${config_disk_avail}MB free on config partition"
			_info 'Fix: Free up disk space'
		elif ((config_disk_avail < 500)); then
			_warn "Disk space: ${config_disk_avail}MB free" \
				"on config partition (low)"
		else
			_pass "Disk space: ${config_disk_avail}MB free"
		fi
	fi

	# -- Cowork Mode --
	echo
	echo -e "${_bold}Cowork Mode${_reset}"
	echo '----------------'

	# Detect distro for package hints
	local _distro_id
	_distro_id=$(_cowork_distro_id)

	# Bubblewrap (default backend)
	if command -v bwrap &>/dev/null; then
		_pass 'bubblewrap: found'
	else
		_warn 'bubblewrap: not found'
		_info \
			"Fix: $(_cowork_pkg_hint "$_distro_id" bubblewrap)"
	fi

	# Warn on missing KVM deps only when explicitly requested;
	# otherwise just inform since bwrap is the default.
	local _kvm_active=false
	[[ ${COWORK_VM_BACKEND-} == [Kk][Vv][Mm] ]] && _kvm_active=true
	local _kvm_issue=_info
	$_kvm_active && _kvm_issue=_warn

	# KVM backend (opt-in via COWORK_VM_BACKEND=kvm)
	if [[ -e /dev/kvm ]]; then
		if [[ -r /dev/kvm && -w /dev/kvm ]]; then
			_pass 'KVM: accessible'
		else
			"$_kvm_issue" 'KVM: /dev/kvm exists but not accessible'
			if $_kvm_active; then
				_info "Fix: sudo usermod -aG kvm $USER"
				_info '(Log out and back in after running this)'
			fi
		fi
	else
		"$_kvm_issue" 'KVM: not available'
		if $_kvm_active; then
			_info \
				'Fix: Install qemu-kvm and ensure KVM is enabled in BIOS'
		fi
	fi

	# vsock module
	if [[ -e /dev/vhost-vsock ]]; then
		_pass 'vsock: module loaded'
	else
		"$_kvm_issue" 'vsock: /dev/vhost-vsock not found'
		if $_kvm_active; then
			_info 'Fix: sudo modprobe vhost_vsock'
		fi
	fi

	# KVM tools: QEMU, socat, virtiofsd
	local _tool_label _tool_bin _tool_pkg
	for _tool_label in \
		'QEMU:qemu-system-x86_64:qemu' \
		'socat:socat:socat' \
		'virtiofsd:virtiofsd:virtiofsd'
	do
		_tool_bin="${_tool_label#*:}"
		_tool_pkg="${_tool_bin#*:}"
		_tool_bin="${_tool_bin%%:*}"
		_tool_label="${_tool_label%%:*}"

		if command -v "$_tool_bin" &>/dev/null; then
			_pass "$_tool_label: found"
		else
			"$_kvm_issue" "$_tool_label: not found"
			if $_kvm_active; then
				_info \
					"Fix: $(_cowork_pkg_hint "$_distro_id" "$_tool_pkg")"
			fi
		fi
	done

	# VM image
	local vm_image
	vm_image="${HOME}/.local/share/claude-desktop/vm/rootfs.qcow2"
	if [[ -f $vm_image ]]; then
		local vm_size
		vm_size=$(du -h "$vm_image" 2>/dev/null \
			| cut -f1) || vm_size='unknown size'
		_pass "VM image: $vm_size"
	else
		_info 'VM image: not downloaded yet'
	fi

	# Determine active backend (matches daemon's detectBackend())
	local cowork_backend='none (host-direct, no isolation)'
	if [[ -n ${COWORK_VM_BACKEND-} ]]; then
		case ${COWORK_VM_BACKEND,,} in
			kvm)  cowork_backend='KVM (full VM isolation, via override)' ;;
			bwrap) cowork_backend='bubblewrap (namespace sandbox, via override)' ;;
			host) cowork_backend='host-direct (no isolation, via override)' ;;
		esac
	elif command -v bwrap &>/dev/null \
		&& bwrap --ro-bind / / true &>/dev/null; then
		cowork_backend='bubblewrap (namespace sandbox)'
	elif [[ -e /dev/kvm ]] \
		&& [[ -r /dev/kvm && -w /dev/kvm ]] \
		&& command -v qemu-system-x86_64 &>/dev/null \
		&& [[ -e /dev/vhost-vsock ]]; then
		cowork_backend='KVM (full VM isolation)'
	fi
	_info "Cowork isolation: $cowork_backend"

	# -- Orphaned cowork daemon --
	local _cowork_pids
	_cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| true
	if [[ -n $_cowork_pids ]]; then
		local _daemon_orphaned=true _pid _cmdline
		for _pid in $(pgrep -f 'claude-desktop' 2>/dev/null); do
			_cmdline=$(tr '\0' ' ' \
				< "/proc/$_pid/cmdline" 2>/dev/null) || continue
			[[ $_cmdline == *cowork-vm-service* ]] && continue
			_daemon_orphaned=false
			break
		done
		if [[ $_daemon_orphaned == true ]]; then
			_warn "Cowork daemon: orphaned (PIDs: $_cowork_pids)"
			_info 'Fix: Restart Claude Desktop' \
				'(daemon will be cleaned up automatically)'
		else
			_pass 'Cowork daemon: running (parent alive)'
		fi
	fi

	# -- Log file --
	local log_path
	log_path="${XDG_CACHE_HOME:-$HOME/.cache}"
	log_path="$log_path/claude-desktop-debian/launcher.log"
	if [[ -f $log_path ]]; then
		local log_size
		log_size=$(stat -c '%s' "$log_path" 2>/dev/null) || log_size=0
		local log_size_kb=$((log_size / 1024))
		if ((log_size_kb > 10240)); then
			_warn "Log file: ${log_size_kb}KB" \
				"(consider clearing: rm '$log_path')"
		else
			_pass "Log file: ${log_size_kb}KB ($log_path)"
		fi
	else
		_info 'Log file: not yet created (OK)'
	fi

	# -- Summary --
	echo
	if ((_doctor_failures == 0)); then
		echo -e "${_green}${_bold}All checks passed.${_reset}"
	else
		echo -e "${_red}${_bold}${_doctor_failures} check(s) failed.${_reset}"
		echo 'See above for fixes.'
	fi

	return "$_doctor_failures"
}
