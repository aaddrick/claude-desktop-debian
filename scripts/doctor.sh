#===============================================================================
# Doctor Diagnostics
#
# Sourced by: scripts/launcher-common.sh (which is in turn sourced by the
# per-package launcher scripts — deb, rpm, AppImage, Nix).
#
# Provides: run_doctor (the `claude-desktop --doctor` entry point) plus its
# internal helpers. Self-contained — no dependencies on launcher-common.sh
# state or functions.
#
# To add a new check: define an internal function `_check_<name>`, call it
# from run_doctor in the appropriate section, use _pass / _fail / _warn /
# _info to print results. _fail increments _doctor_failures (local to
# run_doctor) which becomes the exit status.
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

# Locate the virtiofsd binary. Distros install it at different
# off-PATH locations:
#   - Debian/Ubuntu: /usr/libexec/virtiofsd (qemu-system-common)
#   - Fedora/RHEL:   /usr/libexec/virtiofsd
#   - Older Debian:  /usr/lib/qemu/virtiofsd
#   - Arch/Manjaro:  /usr/lib/virtiofsd
#
# `command -v virtiofsd` alone produces a false negative on any of
# the above. Search PATH first, then the well-known fallback paths.
#
# Prints the discovered path on stdout; returns 0 on hit, 1 on miss.
# Fallback paths are overridable via _COWORK_DOCTOR_VFSD_PATHS
# (colon-separated) so tests can point at a stub directory. The
# namespaced prefix signals "internal test hook — not a user knob".
_find_virtiofsd() {
	local bin
	bin=$(command -v virtiofsd 2>/dev/null)
	if [[ -n $bin ]]; then
		printf '%s' "$bin"
		return 0
	fi

	local fallback_paths="${_COWORK_DOCTOR_VFSD_PATHS:-}"
	if [[ -z $fallback_paths ]]; then
		fallback_paths='/usr/libexec/virtiofsd'
		fallback_paths+=':/usr/lib/qemu/virtiofsd'
		fallback_paths+=':/usr/lib/virtiofsd'
	fi

	local fallback
	local IFS=:
	for fallback in $fallback_paths; do
		if [[ -x $fallback ]]; then
			printf '%s' "$fallback"
			return 0
		fi
	done
	return 1
}

