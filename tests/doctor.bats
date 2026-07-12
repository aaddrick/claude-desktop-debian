#!/usr/bin/env bats
#
# doctor.bats
# Tests for diagnostic helpers in scripts/doctor.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

	# Clear all input/display vars to avoid host-state leakage
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset XDG_SESSION_TYPE
	unset CLAUDE_USE_WAYLAND
	unset GTK_IM_MODULE
	unset CLAUDE_GTK_IM_MODULE
	unset CLAUDE_PASSWORD_STORE
	unset _DOCTOR_SECRET_BACKEND

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"

	_doctor_colors
	_doctor_failures=0

	# Default _pkg_installed to "unknown" (rc=2) so tests don't have
	# to stub it unless they're exercising the package-check branch.
	# Override in-test for rc=0 (installed) or rc=1 (missing).
	_pkg_installed() { return 2; }
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Make `command -v gtk-query-immodules-3.0` report "not found" so the
# immodules cache check is skipped. Used by tests that aren't
# exercising the cache branch but reach it because no earlier gate
# fires. `command -v` finds bash functions too, so just unsetting a
# stub function isn't enough — we shadow `command` itself.
_skip_gtk_query() {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
}

# =============================================================================
# _cowork_pkg_hint: ibus-gtk3 mapping (#550)
# =============================================================================

@test "_cowork_pkg_hint: debian maps ibus-gtk3 to ibus-gtk3 via apt" {
	local result
	result=$(_cowork_pkg_hint debian ibus-gtk3)
	[[ $result == "sudo apt install ibus-gtk3" ]]
}

@test "_cowork_pkg_hint: fedora maps ibus-gtk3 to ibus-gtk3 via dnf" {
	local result
	result=$(_cowork_pkg_hint fedora ibus-gtk3)
	[[ $result == "sudo dnf install ibus-gtk3" ]]
}

@test "_cowork_pkg_hint: arch maps ibus-gtk3 to ibus (bundled)" {
	local result
	result=$(_cowork_pkg_hint arch ibus-gtk3)
	[[ $result == "sudo pacman -S ibus" ]]
}

# =============================================================================
# _doctor_check_im_modules: CLAUDE_GTK_IM_MODULE override visibility
# =============================================================================

@test "_doctor_check_im_modules: emits override line when CLAUDE_GTK_IM_MODULE set" {
	# CLAUDE_GTK_IM_MODULE makes active_im non-empty, so we'd reach
	# the cache check — skip it to keep this test focused.
	_skip_gtk_query

	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output == *'CLAUDE_GTK_IM_MODULE=xim'* ]]
	[[ $output == *'overrides GTK_IM_MODULE for Electron'* ]]
}

@test "_doctor_check_im_modules: no override line when CLAUDE_GTK_IM_MODULE unset" {
	run _doctor_check_im_modules debian
	[[ $output != *'CLAUDE_GTK_IM_MODULE'* ]]
}

# =============================================================================
# _doctor_check_im_modules: XWayland-with-IBus routing note
# =============================================================================

@test "_doctor_check_im_modules: emits XWayland note when wayland session and CLAUDE_USE_WAYLAND unset" {
	XDG_SESSION_TYPE='wayland'
	# CLAUDE_USE_WAYLAND deliberately unset
	run _doctor_check_im_modules debian
	[[ $output == *'XWayland'* ]]
	[[ $output == *'CLAUDE_USE_WAYLAND=1'* ]]
}

@test "_doctor_check_im_modules: no XWayland note when CLAUDE_USE_WAYLAND=1" {
	XDG_SESSION_TYPE='wayland'
	CLAUDE_USE_WAYLAND='1'
	run _doctor_check_im_modules debian
	[[ $output != *'XWayland'* ]]
}

@test "_doctor_check_im_modules: no XWayland note on X11 session" {
	XDG_SESSION_TYPE='x11'
	run _doctor_check_im_modules debian
	[[ $output != *'XWayland'* ]]
}

# =============================================================================
# _doctor_check_im_modules: ibus-gtk3 package check
# =============================================================================

