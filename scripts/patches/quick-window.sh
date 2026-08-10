#===============================================================================
# Quick-window patches: KDE-gated blur/focus workarounds for the pop-up menu
# so the main window reappears after quick-entry submit.
#
# Sourced by: build.sh
# Sourced globals: (none — each part resolves its own file via
#   _resolve_anchor_file, defined in app-asar.sh)
# Modifies globals: (none)
#
# The two parts resolve independently: on 1.26832.0 both happen to land
# in the same chunk, but part 1's setAlwaysOnTop call and part 2's
# QuickEntry submit path are separate subsystems and upstream is free to
# split them apart again.
#===============================================================================

# Quote class: 1.26832.0 swapped the minifier and re-emitted nearly every
# string literal as a backtick template, so a bare " in an anchor matches
# nothing (#820).
_QW_Q='[`"'"'"']'

patch_quick_window() {
	echo 'Patching quick window for Linux...'

	# Resolve on the full setAlwaysOnTop shape, not on "pop-up-menu"
	# alone — the bare literal also occurs in a sibling chunk that has no
	# call to rewrite.
	local index_js
	index_js=$(_resolve_anchor_file 'quick-window setAlwaysOnTop' \
		"[\$\\w]+\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*${_QW_Q}pop-up-menu${_QW_Q}\\)") \
		|| return 1

	# Extract the quick window variable name from the unique "pop-up-menu"
	# setAlwaysOnTop call, e.g.: Sa.setAlwaysOnTop(!0,`pop-up-menu`)
	local quick_var
	quick_var=$(grep -oP "[\$\\w]+(?=\\.setAlwaysOnTop\\(\\s*!0\\s*,\\s*${_QW_Q}pop-up-menu${_QW_Q}\\))" \
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
	elif grep -qP "\|\|\s*${quick_var_re}\.hide\(\)" "$index_js"; then
		sed -i -E \
			"s/\|\|\s*${quick_var_re}\.hide\(\)/||(${de_check}?(${quick_var}.blur(),${quick_var}.hide()):${quick_var}.hide())/g" \
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
	#
	# Resolved separately from part 1: the QuickEntry submit path is its
	# own subsystem and upstream may split it into another chunk.
	local submit_js
	submit_js=$(_resolve_anchor_file 'quick-entry submit' \
		'\[QuickEntry\] Creating new chat with submit_quick_entry') \
		|| return 1

	if INDEX_JS="$submit_js" node << 'QUICK_WINDOW_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Both the focus check and the window handle are captured from the call
// site itself.
//
// Earlier revisions resolved them definition-side: find
// `isWindowFocused:()=>!!X()`, then hunt for a sibling visibility helper
// near X's definition. 1.26832.0 moved that pair into a shared module,
// so the call site now sees them only as import bindings (`i.s`, `i.f`)
// whose names have nothing to do with the definitions, and the
// definitions live in a different file from the call site. A
// definition-side lookup can no longer name what the call site calls;
// the call site is the only place both are spelled the way they are
// used. Capturing there also drops two fragile lookups.
const win = String.raw`[\w$]+(?:\.[\w$]+)*`;

// Anchor on unique QuickEntry log strings to patch only the right sites.
// A second anchor, 'Navigating to existing chat', was dropped: it is
// absent from both 1.24012.11 and 1.26832.0, so it only ever produced a
// standing WARNING that trained the eye to ignore real ones.
const anchors = [
    'Creating new chat with submit_quick_entry',
];
// Sites already carrying the gate from a previous run. Counted
// separately from patchCount so a re-run over a fully patched bundle
// stays silent instead of emitting a WARNING that nothing was patched —
// there was nothing left to patch, which is success, not a miss.
let alreadyCount = 0;
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
        alreadyCount++;
        continue;
    }
    // matches: <focusCall>()||<win>.show(). Both sides are captured:
    // <focusCall> is a bare minified local (`n1`) on older builds and an
    // import binding (`i.s`) from 1.26832.0; <win> is a bare local
    // through 1.18286.0, `exports.mainWindow` from 1.19367.0, and `i.f`
    // from 1.26832.0. Capturing the whole handle keeps the .show() call
    // pointed at the real window after the rewrite.
    const showRe = new RegExp(
        `(${win})\\(\\)\\|\\|(${win})\\.show\\(\\)`
    );
    const showMatch = region.match(showRe);
    if (showMatch) {
        const oldStr = showMatch[0];
        const focusCall = showMatch[1];
        const mainWin = showMatch[2];
        // Gate the visibility check to KDE only; fall back to original
        // focus check on GNOME/other so #390 doesn't regress them (#393).
        const deCheck = '(process.env.XDG_CURRENT_DESKTOP||"")' +
            '.toLowerCase().includes("kde")';
        // Inline the visibility test from the captured handle rather
        // than calling upstream's helper, which is no longer nameable
        // from here. Upstream's version ORs in
        // `mainView?.webContents?.isFocused()`; this drops that clause,
        // so a hidden window whose webContents still reports focus now
        // gets show() called instead of skipped. That is the safe
        // direction for #390, whose whole symptom is show() being
        // skipped, and the state itself is not reachable in practice.
        const visible = '(!' + mainWin + '||' + mainWin +
            '.isDestroyed()?!1:' + mainWin + '.isVisible())';
        // Built by concatenation, never through replace(): a captured
        // handle can contain `$`, which replace() would reinterpret as a
        // substitution pattern (docs/learnings/patching-minified-js.md).
        const newStr = '(' + deCheck + '?' + visible + ':' +
            focusCall + '())||' + mainWin + '.show()';
        if (oldStr !== newStr) {
            const absIdx = anchorIdx + region.indexOf(oldStr);
            code = code.substring(0, absIdx) + newStr +
                code.substring(absIdx + oldStr.length);
            console.log('  KDE-gated ' + focusCall + '()/' + mainWin +
                '.isVisible() for show() near "' +
                anchor.substring(0, 30) + '..."');
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
} else if (alreadyCount === anchors.length) {
    console.log('  Quick entry show() calls already patched (' +
        alreadyCount + '/' + anchors.length + ')');
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
