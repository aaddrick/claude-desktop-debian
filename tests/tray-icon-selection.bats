#!/usr/bin/env bats
#
# patch_tray_icon_env_override: threads CLAUDE_TRAY_USE_DARK_ICON into
# the upstream TrayIconLinux ternary (#604).
#
# The near-miss fixtures (no-GNOME-half, Win32-ico lookalike, duplicate
# site, optional-chaining callee) sit one edit away from the anchor on
# purpose: loosening the regex, dropping the exactly-1 assertion or
# dropping the pre-splice character guard turns their expected hard-fail
# into a pass and goes red
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

	# 1.26832.0 minified bytes: the bundler swap re-emitted every string
	# literal as a backtick template, which took this anchor to zero
	# matches (#820). Callee reduced to the bare `lt()` here so this
	# fixture isolates the quote class; the pristine bundle's chain
	# callee is covered by upstream_ternary_chain below.
	upstream_ternary_bt='case`png`:t=lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'

	# Real pristine 1.26832.0 minified bytes, callee chain intact. This
	# is the shape that mispatched: the callee capture took only bare
	# identifiers and the (0,x.y) indirect form, so the match started at
	# `lt`, the `p.` survived in the retained prefix, and the splice
	# emitted p.process.env.CLAUDE_TRAY_USE_DARK_ICON — a TypeError on
	# every tray rebuild, so the tray never registered (#820).
	upstream_ternary_chain='case`png`:t=p.lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'

	# The full post-patch expression for the chain shape. The leading
	# `t=` is the load-bearing part: it is what pins the injected
	# tri-state to the START of the callee. Assert only from
	# `process.env` onward and the mispatched `t=p.process.env...`
	# passes.
	patched_expr_chain='t=process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(p.lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'

	# Shipped bytes from the mispatched v3.2.2+claude1.26832.0 build
	# (reported from a Fedora rpm main.log). The injected tri-state is
	# present but glued to `p.`, and the substring idempotency check read
	# that as "already applied". The `case` label keeps 1.26832.0's
	# backtick because the patch rewrites only from the callee onward;
	# the double quotes downstream of it are the patch's own re-emission.
	mispatched_ternary='case`png`:t=p.process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(lt()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
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

@test "tray icon override: property-chain callee keeps its prefix" {
	# The gap that let #820 ship: the suite covered the (0,x.y)()
	# indirect form but never the plain x.y() chain, so it stayed green
	# through two broken releases. Narrow the callee capture back to
	# bare identifiers and this goes red on the leading `t=`.
	_make_chunk "$upstream_ternary_chain"
	patch_tray_icon_env_override
	grep -qF "$patched_expr_chain" \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: chain-callee shape is idempotent" {
	_make_chunk "$upstream_ternary_chain"
	patch_tray_icon_env_override
	local chunk="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	chunk+='/index.chunk-test.js'
	cp "$chunk" "$BATS_TEST_TMPDIR/first-run.js"
	run patch_tray_icon_env_override
	[[ $status -eq 0 ]]
	[[ $output == *'already applied'* ]]
	cmp "$chunk" "$BATS_TEST_TMPDIR/first-run.js"
}

_assert_chunk_untouched() {
	run grep -qF 'CLAUDE_TRAY_USE_DARK_ICON' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
	[[ $status -ne 0 ]]
}

@test "tray icon override: near-miss optional-chaining callee fails" {
	# One edit from the anchor, and a shape upstream can plausibly emit
	# now that the bundler preserves optional chaining. The callee
	# capture cannot express `p?.lt`, so the engine matches from `lt`
	# and the splice would glue the tri-state onto the retained `p?.`.
	# The pre-splice assertion is the only thing that catches this —
	# drop it and the patch exits 0 having corrupted the chunk.
	_make_chunk \
		'case`png`:t=p?.lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray icon override: near-miss await-prefixed callee fails" {
	# Why the guard is an allowlist of what may PRECEDE the match rather
	# than a denylist of identifier characters: the char before `lt` here
	# is a space, so "not [\w$.]" waves it through and the splice moves
	# the await onto the env read (`t=await process.env...`), silently
	# dropping it from the detector call. Loosen the guard to a denylist
	# and this goes green-corrupt.
	_make_chunk \
		'case`png`:t=await lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray icon override: near-miss private-name callee fails" {
	# The worst case a denylist misses: `#` is not an identifier char, so
	# the splice would emit `this.#process.env.CLAUDE_...` — an
	# undeclared private name, i.e. a SyntaxError that takes the whole
	# main chunk out rather than just the tray.
	_make_chunk \
		'case`png`:t=this.#lt()===`gnome`||R.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;break'
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'matched mid-expression'* ]]
	_assert_chunk_untouched
}

