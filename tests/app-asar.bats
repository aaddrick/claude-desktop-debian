#!/usr/bin/env bats
#
# _check_upstream_tripwires (AU-1/MB-1): the build must fail loudly if
# the official bundle stops shipping the Linux updater-off marker
# (managed_by_package_manager, renamed from apt_channel_pending in the
# 1.18286.2 → 1.19367.0 window) or the menu-bar-on default — the
# deleted 2.x patches used to WARN when those anchors moved, and the
# tripwires replace that signal.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"
}

_write_bundle() {
	# $1 = destination, remaining args = lines of bundle content
	local dest="$1"
	shift
	printf '%s\n' "$@" > "$dest"
}

@test "tripwires: clear when both anchors are present (minified)" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" \
		'nt("desktop_update_disabled",{reason:"managed_by_package_manager"})' \
		'y={menuBarEnabled:!0}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 0 ]]
	[[ $output == *'tripwires clear'* ]]
}

@test "tripwires: clear with beautified whitespace around menuBarEnabled" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" \
		'x = { reason: "managed_by_package_manager" }' \
		'y = { menuBarEnabled: !0 }'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 0 ]]
}

@test "tripwires: missing managed_by_package_manager fails with AU-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" 'y={menuBarEnabled:!0}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'AU-1'* ]]
	[[ $output == *'autoupdater'* ]]
}

@test "tripwires: missing menuBarEnabled:!0 fails with MB-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" 'x="managed_by_package_manager"'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'MB-1'* ]]
	[[ $output == *'menu-bar'* ]]
}

@test "tripwires: menuBarEnabled:!1 (default flipped off) fails with MB-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" \
		'x="managed_by_package_manager"' \
		'y={menuBarEnabled:!1}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'MB-1'* ]]
}

# =============================================================================
# _derive_wm_class (#779): WM_CLASS comes from package.json desktopName
# minus its .desktop suffix — the field Chromium actually derives the
# X11 WM_CLASS / Wayland app_id from. Upstream renamed the value across
# 1.18286.0 → 1.19367.0, so the shapes of both releases are pinned here
# and every malformed shape must fail the build loudly rather than ship
# a broken StartupWMClass.
# =============================================================================

@test "derive_wm_class: 1.19367.0 shape strips the .desktop suffix" {
	run _derive_wm_class 'com.anthropic.Claude.desktop'
	[[ $status -eq 0 ]]
	[[ $output == 'com.anthropic.Claude' ]]
}

@test "derive_wm_class: pre-rename 1.18286.0 shape" {
	run _derive_wm_class 'claude-desktop.desktop'
	[[ $status -eq 0 ]]
	[[ $output == 'claude-desktop' ]]
}

@test "derive_wm_class: strips only the final .desktop suffix" {
	# Near-miss: 'desktop' as an interior name segment must survive.
	run _derive_wm_class 'com.desktop.Claude.desktop'
	[[ $status -eq 0 ]]
	[[ $output == 'com.desktop.Claude' ]]
}

@test "derive_wm_class: empty desktopName fails the build" {
	run _derive_wm_class ''
	[[ $status -eq 1 ]]
	[[ $output == *'desktopName'* ]]
	[[ $output == *'#779'* ]]
}

@test "derive_wm_class: value without .desktop suffix fails the build" {
	# Near-miss: a bare window class where the desktop-file id should
	# be means upstream changed the field's shape — refuse to guess.
	run _derive_wm_class 'com.anthropic.Claude'
	[[ $status -eq 1 ]]
	[[ $output == *'.desktop'* ]]
	[[ $output == *'#779'* ]]
}
