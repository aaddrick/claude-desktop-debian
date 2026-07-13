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
# Sourced globals: main_js (optional — the resolved main chunk; set by
#   patch_app_asar. Falls back to .vite/build/index.js for older bundles.)
# Modifies globals: (none)
#===============================================================================

patch_tray_icon_env_override() {
	echo 'Patching Linux tray icon selection (CLAUDE_TRAY_USE_DARK_ICON)...'
	local index_js="${main_js:-app.asar.contents/.vite/build/index.js}"

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

// Idempotency: keyed to the injected tri-state expression, NOT the
// bare env-var name. Upstream report anthropics/claude-code#77170
// advertises this variable, so upstream could ship its own (weaker,
// e.g. truthy-only) read of the same name — the name alone matching
// would silently skip the patch while the docs still promise "0"
// forces the plain icon. The expression prefix is identifier-free
// and cannot occur upstream; if upstream adopts the var AND the
// ternary anchor changed, the exactly-1 check below hard-fails and a
// human decides — the right outcome in every branch.
const applied = flag + '==="1"||' + flag + '!=="0"&&(';
if (code.includes(applied)) {
    console.log('  Tray icon env override already applied');
    process.exit(0);
}

// The sole Linux tray selection ternary (1.19367.0 minified):
//   oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors
//     ?"TrayIconLinux-Dark.png":"TrayIconLinux.png"
// The detector callee tolerates the bundler indirect-call shape
// ((0,i.oPe)()) and the electron handle tolerates a property chain —
// both are real minifier artifacts post-code-split (the quick-window
// patch hit the exports.mainWindow rename the same way).
const ternRe = new RegExp(
    String.raw`((?:\(0,\s*[\w$]+(?:\.[\w$]+)*\)|[\w$]+))` +
    String.raw`\(\)\s*===\s*"gnome"\s*\|\|\s*` +
    String.raw`([\w$]+(?:\.[\w$]+)*)\.nativeTheme\.shouldUseDarkColors` +
    String.raw`\s*\?\s*"TrayIconLinux-Dark\.png"\s*:\s*"TrayIconLinux\.png"`,
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
