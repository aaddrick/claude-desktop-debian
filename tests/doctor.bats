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
