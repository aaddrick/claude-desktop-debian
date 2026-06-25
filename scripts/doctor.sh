# shellcheck shell=bash
#===============================================================================
# Doctor Diagnostics
#
# Sourced by: scripts/launcher-common.sh (which is in turn sourced by the
# per-package launcher scripts — deb, rpm, AppImage, Nix).
#
# Provides: run_doctor (the `claude-desktop-unofficial --doctor` entry
# point) plus its
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

# Locate the virtiofsd binary anywhere a distro puts it. Distros
# install it at different off-PATH locations:
#   - Debian/Ubuntu: /usr/libexec/virtiofsd (qemu-system-common)
#   - Fedora/RHEL:   /usr/libexec/virtiofsd
#   - Older Debian:  /usr/lib/qemu/virtiofsd
#   - Arch/Manjaro:  /usr/lib/virtiofsd
#
# `command -v virtiofsd` alone produces a false negative on any of
# the above. Search PATH first, then the well-known fallback paths.
#
# NOTE: this is deliberately BROADER than the official client's own
# probe, which checks only /usr/libexec and /usr/bin plus its bundled
# copy (see _check_cowork_virtiofsd). A hit here does NOT mean the
# client will find it — _check_cowork_virtiofsd uses this helper only
# to explain a "found somewhere the client won't look" mismatch.
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
#   /usr/lib/claude-desktop-unofficial/claude-desktop)
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

# Report how the Chromium password-store backend is selected.
#
# Since the v3.0.0 rebase the launcher no longer probes for a keyring:
# the official build's os_crypt autodetection owns that decision (and
# deliberately declines weak persistence on some sessions). The only
# knob is CLAUDE_PASSWORD_STORE, the documented escape hatch. There is
# nothing to probe, so this is informational only — no PASS/FAIL.
_doctor_check_password_store() {
	if [[ -n ${CLAUDE_PASSWORD_STORE:-} ]]; then
		_info "Password store: forced to $CLAUDE_PASSWORD_STORE" \
			'(overrides upstream autodetection)'
	else
		_info 'Password store: upstream os_crypt autodetect (default)'
	fi
}

# Return whether a session secret backend usable by Chromium's
# os_crypt (Secret Service or KWallet) is reachable — running or
# D-Bus-activatable. Prints the matched bus name on stdout.
# Exit 0 = reachable, 1 = provably absent, 2 = unprobeable (no
# session bus or no D-Bus tooling). Overridable via
# _DOCTOR_SECRET_BACKEND=present|absent for tests (same
# internal-hook convention as _DOCTOR_KVM_DEV).
_secret_backend_reachable() {
	case "${_DOCTOR_SECRET_BACKEND:-}" in
		present)
			echo 'org.freedesktop.secrets'
			return 0
			;;
		absent)
			return 1
			;;
	esac

	local bus_sock="${XDG_RUNTIME_DIR:-/nonexistent}/bus"
	if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && ! -S $bus_sock ]]; then
		return 2
	fi

	local names=''
	if command -v busctl &>/dev/null; then
		# The default listing includes activatable names, so a
		# keyring daemon that starts on demand still counts.
		names=$(busctl --user --no-pager --no-legend list \
			2>/dev/null)
	elif command -v gdbus &>/dev/null; then
		local method
		for method in ListNames ListActivatableNames; do
			names+=$(gdbus call --session \
				--dest org.freedesktop.DBus \
				--object-path /org/freedesktop/DBus \
				--method "org.freedesktop.DBus.$method" \
				2>/dev/null)
		done
	else
		return 2
	fi
	[[ -n $names ]] || return 2

	local name
	for name in org.freedesktop.secrets \
		org.kde.kwalletd6 org.kde.kwalletd5; do
		if [[ $names == *"$name"* ]]; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

