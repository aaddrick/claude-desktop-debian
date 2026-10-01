# shellcheck shell=bash
#===============================================================================
# Linux tray icon env override: honor CLAUDE_TRAY_USE_DARK_ICON.
#
# Upstream already ships TrayIconLinux.png (dark glyph, light panels)
# and TrayIconLinux-Dark.png (light glyph, dark panels) and picks
# between them from nativeTheme.shouldUseDarkColors plus a GNOME
# desktop check — its DE detector only ever returns kde/gnome/other,
# so Cinnamon falls to "other". Cinnamon often uses a dark panel
# while GTK still reports a light colour scheme, so the black icon
# lands on a dark gray tray (#604). The launcher probes that case and
# exports CLAUDE_TRAY_USE_DARK_ICON=1; this patch threads the flag
# into the existing ternary without replacing upstream's icons.
#
# Tri-state: "1" forces TrayIconLinux-Dark.png, "0" forces
# TrayIconLinux.png (overriding the GNOME check and
# shouldUseDarkColors), anything else leaves upstream's selection
# untouched. The env read lands inside the selector, which re-runs on
# nativeTheme "updated", so the flag survives theme-change rebuilds.
#
# An anchor miss fails the build: shipping without this patch leaves
# CLAUDE_TRAY_USE_DARK_ICON inert while the docs and launcher still
# advertise it (#429 failure class, and check-claude-version auto-tags
# releases with no human in the loop). The hard fail doubles as the
# retirement tripwire for when upstream teaches its own DE detector
# about Cinnamon (filed as anthropics/claude-code#77170).
#
# Interim fix pending upstream; this is not a net-new feature.
#
# Sourced by: build.sh
# Sourced globals: (none — resolves its own file via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