@test "_doctor_check_im_modules: warns when ibus selected but ibus-gtk3 missing" {
	# Package not installed (rc=1, definitive answer)
	_pkg_installed() { return 1; }

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules debian
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'ibus-gtk3 is not installed'* ]]
	[[ $output == *'sudo apt install ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no warning when ibus selected and ibus-gtk3 present" {
	# Package installed (rc=0); cache lists ibus.
	_pkg_installed() { return 0; }
	gtk-query-immodules-3.0() {
		echo '"ibus" "IBus" "ibus" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no package warning when active module isn't ibus" {
	# Even with rc=1 for ibus-gtk3, the package check should be
	# skipped entirely when GTK_IM_MODULE isn't ibus.
	_pkg_installed() { return 1; }
	_skip_gtk_query

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no package warning on unsupported distro (rc=2)" {
	# Default _pkg_installed (rc=2) — no warning even with ibus.
	_skip_gtk_query

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules unknown
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _doctor_check_im_modules: immodules cache check
# =============================================================================

@test "_doctor_check_im_modules: warns when GTK_IM_MODULE not in immodules cache" {
	# gtk-query-immodules-3.0 lists xim but not fcitx
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules debian
	[[ $output == *'[WARN]'* ]]
	[[ $output == *"'fcitx' not listed"* ]]
	[[ $output == *'gtk-query-immodules-3.0 --update-cache'* ]]
}

@test "_doctor_check_im_modules: no warning when active module is in cache" {
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: skips cache check when gtk-query-immodules-3.0 missing" {
	_skip_gtk_query

	GTK_IM_MODULE='fcitx'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'cache may be stale'* ]]
}

@test "_doctor_check_im_modules: CLAUDE_GTK_IM_MODULE takes precedence as active module" {
	# Cache lists xim but not ibus. CLAUDE_GTK_IM_MODULE=xim should
	# win over GTK_IM_MODULE=ibus, so no cache warning fires.
	gtk-query-immodules-3.0() {
		echo '"xim" "X Input Method" "gtk30" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0

	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no checks fire when no IM module selected" {
	# Neither GTK_IM_MODULE nor CLAUDE_GTK_IM_MODULE set — function
	# should return early before the package or cache checks.
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'ibus-gtk3'* ]]
}

# =============================================================================
# _doctor_check_recent_crashes: GPU FATAL crash counter (#583)
# =============================================================================

# Install a coredumpctl shim. $1 is the coredumpctl-list-style
# multi-line output to emit (header + entry rows). The shim ignores
# its arguments — tests don't exercise the filter syntax.
_install_coredumpctl_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/coredumpctl" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
$1
OUT
SHIM
	chmod +x "$TEST_TMP/bin/coredumpctl"
	export PATH="$TEST_TMP/bin:$PATH"
}

@test "_doctor_check_recent_crashes: no coredumpctl on PATH — silent" {
	# Force coredumpctl off PATH so the helper short-circuits.
	# Restore PATH before returning so teardown's rm works.
	local saved_path="$PATH"
	export PATH="/no-such-dir-for-test"
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	export PATH="$saved_path"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: zero crashes — silent" {
	# Listing has the header line only, no entry rows.
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: 1 crash — info line, no warn" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop-unofficial/claude-desktop 21.6M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_recent_crashes: 3+ crashes — warn + #583 pointer" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop-unofficial/claude-desktop 21.6M
Mon 2026-05-04 07:44:48 EDT 930532 1000 1000 SIGTRAP present /usr/lib/claude-desktop-unofficial/claude-desktop 22.8M
Sun 2026-05-03 14:34:10 EDT 567221 1000 1000 SIGTRAP present /usr/lib/claude-desktop-unofficial/claude-desktop 12.4M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'Recent Electron crashes: 3'* ]]
	[[ $output == *'CLAUDE_DISABLE_GPU=1'* ]]
	[[ $output == *'/issues/583'* ]]
}

@test "_doctor_check_recent_crashes: path mismatch falls back with footnote" {
	# Three crashes from a DIFFERENT electron binary (e.g., Slack).
	# Caller passes claude-desktop's electron path, which doesn't
	# match — helper falls back to total count and adds the footnote
	# so the user knows the count may be cross-app.
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 09:00:00 EDT 200001 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-05 09:00:00 EDT 200002 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M
Wed 2026-05-04 09:00:00 EDT 200003 1000 1000 SIGSEGV present /usr/lib/slack/electron 30M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

@test "_doctor_check_recent_crashes: empty electron_path falls back" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop-unofficial/claude-desktop 21.6M'
	# Caller didn't pass an electron_path — helper still counts and
	# emits the info line based on the unfiltered total.
	run _doctor_check_recent_crashes ''
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

# =============================================================================
# _doctor_check_filename_limit: NAME_MAX probe + eCryptfs hint (#590)
# =============================================================================

# Install a getconf shim that emits $1 on stdout. Empty $1 → shim exits 1
# so callers can test the "getconf failed" path.
_install_getconf_shim() {
	mkdir -p "$TEST_TMP/bin"
	local value="$1"
	if [[ -z $value ]]; then
		cat > "$TEST_TMP/bin/getconf" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/getconf" <<SHIM
#!/usr/bin/env bash
echo ${value}
SHIM
	fi
	chmod +x "$TEST_TMP/bin/getconf"
	export PATH="$TEST_TMP/bin:$PATH"
}

# Install a df shim that emits a single-column fstype listing matching
# the `df --output=fstype` shape the helper relies on. Empty $1 → shim
# exits 1 so callers can test the "df failed" path.
_install_df_shim() {
	mkdir -p "$TEST_TMP/bin"
	local fstype="$1"
	if [[ -z $fstype ]]; then
		cat > "$TEST_TMP/bin/df" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
	else
		cat > "$TEST_TMP/bin/df" <<SHIM
#!/usr/bin/env bash
cat <<'OUT'
Type
${fstype}
OUT
SHIM
	fi
	chmod +x "$TEST_TMP/bin/df"
	export PATH="$TEST_TMP/bin:$PATH"
}

@test "_doctor_check_filename_limit: silent when NAME_MAX >= 200" {
	_install_getconf_shim '255'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: warns when NAME_MAX < 200" {
	_install_getconf_shim '143'
	_install_df_shim 'ext4'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'#590'* ]]
	# Non-ecryptfs fs: no LUKS hint
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: eCryptfs adds LUKS workaround hint" {
	_install_getconf_shim '143'
	_install_df_shim 'ecryptfs'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output == *'eCryptfs'* ]]
	[[ $output == *'LUKS'* ]]
}