@test "tray icon override: an upstream || prefix is still accepted" {
	# The counterweight to the near-misses above: an allowlist can be
	# tightened into a false hard-fail as easily as a denylist can be
	# loosened into a corruption. `e||AL()` is what upstream emitted
	# from 1.30096 through 1.32885.1, so `|` stays on the list and the
	# retained prefix comes through verbatim. Drop `|` and this reds.
	#
	# This pins the SPLICE, not the semantics. With `e||` retained,
	# CLAUDE_TRAY_USE_DARK_ICON=0 reduces to `e||!1||!1` → `e`, so a
	# truthy `e` still forces the dark glyph. That is a pre-existing
	# limit of the anchor's reach (it starts at the callee and cannot
	# see the `e||`), not something the splice guard introduces.
	_make_chunk \
		'case"png":t=e||AL()==="gnome"||R.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";break'
	patch_tray_icon_env_override
	grep -qF 't=e||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(AL()==="gnome"||R.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: a bare return prefix patches" {
	# The only allowlist entry nothing else exercises. Every other
	# fixture sits behind `=`, `|` or `=>`; drop `return` from
	# spliceSafe and this is the single case that reds.
	_make_chunk \
		'case"png":return ek()==="gnome"||a.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'
	patch_tray_icon_env_override
	grep -qF 'return process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(ek()==="gnome"||a.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: the shipped 2.2553.1 form patches verbatim" {
	# Byte-fidelity, not extra coverage — it reds under the same
	# mutation as the `t=e||` case above (drop `|` from spliceSafe) and
	# under no other. Kept because every other fixture paraphrases
	# upstream, and `patching-minified-js.md` is explicit that a regex
	# verified against a paraphrase is not verified. This is what the
	# installed 2.2553.1 main chunk actually carries, read out of the
	# .deb rather than a beautified copy (#876).
	_make_chunk \
		'case"png":return e||ek()==="gnome"||a.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"'
	patch_tray_icon_env_override
	grep -qF 'return e||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"||process.env.CLAUDE_TRAY_USE_DARK_ICON!=="0"&&(ek()==="gnome"||a.nativeTheme.shouldUseDarkColors)?"TrayIconLinux-Dark.png":"TrayIconLinux.png"' \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: =0 loses to the rebuild flag at runtime" {
	# Every other case in this file greps the patched TEXT. This one
	# runs it, because the defect in #876 is a truth table, not a
	# splice: with upstream's `e||` retained in front, =0 reduces the
	# whole condition to `e`.
	#
	# `e` is upstream's tray REBUILD flag, not a theme signal — the
	# caller passes !1 normally and !0 only when it retries after a
	# caught tray-creation exception. So =0 works on every normal
	# launch and is silently ignored on the rebuild, which is the
	# narrow claim #876 makes.
	#
	# This asserts the behavior that ships today, not the behavior
	# docs/configuration.md promises. When #876 is fixed the second
	# value flips to TrayIconLinux.png and this case reds — that is
	# the point: whoever fixes it is sent to the doc that still says
	# =0 pins the plain glyph unconditionally.
	_make_chunk \
		'function icon(e){switch("png"){case"png":return e||ek()==="gnome"||a.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"}}'
	patch_tray_icon_env_override

	# Stubs pick the branch the env var is supposed to own: not GNOME,
	# not a dark GTK scheme, so upstream's own condition is false and
	# only the flag and `e` can decide.
	cat > "$BATS_TEST_TMPDIR/run.js" <<-'EOF'
		const fs = require('fs');
		const path = require('path');
		const src = fs.readFileSync(process.argv[2], 'utf8');
		const prelude = 'const ek=()=>"kde";' +
			'const a={nativeTheme:{shouldUseDarkColors:false}};';
		const mod = path.join(path.dirname(process.argv[2]), 'mod.js');
		fs.writeFileSync(mod, prelude + src + ';module.exports=icon;');
		const icon = require(mod);
		console.log(icon(false), icon(true));
	EOF

	run env CLAUDE_TRAY_USE_DARK_ICON=0 node \
		"$BATS_TEST_TMPDIR/run.js" \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
	[[ $status -eq 0 ]]
	# Normal launch honors =0. Rebuild does not. Second value is #876.
	[[ $output == 'TrayIconLinux.png TrayIconLinux-Dark.png' ]]
}

@test "tray icon override: an arrow-body ternary still patches" {
	# The other way the allowlist can be too tight: a minifier rewrite of
	# function(){return X?A:B} into ()=>X?A:B puts `=>` in front of the
	# match, which is an ordinary expression position. Drop `=>` from the
	# allowlist and this reds with a spurious build failure.
	_make_chunk \
		'let f=()=>oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png";'
	patch_tray_icon_env_override
	grep -qF "=>$patched_expr" \
		"$BATS_TEST_TMPDIR/app.asar.contents/.vite/build/index.chunk-test.js"
}

@test "tray icon override: an already-mispatched bundle fails loudly" {
	# A bundle carrying the tri-state glued to an identifier is corrupt,
	# not patched. The substring idempotency check could not tell the
	# two apart — `applied` is a substring of `p.` + `applied` — so a
	# second pass logged "already applied" and shipped the damage.
	# Restore the substring check and this goes red on both pins.
	_make_chunk "$mispatched_ternary"
	run patch_tray_icon_env_override
	[[ $status -eq 1 ]]
	[[ $output == *'bundle is corrupt'* ]]
}