# Advisory follow-on to the password-store report: when no secret
# backend is reachable, the official build's os_crypt autodetect
# falls back to the plaintext 'basic' backend and the login token
# persists unencrypted at rest under ~/.config/Claude. Login still
# works (live-verified on keyring-less wlroots/i3 sessions) — this
# is a data-at-rest advisory, never a FAIL.
_doctor_check_keyring_persistence() {
	local forced="${CLAUDE_PASSWORD_STORE:-}"
	if [[ -n $forced && $forced != 'basic' ]]; then
		# A real backend was forced; nothing to probe.
		return 0
	fi
	if [[ $forced == 'basic' ]]; then
		_warn 'Keyring: CLAUDE_PASSWORD_STORE=basic —' \
			'login token stored unencrypted at rest'
		return 0
	fi

	local backend rc
	backend=$(_secret_backend_reachable)
	rc=$?
	case $rc in
		0)
			_pass "Keyring: $backend reachable for" \
				'credential encryption'
			;;
		1)
			_warn 'Keyring: no Secret Service or KWallet' \
				'on the session bus'
			_info 'Login still works, but the token' \
				"persists via Chromium's plaintext" \
				"'basic' backend"
			_info '(unencrypted at rest under' \
				"${XDG_CONFIG_HOME:-$HOME/.config}/Claude)."
			_info 'Fix: install/enable a keyring' \
				'(gnome-keyring or kwalletd), or ignore' \
				'if acceptable for this machine.'
			;;
		*)
			_info 'Keyring: unable to probe the session bus' \
				'(no busctl/gdbus or no session bus)'
			;;
	esac
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

# Check the Chromium single-instance SingletonLock under the Claude
# config dir. Electron writes it as a 'hostname-PID' symlink; a stale
# one (dead PID) is self-healed — Chromium unlinks the orphan and
# continues. The case that actually blocks startup is a non-symlink
# regular file (possible after an unclean update): ReadLink returns
# empty, the lock parse fails, and the symlink() retry hits EEXIST,
# so the app quits on the next cold launch. That case must not be
# reported as "no lock file", which was a silent false PASS.
#
# Usage: _doctor_check_singleton_lock [config_dir]
_doctor_check_singleton_lock() {
	local config_dir="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/Claude}"
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
	elif [[ -e $lock_file ]]; then
		# WARN, not _fail, for consistency with the stale-symlink
		# precedent above — even though this case provably blocks the
		# next cold launch.
		_warn 'SingletonLock: present but not a symlink (unexpected)'
		_info "Fix: rm '$lock_file'"
	else
		_pass 'SingletonLock: no lock file (OK)'
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
		# Official layout: bare ELF at the package root (no
		# node_modules/electron/dist tree anymore). Prefer our
		# renamed install (claude-desktop-unofficial, Phase 3);
		# fall back to Anthropic's official install path.
		probe_path='/usr/lib/claude-desktop-unofficial/claude-desktop'
		if [[ ! -e $probe_path ]]; then
			probe_path='/usr/lib/claude-desktop/claude-desktop'
		fi
	fi

	# rpm branch: query the file, not the package name, so the answer
	# comes from the database that owns the actual install.
	if command -v rpm &>/dev/null; then
		pkg_version=$(rpm -qf --qf '%{VERSION}-%{RELEASE}' \
			"$probe_path" 2>/dev/null) || pkg_version=''
		if [[ -n $pkg_version ]]; then
			# Record for _check_official_drift (run_doctor scopes the
			# global; see the drift check for how it is consumed).
			_installed_pkg_version="$pkg_version"
			_pass "Installed version: $pkg_version"
			return 0
		fi
	fi

	# dpkg branch: only consulted when rpm does not own the install.
	# Our deb is claude-desktop-unofficial since the Phase 3 rename;
	# plain claude-desktop is Anthropic's official package on dpkg
	# hosts and is not ours to report here.
	if command -v dpkg-query &>/dev/null; then
		pkg_version=$(dpkg-query -W -f='${Version}' \
			claude-desktop-unofficial 2>/dev/null) || pkg_version=''
		if [[ -n $pkg_version ]]; then
			_installed_pkg_version="$pkg_version"
			_pass "Installed version: $pkg_version"
			return 0
		fi
	fi

	# Neither manager knows the install — AppImage or Nix. Only warn
	# when a package tool exists; with none there is nothing to say.
	if command -v rpm &>/dev/null \
		|| command -v dpkg-query &>/dev/null; then
		_warn 'claude-desktop-unofficial not found via dpkg/rpm' \
			'(AppImage?)'
	fi
}