@test "_doctor_check_filename_limit: silent on non-numeric getconf output" {
	_install_getconf_shim 'undefined'
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: silent when getconf fails" {
	_install_getconf_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_filename_limit: df failure suppresses eCryptfs hint, keeps warn" {
	_install_getconf_shim '143'
	_install_df_shim ''
	run _doctor_check_filename_limit
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'NAME_MAX=143'* ]]
	[[ $output != *'eCryptfs'* ]]
	[[ $output != *'LUKS'* ]]
}

# =============================================================================
# _doctor_check_password_store
#
# Since the v3.0.0 rebase the launcher no longer probes a keyring: the
# official build's os_crypt autodetect owns the decision, and
# CLAUDE_PASSWORD_STORE is the only knob. This is informational only —
# no PASS/FAIL.
# =============================================================================

@test "_doctor_check_password_store: unset reports upstream autodetect (no PASS/FAIL)" {
	# CLAUDE_PASSWORD_STORE unset by setup().
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'os_crypt autodetect'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_password_store: set reports the forced override (no PASS/FAIL)" {
	CLAUDE_PASSWORD_STORE='gnome-libsecret'
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'forced to gnome-libsecret'* ]]
	[[ $output == *'overrides upstream autodetection'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _doctor_check_keyring_persistence (LD-3)
#
# Advisory data-at-rest warning for keyring-less sessions: without a
# reachable Secret Service / KWallet, os_crypt falls back to the
# plaintext 'basic' backend. Never a FAIL. Probe outcome forced via
# _DOCTOR_SECRET_BACKEND (present|absent).
# =============================================================================

@test "_doctor_check_keyring_persistence: reachable backend passes" {
	export _DOCTOR_SECRET_BACKEND='present'
	run _doctor_check_keyring_persistence
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'org.freedesktop.secrets'* ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'[FAIL]'* ]]
}

@test "_doctor_check_keyring_persistence: absent backend warns unencrypted-at-rest (advisory)" {
	export _DOCTOR_SECRET_BACKEND='absent'
	run _doctor_check_keyring_persistence
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'no Secret Service or KWallet'* ]]
	[[ $output == *'basic'* ]]
	[[ $output == *'unencrypted at rest'* ]]
	[[ $output != *'[FAIL]'* ]]
}

@test "_doctor_check_keyring_persistence: forced real backend skips the probe silently" {
	CLAUDE_PASSWORD_STORE='gnome-libsecret'
	export _DOCTOR_SECRET_BACKEND='absent'
	run _doctor_check_keyring_persistence
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_keyring_persistence: forced basic warns even with a backend present" {
	CLAUDE_PASSWORD_STORE='basic'
	export _DOCTOR_SECRET_BACKEND='present'
	run _doctor_check_keyring_persistence
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'CLAUDE_PASSWORD_STORE=basic'* ]]
	[[ $output == *'unencrypted at rest'* ]]
}

@test "_doctor_check_keyring_persistence: no session bus reports unable-to-probe info only" {
	# No hook: force the real probe down the rc=2 path by removing
	# every bus signal — no DBUS address, no $XDG_RUNTIME_DIR/bus
	# socket.
	unset DBUS_SESSION_BUS_ADDRESS
	export XDG_RUNTIME_DIR="$TEST_TMP/empty-runtime"
	mkdir -p "$XDG_RUNTIME_DIR"
	run _doctor_check_keyring_persistence
	[[ $status -eq 0 ]]
	[[ $output == *'unable to probe the session bus'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'[FAIL]'* ]]
}

@test "_secret_backend_reachable: kwallet name in the bus listing counts as reachable" {
	# Real probe path with a stubbed busctl: a KDE session where
	# only kwalletd6 (not Secret Service) is on the bus.
	export DBUS_SESSION_BUS_ADDRESS='unix:path=/dev/null'
	busctl() { printf 'org.kde.kwalletd6 123 - - - - -\n'; }
	run _secret_backend_reachable
	[[ $status -eq 0 ]]
	[[ $output == 'org.kde.kwalletd6' ]]
}

# =============================================================================
# _doctor_check_disk_space
# =============================================================================

@test "_doctor_check_disk_space: fails when under 100MB free" {
	df() { printf 'Avail\n50M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[FAIL]'* ]]
	[[ $output == *'50MB free'* ]]
}

