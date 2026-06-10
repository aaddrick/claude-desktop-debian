# shellcheck shell=bash
#===============================================================================
# Doctor Diagnostics
#
# Sourced by: scripts/launcher-common.sh (which is in turn sourced by the
# per-package launcher scripts — deb, rpm, AppImage, Nix).
#
# Provides: run_doctor (the `claude-desktop --doctor` entry point) plus its
# internal helpers. Self-contained except for the WM_CLASS constant defined
# at the top of launcher-common.sh (substituted at build time), which the
# live-UI fingerprint in the orphaned-daemon check reads at runtime.
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
		ibus-gtk3)
			# Arch ships the GTK3 immodule as part of the main ibus
			# package; Debian/Ubuntu and Fedora split it out.
			case "$distro" in
				arch) pkg='ibus' ;;
				*)    pkg='ibus-gtk3' ;;
			esac
			;;
		*) pkg="$tool" ;;
	esac

	printf '%s' "$pkg_cmd $pkg"
}

# Return 0 if the named package is installed, 1 otherwise. Returns 2
# (treated as "unknown") when no recognized package manager is
# available — callers should not warn in that case to avoid false
# positives on unsupported distros.
_pkg_installed() {
	local distro="$1"
	local pkg="$2"
	case "$distro" in
		debian|ubuntu)
			command -v dpkg-query &>/dev/null || return 2
			dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
				| grep -q 'install ok installed'
			;;
		fedora)
			command -v rpm &>/dev/null || return 2
			rpm -q "$pkg" &>/dev/null
			;;
		arch)
			command -v pacman &>/dev/null || return 2
			pacman -Q "$pkg" &>/dev/null
			;;
		*) return 2 ;;
	esac
}

# Diagnose IBus / GTK input-method misconfigurations that break
# keyboard input in the chat (#550). Surfaces:
#   - CLAUDE_GTK_IM_MODULE override visibility (informational)
#   - XWayland-with-IBus routing note: on a Wayland session Electron
#     defaults to XWayland (preserves global hotkeys), which forces
#     the IBus path through XIM — a known weak link for some IMEs.
#   - ibus-gtk3 package missing when GTK_IM_MODULE=ibus
#   - GTK immodules cache stale: active module not listed by
#     gtk-query-immodules-3.0 (--update-cache fixes it)
#
# Usage: _doctor_check_im_modules <distro_id>
_doctor_check_im_modules() {
	local distro="$1"
	local active_im="${CLAUDE_GTK_IM_MODULE:-${GTK_IM_MODULE:-}}"

	if [[ -n ${CLAUDE_GTK_IM_MODULE:-} ]]; then
		_info "CLAUDE_GTK_IM_MODULE=$CLAUDE_GTK_IM_MODULE" \
			"(overrides GTK_IM_MODULE for Electron)"
	fi

	if [[ ${XDG_SESSION_TYPE:-} == 'wayland' \
		&& -z ${CLAUDE_USE_WAYLAND:-} ]]; then
		_info \
			'IME note: Wayland session, Electron via XWayland —' \
			'IBus path goes through XIM (lossy for some IMEs).'
		_info \
			'Tip: CLAUDE_USE_WAYLAND=1 enables native Wayland IME' \
			'(loses global hotkeys).'
	fi

	# Nothing further to check without an active IM module.
	[[ -n $active_im ]] || return 0

	# ibus-gtk3 package check — only when the active module is ibus.
	# rc=1 means definitely missing (warn); rc=2 means unsupported
	# distro / no package manager (skip silently to avoid false
	# negatives). On warn, return early — `apt install` refreshes
	# the immodules cache, so the cache check below would be noise.
	if [[ $active_im == 'ibus' ]]; then
		_pkg_installed "$distro" ibus-gtk3
		case $? in
			1)
				_warn \
					"GTK_IM_MODULE=ibus but ibus-gtk3 is not installed"
				_info "Fix: $(_cowork_pkg_hint "$distro" ibus-gtk3)"
				return 0
				;;
		esac
	fi

	# GTK immodules cache check. gtk-query-immodules-3.0 ships with
	# libgtk-3-bin (Debian/Ubuntu) / gtk3 (Fedora/Arch); absence
	# means GTK 3 isn't in use — skip silently rather than warn.
	command -v gtk-query-immodules-3.0 &>/dev/null || return 0

	if ! gtk-query-immodules-3.0 2>/dev/null \
		| grep -q "\"$active_im\""; then
		_warn \
			"GTK immodules: '$active_im' not listed by" \
			"gtk-query-immodules-3.0 (cache may be stale)"
		_info \
			'Fix: sudo gtk-query-immodules-3.0 --update-cache'
	fi
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

