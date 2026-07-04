#!/usr/bin/env bats
#
# _check_upstream_tripwires (AU-1/MB-1): the build must fail loudly if
# the official bundle stops shipping the autoupdater-pending marker or
# the menu-bar-on default — the deleted 2.x patches used to WARN when
# those anchors moved, and the tripwires replace that signal.

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
		'x={autoUpdater:"apt_channel_pending"}' \
		'y={menuBarEnabled:!0}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 0 ]]
	[[ $output == *'tripwires clear'* ]]
}

@test "tripwires: clear with beautified whitespace around menuBarEnabled" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" \
		'x = { autoUpdater: "apt_channel_pending" }' \
		'y = { menuBarEnabled: !0 }'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 0 ]]
}

@test "tripwires: missing apt_channel_pending fails with AU-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" 'y={menuBarEnabled:!0}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'AU-1'* ]]
	[[ $output == *'autoupdater'* ]]
}

@test "tripwires: missing menuBarEnabled:!0 fails with MB-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" 'x="apt_channel_pending"'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'MB-1'* ]]
	[[ $output == *'menu-bar'* ]]
}

@test "tripwires: menuBarEnabled:!1 (default flipped off) fails with MB-1" {
	local bundle="$BATS_TEST_TMPDIR/app.asar"
	_write_bundle "$bundle" \
		'x="apt_channel_pending"' \
		'y={menuBarEnabled:!1}'
	run _check_upstream_tripwires "$bundle"
	[[ $status -eq 1 ]]
	[[ $output == *'MB-1'* ]]
}
