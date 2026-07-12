#!/usr/bin/env bats
#
# _check_upstream_tripwires (AU-1/MB-1): the build must fail loudly if
# the official bundle stops shipping the Linux updater-off marker
# (managed_by_package_manager, renamed from apt_channel_pending in the
# 1.18286.2 → 1.19367.0 window) or the menu-bar-on default — the
# deleted 2.x patches used to WARN when those anchors moved, and the
# tripwires replace that signal.
#
# _resolve_main_js: since 1.19367.0 the main process is code-split, so
# index.js is a stub that require()s a content-hashed main chunk. The
# resolver follows that require, falls back to index.js on the older
# single-file layout, and fails loud on anything ambiguous.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"
}

# Build the .vite/build tree _resolve_main_js reads (relative to CWD) and
# cd into its parent so the resolver's relative paths resolve. $1 = the
# index.js body; remaining args = "chunk-name:body" files to also create.
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

@test "resolve: follows the stub require to the code-split main chunk" {
	_make_build_tree \
		'"use strict";require("./index.chunk-CNXUb5h4.js");' \
		'index.chunk-CNXUb5h4.js:/* main process */'
	run _resolve_main_js
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.chunk-CNXUb5h4.js' ]]
}

@test "resolve: falls back to index.js on the old single-file layout" {
	_make_build_tree 'var x=1;/* whole main process, no chunk require */'
	run _resolve_main_js
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.js' ]]
}

@test "resolve: ignores non-chunk requires when falling back" {
	# electron/node requires in the stub must not be mistaken for a chunk
	_make_build_tree \
		'require("node:path");require("electron");require("./preload.js");'
	run _resolve_main_js
	[[ $status -eq 0 ]]
	[[ $output == 'app.asar.contents/.vite/build/index.js' ]]
}

@test "resolve: fails loud when the stub requires two main chunks" {
	_make_build_tree \
		'require("./index.chunk-AAAA1111.js");require("./index.chunk-BBBB2222.js");' \
		'index.chunk-AAAA1111.js:/* a */' \
		'index.chunk-BBBB2222.js:/* b */'
	run _resolve_main_js
	[[ $status -eq 1 ]]
	[[ $output == *'2 main chunks'* ]]
	[[ $output == *'per-anchor resolution'* ]]
}

@test "resolve: fails loud when the required chunk file is missing" {
	# stub names a chunk, but the bundler output doesn't contain it
	_make_build_tree \
		'require("./index.chunk-CNXUb5h4.js");'
	run _resolve_main_js
	[[ $status -eq 1 ]]
	[[ $output == *'missing'* ]]
}

@test "resolve: fails loud when index.js is absent" {
	rm -rf "$BATS_TEST_TMPDIR/app.asar.contents"
	mkdir -p "$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	cd "$BATS_TEST_TMPDIR" || return 1
	run _resolve_main_js
	[[ $status -eq 1 ]]
	[[ $output == *'No index.js'* ]]
}