@test "_doctor_check_disk_space: warns when under 500MB free" {
	df() { printf 'Avail\n300M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'300MB free'* ]]
}

@test "_doctor_check_disk_space: warns at exactly 100MB (tier boundary)" {
	# 100 is not < 100, so the FAIL tier must not fire; < 500 → WARN.
	df() { printf 'Avail\n100M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[WARN]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output == *'100MB free'* ]]
}

@test "_doctor_check_disk_space: passes at exactly 500MB (tier boundary)" {
	# 500 is not < 500, so the WARN tier must not fire → PASS.
	df() { printf 'Avail\n500M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[PASS]'* ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output == *'500MB free'* ]]
}

@test "_doctor_check_disk_space: no false PASS on leading-zero df output" {
	# '0099' clears the numeric regex but would make (( )) parse the
	# value as octal and error out, falling through to the PASS
	# branch. The 10# normalization must read it as 99 → FAIL tier.
	df() { printf 'Avail\n0099M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[FAIL]'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output == *'99MB free'* ]]
}

@test "_doctor_check_disk_space: passes with ample free space" {
	df() { printf 'Avail\n2048M\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'2048MB free'* ]]
}

@test "_doctor_check_disk_space: no false PASS on non-numeric df output" {
	# A malformed/empty avail field must not slip through as a PASS,
	# and the skip must be visible rather than hiding behind a clean
	# summary.
	df() { printf 'Avail\nN/A\n'; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $status -eq 0 ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output == *'Disk space: unable to read (df)'* ]]
}

@test "_doctor_check_disk_space: visible skip when df is unavailable" {
	df() { return 127; }
	run _doctor_check_disk_space "$XDG_CONFIG_HOME"
	[[ $status -eq 0 ]]
	[[ $output == *'Disk space: unable to read (df)'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _doctor_check_pkg_version: package-manager ownership (#711)
# =============================================================================

# Make `command -v` report the named package tools (rpm, dpkg-query)
# as missing so tests can simulate single-manager or tool-less hosts
# regardless of what the CI/dev box really has installed. Same shadow
# trick as _skip_gtk_query: `command -v` finds functions too, so
# shadowing `command` itself is the only reliable way.
_hide_pkg_tools() {
	_hidden_pkg_tools=" $* "
	command() {
		if [[ $1 == '-v' \
			&& $_hidden_pkg_tools == *" $2 "* ]]; then
			return 1
		fi
		builtin command "$@"
	}
}

@test "_doctor_check_pkg_version: rpm owns the path — rpm version wins over stale dpkg record (#711)" {
	# The #711 repro: Fedora host, rpm owns the install, but a stale
	# dpkg record from an old deb experiment still answers. The rpm
	# answer must win; the stale dpkg version must not appear at all.
	rpm() { printf '1.11847.5-2.0.19'; }
	dpkg-query() { printf '1.5354.0'; }

	run _doctor_check_pkg_version \
		'/usr/lib/claude-desktop-unofficial/claude-desktop'
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Installed version: 1.11847.5-2.0.19'* ]]
	[[ $output != *'1.5354.0'* ]]
}

@test "_doctor_check_pkg_version: dpkg-only host reports dpkg version" {
	_hide_pkg_tools rpm
	# -f='${db:Status-Status} ${Version}': status prefix first.
	dpkg-query() { printf 'installed 1.11847.5'; }

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Installed version: 1.11847.5'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_pkg_version: dual-DB host where rpm does not own the path falls back to dpkg" {
	# rpm exists but the install is a real deb: `rpm -qf` says "not
	# owned" (rc=1, message on stdout) and dpkg must be consulted.
	rpm() {
		# $4 = probe path ($1=-qf $2=--qf $3=<format>)
		printf 'file %s is not owned by any package\n' "$4"
		return 1
	}
	dpkg-query() { printf 'installed 1.11847.5'; }

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Installed version: 1.11847.5'* ]]
	[[ $output != *'not owned'* ]]
}

@test "_doctor_check_pkg_version: removed-but-not-purged dpkg record (rc state) warns, not PASS (#711 follow-up)" {
	# apt remove without --purge leaves a config-files (rc) record;
	# dpkg-query still answers a version for it. Must not PASS.
	_hide_pkg_tools rpm
	dpkg-query() { printf 'config-files 1.5354.0'; }

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'AppImage'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'1.5354.0'* ]]
}

@test "_doctor_check_pkg_version: neither manager owns the install — warn (AppImage/Nix)" {
	rpm() { return 1; }
	dpkg-query() { return 1; }

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'AppImage'* ]]
	[[ $output != *'[PASS]'* ]]
}