# Best-effort drift check against Anthropic's official APT pool.
#
# doctor.sh is installed WITHOUT official-deb.sh, so the resolver is
# embedded here rather than sourced. It reuses the same RS='' Packages
# stanza parse as resolve_official_deb in scripts/setup/official-deb.sh
# (kept in lock-step by hand). Network-optional: a missing curl, an
# unsupported arch, or an unreachable pool is an _info skip, never a
# failure.
#
# Reads the installed upstream version from the _installed_pkg_version
# global recorded by _doctor_check_pkg_version — the part before the
# first '-', since our packages append '-<wrapper>' to upstream's
# dotted version.
_check_official_drift() {
	if ! command -v curl &>/dev/null; then
		_info 'Version drift: skipped (curl not available)'
		return 0
	fi

	local arch
	case "$(uname -m)" in
		x86_64)  arch='amd64' ;;
		aarch64) arch='arm64' ;;
		*)
			_info 'Version drift: skipped (unsupported architecture)'
			return 0
			;;
	esac

	local base='https://downloads.claude.ai/claude-desktop/apt/stable'
	local index_url="$base/dists/stable/main/binary-${arch}/Packages"

	local newest
	newest=$(curl -fsS --max-time 8 "$index_url" 2>/dev/null | awk -v RS='' '
		/^Package: claude-desktop\n/ || $1 == "Package:" {
			v = ""
			n = split($0, lines, "\n")
			for (i = 1; i <= n; i++) {
				if (lines[i] ~ /^Version: /) v = substr(lines[i], 10)
			}
			if (v != "") print v
		}' | sort -V | tail -1)

	if [[ -z $newest ]]; then
		_info 'Version drift: skipped (offline or pool unreachable)'
		return 0
	fi

	local installed="${_installed_pkg_version:-}"
	installed="${installed%%-*}"

	if [[ -z $installed ]]; then
		_info "Version drift: newest official pool version is $newest" \
			'(installed version unknown — AppImage?)'
		return 0
	fi

	if [[ $installed == "$newest" ]]; then
		_pass "Version: in sync with the official pool ($newest)"
	else
		_warn "Version drift: official pool has $newest," \
			"this install packages $installed"
		_info 'Fix: upgrade via your package manager or download the' \
			'newest release'
	fi
}

