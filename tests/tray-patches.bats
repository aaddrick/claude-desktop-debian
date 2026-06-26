#!/usr/bin/env bats
#
# tray-patches.bats
# Tests for scripts/patches/tray.sh — focused on patch_tray_inplace_update
# (the in-place fast-path that dodges the #515 KDE duplicate-icon
# StatusNotifier race) and patch_menu_bar_default.
#
# Regression guard for the 1.13576+ "yukonSilver"-era tray rebuild
# refactor, which restructured the destroy/recreate block and switched
# the context menu from an inline builder call to a prebuilt object,
# while introducing a setContextMenu(null) menu-clear that a naive
# head -1 latches onto. Both broke the fast-path silently (tray patches
# warn-and-continue, so it shipped via green CI).

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
TRAY_SH="$SCRIPT_DIR/../scripts/patches/tray.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# The patch functions read/write a path relative to cwd.
	index_js_dir="$TEST_TMP/app.asar.contents/.vite/build"
	mkdir -p "$index_js_dir"
	index_js="$index_js_dir/index.js"

	# Globals the partial expects from build.sh.
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

# A minified fixture mirroring the 1.13576+ tray rebuild shape:
#  - destroy/recreate guarded by `if(A9=[],e9=!1,vE&&(vE.destroy()...),!A)`
#  - the menu is a *prebuilt object* `yh=S5A()`, set via setContextMenu(yh)
#  - a decoy `setContextMenu(null)` menu-clear precedes the real call
#  - menuBarEnabled read through a settings getter with a defaults map
write_new_shape_fixture() {
	cat > "$index_js" <<'JS'
const aA=require("electron");
function Di(k){return({menuBarEnabled:!0,legacyQuickEntryEnabled:!0})[k]}
function S5A(){return aA.Menu.buildFromTemplate([{label:"Show App"},{label:"Quit"}])}
function VIe(){return!1}
function rebuild(){
const A=Di("menuBarEnabled");if(VIe())return;let e;
e=aA.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png";
const t=X.join(toi(),e),i=!xrt;
if(A9=[],e9=!1,vE&&(vE.destroy(),vE=null),!A){JhA();return}
vE=new aA.Tray(aA.nativeImage.createFromPath(t)),xrt=!0,vEA=!1,yh=S5A(),vE.on("click",()=>void Loi()),vE.on("right-click",()=>{WN()&&(vEA=!0,vE.setContextMenu(null)),(vEA||!yh)&&(yh=S5A(),vEA=!1),vE.popUpContextMenu(yh)}),WN()||(vE.setContextMenu(yh),e9=!0);
}
kd.on("menuBarEnabled",()=>{rebuild()});
JS
}

@test "inplace: resolves the real menu builder, not the setContextMenu(null) decoy" {
	write_new_shape_fixture
	cd "$TEST_TMP"
	run patch_tray_inplace_update
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q 'Found menu function: S5A'
	# The fast-path must call the builder, never null().
	grep -qF 'vE.setContextMenu(S5A())' "$index_js"
	! grep -qF 'setContextMenu(null())' "$index_js"
}

@test "inplace: fast-path lands before the destroy/recreate block and stays valid JS" {
	write_new_shape_fixture
	cd "$TEST_TMP"
	run patch_tray_inplace_update
	[[ "$status" -eq 0 ]]
	# Fast-path returns before the destroy block runs.
	grep -qF 'if(vE&&A!==false){vE.setImage(aA.nativeImage.createFromPath(t));' \
		"$index_js"
	local fp dr
	fp=$(grep -boF 'vE.setImage(aA.nativeImage.createFromPath(t))' "$index_js" \
		| head -1 | cut -d: -f1)
	dr=$(grep -boF 'vE.destroy()' "$index_js" | head -1 | cut -d: -f1)
	[[ -n "$fp" && -n "$dr" && "$fp" -lt "$dr" ]]
	node --check "$index_js"
}

@test "inplace: idempotent — second run is a no-op and keeps valid JS" {
	write_new_shape_fixture
	cd "$TEST_TMP"
	patch_tray_inplace_update
	run patch_tray_inplace_update
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q 'already present (idempotent)'
	[[ "$(grep -cF 'vE.setImage(aA.nativeImage.createFromPath(t))' \
		"$index_js")" -eq 1 ]]
	node --check "$index_js"
}

@test "inplace: missing TRAY.destroy() site is a loud failure, not a silent skip" {
	# A bundle with a context menu but no destroy/recreate block: the
	# resolver succeeds but the injection anchor is gone — must exit non-zero.
	cat > "$index_js" <<'JS'
const aA=require("electron");
function S5A(){return aA.Menu.buildFromTemplate([])}
function rebuild(){
const A=Di("menuBarEnabled");
const t=X.join(toi(),e);
vE=new aA.Tray(aA.nativeImage.createFromPath(t)),yh=S5A(),vE.setContextMenu(yh);
}
kd.on("menuBarEnabled",()=>{rebuild()});
JS
	cd "$TEST_TMP"
	run patch_tray_inplace_update
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -q 'destroy'
}

@test "inplace: ambiguous TRAY.destroy() (two sites) is a loud failure" {
	# Two destroy sites: indexOf would mis-place the injection. The
	# count==1 guard must bail rather than trust the first hit.
	write_new_shape_fixture
	cat >> "$index_js" <<'JS'
function teardownAgain(){vE.destroy();}
JS
	cd "$TEST_TMP"
	run patch_tray_inplace_update
	[[ "$status" -ne 0 ]]
	echo "$output" | grep -qiE 'expected exactly 1|found 2'
}

@test "menu-bar-default: recognizes the upstream defaults map as already-true" {
	write_new_shape_fixture
	cd "$TEST_TMP"
	run patch_menu_bar_default
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -q 'already defaults to true upstream'
}

@test "menu-bar-default: still rewrites the legacy !!var shape" {
	cat > "$index_js" <<'JS'
const aA=require("electron");
const A=Di("menuBarEnabled");
const cfg=mk({tray:1},!!A);
JS
	cd "$TEST_TMP"
	run patch_menu_bar_default
	[[ "$status" -eq 0 ]]
	grep -qF ',A!==false)' "$index_js"
	! grep -qF ',!!A)' "$index_js"
}

@test "menu-bar-default: warns when neither legacy anchor nor upstream default exists" {
	cat > "$index_js" <<'JS'
const aA=require("electron");
const A=Di("menuBarEnabled");
const cfg=mk({tray:1},A);
JS
	cd "$TEST_TMP"
	run patch_menu_bar_default
	[[ "$status" -eq 0 ]]
	echo "$output" | grep -qi 'WARNING'
}