@test "_doctor_check_pkg_version: silent when no package tools exist" {
	_hide_pkg_tools rpm dpkg-query

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

# =============================================================================
# _check_legacy_env: 2.x knobs no longer honored (post-rebase)
# =============================================================================

@test "_check_legacy_env: silent when no legacy knobs are set" {
	unset CLAUDE_TITLEBAR_STYLE CLAUDE_MENU_BAR CLAUDE_KEEP_AWAKE \
		CLAUDE_QUIT_ON_CLOSE
	run _check_legacy_env
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_check_legacy_env: warns for each set legacy knob" {
	unset CLAUDE_MENU_BAR CLAUDE_KEEP_AWAKE CLAUDE_QUIT_ON_CLOSE
	CLAUDE_TITLEBAR_STYLE='hybrid'
	run _check_legacy_env
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'CLAUDE_TITLEBAR_STYLE'* ]]
	[[ $output == *'no longer honored'* ]]
	[[ $output != *'CLAUDE_MENU_BAR'* ]]
}

@test "_check_legacy_env: CLAUDE_QUIT_ON_CLOSE points at the tray toggle" {
	unset CLAUDE_TITLEBAR_STYLE CLAUDE_MENU_BAR CLAUDE_KEEP_AWAKE
	CLAUDE_QUIT_ON_CLOSE='1'
	run _check_legacy_env
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'CLAUDE_QUIT_ON_CLOSE'* ]]
	[[ $output == *'System Tray'* ]]
}

# =============================================================================
# _check_kvm: /dev/kvm presence + access (device path via _DOCTOR_KVM_DEV)
# =============================================================================

@test "_check_kvm: missing device warns that Cowork requires KVM" {
	export _DOCTOR_KVM_DEV="$TEST_TMP/no-such-kvm"
	run _check_kvm
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'Cowork requires KVM'* ]]
}

@test "_check_kvm: present and read-write passes" {
	export _DOCTOR_KVM_DEV="$TEST_TMP/kvm-rw"
	: > "$_DOCTOR_KVM_DEV"
	run _check_kvm
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'present and accessible'* ]]
}

@test "_check_kvm: present but not read-write warns with group hint" {
	# -r/-w are actual-access checks; root bypasses mode bits, so this
	# scenario is only meaningful for a non-root tester.
	[[ $EUID -eq 0 ]] && skip 'permission bits not enforced for root'
	export _DOCTOR_KVM_DEV="$TEST_TMP/kvm-ro"
	: > "$_DOCTOR_KVM_DEV"
	chmod 0000 "$_DOCTOR_KVM_DEV"
	run _check_kvm
	chmod 0644 "$_DOCTOR_KVM_DEV"
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'not read-write'* ]]
	[[ $output == *'usermod -aG kvm'* ]]
}

# =============================================================================
# _check_vhost_vsock: /dev/vhost-vsock (device path via _DOCTOR_VSOCK_DEV)
# =============================================================================

@test "_check_vhost_vsock: present passes" {
	export _DOCTOR_VSOCK_DEV="$TEST_TMP/vsock"
	: > "$_DOCTOR_VSOCK_DEV"
	run _check_vhost_vsock
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
}

@test "_check_vhost_vsock: absent warns with modprobe fix" {
	export _DOCTOR_VSOCK_DEV="$TEST_TMP/no-vsock"
	run _check_vhost_vsock
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'modprobe vhost_vsock'* ]]
	[[ $output == *'modules-load.d'* ]]
}

# =============================================================================
# _check_cowork_stack: firmware probe (paths via _DOCTOR_OVMF_PATHS)
# =============================================================================

@test "_check_cowork_stack: firmware found at an official probe path passes" {
	export _DOCTOR_OVMF_PATHS="$TEST_TMP/OVMF_CODE.fd"
	: > "$_DOCTOR_OVMF_PATHS"
	run _check_cowork_stack debian
	[[ $status -eq 0 ]]
	[[ $output == *"Firmware: $_DOCTOR_OVMF_PATHS"* ]]
	[[ $output != *'none of the official probe paths'* ]]
}

@test "_check_cowork_stack: firmware absent from probe list warns (distro-layout note)" {
	# A firmware file that exists elsewhere must NOT count — only the
	# official probe paths do. Point the probe list at a nonexistent path.
	export _DOCTOR_OVMF_PATHS="$TEST_TMP/nope/OVMF_CODE.fd"
	run _check_cowork_stack debian
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'none of the official probe paths'* ]]
	[[ $output == *'edk2 layouts'* ]]
}

# =============================================================================
# _check_device_registry: ant-device-registry.json state (#780, path via
# _DOCTOR_DEVICE_REGISTRY). Diagnostic-only — INFO or silent, never
# WARN/FAIL, and must never flip _cowork_incomplete.
# =============================================================================

