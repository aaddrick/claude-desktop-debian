#!/usr/bin/env bats
#
# patch_tray_icon_env_override: threads CLAUDE_TRAY_USE_DARK_ICON into
# the upstream TrayIconLinux ternary (#604).
#
# The near-miss fixtures (no-GNOME-half, Win32-ico lookalike, duplicate
# site) sit one edit away from the anchor on purpose: loosening the
# regex or dropping the exactly-1 assertion turns their expected
# hard-fail into a pass and goes red
# (docs/learnings/test-methodology-and-coverage.md).

setup() {
	# shellcheck source=scripts/patches/tray-icon-selection.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/tray-icon-selection.sh"

	# Real 1.19367.0 minified bytes around the anchor (identifiers
	# oPe/G as shipped; verified against the pinned official .deb).
	upstream_ternary='case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'

	# The full post-patch expression — asserting through to the icon
	# literals pins placement inside the ternary, not just marker
	# presence.
	patched_expr='process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'
}

_make_chunk() {
	local build="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	mkdir -p "$build"
	printf '%s\n' "$1" > "$build/index.chunk-test.js"
	main_js='app.asar.contents/.vite/build/index.chunk-test.js'
	cd "$BATS_TEST_TMPDIR" || return 1
}

@test "tray icon override: injects tri-state guard inside the ternary" {
	_make_chunk "$upstream_ternary"
	patch_tray_icon_env_override
	grep -qF "$patched_expr" \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: matches the beautified-spacing form" {
	local build="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	mkdir -p "$build"
	cat > "$build/index.chunk-test.js" << 'EOF'
        t =
          oPe() === "gnome" || G.nativeTheme.shouldUseDarkColors
            ? "TrayIconLinux-Dark.png"
            : "TrayIconLinux.png";
EOF
	main_js='app.asar.contents/.vite/build/index.chunk-test.js'
	cd "$BATS_TEST_TMPDIR" || return 1
	patch_tray_icon_env_override
	grep -qF 'CLAUDE_TRAY_USE_DARK_ICON==="1"' "$build/index.chunk-test.js"
	grep -qF '?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' \
		"$build/index.chunk-test.js"
}

@test "tray icon override: idempotent and byte-identical on re-run" {
	_make_chunk "$upstream_ternary"
	patch_tray_icon_env_override
	local chunk="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	chunk+='/index.chunk-test.js'
	cp "$chunk" "$BATS_TEST_TMPDIR/first-run.js"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'already applied'* ]]
	cmp "$chunk" "$BATS_TEST_TMPDIR/first-run.js"
}

@test "tray icon override: missing anchor fails the build" {
	_make_chunk 'case"png":t="TrayIconLinux.png";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'WARNING'* ]]
	[[ $output == *'ERROR'* ]]
}

@test "tray icon override: near-miss without the GNOME half fails" {
	# One edit short of the anchor: drops `oPe()==="gnome"||`. A patch
	# weakened to match on shouldUseDarkColors alone would pass here.
	# The output pin ties status 1 to the anchor count, not to an
	# unrelated failure (missing node, bad fixture path).
	_make_chunk \
		'case"png":t=G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'found 0'* ]]
}

@test "tray icon override: Win32 ico lookalike ternary fails" {
	# Upstream's sibling "ico" case — same shape, different literals. A
	# patch weakened to ignore the TrayIconLinux literals would pass.
	_make_chunk \
		'case"ico":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'found 0'* ]]
}

@test "tray icon override: matches the bundler indirect-call shape" {
	# Post-code-split minifier artifact: a cross-chunk detector import
	# becomes (0,Ei.oPe)(), and the electron handle can be a property
	# chain — the quick-window patch hit the exports.mainWindow rename
	# the same way. A benign re-minification into this shape must not
	# hard-fail a release.
	_make_chunk \
		'case"png":t=(0,Ei.oPe)()==="gnome"||Ei.G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	patch_tray_icon_env_override
	local chunk="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	chunk+='/index.chunk-test.js'
	grep -qF 'CLAUDE_TRAY_USE_DARK_ICON!=="0"&&((0,Ei.oPe)()==="gnome"||Ei.G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png"' \
		"$chunk"
}

@test "tray icon override: duplicate anchor site fails" {
	_make_chunk "$upstream_ternary$upstream_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'found 2'* ]]
}
