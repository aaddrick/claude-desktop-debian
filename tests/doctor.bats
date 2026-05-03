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
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
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
	# Stub gtk-query-immodules-3.0 to absent so the cache check is
	# skipped (we're only testing the override-visibility branch).
	gtk-query-immodules-3.0() { return 127; }
	export -f gtk-query-immodules-3.0
	# Make command -v miss the function as well, by calling via 'which'.
	# In bash, command -v finds functions, so override the function instead.
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	# Stub _pkg_installed so the package check is skipped (rc=2, unknown).
	_pkg_installed() { return 2; }

	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output == *'CLAUDE_GTK_IM_MODULE=xim'* ]]
	[[ $output == *'overrides GTK_IM_MODULE for Electron'* ]]
}

@test "_doctor_check_im_modules: no override line when CLAUDE_GTK_IM_MODULE unset" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 2; }

	run _doctor_check_im_modules debian
	[[ $output != *'CLAUDE_GTK_IM_MODULE'* ]]
}

# =============================================================================
# _doctor_check_im_modules: XWayland-with-IBus routing note
# =============================================================================

@test "_doctor_check_im_modules: emits XWayland note when wayland session and CLAUDE_USE_WAYLAND unset" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 2; }

	XDG_SESSION_TYPE='wayland'
	# CLAUDE_USE_WAYLAND deliberately unset
	run _doctor_check_im_modules debian
	[[ $output == *'XWayland'* ]]
	[[ $output == *'CLAUDE_USE_WAYLAND=1'* ]]
}

@test "_doctor_check_im_modules: no XWayland note when CLAUDE_USE_WAYLAND=1" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 2; }

	XDG_SESSION_TYPE='wayland'
	CLAUDE_USE_WAYLAND='1'
	run _doctor_check_im_modules debian
	[[ $output != *'XWayland'* ]]
}

@test "_doctor_check_im_modules: no XWayland note on X11 session" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 2; }

	XDG_SESSION_TYPE='x11'
	run _doctor_check_im_modules debian
	[[ $output != *'XWayland'* ]]
}

# =============================================================================
# _doctor_check_im_modules: ibus-gtk3 package check
# =============================================================================

@test "_doctor_check_im_modules: warns when ibus selected but ibus-gtk3 missing" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	# Package not installed (rc=1, definitive answer)
	_pkg_installed() { return 1; }

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules debian
	[[ $output == *'[WARN]'* ]]
	[[ $output == *'ibus-gtk3 is not installed'* ]]
	[[ $output == *'sudo apt install ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no warning when ibus selected and ibus-gtk3 present" {
	# Stub: gtk-query-immodules-3.0 lists ibus
	gtk-query-immodules-3.0() {
		echo '"ibus" "IBus" "ibus" "/usr/share/locale" "*"'
	}
	export -f gtk-query-immodules-3.0
	# Package installed (rc=0)
	_pkg_installed() { return 0; }

	GTK_IM_MODULE='ibus'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no package warning when active module isn't ibus" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	# Even if _pkg_installed would say "missing" for ibus-gtk3, the
	# function should not query it when GTK_IM_MODULE=xim.
	_pkg_installed() { return 1; }

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'ibus-gtk3'* ]]
}

@test "_doctor_check_im_modules: no package warning on unsupported distro (rc=2)" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	# Unsupported distro: _pkg_installed returns rc=2 → no warning.
	_pkg_installed() { return 2; }

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
	_pkg_installed() { return 2; }

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
	_pkg_installed() { return 2; }

	GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: skips cache check when gtk-query-immodules-3.0 missing" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 2; }

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
	_pkg_installed() { return 2; }

	GTK_IM_MODULE='ibus'
	CLAUDE_GTK_IM_MODULE='xim'
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
}

@test "_doctor_check_im_modules: no checks fire when no IM module selected" {
	command() {
		if [[ $1 == '-v' && $2 == 'gtk-query-immodules-3.0' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	_pkg_installed() { return 1; }

	# Neither GTK_IM_MODULE nor CLAUDE_GTK_IM_MODULE set
	run _doctor_check_im_modules debian
	[[ $output != *'[WARN]'* ]]
	[[ $output != *'ibus-gtk3'* ]]
}