@test "_check_device_registry: absent file emits nothing" {
	export _DOCTOR_DEVICE_REGISTRY="$TEST_TMP/no-registry.json"
	run _check_device_registry "$TEST_TMP/config"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_check_device_registry: none-only value reports the Linux upstream gap as INFO" {
	export _DOCTOR_DEVICE_REGISTRY="$TEST_TMP/registry.json"
	echo '{"acct":"none:123"}' > "$_DOCTOR_DEVICE_REGISTRY"
	run _check_device_registry "$TEST_TMP/config"
	[[ $status -eq 0 ]]
	[[ $output == *'not registered'* ]]
	[[ $output == *'#780'* ]]
	[[ $output != *'[FAIL]'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_check_device_registry: pk1 value reports registered" {
	export _DOCTOR_DEVICE_REGISTRY="$TEST_TMP/registry.json"
	echo '{"acct":"pk1:deadbeef:rowpk"}' > "$_DOCTOR_DEVICE_REGISTRY"
	run _check_device_registry "$TEST_TMP/config"
	[[ $status -eq 0 ]]
	[[ $output == *'registered'* ]]
}

@test "_check_device_registry: never flips _cowork_incomplete" {
	# Call the helper directly (not via `run`) — `run` executes in a
	# subshell, so a flag mutation there is invisible to the test shell.
	export _DOCTOR_DEVICE_REGISTRY="$TEST_TMP/registry.json"
	echo '{"acct":"none:123"}' > "$_DOCTOR_DEVICE_REGISTRY"
	_cowork_incomplete=false
	_check_device_registry "$TEST_TMP/config" > "$TEST_TMP/out"
	[[ $_cowork_incomplete == false ]]
}

@test "_check_device_registry: mixed pk1+none prefers registered" {
	export _DOCTOR_DEVICE_REGISTRY="$TEST_TMP/registry.json"
	echo '{"acct1":"none:123","acct2":"pk1:deadbeef:rowpk"}' \
		> "$_DOCTOR_DEVICE_REGISTRY"
	run _check_device_registry "$TEST_TMP/config"
	[[ $status -eq 0 ]]
	[[ $output == *'registered'* ]]
	[[ $output != *'not registered'* ]]
}

# =============================================================================
# _check_official_drift: pool version comparison (curl stubbed)
# =============================================================================

# A curl stub emitting a one-stanza Packages index for a given pool
# version. The version is stashed in a global the stub reads at call
# time (avoids eval); args are ignored — tests don't exercise the URL.
_stub_curl_packages() {
	_STUB_PKG_VERSION="$1"
	curl() {
		cat <<PKGS
Package: claude-desktop
Version: $_STUB_PKG_VERSION
Filename: pool/main/c/claude-desktop/claude-desktop_${_STUB_PKG_VERSION}_amd64.deb
SHA256: deadbeefdeadbeef
Size: 123456
PKGS
	}
}

@test "_check_official_drift: skipped when curl is unavailable" {
	command() {
		if [[ $1 == '-v' && $2 == 'curl' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	run _check_official_drift
	[[ $status -eq 0 ]]
	[[ $output == *'skipped'* ]]
	[[ $output == *'curl not available'* ]]
}

@test "_check_official_drift: offline (curl fails) is a skip, not a failure" {
	curl() { return 1; }
	_installed_pkg_version='1.17377.2-3.0.0'
	run _check_official_drift
	[[ $status -eq 0 ]]
	[[ $output == *'skipped'* ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'[PASS]'* ]]
}

@test "_check_official_drift: installed matches pool — PASS in sync" {
	_stub_curl_packages '1.17377.9'
	_installed_pkg_version='1.17377.9-3.0.0'
	run _check_official_drift
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'in sync'* ]]
	[[ $output == *'1.17377.9'* ]]
}

@test "_check_official_drift: installed behind pool — WARN with both versions" {
	_stub_curl_packages '1.17377.9'
	_installed_pkg_version='1.17000.0-3.0.0'
	run _check_official_drift
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'official pool has 1.17377.9'* ]]
	[[ $output == *'this install packages 1.17000.0'* ]]
}

@test "_check_official_drift: unknown installed version reports newest only" {
	_stub_curl_packages '1.17377.9'
	_installed_pkg_version=''
	run _check_official_drift
	[[ $status -eq 0 ]]
	[[ $output == *'1.17377.9'* ]]
	[[ $output == *'installed version unknown'* ]]
	[[ $output != *'[PASS]'* ]]
	[[ $output != *'[WARN]'* ]]
}

# =============================================================================
# _check_name_collision: classify an installed dpkg claude-desktop
# (official Anthropic package, or a pre-rename install of ours)
# (sources dir via _DOCTOR_APT_SOURCES_DIR; deb-family only)
# =============================================================================

# Stub dpkg-query answering the ${db:Status-Status}, ${Maintainer} and
# ${Version} probes for the package claude-desktop. $1 = maintainer,
# $2 = version, $3 = install status (default 'installed'); empty
# maintainer/version model "package not installed" (query fails), and
# the status probe fails the same way so a not-installed package also
# fails the caller's status gate.
_stub_dpkg_query() {
	_STUB_DPKG_MAINTAINER="$1"
	_STUB_DPKG_VERSION="$2"
	_STUB_DPKG_STATUS="${3:-installed}"
	dpkg-query() {
		case "$2" in
			*Status*)
				[[ -n $_STUB_DPKG_VERSION ]] || return 1
				printf '%s' "$_STUB_DPKG_STATUS"
				;;
			*Maintainer*)
				[[ -n $_STUB_DPKG_MAINTAINER ]] || return 1
				printf '%s' "$_STUB_DPKG_MAINTAINER"
				;;
			*Version*)
				[[ -n $_STUB_DPKG_VERSION ]] || return 1
				printf '%s' "$_STUB_DPKG_VERSION"
				;;
			*)
				return 1
				;;
		esac
	}
}

