# shellcheck shell=bash disable=SC2154
# SC2154: project_root is exported by build.sh before this file is
# sourced — the same pattern that scripts/patches/cowork.sh uses. The
# CI shellcheck job runs `shellcheck -x` which resolves the sourced
# global; the local pre-push hook runs plain shellcheck and would
# otherwise flag it.
#===============================================================================
# BuddyBleTransport stub — neutralise the Windows companion (Bluetooth
# Low Energy) transport that has no handler on Linux.
#
# Symptom without this patch (Claude 1.15962.1, wrapper 2.0.22):
#   * "$eipc_message$_…_claude.buddy_$_BuddyBleTransport_$_reportState:
#     Error: No handler registered" from ipcRenderer.invoke in the
#     mainView preload.
#   * MaxListenersExceededWarning on a "change" event from the updater
#     EventEmitter, one listener over the default cap of 10.
#   * Main-process V8 heap climbs to ~2 GB → OOM (exit 133) during
#     sustained Cowork/Dispatch use.
#
# This is a stub — do NOT implement BLE. It does two things, both
# anchored on stable string literals:
#
#   1. Install a global `ipcMain.handle` no-op fallback for the three
#      $_claude.buddy_$_BuddyBleTransport_$_* channels (rx, reportState,
#      log) as an IIFE prepended to the main-process bundle. Electron's
#      invoke dispatch falls through to ipcMain.handle when the per-
#      webContents `webContents.ipc.handle` scope has no entry, so a
#      global no-op catches every window (including the 3P config /
#      device-code windows that share mainView.js as preload but never
#      reach the BLE bridge init path).
#
#   2. Harden the sole `qa.on("change", a)` site inside the auto-updater
#      `onStateChange` callback with a `removeListener`-before-add. That
#      callback is invoked by the checker's tick loop; without the
#      remove-before-add, re-invocations accumulate identical listeners
#      on the same "change" event on the `qa` emitter. This is a
#      register-once-effective fix at the source; it is NOT a
#      setMaxListeners bump.
#
# The Dispatch relay/websocket path is NOT touched — only the local
# companion transport that is dead on Linux.
#
# Sourced by: build.sh (via scripts/patches/app-asar.sh)
# Sourced globals: project_root
#===============================================================================