# Check custom bwrap mount configuration and report findings
_doctor_check_bwrap_mounts() {
	local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
	local config_file="$config_dir/claude_desktop_linux_config.json"

	[[ -f $config_file ]] || return 0

	local parser=''
	if command -v python3 &>/dev/null; then
		parser='python3'
	elif command -v node &>/dev/null; then
		parser='node'
	else
		return 0
	fi

	local mounts_json=''
	if [[ $parser == 'python3' ]]; then
		mounts_json=$(python3 - "$config_file" 2>/dev/null <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    mounts = cfg.get('preferences', {}).get('coworkBwrapMounts', {})
    if mounts:
        print(json.dumps(mounts))
except Exception:
    pass
PYEOF
)
	else
		mounts_json=$(node - "$config_file" 2>/dev/null <<'JSEOF'
try {
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
    const m = (cfg.preferences || {}).coworkBwrapMounts || {};
    if (Object.keys(m).length > 0)
        process.stdout.write(JSON.stringify(m));
} catch (_) {}
JSEOF
)
	fi

	if [[ -z $mounts_json ]]; then
		_info 'Bwrap mounts: default (no custom configuration)'
		return 0
	fi

	_info 'Bwrap custom mount configuration detected:'

	local parsed_output=''
	if [[ $parser == 'python3' ]]; then
		parsed_output=$(python3 - "$mounts_json" 2>/dev/null <<'PYEOF'
import json, sys
m = json.loads(sys.argv[1])
for p in m.get('additionalROBinds', []):
    print(p)
print('---')
for p in m.get('additionalBinds', []):
    print(p)
print('---')
for p in m.get('disabledDefaultBinds', []):
    print(p)
PYEOF
)
	else
		parsed_output=$(node - "$mounts_json" 2>/dev/null <<'JSEOF'
const m = JSON.parse(process.argv[1]);
(m.additionalROBinds || []).forEach(p => console.log(p));
console.log('---');
(m.additionalBinds || []).forEach(p => console.log(p));
console.log('---');
(m.disabledDefaultBinds || []).forEach(p => console.log(p));
JSEOF
)
	fi

	local ro_binds='' rw_binds='' disabled_binds=''
	local section=0
	while IFS= read -r line; do
		if [[ $line == '---' ]]; then
			((section++))
			continue
		fi
		case $section in
			0) ro_binds+="${line}"$'\n' ;;
			1) rw_binds+="${line}"$'\n' ;;
			2) disabled_binds+="${line}"$'\n' ;;
		esac
	done <<< "$parsed_output"
	ro_binds=${ro_binds%$'\n'}
	rw_binds=${rw_binds%$'\n'}
	disabled_binds=${disabled_binds%$'\n'}

	if [[ -n $ro_binds ]]; then
		_info '  Read-only mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$ro_binds"
	fi

	if [[ -n $rw_binds ]]; then
		_info '  Read-write mounts:'
		while IFS= read -r bind_path; do
			_info "    - $bind_path"
		done <<< "$rw_binds"
	fi

	local critical_warned=false
	if [[ -n $disabled_binds ]]; then
		while IFS= read -r bind_path; do
			case "$bind_path" in
				/usr|/etc)
					_warn \
						"Disabled default mount: $bind_path" \
						'(may break system tools!)'
					critical_warned=true
					;;
				*)
					_info "  Disabled default mount: $bind_path"
					;;
			esac
		done <<< "$disabled_binds"
		if [[ $critical_warned == true ]]; then
			_info \
				'  Disabling /usr or /etc may cause commands' \
				'to fail inside the sandbox.'
			_info \
				'  Restart the daemon after config changes:' \
				'pkill -f cowork-vm-service'
		fi
	fi

	if [[ $critical_warned != true ]]; then
		_info \
			'  Note: Restart daemon for config changes:' \
			'pkill -f cowork-vm-service'
	fi
}

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

	# Determine whether bwrap is the active backend (for severity
	# of bwrap-related diagnostics). Auto-detect prefers bwrap, so
	# bwrap is active unless the user has overridden to KVM or host.
	local _bwrap_active=true
	case "${COWORK_VM_BACKEND,,}" in
		kvm|host) _bwrap_active=false ;;
	esac

	# Bubblewrap (default backend)
	if command -v bwrap &>/dev/null; then
		_pass 'bubblewrap: found'

		# Probe the sandbox. User namespaces must be available for
		# bwrap to create its sandbox; Ubuntu 24.04+ blocks them via
		# AppArmor by default (issue #351).
		local _bwrap_probe_err='' _bwrap_probe_rc=0
		_bwrap_probe_err=$(bwrap --ro-bind / / true 2>&1 >/dev/null) \
			|| _bwrap_probe_rc=$?
		if ((_bwrap_probe_rc == 0)); then
			_pass 'bubblewrap: sandbox probe succeeded'
		else
			local _bwrap_issue=_warn
			$_bwrap_active && _bwrap_issue=_fail
			"$_bwrap_issue" \
				"bubblewrap: sandbox probe failed" \
				"(rc=$_bwrap_probe_rc)"
			if [[ -n $_bwrap_probe_err ]]; then
				_info "  stderr: $_bwrap_probe_err"
			fi
			# Detect the Ubuntu 24.04 AppArmor userns block
			# specifically, and hint the remediation.
			local _userns_re='(user[[:space:]_-]?namespace|apparmor|[Oo]peration not permitted|CLONE_NEW|CAP_SYS_ADMIN)'
			if [[ $_bwrap_probe_err =~ $_userns_re ]]; then
				_info \
					'  Likely cause: unprivileged user namespaces' \
					'are blocked.'
				_info \
					'  Common on Ubuntu 24.04+ where AppArmor sets' \
					'apparmor_restrict_unprivileged_userns=1'
				_info \
					'  by default. See docs/TROUBLESHOOTING.md' \
					'"Cowork on Ubuntu 24.04"'
				_info '  for the AppArmor profile fix.'
			fi
		fi
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

	# KVM tools: QEMU, socat. virtiofsd is handled separately below
	# because Debian/Ubuntu install it off-PATH.
	local _tool_label _tool_bin _tool_pkg
	for _tool_label in \
		'QEMU:qemu-system-x86_64:qemu' \
		'socat:socat:socat'
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

	# virtiofsd: ships off-PATH on several distros (see _find_virtiofsd
	# above). Probe known locations so we don't report "not found" when
	# the package is actually installed. KvmBackend spawns by PATH name
	# and silently falls back to virtio-9p (lower perf) if the spawn
	# fails — so when KVM is the active backend and virtiofsd is only
	# reachable off-PATH, surface a [WARN] so the user knows they need
	# a symlink to actually get virtiofs performance. On the bwrap
	# default path virtiofsd is unused, so [PASS] is fine.
	local _vfsd_path _vfsd_on_path
	_vfsd_on_path=$(command -v virtiofsd 2>/dev/null)
	_vfsd_path=$(_find_virtiofsd)
	if [[ -n $_vfsd_path ]]; then
		if [[ $_vfsd_path == "$_vfsd_on_path" ]]; then
			_pass 'virtiofsd: found'
		elif $_kvm_active; then
			_warn "virtiofsd: found at $_vfsd_path but not on PATH"
			_info 'KvmBackend spawns by PATH name and will fall back'
			_info 'to virtio-9p (lower performance) without a symlink.'
			_info "Fix: sudo ln -s $_vfsd_path /usr/local/bin/virtiofsd"
		else
			_pass "virtiofsd: found at $_vfsd_path (not on PATH)"
		fi
	else
		"$_kvm_issue" 'virtiofsd: not found'
		if $_kvm_active; then
			_info "Fix: $(_cowork_pkg_hint "$_distro_id" virtiofsd)"
		fi
	fi

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
	elif command -v bwrap &>/dev/null; then
		# bwrap is installed: if the probe succeeds, use it;
		# otherwise fall to host (matching daemon behavior, so we
		# don't silently imply KVM will be chosen when bwrap is
		# blocked — see #351).
		if bwrap --ro-bind / / true &>/dev/null; then
			cowork_backend='bubblewrap (namespace sandbox)'
		else
			cowork_backend='host-direct (bwrap probe failed — see above)'
		fi
	elif [[ -e /dev/kvm ]] \
		&& [[ -r /dev/kvm && -w /dev/kvm ]] \
		&& command -v qemu-system-x86_64 &>/dev/null \
		&& [[ -e /dev/vhost-vsock ]]; then
		cowork_backend='KVM (full VM isolation)'
	fi
	_info "Cowork isolation: $cowork_backend"

	# Custom bwrap mount configuration
	_doctor_check_bwrap_mounts

	# -- Orphaned cowork daemon --
	# Uses the same live-UI detection as cleanup_orphaned_cowork_daemon
	# above: a live UI is an Electron main process on app.asar that is
	# not a Chromium helper (--type=...), not the cowork daemon itself,
	# and not stopped/zombie.  Counting any `claude-desktop`-matching
	# process (as the old check did) would include the launcher's own
	# bash and stuck launcher bashes from previous crashes, producing
	# false negatives where a real orphan is misreported as "parent
	# alive".
	local _cowork_pids
	_cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| true
	if [[ -n $_cowork_pids ]]; then
		local _daemon_orphaned=true _pid _cmdline _state
		for _pid in $(pgrep -f 'app\.asar' 2>/dev/null); do
			[[ $_pid == "$$" || $_pid == "$PPID" ]] && continue
			_cmdline=$(tr '\0' ' ' \
				< "/proc/$_pid/cmdline" 2>/dev/null) || continue
			[[ $_cmdline == *cowork-vm-service* ]] && continue
			[[ $_cmdline == *--type=* ]] && continue
			_state=$(awk '/^State:/ {print $2; exit}' \
				"/proc/$_pid/status" 2>/dev/null) || continue
			[[ $_state == T || $_state == t || $_state == Z ]] \
				&& continue
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
