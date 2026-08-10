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
	# _resolve_anchor_file lives here; the patch resolves its own file
	# rather than reading a main_js global (#820).
	# shellcheck source=scripts/patches/app-asar.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"

	# Real 1.19367.0 minified bytes around the anchor (identifiers
	# oPe/G as shipped; verified against the pinned official .deb).
	upstream_ternary='case"png":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'

	# The full post-patch expression — asserting through to the icon
	# literals pins placement inside the ternary, not just marker
	# presence.
	patched_expr='process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	# Real 1.26832.0 minified bytes: the bundler swap re-emitted every
	# string literal as a backtick template, which took this anchor to
	# zero matches (#820).
	upstream_ternary_bt='case`png`:t=lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
}

_make_chunk() {
	local build="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	mkdir -p "$build"
	printf '%s\n' "$1" > "$build/index.chunk-test.js"
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
	# The icon-literal pair is now the resolution anchor, so a bundle
	# without it fails before the patch body runs. The build still stops,
	# which is the property under test; only the message moved.
	_make_chunk 'case"png":t="TrayIconLinux.png";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched no file'* ]]
	[[ $output == *'Re-derive'* ]]
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
	# The TrayIconLinux literals guard this from the resolver now rather
	# than from the ternary count: weakening the resolution anchor to
	# ignore them lets resolution succeed, and the ternary count then
	# reports 0 and still fails. Either way this fixture stays red.
	_make_chunk \
		'case"ico":t=oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico";break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched no file'* ]]
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

@test "tray icon override: applies to the 1.26832.0 backticked shape" {
	# Pins the quote class: an anchor keyed to a bare double quote finds
	# nothing in a 1.26832.0 bundle and hard-fails the release.
	_make_chunk "$upstream_ternary_bt"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	grep -qF 'CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: backticked shape is idempotent" {
	_make_chunk "$upstream_ternary_bt"
	patch_tray_icon_env_override
	local chunk="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	chunk+='/index.chunk-test.js'
	local first; first="$(cat "$chunk")"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'already applied'* ]]
	[[ "$(cat "$chunk")" == "$first" ]]
}
