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

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"

	_doctor_colors
	_doctor_failures=0

	# Default _pkg_installed to "unknown" (rc=2) so tests don't have
	# to stub it unless they're exercising the package-check branch.
	# Override in-test for rc=0 (installed) or rc=1 (missing).
	_pkg_installed() { return 2; }

	# Default stub for _detect_password_store (defined in
	# launcher-common.sh, not sourced here). Tests that exercise
	# _doctor_check_password_store override this in-test if needed.
	_detect_password_store() { echo 'basic'; }
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
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	export PATH="$saved_path"
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: zero crashes — silent" {
	# Listing has the header line only, no entry rows.
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "_doctor_check_recent_crashes: 1 crash — info line, no warn" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'Recent Electron crashes: 1'* ]]
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_recent_crashes: 3+ crashes — warn + #583 pointer" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M
Mon 2026-05-04 07:44:48 EDT 930532 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 22.8M
Sun 2026-05-03 14:34:10 EDT 567221 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 12.4M'
	run _doctor_check_recent_crashes \
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
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
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'may be from other Electron apps'* ]]
}

@test "_doctor_check_recent_crashes: empty electron_path falls back" {
	_install_coredumpctl_shim 'TIME PID UID GID SIG COREFILE EXE SIZE
Wed 2026-05-06 08:00:21 EDT 130375 1000 1000 SIGTRAP present /usr/lib/claude-desktop/node_modules/electron/dist/electron 21.6M'
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
# =============================================================================

@test "_doctor_check_password_store: output contains 'Password store:' with a valid backend" {
	# setup() already stubs _detect_password_store to return 'basic'.
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Password store:'* ]]
	[[ $output == *'basic'* ]]
}

@test "_doctor_check_password_store: warns, not PASS, when detection returns empty" {
	# An empty backend means detection failed (e.g. sourcing-order
	# regression) — it must not surface as a green PASS with a blank value.
	_detect_password_store() { echo ''; }
	run _doctor_check_password_store
	[[ $status -eq 0 ]]
	[[ $output == *'[WARN]'* ]]
	[[ $output != *'[PASS]'* ]]
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
		'/usr/lib/claude-desktop/node_modules/electron/dist/electron'
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Installed version: 1.11847.5-2.0.19'* ]]
	[[ $output != *'1.5354.0'* ]]
}

@test "_doctor_check_pkg_version: dpkg-only host reports dpkg version" {
	_hide_pkg_tools rpm
	dpkg-query() { printf '1.11847.5'; }

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
	dpkg-query() { printf '1.11847.5'; }

	run _doctor_check_pkg_version ''
	[[ $status -eq 0 ]]
	[[ $output == *'[PASS]'* ]]
	[[ $output == *'Installed version: 1.11847.5'* ]]
	[[ $output != *'not owned'* ]]
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
