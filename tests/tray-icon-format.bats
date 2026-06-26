#!/usr/bin/env bats
#
# tray-icon-format.bats
# Tests for patch_tray_icon_selection in scripts/patches/tray.sh — the
# fix that routes the tray icon *format* to the PNG case on Linux.
#
# Regression guard for #746: upstream 1.13576+ bakes the icon format as a
# build-time constant (uPi="ico") and routes it through
#   switch(uPi){case"ico":…Tray-Win32.ico…;case"png":…TrayIconTemplate…}
# Since we repackage the Windows asar, that constant stays "ico" on Linux,
# so the tray loads the Windows .ico and renders as a black square on the
# freedesktop/KDE StatusNotifier. The patch wraps the switch discriminant
# so Linux takes the already-theme-aware "png" case.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
TRAY_SH="$SCRIPT_DIR/../scripts/patches/tray.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	index_js_dir="$TEST_TMP/app.asar.contents/.vite/build"
	mkdir -p "$index_js_dir"
	index_js="$index_js_dir/index.js"

	project_root="$TEST_TMP"
	electron_var='aA'
	electron_var_re='aA'
	export project_root electron_var electron_var_re

	# shellcheck source=../scripts/patches/tray.sh
	source "$TRAY_SH"
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Minified fixture mirroring the 1.13576+ icon-format switch: a baked
# uPi="ico" constant, the three-case switch (Windows .ico / template /
# theme-aware png), and the Tray creation that consumes the result.
write_icon_switch_fixture() {
	cat > "$index_js" <<'JS'
const aA=require("electron");
const gPi=!0,lPi=36,uPi="ico",IPi=!0;
function rebuild(){
let e;switch(uPi){case"ico":e=aA.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";break;case"template-image":e="TrayIconTemplate.png";break;case"png":e=aA.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png";break}
const t=X.join(toi(),e);
vE=new aA.Tray(aA.nativeImage.createFromPath(t));
}
JS
}

@test "icon-format: routes the switch discriminant to png on Linux" {
	write_icon_switch_fixture
	cd "$TEST_TMP"
	run patch_tray_icon_selection
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q 'Found icon-format switch var: uPi'
	grep -qF 'switch(process.platform==="linux"?"png":uPi){case"ico":' \
		"$index_js"
	node --check "$index_js"
}

@test "icon-format: the routed-to png case still selects the theme-aware PNG" {
	write_icon_switch_fixture
	cd "$TEST_TMP"
	patch_tray_icon_selection
	# The case Linux now lands on must keep the dark/light PNG template
	# selection — i.e. the fix is inert if the png case lost it.
	grep -qF 'case"png":e=aA.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"' \
		"$index_js"
}

@test "icon-format: idempotent — second run is a no-op" {
	write_icon_switch_fixture
	cd "$TEST_TMP"
	patch_tray_icon_selection
	run patch_tray_icon_selection
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q 'already routed to png on Linux'
	[[ "$(grep -coF 'process.platform==="linux"?"png":' "$index_js")" -eq 1 ]]
	node --check "$index_js"
}

@test "icon-format: warns and skips when the switch shape is absent" {
	cat > "$index_js" <<'JS'
const aA=require("electron");
function rebuild(){const e="TrayIconTemplate.png";vE=new aA.Tray(aA.nativeImage.createFromPath(e));}
JS
	cd "$TEST_TMP"
	run patch_tray_icon_selection
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -qi 'WARNING'
	# Must not have injected a bogus discriminant.
	! grep -qF 'process.platform==="linux"?"png":' "$index_js"
}

@test "icon-format: warns when more than one icon-format switch exists" {
	write_icon_switch_fixture
	cat >> "$index_js" <<'JS'
function other(){switch(zZ){case"ico":e=1;break}}
JS
	cd "$TEST_TMP"
	run patch_tray_icon_selection
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -qiE 'expected exactly 1|found 2'
	! grep -qF 'process.platform==="linux"?"png":' "$index_js"
}