patch_tray_icon_env_override() {
	echo 'Patching Linux tray icon selection (CLAUDE_TRAY_USE_DARK_ICON)...'

	# On 1.26832.0 this anchor sits in index.js itself rather than in any
	# chunk — the entry file stopped being a stub and now carries real
	# code (#820). Resolving by anchor rather than by filename is what
	# makes that a non-event.
	local index_js
	# Anchored on the adjacent icon-literal pair rather than on the
	# ternary condition: the patch rewrites the condition but re-emits
	# these two literals verbatim, so resolution still works on a re-run.
	index_js=$(_resolve_anchor_file 'tray icon literals' \
		'[`"'"'"']TrayIconLinux-Dark\.png[`"'"'"']\s*:\s*[`"'"'"']TrayIconLinux\.png[`"'"'"']') \
		|| return 1

	# Anchored on the two stable icon literals (developer strings
	# survive minification); the DE-detector and electron identifiers
	# are captured, not hardcoded — they change every release
	# (docs/learnings/patching-minified-js.md). Whitespace-tolerant so
	# the same anchor matches beautified reference bundles.
	if INDEX_JS="$index_js" node << 'TRAY_ICON_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

const flag = 'process.env.CLAUDE_TRAY_USE_DARK_ICON';

const applied = flag + '==="1"||' + flag + '!=="0"&&(';

// Is index `i` a place the tri-state can start without swallowing the
// text in front of it? The retained prefix has to END an expression, so
// its last non-whitespace token must be a punctuator that can be
// followed by a fresh one — or `return`.
//
// Allowlist, not denylist. A denylist ("the previous char isn't [\w$.]")
// looks equivalent and isn't: `await lt()` and `this.#lt()` both walk
// straight through one, and the second splices an undeclared private
// name that fails to parse. Enumerating bad prefixes only moves the
// goalposts to the next shape nobody pictured, which is the whole
// lesson of #820.
//
// The set is chosen against real bundles, not from the grammar:
//   `=`  every release so far ships `t=<callee>()===...`
//   `|`  upstream has emitted `e||AL()` since 1.30096
//   `=>` a minifier arrow-rewrite of `function(){return X?A:B}`
//   `(,;:?{[` and `return` — ordinary expression positions
// `&` is deliberately absent: an `a&&` prefix would be absorbed by the
// injected ||-chain and the guard it expresses silently lost.
//
// `|` is admitted because it is the status quo (the shape shipped in
// three releases) and excluding it would newly hard-fail those bundles
// — NOT because it composes cleanly. It does not: with `e||` retained
// in front, CLAUDE_TRAY_USE_DARK_ICON=0 reduces to `e||!1||!1` → `e`,
// so a truthy `e` still forces the dark glyph and the "0 pins the plain
// icon" contract in docs/configuration.md is not honored. That gap
// predates this guard and is the patch's reach, not its splice point:
// the anchor starts at the callee and cannot see the `e||` in front of
// it. Tracked separately from #820.
const spliceSafe = i => {
    const tail = code.slice(0, i).replace(/\s+$/, '');
    return tail === '' || /(?:[=(,;:?|{[]|=>)$/.test(tail) ||
        /(?:^|[^\w$.])return$/.test(tail);
};

// Idempotency, keyed to the injected tri-state, NOT the bare env-var
// name. Upstream report anthropics/claude-code#77170 advertises this
// variable, so upstream could ship its own (weaker, e.g. truthy-only)
// read of the same name — the name alone matching would silently skip
// the patch while the docs still promise "0" forces the plain icon. The
// expression prefix is identifier-free and cannot occur upstream; if
// upstream adopts the var AND the ternary anchor changed, the exactly-1
// check below hard-fails and a human decides — the right outcome in
// every branch.
//
// Presence is not enough either. A mispatched bundle carries this exact
// expression with an identifier glued to its front
// (p.process.env.CLAUDE_...), and that text CONTAINS `applied`, so the
// substring check this replaces reported "already applied" on the
// second pass and shipped the damage (#820). Every occurrence has to
// start an expression; one that doesn't means a prior build spliced
// mid-expression, which is a corrupt bundle rather than a patched one.
const seen = [];
for (let i = code.indexOf(applied); i !== -1;
        i = code.indexOf(applied, i + 1)) {
    seen.push(i);
}
if (seen.length) {
    if (seen.every(spliceSafe)) {
        console.log('  Tray icon env override already applied');
        process.exit(0);
    }
    console.log('  WARNING: the injected tri-state is present but does ' +
        'not start an expression (e.g. p.' + flag + ') — a prior build ' +
        'spliced it mid-expression, so this bundle is corrupt. ' +
        'Re-extract a pristine asar and re-run (#820)');
    process.exit(1);
}

// The sole Linux tray selection ternary (1.19367.0 minified):
//   oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors
//     ?"TrayIconLinux-Dark.png":"TrayIconLinux.png"
// The detector callee tolerates the bundler indirect-call shape
// ((0,i.oPe)()) AND a plain property chain (p.lt()), the same latitude
// the electron handle has always had — both are real minifier artifacts
// post-code-split (the quick-window patch hit the exports.mainWindow
// rename the same way). The asymmetry was the #820 mispatch: against
// 1.26832.0's p.lt() the match started at `lt`, the `p.` stayed in the
// retained prefix, and the splice below produced
// p.process.env.CLAUDE_TRAY_USE_DARK_ICON — a TypeError that killed the
// tray on every start, swallowed by the global Sentry handler.
// q(): match a literal under any delimiter. 1.26832.0 swapped the
// minifier and re-emitted nearly every string as a backtick template, so
// a bare " here matches nothing (#820).
const q = s => '[`"\']' + s + '[`"\']';
const ternRe = new RegExp(
    String.raw`((?:\(0,\s*[\w$]+(?:\.[\w$]+)*\)|[\w$]+(?:\.[\w$]+)*))` +
    `\\(\\)\\s*===\\s*${q('gnome')}\\s*\\|\\|\\s*` +
    String.raw`([\w$]+(?:\.[\w$]+)*)\.nativeTheme\.shouldUseDarkColors` +
    `\\s*\\?\\s*${q('TrayIconLinux-Dark\\.png')}` +
    `\\s*:\\s*${q('TrayIconLinux\\.png')}`,
    'g');
const matches = [...code.matchAll(ternRe)];
if (matches.length !== 1) {
    console.log('  WARNING: expected exactly 1 TrayIconLinux ternary, ' +
        'found ' + matches.length);
    process.exit(1);
}

// Tri-state: "1" wins outright; anything but "0" falls through to
// upstream's condition; "0" makes the whole condition false. Built by
// concatenation so no `$` ever sits in a replace() DSL position.
const m = matches[0];

// Splice sanity. The exactly-1 assertion above counts matches; it says
// nothing about where the match STARTS. Whenever the capture cannot
// express the real callee — `p?.lt()`, `a[0].lt()`, `await lt()`,
// `this.#lt()` — the engine matches the TAIL of it and everything to
// the left survives in the retained prefix, which is how #820 shipped
// p.process.env.CLAUDE_TRAY_USE_DARK_ICON and a dead tray on two
// releases. spliceSafe is the same allowlist the idempotency check
// uses; a prefix that doesn't end an expression means the callee shape
// drifted past the capture, so stop the build and let a human
// re-derive rather than corrupt the bundle.
if (!spliceSafe(m.index)) {
    console.log('  WARNING: TrayIconLinux ternary matched mid-expression' +
        ' (prefix ends "' + code.slice(0, m.index).slice(-16) + '") — ' +
        'the callee shape drifted past what the capture expresses and ' +
        'splicing here would corrupt the bundle. Widen the callee ' +
        'capture in scripts/patches/tray-icon-selection.sh (#820)');
    process.exit(1);
}

const deCall = m[1];
const electron = m[2];
const cond = applied +
    deCall + '()==="gnome"||' +
    electron + '.nativeTheme.shouldUseDarkColors)';
const replacement =
    cond + '?"TrayIconLinux-Dark.png":"TrayIconLinux.png"';
code = code.substring(0, m.index) + replacement +
    code.substring(m.index + m[0].length);
fs.writeFileSync(indexJs, code);
console.log('  Tray icon ternary (' + deCall + '/' + electron +
    ') now honors CLAUDE_TRAY_USE_DARK_ICON (1=dark-panel, 0=plain)');
TRAY_ICON_PATCH
	then
		echo 'Tray icon env override applied'
	else
		echo 'ERROR: tray icon env-override patch failed. Without it,' \
			'CLAUDE_TRAY_USE_DARK_ICON is inert and Cinnamon dark panels' \
			'keep the invisible black tray glyph (#604). Update the' \
			'anchor in scripts/patches/tray-icon-selection.sh against' \
			'the new bundle — or, if upstream taught its DE detector' \
			'about Cinnamon (anthropics/claude-code#77170; local record:' \
			'docs/upstream-reports/604-tray-panel-theme.md), retire the' \
			'patch. To unblock a security-bearing release while that' \
			'gets sorted, dropping patch_tray_icon_env_override from' \
			'active_patches is a legitimate stopgap — file the follow-up' \
			'issue.' >&2
		return 1
	fi
	echo '##############################################################'
}
