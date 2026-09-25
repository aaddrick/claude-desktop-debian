#!/usr/bin/env bats
#
# _check_upstream_tripwires (AU-1/MB-1): the build must fail loudly if
# the official bundle stops shipping the Linux updater-off marker
# (managed_by_package_manager, renamed from apt_channel_pending in the
# 1.18286.2 → 1.19367.0 window) or the menu-bar-on default — the
# deleted 2.x patches used to WARN when those anchors moved, and the
# tripwires replace that signal.
#
# _resolve_anchor_file: there is no single main-process file any more.
# 1.19367.0 split it into a stub plus one content-hashed chunk; 1.26832.0
# dissolved that core into 83 chunks across two families and left some
# anchors in index.js itself (#820). Each patch resolves the file its own
# anchor lives in, and the exactly-one assertion is what replaces the old
# multi-chunk guard.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"
}

# Build the .vite/build tree _resolve_anchor_file reads (relative to CWD)
# and cd into its parent so the resolver's relative paths resolve. $1 =
# the index.js body; remaining args = "chunk-name:body" files to create.
_make_build_tree() {
	local index_body="$1"
	shift
	local build="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	rm -rf "$BATS_TEST_TMPDIR/app.asar.contents"
	mkdir -p "$build"
	printf '%s\n' "$index_body" > "$build/index.js"
	local spec
	for spec in "$@"; do
		printf '%s\n' "${spec#*:}" > "$build/${spec%%:*}"
	done
	cd "$BATS_TEST_TMPDIR" || return 1
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

@test "resolve: finds the single chunk carrying the anchor" {
	_make_build_tree \
		'"use strict";require("./index.chunk-CNXUb5h4.js");' \
		'index.chunk-CNXUb5h4.js:var a=`TrayIconLinux-Dark.png`;'
	run _resolve_anchor_file 'tray' 'TrayIconLinux-Dark\.png'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.chunk-CNXUb5h4.js' ]]
}

@test "resolve: finds an anchor left in index.js itself (1.26832.0)" {
	# The entry file stopped being a stub: the tray anchor lives there.
	_make_build_tree \
		'var a=`TrayIconLinux-Dark.png`;require("./index.chunk-AAAA1111.js");' \
		'index.chunk-AAAA1111.js:/* unrelated */'
	run _resolve_anchor_file 'tray' 'TrayIconLinux-Dark\.png'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.js' ]]
}

@test "resolve: finds an anchor in the index2 chunk family" {
	_make_build_tree \
		'require("./index2.chunk-ZZZZ9999.js");' \
		'index2.chunk-ZZZZ9999.js:function q(){return process.platform,r()}'
	run _resolve_anchor_file 'cowork A' 'return process\.platform,[\w$]+\(\)\}'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index2.chunk-ZZZZ9999.js' ]]
}

@test "resolve: matches a backtick literal via the quote class" {
	# 1.26832.0 re-emitted nearly every string as a backtick template; an
	# anchor pinned to a bare double quote would find nothing.
	_make_build_tree \
		'var x=1;' \
		'index.chunk-AAAA1111.js:e.setAlwaysOnTop(!0,`pop-up-menu`)'
	run _resolve_anchor_file 'quick-window' \
		'\.setAlwaysOnTop\(\s*!0\s*,\s*[`"'"'"']pop-up-menu[`"'"'"']\)'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.chunk-AAAA1111.js' ]]
}

@test "resolve: the same anchor still matches the old double-quoted shape" {
	_make_build_tree \
		'var x=1;' \
		'index.chunk-AAAA1111.js:e.setAlwaysOnTop(!0,"pop-up-menu")'
	run _resolve_anchor_file 'quick-window' \
		'\.setAlwaysOnTop\(\s*!0\s*,\s*[`"'"'"']pop-up-menu[`"'"'"']\)'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.chunk-AAAA1111.js' ]]
}

@test "resolve: fails loud when the anchor matches nothing" {
	_make_build_tree 'var x=1;' 'index.chunk-AAAA1111.js:/* nothing */'
	run _resolve_anchor_file 'tray' 'TrayIconLinux-Dark\.png'
	[[ $status -eq 1 ]]
	[[ $output == *'matched no file'* ]]
	[[ $output == *'Re-derive'* ]]
}

@test "resolve: fails loud when the anchor is ambiguous across chunks" {
	# The decoy case: a distinctive string can recur in a sibling chunk
	# that carries no call to rewrite, so resolving on it must not pick
	# one at random.
	_make_build_tree \
		'var x=1;' \
		'index.chunk-AAAA1111.js:log(`pop-up-menu`)' \
		'index.chunk-BBBB2222.js:e.setAlwaysOnTop(!0,`pop-up-menu`)'
	run _resolve_anchor_file 'quick-window' 'pop-up-menu'
	[[ $status -eq 1 ]]
	[[ $output == *'matched 2 files'* ]]
	[[ $output == *'ambiguous'* ]]
}

@test "resolve: the full anchor shape disambiguates where the string cannot" {
	# Same tree as above; anchoring on the call shape rather than the
	# bare literal selects the one file that actually has a patch site.
	_make_build_tree \
		'var x=1;' \
		'index.chunk-AAAA1111.js:log(`pop-up-menu`)' \
		'index.chunk-BBBB2222.js:e.setAlwaysOnTop(!0,`pop-up-menu`)'
	run _resolve_anchor_file 'quick-window' \
		'\.setAlwaysOnTop\(\s*!0\s*,\s*[`"'"'"']pop-up-menu[`"'"'"']\)'
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.chunk-BBBB2222.js' ]]
}

@test "resolve: fails loud when the build dir is absent" {
	rm -rf "$BATS_TEST_TMPDIR/app.asar.contents"
	mkdir -p "$BATS_TEST_TMPDIR"
	cd "$BATS_TEST_TMPDIR" || return 1
	run _resolve_anchor_file 'tray' 'TrayIconLinux-Dark\.png'
	[[ $status -eq 1 ]]
	[[ $output == *'upstream layout changed'* ]]
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

# =============================================================================
# Retirement tripwire (_run_active_patches / _check_patch_effect)
#
# Every build starts from the pristine official bundle, so an active
# patch that changes no bytes there has either been fixed upstream or
# lost its anchor — both need a human before shipping. A patch's own
# "applied" message is not evidence (org-plugins.sh prints "Added"
# after a sed that may not have matched), so the orchestrator measures
# the bundle before and after each patch instead.
# =============================================================================

# Stub patches, run with CWD at the fake resources dir. Each touches a
# different kind of change so the digest is exercised on all of them.
_patch_edits() {
	printf 'patched\n' >> app.asar.contents/.vite/build/index.js
}
_patch_edits_chunk() {
	sed -i 's/core/core+fix/' app.asar.contents/.vite/build/index.chunk-a.js
}
_patch_noop() { :; }
# Changes bytes and THEN fails, so a loop that ignored the failure would
# pass the effect check and run the next patch — a failing no-op would
# be stopped by the tripwire instead, and hide that bug.
_patch_fails() {
	printf 'half\n' >> app.asar.contents/.vite/build/index.js
	return 1
}

@test "retirement tripwire: a patch that changes the bundle passes" {
	_make_build_tree 'require("./index.chunk-a.js")' 'index.chunk-a.js:core'
	active_patches=(_patch_edits _patch_edits_chunk)
	run _run_active_patches
	[[ $status -eq 0 ]]
	[[ $output != *'tripwire'* ]]
}

@test "retirement tripwire: a no-op patch fails the build, named" {
	_make_build_tree 'require("./index.chunk-a.js")' 'index.chunk-a.js:core'
	patch_retirement[_patch_noop]='bytes: test-report.md'
	active_patches=(_patch_edits _patch_noop)
	run _run_active_patches
	[[ $status -eq 1 ]]
	[[ $output == *'Retirement tripwire: _patch_noop changed nothing'* ]]
	# The registry entry is what tells the triager what "fixed" means.
	[[ $output == *'Retires by: bytes: test-report.md'* ]]
	# Near-miss: the patch that did change bytes is not the one blamed.
	[[ $output != *'_patch_edits changed nothing'* ]]
}

@test "retirement tripwire: a no-op with no registry entry still fails" {
	_make_build_tree 'x'
	active_patches=(_patch_noop)
	run _run_active_patches
	[[ $status -eq 1 ]]
	[[ $output == *'no patch_retirement entry'* ]]
}

@test "retirement tripwire: a failing patch stops the loop" {
	_make_build_tree 'x'
	active_patches=(_patch_fails _patch_edits)
	run _run_active_patches
	[[ $status -eq 1 ]]
	# _patch_edits never ran: only _patch_fails's line was appended.
	[[ $(< app.asar.contents/.vite/build/index.js) == $'x\nhalf' ]]
}

@test "retirement tripwire: re-run accepts a patch that changes nothing" {
	_make_build_tree 'x'
	active_patches=(_patch_noop)
	PATCH_STAGE_RERUN=1 run _run_active_patches
	[[ $status -eq 0 ]]
}

@test "retirement tripwire: re-run rejects a patch that changes bytes" {
	# An idempotency guard that misses its own output re-applies on the
	# second pass; name the patch rather than leave a bare hash diff.
	_make_build_tree 'x'
	active_patches=(_patch_edits)
	PATCH_STAGE_RERUN=1 run _run_active_patches
	[[ $status -eq 1 ]]
	[[ $output == *'Idempotency: _patch_edits changed'* ]]
}

@test "retirement tripwire: a missing build tree fails, not passes" {
	# Without the tree the digest is empty on both sides and would
	# compare equal — a false no-op on pass 1, a false pass on re-run.
	cd "$BATS_TEST_TMPDIR" || return 1
	active_patches=(_patch_noop)
	PATCH_STAGE_RERUN=1 run _run_active_patches
	[[ $status -eq 1 ]]
}

@test "retirement tripwire: an empty build tree fails, not passes" {
	# Near-miss of the missing-tree case: the directory exists but holds
	# no files, so xargs would still run sha256sum once on empty input
	# and both digests would be the same constant.
	mkdir -p "$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	cd "$BATS_TEST_TMPDIR" || return 1
	active_patches=(_patch_noop)
	PATCH_STAGE_RERUN=1 run _run_active_patches
	[[ $status -eq 1 ]]
}

@test "retirement tripwire: every active patch has a registry entry" {
	# Sourcing app-asar.sh resets active_patches to the shipped list.
	local patch_fn missing=()
	for patch_fn in "${active_patches[@]}"; do
		[[ -n ${patch_retirement[$patch_fn]:-} ]] || missing+=("$patch_fn")
	done
	(( ${#active_patches[@]} > 0 ))
	(( ${#missing[@]} == 0 )) || {
		printf 'no patch_retirement entry: %s\n' "${missing[@]}" >&2
		return 1
	}
}

@test "retirement tripwire: registry rows name a known retirement kind" {
	local patch_fn row
	for patch_fn in "${!patch_retirement[@]}"; do
		row=${patch_retirement[$patch_fn]}
		[[ $row =~ ^(bytes|behavior|never):\  ]] && continue
		printf 'bad kind for %s: %s\n' "$patch_fn" "$row" >&2
		return 1
	done
}