# Classify a dpkg package named claude-desktop. Since the Phase 3
# rename our package is claude-desktop-unofficial, so that name now
# identifies either Anthropic's official package (fine — just note the
# shared profile dir) or a leftover pre-rename (< 1.16000) install of
# this project (warn, with the migration hint). deb-family only;
# silent when dpkg-query is absent or nothing detectable is installed.
# The sources.list.d directory is overridable via _DOCTOR_APT_SOURCES_DIR
# so tests can point at a fixture tree.
_check_name_collision() {
	command -v dpkg-query &>/dev/null || return 0

	local sources_list='/etc/apt/sources.list'
	local sources_dir="${_DOCTOR_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
	local pattern='downloads\.claude\.ai/claude-desktop/apt'

	# (a) Is Anthropic's official repo configured in APT's source lists?
	# grep -qs stays quiet on missing/unreadable files.
	local repo_found=false
	if grep -qs "$pattern" "$sources_list" 2>/dev/null; then
		repo_found=true
	elif [[ -d $sources_dir ]]; then
		local f
		for f in "$sources_dir"/*; do
			[[ -f $f ]] || continue
			if grep -qs "$pattern" "$f" 2>/dev/null; then
				repo_found=true
				break
			fi
		done
	fi

	# (b) Is a package named claude-desktop installed, and whose is it?
	local maintainer version
	maintainer=$(dpkg-query -W -f='${Maintainer}' claude-desktop \
		2>/dev/null) || maintainer=''
	version=$(dpkg-query -W -f='${Version}' claude-desktop \
		2>/dev/null) || version=''
	[[ -n $maintainer || -n $version ]] || return 0

	# Anthropic's official package alongside ours: not a conflict —
	# both apps share ~/.config/Claude and its SingletonLock, so only
	# one can run at a time.
	if [[ $maintainer == *Anthropic* ]]; then
		_info "Anthropic's official claude-desktop package is also" \
			'installed. Both apps share ~/.config/Claude and its' \
			'SingletonLock, so only one can run at a time.'
		return 0
	fi

	# Pre-rename install of this project (< 1.16000, before the
	# claude-desktop-unofficial rename) still lingering in dpkg.
	if command -v dpkg &>/dev/null && [[ -n $version ]] \
		&& dpkg --compare-versions "$version" lt 1.16000; then
		_warn "Installed claude-desktop ($version) is this project's" \
			'pre-rename package'
		_info 'Migrate: sudo apt install claude-desktop-unofficial' \
			'(Conflicts/Replaces removes the old package)'
		return 0
	fi

	# Not legacy and not Anthropic by maintainer — but with their apt
	# source configured, an installed claude-desktop is theirs.
	if $repo_found; then
		_info "Anthropic's official claude-desktop package is also" \
			'installed. Both apps share ~/.config/Claude and its' \
			'SingletonLock, so only one can run at a time.'
	fi
}

# Warn about 2.x environment knobs that the v3.0.0 rebase onto the
# official build no longer honors (the patches that read them were
# deleted in Phase 2). Silent when none are set.
_check_legacy_env() {
	local var
	for var in \
		CLAUDE_TITLEBAR_STYLE \
		CLAUDE_MENU_BAR \
		CLAUDE_KEEP_AWAKE
	do
		if [[ -n ${!var:-} ]]; then
			_warn "$var is set but no longer honored since the v3.0.0" \
				'rebase onto the official build'
		fi
	done

	# LD-2: close-to-tray left with frame-fix-wrapper.js, but the
	# official build supersedes it natively — deliberately a no-op, not
	# a regression, so it gets its own pointer instead of the generic
	# warning above.
	if [[ -n ${CLAUDE_QUIT_ON_CLOSE:-} ]]; then
		_warn 'CLAUDE_QUIT_ON_CLOSE is set but no longer honored since' \
			'the v3.0.0 rebase onto the official build'
		_info 'Close behavior is now a native setting: Settings >' \
			'General > System Tray (on = close to tray, off = quit)'
	fi
}

# Cowork isolation on the official client is KVM-only. Report whether
# /dev/kvm is present and read-write. The device path is overridable via
# _DOCTOR_KVM_DEV for tests (same internal-hook convention as
# _COWORK_VFSD_PATHS). Cowork absence is never a failure — the app works
# fine without it.
_check_kvm() {
	local dev="${_DOCTOR_KVM_DEV:-/dev/kvm}"
	if [[ ! -e $dev ]]; then
		_warn 'KVM: /dev/kvm not present — Cowork requires KVM'
		_info 'Enable hardware virtualization (VT-x/AMD-V) in your' \
			'BIOS/UEFI, then: sudo modprobe kvm'
		_cowork_incomplete=true
		return 0
	fi
	if [[ -r $dev && -w $dev ]]; then
		_pass 'KVM: /dev/kvm present and accessible'
	else
		_warn 'KVM: /dev/kvm present but not read-write'
		_info "Fix: sudo usermod -aG kvm $USER"
		_info '(Log out and back in for the group change to take effect)'
		_cowork_incomplete=true
	fi
}

# Cowork's guest<->host control channel rides vhost-vsock. The device
# path is overridable via _DOCTOR_VSOCK_DEV for tests.
_check_vhost_vsock() {
	local dev="${_DOCTOR_VSOCK_DEV:-/dev/vhost-vsock}"
	if [[ -e $dev ]]; then
		_pass 'vsock: /dev/vhost-vsock present'
	else
		_warn 'vsock: /dev/vhost-vsock not found'
		_info 'Fix: sudo modprobe vhost_vsock'
		_info 'Persist across reboots: echo vhost_vsock |' \
			'sudo tee /etc/modules-load.d/vhost_vsock.conf'
		_cowork_incomplete=true
	fi
}

# Check virtiofsd the way the client actually resolves it (#771/#772):
# two hardcoded system paths (read-access, like the client's R_OK
# probe), then the bundled resources/virtiofsd — which our
# virtiofsd-probe asar patch un-gates (upstream limits it to Ubuntu
# 22.x). A binary anywhere else (Arch's /usr/lib/virtiofsd, Debian's
# /usr/lib/qemu/virtiofsd, PATH) is invisible to the client, so it
# must NOT pass — that false PASS is exactly the doctor-vs-app
# disagreement reported in #771.
#
# Client-probed paths are overridable via _COWORK_VFSD_CLIENT_PATHS
# (colon-list) for tests, mirroring _COWORK_VFSD_PATHS.
#
# Usage: _check_cowork_virtiofsd <distro_id> <resources_dir>
_check_cowork_virtiofsd() {
	local distro="$1"
	local resources_dir="$2"

	local client_paths="${_COWORK_VFSD_CLIENT_PATHS:-}"
	if [[ -z $client_paths ]]; then
		client_paths='/usr/libexec/virtiofsd:/usr/bin/virtiofsd'
	fi

	local -a client_list
	IFS=: read -r -a client_list <<< "$client_paths"
	local probed vfsd=''
	for probed in "${client_list[@]}"; do
		if [[ -r $probed ]]; then
			vfsd="$probed"
			break
		fi
	done

	if [[ -n $vfsd ]]; then
		_pass "virtiofsd: $vfsd (client-probed path)"
		return
	fi

	local bundled="${resources_dir:+$resources_dir/virtiofsd}"
	if [[ -n $bundled && -x $bundled ]]; then
		_pass "virtiofsd: bundled copy ($bundled)"
		return
	fi

	# Present somewhere the client won't look?
	local elsewhere
	if elsewhere=$(_find_virtiofsd); then
		_warn "virtiofsd: found at $elsewhere, but the client only" \
			'probes /usr/libexec/virtiofsd and /usr/bin/virtiofsd'
		_info "Fix: sudo ln -s $elsewhere /usr/bin/virtiofsd"
	else
		_warn 'virtiofsd: not found'
		_info "Fix: $(_cowork_pkg_hint "$distro" virtiofsd)"
	fi
	_cowork_incomplete=true
}

# Check the QEMU/KVM userspace stack Cowork drives: the arch-matched
# qemu-system binary on PATH, firmware at the paths the official client
# hardcodes, and virtiofsd at the paths the client probes (see
# _check_cowork_virtiofsd).
#
# Firmware: the official probe list is hardcoded with no env override
# (audit fact — docs/learnings/official-deb-rebase-verification.md).
# Firmware present at a Fedora/Arch edk2 location does NOT count, so we
# check only the official paths and explain the mismatch on a miss. The
# probe list is overridable via _DOCTOR_OVMF_PATHS (colon-list) for
# tests.
#
# Usage: _check_cowork_stack <distro_id> <resources_dir>
_check_cowork_stack() {
	local distro="$1"
	local resources_dir="${2:-}"
	local qemu_bin fw_default
	case "$(uname -m)" in
		aarch64)
			qemu_bin='qemu-system-aarch64'
			fw_default='/usr/share/AAVMF/AAVMF_CODE.fd'
			;;
		*)
			qemu_bin='qemu-system-x86_64'
			fw_default='/usr/share/OVMF/OVMF_CODE_4M.fd'
			fw_default+=':/usr/share/OVMF/OVMF_CODE.fd'
			;;
	esac

	# QEMU binary — the client spawns it by PATH name.
	if command -v "$qemu_bin" &>/dev/null; then
		_pass "QEMU: $qemu_bin found"
	else
		_warn "QEMU: $qemu_bin not found on PATH"
		_info "Fix: $(_cowork_pkg_hint "$distro" qemu)"
		_cowork_incomplete=true
	fi

	# Firmware at the officially probed paths ONLY.
	local fw_paths="${_DOCTOR_OVMF_PATHS:-$fw_default}"
	local -a fw_list
	IFS=: read -r -a fw_list <<< "$fw_paths"
	local fw fw_found=''
	for fw in "${fw_list[@]}"; do
		if [[ -f $fw ]]; then
			fw_found="$fw"
			break
		fi
	done
	if [[ -n $fw_found ]]; then
		_pass "Firmware: $fw_found"
	else
		_warn 'Firmware: none of the official probe paths exist' \
			"($fw_paths)"
		_info 'The official client hardcodes this probe list with no' \
			'env override, so firmware installed elsewhere'
		_info '(Fedora/Arch edk2 layouts) is not found — add a compat' \
			'symlink at the probed path.'
		_cowork_incomplete=true
	fi

	# virtiofsd — client-probed paths + bundled copy only.
	_check_cowork_virtiofsd "$distro" "$resources_dir"
}

# Cowork cloud tasks need a hardware-backed device key so the
# remote-tools bridge can attest this machine; @ant/claude-native has
# no Linux implementation of that key yet (upstream gap, #780), so
# ant-device-registry.json can only ever hold a "none:<ts>" row on
# Linux — never the "pk1:<fp>:<rowpk>" row that marks a registered
# device. This is diagnostic only: it explains why new cloud tasks
# show "Not linked to a computer" and is INFO-only, since it is
# upstream-owned and pre-existing HostLoop/on-device sessions are
# unaffected. It must never _warn/_fail or flip _cowork_incomplete.
#
# The registry path is overridable via _DOCTOR_DEVICE_REGISTRY for
# tests (same internal-hook convention as _DOCTOR_KVM_DEV). A missing
# file means Cowork was never used on this profile, so stay silent.
#
# Usage: _check_device_registry <config_dir>
_check_device_registry() {
	local config_dir="$1"
	local registry
	registry="${_DOCTOR_DEVICE_REGISTRY:-$config_dir/ant-device-registry.json}"

	[[ -f $registry ]] || return 0

	if grep -q '"pk1:' "$registry" 2>/dev/null; then
		_info 'Device registry: registered (hardware-backed key present)'
		return 0
	fi

	if grep -q '"none:' "$registry" 2>/dev/null; then
		_info 'Device registry: not registered — Linux has no' \
			'hardware-backed device key yet (upstream gap, #780)'
		_info '  New Cowork cloud tasks show "Not linked to a' \
			'computer"; pre-existing HostLoop/on-device sessions' \
			'are unaffected.'
	fi
}

# True when the given node binary provides fs.statfsSync — the
# capability the bwrap daemon requires (getSessionsDiskInfo reports real
# session-disk space). It landed in Node 18.15 / 16.19, so probe the
# call directly rather than compare a major: Node 18.0-18.14 has major
# 18 but not the call. Shared by the launcher (setup_cowork_bwrap_env)
# and this doctor check so both agree with the daemon's own startup
# guard (nodeHasRequiredFeatures in cowork-vm-service.js).
cowork_node_has_features() {
	local node_bin="$1"
	[[ -n $node_bin && -x $node_bin ]] || return 1
	"$node_bin" -e \
		'process.exit(typeof require("fs").statfsSync==="function"?0:1)' \
		2>/dev/null
}

# The bwrap fallback daemon needs a system Node runtime and its own
# shipped script: the official Electron binary has the RunAsNode fuse
# off, so it can't run the daemon, and the launcher hands a resolved
# node path to the patched spawn via COWORK_NODE_PATH. Verify both are
# present and the node is new enough. Consistent with the "Cowork
# absence is never a _fail" doctrine, gaps here _warn (and mark the
# section incomplete) rather than flipping the doctor exit code — the
# user opted into an optional feature. Runs only under
# COWORK_VM_BACKEND=bwrap.
#
# Usage: _doctor_check_bwrap_node <resources_dir>
_doctor_check_bwrap_node() {
	local resources_dir="$1"

	local node_bin="${COWORK_NODE_PATH:-}"
	if [[ -z $node_bin ]]; then
		node_bin=$(command -v node 2>/dev/null) \
			|| node_bin=$(command -v nodejs 2>/dev/null) || node_bin=''
	fi
	if [[ -n $node_bin && -x $node_bin ]]; then
		local nv
		nv=$("$node_bin" --version 2>/dev/null) || nv=''
		if cowork_node_has_features "$node_bin"; then
			_pass "bwrap daemon runtime: node $nv ($node_bin)"
		else
			_warn "bwrap daemon runtime: node ${nv:-?} lacks" \
				"fs.statfsSync (needs Node >= 18.15) ($node_bin)"
			_info 'Fix: install a newer Node.js (>= 18.15), or point' \
				'COWORK_NODE_PATH at one'
			_cowork_incomplete=true
		fi
	else
		_warn 'bwrap daemon runtime: no system node/nodejs on PATH'
		_info 'Fix: install Node.js' \
			'(>= 18.15, e.g. sudo apt install nodejs), or set' \
			'COWORK_NODE_PATH to a node binary'
		_cowork_incomplete=true
	fi

	# The daemon ships beside app.asar (process.resourcesPath).
	if [[ -n $resources_dir ]]; then
		if [[ -f "$resources_dir/cowork-vm-service.js" ]]; then
			_pass 'bwrap daemon: cowork-vm-service.js present'
		else
			_warn 'bwrap daemon: cowork-vm-service.js missing from' \
				"$resources_dir"
			_info 'Fix: reinstall the claude-desktop-unofficial package' \
				'(the bwrap patch may not have been active at build time)'
			_cowork_incomplete=true
		fi
	fi
}

# Bwrap sandbox diagnostics for the opt-in COWORK_VM_BACKEND=bwrap path
# (patch_cowork_bwrap). Runs solely when the user sets that flag.
#
# Usage: _doctor_check_bwrap_fallback <distro_id>
_doctor_check_bwrap_fallback() {
	local distro="$1"

	if command -v bwrap &>/dev/null; then
		_pass 'bubblewrap: found'

		# User namespaces must be available for bwrap to create its
		# sandbox; Ubuntu 24.04+ blocks them via AppArmor (issue #351).
		local _err='' _rc=0
		_err=$(bwrap --ro-bind / / true 2>&1 >/dev/null) || _rc=$?
		if ((_rc == 0)); then
			_pass 'bubblewrap: sandbox probe succeeded'
		else
			_warn "bubblewrap: sandbox probe failed (rc=$_rc)"
			[[ -n $_err ]] && _info "  stderr: $_err"
			local _re='(user[[:space:]_-]?namespace|apparmor|[Oo]peration not permitted|CLONE_NEW|CAP_SYS_ADMIN)'
			if [[ $_err =~ $_re ]]; then
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
		_info "Fix: $(_cowork_pkg_hint "$distro" bubblewrap)"
	fi

	_doctor_check_bwrap_mounts
}

# Run all diagnostic checks and print results
# Arguments: $1 = electron path (optional, for package-specific checks)
run_doctor() {
	local electron_path="${1:-}"
	local _doctor_failures=0
	# Recorded by _doctor_check_pkg_version, consumed by
	# _check_official_drift (dynamic scope makes the helper's assignment
	# land on this local).
	local _installed_pkg_version=''
	# Flipped true by any Cowork stack check that isn't green, so the
	# section summary can report readiness without recomputing.
	local _cowork_incomplete=false

	# Doctor must see the same environment a launch would: the per-user
	# config file can carry the launcher vars this run inspects
	# (COWORK_VM_BACKEND=bwrap is the exact #772 persona). Guarded — a
	# standalone `source doctor.sh` (doctor.bats) has no
	# launcher-common.sh in scope. log_message no-ops here because the
	# doctor path never runs setup_logging.
	declare -F load_launcher_config > /dev/null && load_launcher_config
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

	# -- Version drift vs. the official pool (best-effort, network) --
	_check_official_drift

	# -- Package-name collision with Anthropic's APT repo --
	_check_name_collision

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

	# -- Legacy 2.x env knobs (no longer honored post-rebase) --
	_check_legacy_env

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
		_info 'Fix: Reinstall the claude-desktop-unofficial package'
	elif command -v electron &>/dev/null; then
		local ver
		ver=$(_electron_version "$(command -v electron)")
		_pass "Electron: ${ver:+v${ver#v} }(system)"
	else
		_fail 'Electron binary not found'
		_info 'Fix: Reinstall the claude-desktop-unofficial package'
	fi

	# -- Chrome sandbox permissions --
	# Official layout: chrome-sandbox sits at the package root beside the
	# ELF (no node_modules/electron/dist tree anymore).
	local sandbox_paths=(
		'/usr/lib/claude-desktop-unofficial/chrome-sandbox'
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
	local _deb_electron='/usr/lib/claude-desktop-unofficial/claude-desktop'
	if [[ $_userns_val == 1 && -e $_deb_electron ]]; then
		# Profile name must match deb.sh's /etc/apparmor.d/$package_name
		# (PACKAGE_NAME in build.sh — claude-desktop-unofficial since
		# the Phase 3 rename; plain claude-desktop is the official
		# package's profile, registered by Anthropic's own postinst).
		local _aa_profile='/etc/apparmor.d/claude-desktop-unofficial'
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
			if printf '%s\n' "$_loaded_set" \
				| grep -q '^claude-desktop-unofficial '; then
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
	_doctor_check_singleton_lock "$config_dir"

	# -- Password store --
	_doctor_check_password_store
	_doctor_check_keyring_persistence

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
	local desktop_file
	desktop_file='/usr/share/applications/claude-desktop-unofficial.desktop'
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

	# The official Linux client runs Cowork as coworkd + QEMU/KVM; there
	# is no bwrap backend. Report the KVM stack honestly. Cowork absence
	# is never a _fail — the app works fine without it.
	_check_kvm
	_check_vhost_vsock
	# Resources dir sits next to the Electron ELF in the official
	# co-located layout (deb/rpm/AppImage/Nix all preserve it); the
	# bundled virtiofsd lives there.
	local _resources_dir=''
	[[ -n $electron_path ]] &&
		_resources_dir="$(dirname "$electron_path")/resources"
	_check_cowork_stack "$_distro_id" "$_resources_dir"

	# One-line readiness summary (the checks above flip
	# _cowork_incomplete on any non-green result).
	if [[ $_cowork_incomplete == true ]]; then
		_info 'Cowork: unavailable until the KVM stack is complete' \
			'(see above)'
	else
		_info 'Cowork isolation: KVM (official)'
	fi

	# Device registration (upstream gap, #780) — diagnostic only, never
	# feeds _cowork_incomplete.
	_check_device_registry "$config_dir"

	# Bwrap fallback (opt-in, patch_cowork_bwrap). Set
	# COWORK_VM_BACKEND=bwrap to route Cowork through the bundled Node
	# daemon + bubblewrap instead of the KVM microVM — for hosts that
	# can't do KVM/vhost-vsock (ChromeOS Crostini, #772). These
	# diagnostics run only when that flag is set. Any other non-empty
	# value is a 2.x knob the official client ignores.
	local _cvb="${COWORK_VM_BACKEND:-}"
	if [[ -n $_cvb ]]; then
		if [[ ${_cvb,,} == 'bwrap' ]]; then
			echo
			_info 'COWORK_VM_BACKEND=bwrap: Cowork routes through the' \
				'bubblewrap fallback daemon (opt-in).'
			_doctor_check_bwrap_node "$_resources_dir"
			_doctor_check_bwrap_fallback "$_distro_id"
		else
			_info "COWORK_VM_BACKEND=$_cvb: not read by the official" \
				'client (2.x knob)'
		fi
	fi

	# Short NAME_MAX on the host's ~/.claude tree (eCryptfs etc.)
	# blocks cowork session init with ENAMETOOLONG — see #590.
	_doctor_check_filename_limit

	# -- Orphaned cowork-vm-service daemon --
	# cowork-vm-service.js is the bwrap fallback daemon (opt-in
	# COWORK_VM_BACKEND=bwrap, patch_cowork_bwrap); it was also OUR 2.x
	# VM daemon. Either way, a daemon whose parent UI is gone is
	# orphaned — holding a stale socket — so we reap it. When the UI is
	# alive the daemon is healthy (expected on the flagged path). Live-UI
	# detection matches cleanup_orphaned_cowork_daemon:
	# _claude_desktop_ui_is_alive in launcher-common.sh fingerprints the
	# --class=$WM_CLASS flag (since #700 the launchers no longer pass
	# app.asar in argv), excluding Chromium helpers (--type=...), cowork
	# helpers, our own launcher bash, and stopped/zombie processes.
	local _cowork_pids
	_cowork_pids=$(pgrep -f 'cowork-vm-service\.js' 2>/dev/null) || true
	if [[ -n $_cowork_pids ]]; then
		if ! _claude_desktop_ui_is_alive; then
			_warn "Cowork bwrap daemon: orphaned" \
				"(PIDs: $_cowork_pids)"
			_info 'Fix: Restart Claude Desktop' \
				'(daemon will be cleaned up automatically)'
		else
			_pass 'Cowork bwrap daemon: running (parent alive)'
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