# Warn about an unrecognized COWORK_VM_BACKEND value. The daemon
# (cowork-vm-service.js) ignores invalid values and falls through to
# auto-detect — see #442 for the daemon-side wart. Called from both
# COWORK_VM_BACKEND case statements below so the warning fires once
# at the severity-gating site and once at the user-facing summary.
_warn_unknown_backend() {
	_warn "Unknown COWORK_VM_BACKEND: '${COWORK_VM_BACKEND}'"
	_info 'Valid values: kvm, bwrap, host'
}

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
# Fallback paths are overridable via _COWORK_VFSD_PATHS
# (colon-separated) so tests can point at a stub directory. The
# namespaced prefix signals "internal test hook — not a user knob".
# Shared with the VM daemon (cowork-vm-service.js) so doctor's
# diagnosis and the daemon's actual probe stay in lock-step.
_find_virtiofsd() {
	local bin
	bin=$(command -v virtiofsd 2>/dev/null)
	if [[ -n $bin ]]; then
		printf '%s' "$bin"
		return 0
	fi

	local fallback_paths="${_COWORK_VFSD_PATHS:-}"
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
def fmt(p):
    if isinstance(p, str):
        return p
    if isinstance(p, dict) and isinstance(p.get('src'), str) \
            and isinstance(p.get('dst'), str):
        return p['src'] + ' -> ' + p['dst']
    return None
m = json.loads(sys.argv[1])
for p in m.get('additionalROBinds', []):
    s = fmt(p)
    if s is not None:
        print(s)
print('---')
for p in m.get('additionalBinds', []):
    s = fmt(p)
    if s is not None:
        print(s)
print('---')
for p in m.get('disabledDefaultBinds', []):
    if isinstance(p, str):
        print(p)
PYEOF
)
	else
		parsed_output=$(node - "$mounts_json" 2>/dev/null <<'JSEOF'
function fmt(p) {
    if (typeof p === 'string') return p;
    if (p && typeof p === 'object'
        && typeof p.src === 'string' && typeof p.dst === 'string') {
        return p.src + ' -> ' + p.dst;
    }
    return null;
}
const m = JSON.parse(process.argv[1]);
(m.additionalROBinds || []).forEach(p => {
    const s = fmt(p);
    if (s !== null) console.log(s);
});
console.log('---');
(m.additionalBinds || []).forEach(p => {
    const s = fmt(p);
    if (s !== null) console.log(s);
});
console.log('---');
(m.disabledDefaultBinds || []).forEach(p => {
    if (typeof p === 'string') console.log(p);
});
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

	# Warn when an additional mount's dst lands on a default RO mount.
	# bwrap honors the later mount, so this silently replaces a system
	# path inside the sandbox. Only the {src, dst} form can trigger this
	# (string form mounts src=dst, and additionalBinds requires src under
	# $HOME, which never overlaps the default RO set).
	local shadow_input=''
	[[ -n $ro_binds ]] && shadow_input+="${ro_binds}"$'\n'
	[[ -n $rw_binds ]] && shadow_input+="${rw_binds}"$'\n'
	shadow_input=${shadow_input%$'\n'}
	local shadow_line shadow_dst
	if [[ -n $shadow_input ]]; then
		while IFS= read -r shadow_line; do
			[[ $shadow_line == *' -> '* ]] || continue
			shadow_dst=${shadow_line##* -> }
			# Long alternation pattern (STYLEGUIDE 80-col exception)
			case $shadow_dst in
				/usr|/usr/*|/etc|/etc/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*)
					_warn \
						"Mount dst '${shadow_dst}' shadows a default sandbox mount" \
						'(may break system tools inside the sandbox)'
					;;
			esac
		done <<< "$shadow_input"
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

# Diagnose short-filename-limit filesystems that break cowork session
# initialization. Claude Code creates a per-session directory under
# ~/.claude/projects/ whose name is the sanitized host CWD — for cowork
# sessions that flattens to ~180 chars (the host CWD is the deeply
# nested outputs dir under ~/.config/Claude/local-agent-mode-sessions/
# <accountId>/<orgId>/local_<uuid>/outputs). On filesystems with a
# short NAME_MAX — eCryptfs caps at 143 due to filename-encryption
# overhead — that mkdir fails with ENAMETOOLONG and the session never
# starts. Standard fs (ext4/btrfs/xfs/zfs) cap at 255 and are fine. See
# #590.
_doctor_check_filename_limit() {
	# Walk up from ~/.claude/projects to the first dir that exists so
	# getconf has something to query on a fresh install where the tree
	# hasn't been created yet. $HOME is the floor — stop there rather
	# than crossing into /.
	local probe_dir="$HOME/.claude/projects"
	while [[ ! -d $probe_dir ]]; do
		probe_dir=$(dirname "$probe_dir")
		[[ $probe_dir == "$HOME" || $probe_dir == / ]] && break
	done
	[[ -d $probe_dir ]] || return 0

	local name_max
	name_max=$(getconf NAME_MAX "$probe_dir" 2>/dev/null) || return 0
	[[ $name_max =~ ^[0-9]+$ ]] || return 0
	# Force base 10 so a leading zero can't trip octal arithmetic.
	name_max=$((10#$name_max))

	((name_max >= 200)) && return 0

	_warn "Filename limit: NAME_MAX=$name_max on $probe_dir (< 200)"
	_info \
		'Cowork sessions create project-dir names up to ~180 chars' \
		'under ~/.claude/projects/; short limits cause ENAMETOOLONG'
	_info 'when Claude Code initializes a session inside cowork (#590).'

	local fs_type
	fs_type=$(df --output=fstype "$probe_dir" 2>/dev/null \
		| awk 'NR==2 {print $1}')
	if [[ $fs_type == 'ecryptfs' ]]; then
		_info \
			'Detected eCryptfs (legacy Ubuntu/Mint encrypted home,' \
			'NAME_MAX=143 due to filename-encryption overhead).'
		_info \
			'Workaround: move ~/.config/Claude onto a separate' \
			'LUKS-encrypted ext4 volume (NAME_MAX=255) and symlink it'
		_info \
			'back. See docs/troubleshooting.md "Cowork: ENAMETOOLONG' \
			'on encrypted home (eCryptfs)" for the worked steps.'
	fi
}

# Surface a warning when systemd-coredump shows N+ recent Electron
# crashes. The most common cause on Linux is the GPU process FATAL
# exhaustion tracked in #583 — workaround for affected users is the
# upstream Settings → disable hardware acceleration toggle, or
# CLAUDE_DISABLE_GPU=1 in the environment for headless persistence.
#
# Arguments: $1 = electron path (e.g.,
#   /usr/lib/claude-desktop/node_modules/electron/dist/electron)
#   Used to filter results to claude-desktop's electron when possible;
#   falls back to all-electron crashes when the path doesn't match
#   (e.g., AppImage mount paths are transient).
_doctor_check_recent_crashes() {
	local electron_path="${1:-}"
	command -v coredumpctl &>/dev/null || return 0

	# `coredumpctl list electron` filters by COMM=electron. If the
	# exact electron_path matches any entry's EXE column, prefer that
	# tighter count; otherwise fall back to all-electron entries.
	local listing total_count path_count
	listing=$(coredumpctl list electron \
		--since='7 days ago' --no-pager 2>/dev/null) || return 0
	[[ -n $listing ]] || return 0

	# Drop the header line; count remaining entries.
	# Assumes `coredumpctl list electron`'s COMM=electron filter
	# excludes `-- Reboot --` separator rows from the listing (true
	# on systemd as of writing). The path-matched branch below uses
	# index($0, p) so it's unaffected even if that ever changes;
	# revisit this total-count branch if a future systemd version
	# starts leaking reboot markers into per-COMM listings.
	total_count=$(awk 'NR>1 && NF>0' <<< "$listing" | wc -l)
	((total_count == 0)) && return 0

	if [[ -n $electron_path ]]; then
		path_count=$(awk -v p="$electron_path" \
			'NR>1 && index($0, p)' <<< "$listing" | wc -l)
	else
		path_count=0
	fi

	# Use the path-matched count when available; else the unfiltered
	# count with a footnote so the user knows it may include other
	# Electron apps (Slack, VSCode, etc.).
	local count footnote=''
	if ((path_count > 0)); then
		count=$path_count
	else
		count=$total_count
		footnote=' (some entries may be from other Electron apps)'
	fi

	# Threshold tuned against the #583 repro (~10 crashes over 7 days
	# on the affected laptop); a noisy session typically clears 3 in a
	# week, so 3 is the floor for "worth surfacing the workaround".
	if ((count >= 3)); then
		_warn "Recent Electron crashes: $count in last 7 days$footnote"
		_info \
			'Most common cause: Chromium GPU process FATAL (#583).' \
			'Try one of:'
		_info '  Settings → toggle hardware acceleration off → restart'
		_info '  or set CLAUDE_DISABLE_GPU=1 in the environment'
		_info \
			'Tracking:' \
			'https://github.com/aaddrick/claude-desktop-debian/issues/583'
	elif ((count > 0)); then
		_info "Recent Electron crashes: $count in last 7 days$footnote"
	fi
}

# Report the active Chromium password-store backend.
#
# Calls _detect_password_store() (defined in launcher-common.sh, which
# sources this file) to surface what keyring Electron will use for
# safeStorage / cookie encryption. 'basic' is valid but means tokens
# rely on filesystem permissions alone, so we note it for visibility.
# An empty result means detection itself failed (e.g. a sourcing-order
# regression) and warns rather than emitting a green PASS with a blank
# value.
_doctor_check_password_store() {
	local store
	store=$(_detect_password_store)
	if [[ -z $store ]]; then
		_warn 'Password store: unable to detect backend'
		return
	fi
	_pass "Password store: $store"
	if [[ $store == 'basic' ]]; then
		_info \
			'  → using fixed-key fallback;' \
			'tokens are protected by filesystem permissions only'
	fi
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		_info \
			"  → overridden by CLAUDE_PASSWORD_STORE=${CLAUDE_PASSWORD_STORE}"
	fi
}

# Report free space on the partition holding the Claude config dir.
# Arguments: $1 = config directory to check.
#
# Skips when df is unavailable or yields a non-numeric value, leaving
# an _info line so the summary never claims a pass over an unrun
# check: better a visible skip than a green PASS reporting space we
# could not read.
_doctor_check_disk_space() {
	local config_dir="$1"
	local avail
	avail=$(df -BM --output=avail "$config_dir" 2>/dev/null \
		| tail -1 | tr -d ' M') || true
	if [[ ! $avail =~ ^[0-9]+$ ]]; then
		_info 'Disk space: unable to read (df)'
		return 0
	fi
	# Force base 10: a leading zero ("0099") would otherwise make
	# (( )) parse the value as octal and error out, falling through
	# to the PASS branch.
	avail=$((10#$avail))
	if ((avail < 100)); then
		_fail "Disk space: ${avail}MB free on config partition"
		_info 'Fix: Free up disk space'
	elif ((avail < 500)); then
		_warn "Disk space: ${avail}MB free" \
			"on config partition (low)"
	else
		_pass "Disk space: ${avail}MB free"
	fi
}

# Report the installed claude-desktop version from the package manager
# that actually owns the install (#711). On dual-DB hosts (e.g. a
# Fedora box with dpkg installed for deb work) a stale dpkg record
# must not shadow the live rpm install, so rpm ownership of the real
# Electron binary is probed first: `rpm -qf <path>` succeeds only when
# rpm installed the file, which a stale dpkg record can never claim.
# dpkg is consulted only when rpm does not own the path.
#
# AppImage and Nix installs (no package owns the path) keep the
# existing not-found warn; hosts with no package tools stay silent.
#
# Usage: _doctor_check_pkg_version <electron_path>
_doctor_check_pkg_version() {
	local electron_path="${1:-}"
	local probe_path="$electron_path"
	local pkg_version=''

	if [[ -z $probe_path ]]; then
		probe_path='/usr/lib/claude-desktop'
		probe_path+='/node_modules/electron/dist/electron'
	fi

	# rpm branch: query the file, not the package name, so the answer
	# comes from the database that owns the actual install.
	if command -v rpm &>/dev/null; then
		pkg_version=$(rpm -qf --qf '%{VERSION}-%{RELEASE}' \
			"$probe_path" 2>/dev/null) || pkg_version=''
		if [[ -n $pkg_version ]]; then
			_pass "Installed version: $pkg_version"
			return 0
		fi
	fi

	# dpkg branch: only consulted when rpm does not own the install.
	if command -v dpkg-query &>/dev/null; then
		pkg_version=$(dpkg-query -W -f='${Version}' \
			claude-desktop 2>/dev/null) || pkg_version=''
		if [[ -n $pkg_version ]]; then
			_pass "Installed version: $pkg_version"
			return 0
		fi
	fi

	# Neither manager knows the install — AppImage or Nix. Only warn
	# when a package tool exists; with none there is nothing to say.
	if command -v rpm &>/dev/null \
		|| command -v dpkg-query &>/dev/null; then
		_warn 'claude-desktop not found via dpkg/rpm (AppImage?)'
	fi
}

# Run all diagnostic checks and print results
# Arguments: $1 = electron path (optional, for package-specific checks)
run_doctor() {
	local electron_path="${1:-}"
	local _doctor_failures=0
	_doctor_colors

	# Distro ID is shared between the IM-module check (#550) and the
	# Cowork Mode section further down. Resolve once.
	local _distro_id
	_distro_id=$(_cowork_distro_id)

	echo -e "${_bold}Claude Desktop Diagnostics${_reset}"
	echo '================================'
	echo

	# -- Installed package version --
	_doctor_check_pkg_version "$electron_path"

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

	# -- Input method (IBus / GTK) --
	_doctor_check_im_modules "$_distro_id"

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

	# -- Titlebar style --
	local titlebar_style="${CLAUDE_TITLEBAR_STYLE:-}"
	if [[ -n $titlebar_style ]]; then
		local resolved_style="${titlebar_style,,}"
		case "$resolved_style" in
			hybrid|native)
				_pass "Titlebar style: $resolved_style" \
					"(CLAUDE_TITLEBAR_STYLE=$titlebar_style)"
				;;
			hidden)
				_warn "Titlebar style: hidden — topbar clicks unresponsive on Linux (both X11 and Wayland)"
				_info 'Use hybrid (default) or native for clickable buttons'
				;;
			*)
				_warn "Unknown CLAUDE_TITLEBAR_STYLE: '$titlebar_style'"
				_info 'Will fall back to hybrid'
				_info 'Valid values: hybrid, native, hidden'
				;;
		esac
	else
		_info 'Titlebar style: hybrid (default, native frame + in-app topbar)'
	fi

	# -- Keep awake override --
	local keep_awake="${CLAUDE_KEEP_AWAKE:-}"
	if [[ $keep_awake == '0' ]]; then
		_pass 'Keep awake: suppressed (CLAUDE_KEEP_AWAKE=0)'
	elif [[ -n $keep_awake ]]; then
		_info "Keep awake: CLAUDE_KEEP_AWAKE=$keep_awake (default behavior)"
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

	# -- User-namespace sandbox (Ubuntu 24.04+ AppArmor) --
	# Ubuntu 24.04+ sets apparmor_restrict_unprivileged_userns=1, which
	# blocks the user namespaces Chromium's sandbox needs and crashes the
	# app on launch (credentials.cc FATAL, exit 133). A scoped AppArmor
	# profile permits them for Claude only. Only report when the
	# restriction is actually in force — on other distros the knob is
	# absent and this check stays silent.
	local _userns_path='/proc/sys/kernel/apparmor_restrict_unprivileged_userns'
	local _userns_val=''
	[[ -r $_userns_path ]] && _userns_val=$(<"$_userns_path")
	# Gate on the deb's installed Electron, not $electron_path (the
	# invoking build's binary): the profile pins this exact path, so only
	# a deb install is confined by it. AppImage always runs --no-sandbox
	# and Nix binaries live in the store — neither can hit the crash.
	local _deb_electron='/usr/lib/claude-desktop'
	_deb_electron+='/node_modules/electron/dist/electron'
	if [[ $_userns_val == 1 && -e $_deb_electron ]]; then
		# Profile name must match deb.sh's /etc/apparmor.d/$package_name
		# (PACKAGE_NAME in build.sh).
		local _aa_profile='/etc/apparmor.d/claude-desktop'
		local _aa_loaded='/sys/kernel/security/apparmor/profiles'
		# securityfs marks this file world-readable (0444), but the kernel
		# still denies the actual read without CAP_MAC_ADMIN — so a -r test
		# passes for non-root yet the read returns nothing. Attempt the read
		# and judge by whether we actually got data, not by the mode bits.
		local _loaded_set=''
		_loaded_set=$(cat "$_aa_loaded" 2>/dev/null)
		if [[ -n $_loaded_set ]]; then
			# Authoritative: we actually read the kernel's loaded profile
			# set (needs root), so report the real load state — not
			# mere presence on disk.
			if printf '%s\n' "$_loaded_set" | grep -q '^claude-desktop '; then
				_pass 'User namespaces: restricted, AppArmor profile loaded'
			else
				_warn 'User namespaces: restricted by AppArmor,' \
					'Claude profile not loaded'
				if [[ -e $_aa_profile ]]; then
					_info '  Profile is on disk but not loaded. Load it:'
					_info "  sudo apparmor_parser -r $_aa_profile"
				else
					_info '  No profile found. See docs/troubleshooting.md'
					_info '  "Claude Desktop crashes immediately on launch".'
				fi
			fi
		elif [[ -e $_aa_profile ]]; then
			# The loaded set was unreadable: non-root (the kernel needs
			# CAP_MAC_ADMIN despite the 0444 mode), or securityfs is
			# unmounted (common in containers). Report presence on disk
			# only — never a definitive PASS.
			if (( EUID == 0 )); then
				_info 'User namespaces: AppArmor profile present on disk' \
					'(securityfs unavailable; cannot confirm it is loaded)'
			else
				_info 'User namespaces: AppArmor profile present on disk' \
					'(re-run with sudo to confirm it is loaded)'
			fi
		else
			_warn 'User namespaces: restricted by AppArmor,' \
				'no Claude profile found'
			_info '  Unprivileged user namespaces are blocked, which'
			_info '  crashes the app on launch in X11 sessions'
			_info '  (credentials.cc FATAL). Wayland sessions run with'
			_info '  --no-sandbox and are unaffected.'
			_info '  See docs/troubleshooting.md "Claude Desktop crashes'
			_info '  immediately on launch" for the profile to install.'
		fi
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

	# -- Password store --
	_doctor_check_password_store

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
	_doctor_check_disk_space "$config_dir"

	# -- Cowork Mode --
	echo
	echo -e "${_bold}Cowork Mode${_reset}"
	echo '----------------'

	# Determine whether bwrap is the active backend (for severity
	# of bwrap-related diagnostics). Auto-detect prefers bwrap, so
	# bwrap is active unless the user has overridden to KVM or host.
	local _bwrap_active=true
	case "${COWORK_VM_BACKEND,,}" in
		kvm|host) _bwrap_active=false ;;
		''|bwrap) ;;
		*)
			# Unknown values: warn but leave _bwrap_active=true.
			# The daemon falls through to auto-detect, which
			# prefers bwrap — keep severity semantics aligned
			# with that runtime behavior. See #442.
			_warn_unknown_backend
			;;
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
					'  by default. See docs/troubleshooting.md' \
					'"Cowork on Ubuntu 24.04" for the AppArmor profile fix.'
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
			*)
				_warn_unknown_backend
				cowork_backend="auto-detect (invalid override '${COWORK_VM_BACKEND}' — see warning above)"
				;;
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

	# Short NAME_MAX on the host's ~/.claude tree (eCryptfs etc.)
	# blocks cowork session init with ENAMETOOLONG — see #590.
	_doctor_check_filename_limit

	# -- Orphaned cowork daemon --
	# Uses the same live-UI detection as cleanup_orphaned_cowork_daemon:
	# _claude_desktop_ui_is_alive in launcher-common.sh fingerprints on
	# the --class=$WM_CLASS flag from build_electron_args (since #700
	# the launchers no longer pass app.asar in argv — Electron
	# auto-loads it), excluding Chromium helpers (--type=...), the
	# cowork daemon itself, our own launcher bash, and stopped/zombie
	# processes.  Counting any `claude-desktop`-matching process (as
	# the old check did) would include the launcher's own bash and
	# stuck launcher bashes from previous crashes, producing false
	# negatives where a real orphan is misreported as "parent alive".
	local _cowork_pids
	_cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) \
		|| true
	if [[ -n $_cowork_pids ]]; then
		if ! _claude_desktop_ui_is_alive; then
			_warn "Cowork daemon: orphaned (PIDs: $_cowork_pids)"
			_info 'Fix: Restart Claude Desktop' \
				'(daemon will be cleaned up automatically)'
		else
			_pass 'Cowork daemon: running (parent alive)'
		fi
	fi

	# -- Recent crashes --
	# Surfaces the GPU process FATAL pattern (#583) before users
	# notice the in-app "Claude crashed repeatedly" prompt.
	_doctor_check_recent_crashes "$electron_path"

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
