#!/usr/bin/env bats
#
# patch_tray_icon_selection: threads CLAUDE_TRAY_USE_DARK_ICON into the
# upstream TrayIconLinux ternary (#604).

setup() {
	# shellcheck source=scripts/patches/tray-icon-selection.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/tray-icon-selection.sh"
}

_make_chunk() {
	local build="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	mkdir -p "$build"
	printf '%s\n' "$1" > "$build/index.chunk-test.js"
	main_js='app.asar.contents/.vite/build/index.chunk-test.js'
	cd "$BATS_TEST_TMPDIR" || return 1
}

@test "tray icon selection: injects CLAUDE_TRAY_USE_DARK_ICON guard" {
	_make_chunk \
		'case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	patch_tray_icon_selection
	grep -qF 'CLAUDE_TRAY_USE_DARK_ICON==="1"' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon selection: idempotent on re-run" {
	_make_chunk \
		'case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
}

@test "tray icon selection: warns when anchor is missing" {
	_make_chunk 'case"png":t="TrayIconLinux.png";break'
	run patch_tray_icon_selection
	[[ $status -eq 0 ]]
	[[ $output == *'WARNING'* ]]
}
