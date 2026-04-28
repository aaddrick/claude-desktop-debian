#===============================================================================
# Quick-window patches: KDE-gated blur/focus workarounds for the pop-up menu
# so the main window reappears after quick-entry submit.
#
# Sourced by: build.sh
# Sourced globals: (none — all context is captured from index.js at runtime)
# Modifies globals: (none)
#===============================================================================

patch_quick_window() {
	echo 'Patching quick window for Linux...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Extract the quick window variable name from the unique "pop-up-menu"
	# setAlwaysOnTop call, e.g.: Sa.setAlwaysOnTop(!0,"pop-up-menu")
	local quick_var
	quick_var=$(grep -oP '\w+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))' \
		"$index_js" | head -1)
	if [[ -z $quick_var ]]; then
		echo 'WARNING: Could not extract quick window variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found quick window variable: $quick_var"

	local quick_var_re="${quick_var//\$/\\$}"

	# Part 1: Add blur() before hide() on the quick window so that
	# isFocused() returns false after hiding (Electron Linux bug on KDE).
	# The hide call sits after || (e.g. GUARD()||VAR.hide()), so both
	# calls must be wrapped in parens to preserve short-circuit semantics.
	# Gated to KDE only: on GNOME/Ubuntu the blur() regresses quick entry
	# (see #393), and the focus-stale bug doesn't manifest there.
	local de_check='(process.env.XDG_CURRENT_DESKTOP||"")'
	de_check+='.toLowerCase().includes("kde")'
	if grep -qF "${quick_var}.blur(),${quick_var}.hide()" "$index_js"; then
		echo '  Quick window blur already patched'
	elif grep -qP "\|\|${quick_var_re}\.hide\(\)" "$index_js"; then
		sed -i \
			"s/||${quick_var_re}\.hide()/||(${de_check}?(${quick_var}.blur(),${quick_var}.hide()):${quick_var}.hide())/g" \
			"$index_js"
		echo '  Added KDE-gated blur() before hide() on quick window'
	else
		echo '  WARNING: Could not find quick window hide() call'
	fi

	# Part 2: Fix main window not appearing after quick entry submit.
	# On KDE, isFocused() can return stale true after hiding, causing
	# FOCUS_CHECK()||Lt.show() to skip the show. Gate the visibility-check
	# replacement to KDE only: on GNOME, the original focus check works
	# and replacing it regresses quick entry (see #393).
	if INDEX_JS="$index_js" node << 'QUICK_WINDOW_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Find the minified isWindowFocused function via its named property
// export: isWindowFocused: () => !!NAME()
const focusedPropRe = /isWindowFocused:\s*\(\)\s*=>\s*!!(\w+)\(\)/;
const focusedMatch = code.match(focusedPropRe);
if (!focusedMatch) {
    console.log('  WARNING: Could not find isWindowFocused function');
    process.exit(0);
}
const focusFn = focusedMatch[1];
console.log('  Found focus check function: ' + focusFn);

// Find the sibling isVisible function defined near the focus function.
// Tolerate the optional `var <name>(,<name>)*;` declaration the
// minifier hoists when the function body uses optional chaining
// (1.3883.0+ shape: `function aZA(){var e;return!Qt...}`). Older
// builds don't declare anything before `return!`. The non-capturing
// group keeps the prefix optional in either case.
const focusFnIdx = code.indexOf('function ' + focusFn + '(');
const nearbyCode = code.substring(focusFnIdx, focusFnIdx + 500);
const visFnRe = /function (\w+)\(\)\{(?:var \w+(?:,\w+)*;)?return!\w+\|\|\w+\.isDestroyed\(\)\?!1:\w+\.isVisible\(\)/;
const visMatch = nearbyCode.match(visFnRe);
if (!visMatch) {
    console.log('  WARNING: Could not find visibility function near ' +
        focusFn);
    process.exit(0);
}
const visFn = visMatch[1];
console.log('  Found visibility check function: ' + visFn);

// Anchor on unique QuickEntry log strings to patch only the right sites
const anchors = [
    'Navigating to existing chat',
    'Creating new chat with submit_quick_entry',
];
const escapeRegExp = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
for (const anchor of anchors) {
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx === -1) {
        console.log('  WARNING: anchor not found: ' + anchor);
        continue;
    }
    // Search region after anchor (1500 chars covers promise chains)
    const region = code.substring(anchorIdx, anchorIdx + 1500);
    // Idempotency: if region already contains the DE gate, skip
    if (region.indexOf('XDG_CURRENT_DESKTOP') !== -1) {
        console.log('  Quick entry show() already patched near "' +
            anchor.substring(0, 30) + '..."');
        continue;
    }
    // matches: <focusFn>()||(someVar).show()
    const showRe = new RegExp(
        escapeRegExp(focusFn) + String.raw`\(\)\|\|(\w+)\.show\(\)`
    );
    const showMatch = region.match(showRe);
    if (showMatch) {
        const oldStr = showMatch[0];
        const mainWin = showMatch[1];
        // Gate the visibility check to KDE only; fall back to original
        // focus check on GNOME/other so #390 doesn't regress them (#393).
        const deCheck = '(process.env.XDG_CURRENT_DESKTOP||"")' +
            '.toLowerCase().includes("kde")';
        const newStr = '(' + deCheck + '?' + visFn + '():' +
            focusFn + '())||' + mainWin + '.show()';
        if (oldStr !== newStr) {
            const absIdx = anchorIdx + region.indexOf(oldStr);
            code = code.substring(0, absIdx) + newStr +
                code.substring(absIdx + oldStr.length);
            console.log('  KDE-gated ' + focusFn + '()/' + visFn +
                '() for show() near "' + anchor.substring(0, 30) + '..."');
            patchCount++;
        }
    } else {
        console.log('  WARNING: show() pattern not found near "' +
            anchor + '"');
    }
}

if (patchCount > 0) {
    fs.writeFileSync(indexJs, code);
    console.log('  Patched ' + patchCount +
        ' quick entry show() calls to use visibility check');
} else {
    console.log('  WARNING: No quick entry show() calls patched');
}
QUICK_WINDOW_PATCH
	then
		echo 'Quick window patches applied'
	else
		echo 'WARNING: Quick window show patch failed' >&2
	fi
	echo '##############################################################'
}