# Stub dpkg supporting only `--compare-versions A lt B`, via sort -V —
# the doctor host running these tests may not ship real dpkg.
_stub_dpkg_compare() {
	dpkg() {
		[[ $1 == '--compare-versions' && $3 == 'lt' ]] || return 2
		[[ $2 != "$4" ]] || return 1
		[[ $(printf '%s\n%s\n' "$2" "$4" | sort -V | head -1) \
			== "$2" ]]
	}
}

# Drop the official-repo fixture into the overridable sources dir.
_write_official_apt_source() {
	export _DOCTOR_APT_SOURCES_DIR="$TEST_TMP/sources.list.d"
	mkdir -p "$_DOCTOR_APT_SOURCES_DIR"
	cat > "$_DOCTOR_APT_SOURCES_DIR/claude-desktop.list" <<'LIST'
deb [signed-by=/usr/share/keyrings/claude.gpg] https://downloads.claude.ai/claude-desktop/apt/stable stable main
LIST
}

@test "_check_name_collision: silent when dpkg-query is absent" {
	command() {
		if [[ $1 == '-v' && $2 == 'dpkg-query' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	export _DOCTOR_APT_SOURCES_DIR="$TEST_TMP/sources.list.d"
	mkdir -p "$_DOCTOR_APT_SOURCES_DIR"
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_check_name_collision: silent when no claude-desktop is installed (repo alone is fine)" {
	# Post-rename there is no same-name collision: Anthropic's repo
	# being configured is not by itself worth a message.
	_stub_dpkg_query '' ''
	_write_official_apt_source
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_check_name_collision: official install (Anthropic maintainer) — info, not warn" {
	_stub_dpkg_query 'Anthropic, PBC <support@anthropic.com>' \
		'1.18286.0'
	export _DOCTOR_APT_SOURCES_DIR="$TEST_TMP/sources.list.d"
	mkdir -p "$_DOCTOR_APT_SOURCES_DIR"
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ $output == *"Anthropic's official claude-desktop"* ]]
	[[ $output == *'SingletonLock'* ]]
	[[ $output == *'only one can run at a time'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_check_name_collision: official install detected via apt source when maintainer probe is inconclusive" {
	# Maintainer string does not say Anthropic, but the version is
	# post-rename and their apt source is configured — classify as
	# the official package via the repo signal.
	_stub_dpkg_query 'Claude Desktop Team <noreply@example.com>' \
		'1.18286.0'
	_stub_dpkg_compare
	_write_official_apt_source
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ $output == *"Anthropic's official claude-desktop"* ]]
	[[ $output == *'SingletonLock'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_check_name_collision: legacy pre-rename package warns with migration hint" {
	# Our old package kept the name claude-desktop and versions
	# << 1.16000; the rename to claude-desktop-unofficial means a
	# lingering install deserves a warn plus the migration path.
	_stub_dpkg_query 'aaddrick <aaddrick@gmail.com>' '1.11847.5'
	_stub_dpkg_compare
	export _DOCTOR_APT_SOURCES_DIR="$TEST_TMP/sources.list.d"
	mkdir -p "$_DOCTOR_APT_SOURCES_DIR"
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'pre-rename'* ]]
	[[ $output == *'1.11847.5'* ]]
	[[ $output == *'sudo apt install claude-desktop-unofficial'* ]]
}

@test "_check_name_collision: removed-but-not-purged pre-rename record (config-files) stays silent (#711 follow-up)" {
	# apt remove without --purge leaves a config-files (rc) record for
	# a pre-rename claude-desktop; dpkg-query still answers Maintainer
	# and Version for it. Must not warn about software no longer
	# installed.
	_stub_dpkg_query 'aaddrick <aaddrick@gmail.com>' '1.11847.5' \
		'config-files'
	_stub_dpkg_compare
	export _DOCTOR_APT_SOURCES_DIR="$TEST_TMP/sources.list.d"
	mkdir -p "$_DOCTOR_APT_SOURCES_DIR"
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ -z $output ]]
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'pre-rename'* ]]
}

@test "_check_name_collision: removed-but-not-purged transitional dummy (config-files, >=1.16000) with repo configured stays silent (#711 follow-up)" {
	# The transitional claude-desktop 1.16000.0 dummy autoremoved to rc
	# state post-migration: non-Anthropic maintainer + version
	# >= 1.16000 + repo configured would otherwise fall through to the
	# repo_found branch and report an install that is no longer there.
	_stub_dpkg_query 'Claude Desktop Team <noreply@example.com>' \
		'1.16000.0' 'config-files'
	_stub_dpkg_compare
	_write_official_apt_source
	run _check_name_collision
	[[ $status -eq 0 ]]
	[[ -z $output ]]
	[[ $output != *'Anthropic'* ]]
	[[ $output != *'[INFO]'* ]]
}

