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