patch_buddy_ble_stub() {
	echo 'Patching BuddyBleTransport stub for Linux...'
	local index_js='app.asar.contents/.vite/build/index.js'

	if [[ ! -f $index_js ]]; then
		echo "FATAL: ${index_js} not found" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if ! INDEX_JS="$index_js" node << 'BUDDY_BLE_STUB_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// The eIPC channel prefix. This UUID is a stable module-instance salt
// picked at bundle build time; it is present as a literal in every
// upstream Buddy channel string and does NOT depend on minifier
// churn. Anchor on the full channel names — never on _Fn or I9t.
const channelPrefix =
    '$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61' +
    '_$_claude.buddy_$_BuddyBleTransport_$_';
const buddyMethods = ['rx', 'reportState', 'log'];

// Sanity check: the channel literals must exist in the bundle at
// least once each (the per-webContents handler registration site).
// If any are missing, upstream restructured the buddy IPC surface and
// this patch is stale — fail loud so CI catches it, don't ship a
// bundle that silently keeps leaking.
for (const m of buddyMethods) {
    if (!code.includes(channelPrefix + m)) {
        console.error(
            'FATAL: buddy channel literal missing: ' +
            channelPrefix + m
        );
        console.error(
            '  Upstream may have removed or renamed the ' +
            'BuddyBleTransport IPC surface; re-derive anchors.'
        );
        process.exit(1);
    }
}

// ============================================================
// Patch 1: global ipcMain fallback for BuddyBleTransport channels
//
// Prepend a self-contained IIFE right after the "use strict"
// pragma. Uses require('electron').ipcMain directly so it does
// not depend on any minified module-binding name.
//
// Electron's ipcRenderer.invoke dispatch order is:
//   1. webContents.ipc.handle(<channel>) on the sender's webContents
//   2. ipcMain.handle(<channel>)          — global fallback
// The per-webContents handlers ARE registered (see _Fn(A) callers in
// eBe), but they only cover the webContents attached via the eBe
// path. Any other window whose preload invokes reportState (mainView
// preload's un() runs unconditionally at document-start) falls
// through to ipcMain — where without this patch, no handler is
// registered and Electron logs the "No handler registered" error.
//
// Wrapping each ipcMain.handle in try/catch swallows the "second
// handler for channel" throw that Electron raises if the fallback is
// somehow re-registered (extra insurance for hot-reload / dynamic
// eval paths).
// ============================================================
const stubMarker = '/*__CLAUDE_LINUX_BUDDY_BLE_STUB_v1__*/';
if (code.includes(stubMarker)) {
    console.log('  BuddyBleTransport ipcMain fallback already applied');
} else {
    const iife =
        stubMarker +
        '(function(){try{' +
        'var _e=require("electron");' +
        'if(!_e||!_e.ipcMain)return;' +
        'var _p=' + JSON.stringify(channelPrefix) + ';' +
        'var _m=' + JSON.stringify(buddyMethods) + ';' +
        'for(var _i=0;_i<_m.length;_i++){' +
        'try{_e.ipcMain.handle(_p+_m[_i],function(){});}catch(_){}' +
        '}' +
        '}catch(_){}})();';

    // Preserve any leading "use strict" directive at position 0 —
    // strict mode is only recognised as the first statement. Inject
    // right after the pragma if present, else at the very top.
    const useStrictRe = /^("use strict";|'use strict';)/;
    const usm = code.match(useStrictRe);
    if (usm) {
        code = usm[0] + iife + code.slice(usm[0].length);
    } else {
        code = iife + code;
    }
    console.log('  Injected BuddyBleTransport ipcMain fallback IIFE');
}

// ============================================================
// Patch 2: remove-before-add on the auto-updater onStateChange site
//
// The upstream shape (beautified):
//   onStateChange: (a) => {
//     qa.on("change", a);
//   },
// The `qa` name is minified and moves; the site is uniquely
// identified by the KEY name `onStateChange:` (an object-property
// key that survives minification) plus the followed `.on("change",
// PARAM)` on the SAME parameter passed in. That pair captures both
// the emitter variable and the parameter name so the injected
// removeListener uses the right names.
//
// Beautified/minified differences:
//   minified:   onStateChange:a=>{qa.on("change",a)}
//   beautified: onStateChange: (a) => { qa.on("change", a); }
// Prettier wraps a single-arg arrow parameter in parens; the
// minifier drops them. The regex tolerates BOTH shapes and
// whitespace between all tokens.
// ============================================================
const stateRe =
    /(onStateChange\s*:\s*(?:\(\s*([\w$]+)\s*\)|([\w$]+))\s*=>\s*\{\s*)([\w$]+)(\.on\(\s*"change"\s*,\s*(?:\2|\3)\s*\))/;
const stateMatch = code.match(stateRe);
const leakGuardMarker = '/*__CLAUDE_LINUX_QA_ONCHANGE_GUARD_v1__*/';
if (code.includes(leakGuardMarker)) {
    console.log('  onStateChange remove-before-add guard already applied');
} else if (!stateMatch) {
    // Non-fatal: the "No handler" error goes away with Patch 1 alone;
    // the listener-leak fix is defensive. Warn loudly so a future
    // upstream refactor surfaces here without silent breakage.
    console.log(
        '  WARNING: onStateChange qa.on("change") site not found — ' +
        'listener leak fix not applied (see PR / #buddy-ble-stub)'
    );
} else {
    // Verify uniqueness. onStateChange is used elsewhere as a KEY in
    // other objects (unrelated stores), but the regex above ties
    // `KEY(PARAM)=>{EMITTER.on("change",PARAM)}` — that shape is
    // expected exactly once, at the auto-update wiring site. More
    // than one match would mean an ambiguous rewrite; refuse.
    const globalRe = new RegExp(stateRe.source, 'g');
    const all = code.match(globalRe);
    if (all && all.length !== 1) {
        console.error(
            'FATAL: onStateChange qa.on("change") pattern matched ' +
            all.length + ' times (expected 1). Anchor is ambiguous.'
        );
        process.exit(1);
    }

    // Capture groups (see stateRe above):
    //   1 head        — "onStateChange:(a)=>{" or "onStateChange:a=>{"
    //   2 paramParen  — arrow param inside parens, or undefined
    //   3 paramBare   — arrow param without parens, or undefined
    //   4 emitter     — the minified emitter var (e.g. qa)
    //   5 tail        — .on("change", <param>)
    // Either paramParen OR paramBare will be defined, never both.
    const [whole, head, paramParen, paramBare, emitter, tail] = stateMatch;
    const param = paramParen || paramBare;
    // Replacement: EMITTER.removeListener("change",PARAM); EMITTER.on(...)
    const replacement =
        head +
        leakGuardMarker +
        emitter + '.removeListener("change",' + param + ');' +
        emitter + tail;
    code = code.replace(whole, replacement);
    console.log(
        '  Patched onStateChange to removeListener("change", ...) ' +
        'before add (emitter=' + emitter + ', param=' + param + ')'
    );

    // Verify the guard actually landed — a silent no-op replace
    // would leave the leak in place.
    if (!code.includes(leakGuardMarker)) {
        console.error(
            'FATAL: leak-guard marker missing after replacement.'
        );
        process.exit(1);
    }
}

fs.writeFileSync(indexJs, code);
console.log('  BuddyBleTransport stub patch complete');
BUDDY_BLE_STUB_PATCH
	then
		echo 'FATAL: BuddyBleTransport stub patch failed' >&2
		echo 'The main process will spam "No handler registered" and' \
			'may OOM during Cowork/Dispatch use without this patch.' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}