# =============================================================================
# _check_cowork_virtiofsd: mirror the client's probe, not "anywhere" (#771)
# =============================================================================

# The client resolves virtiofsd from two hardcoded paths plus the
# bundled resources copy (un-gated by the virtiofsd-probe patch). A
# binary anywhere else must WARN with the symlink fix, not PASS —
# the false PASS is the doctor-vs-app disagreement from #771.

_stub_vfsd() {
	# Create an executable stub at $1 (under TEST_TMP)
	mkdir -p "$(dirname "$1")"
	printf '#!/bin/sh\n' > "$1"
	chmod +x "$1"
}

@test "_check_cowork_virtiofsd: client-probed path passes" {
	_stub_vfsd "$TEST_TMP/usr/libexec/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/usr/libexec/virtiofsd"
	run _check_cowork_virtiofsd debian ''
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'client-probed path'* ]]
}

@test "_check_cowork_virtiofsd: bundled copy passes when no client path hits" {
	_stub_vfsd "$TEST_TMP/resources/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/nonexistent"
	run _check_cowork_virtiofsd debian "$TEST_TMP/resources"
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'bundled copy'* ]]
}

@test "_check_cowork_virtiofsd: binary at a non-probed path warns with symlink fix" {
	_stub_vfsd "$TEST_TMP/usr/lib/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/usr/lib/virtiofsd"
	run _check_cowork_virtiofsd arch ''
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'the client only'* ]]
	[[ $output == *"sudo ln -s $TEST_TMP/usr/lib/virtiofsd /usr/bin/virtiofsd"* ]]
}

@test "_check_cowork_virtiofsd: not found anywhere warns with package hint" {
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/nonexistent"
	run _check_cowork_virtiofsd arch ''
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'virtiofsd: not found'* ]]
	[[ $output == *'sudo pacman -S'* ]]
}

@test "_check_cowork_virtiofsd: client path needs only read access (R_OK, like the client)" {
	mkdir -p "$TEST_TMP/usr/libexec"
	printf 'x' > "$TEST_TMP/usr/libexec/virtiofsd"
	chmod 444 "$TEST_TMP/usr/libexec/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/usr/libexec/virtiofsd"
	run _check_cowork_virtiofsd debian ''
	[[ $output == *'[PASS]'* ]]
}

@test "_check_cowork_virtiofsd: client-probed path preferred over bundled copy" {
	_stub_vfsd "$TEST_TMP/usr/bin/virtiofsd"
	_stub_vfsd "$TEST_TMP/resources/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/usr/bin/virtiofsd"
	run _check_cowork_virtiofsd debian "$TEST_TMP/resources"
	[[ $output == *'client-probed path'* ]]
	[[ $output != *'bundled copy'* ]]
}

@test "_check_cowork_virtiofsd: bundled copy without exec bit does not pass (X_OK, like the client)" {
	# The client resolves the bundled copy with X_OK; a mode-stripped
	# resources/virtiofsd must fall through to WARN, not PASS.
	mkdir -p "$TEST_TMP/resources"
	printf 'x' > "$TEST_TMP/resources/virtiofsd"
	chmod 644 "$TEST_TMP/resources/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/nonexistent"
	run _check_cowork_virtiofsd debian "$TEST_TMP/resources"
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'virtiofsd: not found'* ]]
}

# The _cowork_incomplete flag feeds run_doctor's Cowork readiness
# summary. These tests call the helper DIRECTLY — `run` executes in a
# subshell, so a flag mutation there is invisible to the test shell
# and can never be asserted (output goes to a file to keep bats logs
# clean).

@test "_check_cowork_virtiofsd: PASS leaves _cowork_incomplete false" {
	_stub_vfsd "$TEST_TMP/usr/libexec/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/usr/libexec/virtiofsd"
	_cowork_incomplete=false
	_check_cowork_virtiofsd debian '' > "$TEST_TMP/out"
	[[ $_cowork_incomplete == false ]]
	grep -q 'client-probed path' "$TEST_TMP/out"
}

@test "_check_cowork_virtiofsd: non-probed-path WARN flips _cowork_incomplete" {
	_stub_vfsd "$TEST_TMP/usr/lib/virtiofsd"
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/usr/lib/virtiofsd"
	_cowork_incomplete=false
	_check_cowork_virtiofsd arch '' > "$TEST_TMP/out"
	[[ $_cowork_incomplete == true ]]
	grep -q 'the client only' "$TEST_TMP/out"
}

@test "_check_cowork_virtiofsd: not-found WARN flips _cowork_incomplete" {
	export _COWORK_VFSD_CLIENT_PATHS="$TEST_TMP/nonexistent"
	export _COWORK_VFSD_PATHS="$TEST_TMP/nonexistent"
	_cowork_incomplete=false
	_check_cowork_virtiofsd arch '' > "$TEST_TMP/out"
	[[ $_cowork_incomplete == true ]]
	grep -q 'virtiofsd: not found' "$TEST_TMP/out"
}
