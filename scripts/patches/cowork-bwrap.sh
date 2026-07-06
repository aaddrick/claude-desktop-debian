# shellcheck shell=bash
#===============================================================================
# Cowork bwrap fallback — opt-in, runtime-gated on COWORK_VM_BACKEND=bwrap.
#
# The official client runs Cowork in a KVM microVM: its yukonSilver
# evaluator demands /dev/kvm + /dev/vhost-vsock, and on success it
# spawns a bundled native helper (`cowork-linux-helper -socket <path>`)
# that owns QEMU. Hosts without KVM/vsock — notably ChromeOS Crostini,
# whose Termina kernel blocks vhost_vsock outright (#772) — can never
# satisfy that gate, and upstream's own "install QEMU" hint can't fix a
# kernel-level block.
#
# This patch reinstates the pre-3.0.0 bubblewrap backend as an opt-in
# path. Every injected branch is gated on BOTH process.platform==="linux"
# AND process.env.COWORK_VM_BACKEND==="bwrap", so on an unflagged launch
# every injected branch evaluates false and the official code path runs
# unchanged — nothing changes for the KVM majority. When flagged:
#
#   A (evaluator)   — report yukonSilver "supported" so the Cowork tab
#                     un-grays and startVM's gate opens.
#   B (spawn swap)  — spawn `node cowork-vm-service.js -socket <path>`
#                     (system node; the official binary's RunAsNode fuse
#                     is off so it can't run the daemon itself) in place
#                     of the native helper. The daemon speaks the helper
#                     socket protocol (scripts/cowork-fallback/PROTOCOL.md)
#                     backed by bubblewrap instead of QEMU.
#   C (download)    — suppress the multi-GB VM-image download the bwrap
#                     backend has no use for (foreground + warm).
#
# A and B are load-bearing: an anchor miss fails the build (shipping
# without them silently reverts the flag to a broken state). C is
# best-effort — a miss only wastes bandwidth, so it warns.
#
# The daemon ships in resources/ (next to app.asar), NOT inside the asar
# or app.asar.unpacked: the repack invariant requires the unpacked-file
# set to match upstream, and child_process can't exec from inside an
# asar. The launcher exports COWORK_NODE_PATH (detected system node) and
# only wires all this up when the user sets COWORK_VM_BACKEND=bwrap.
#
# Sourced by: build.sh
# Sourced globals: (none — identifiers are captured from index.js)
# Modifies globals: (none)
#===============================================================================

patch_cowork_bwrap() {
	echo 'Patching Cowork bwrap fallback (opt-in COWORK_VM_BACKEND=bwrap)...'
	local index_js='app.asar.contents/.vite/build/index.js'

	if INDEX_JS="$index_js" node << 'COWORK_BWRAP_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// The runtime gate shared by every injected branch. Unflagged launches
// never enter any of them, so the official path ships unchanged.
const GATE =
    'process.platform==="linux"&&process.env.COWORK_VM_BACKEND==="bwrap"';

let loadBearingFailed = false;

// ---------------------------------------------------------------------
// Patch A: yukonSilver evaluator — report "supported" when flagged.
//
// The Linux support computer is reached through a platform-dispatch
// wrapper whose whole body is `return process.platform,Cen()` (the
// `process.platform,` is a discarded comma-expression left by upstream
// minification — a stable, unique anchor). Injecting a flagged early
// return here covers BOTH consumers of the evaluator: the renderer's
// Cowork-tab visibility and startVM's execution gate.
// ---------------------------------------------------------------------
const evalRe =
    /function\s+([\w$]+)\(\)\{return process\.platform,([\w$]+)\(\)\}/;
if (new RegExp('return\\{status:"supported"\\};return process\\.platform,')
        .test(code)) {
    console.log('  A: evaluator already gated (supported when flagged)');
} else {
    const m = code.match(evalRe);
    if (m) {
        const replacement = 'function ' + m[1] + '(){if(' + GATE +
            ')return{status:"supported"};return process.platform,' +
            m[2] + '()}';
        code = code.replace(evalRe, replacement);
        console.log('  A: gated yukonSilver evaluator -> supported ' +
            'when flagged (' + m[1] + '/' + m[2] + ')');
    } else {
        console.log('  A: FATAL — yukonSilver platform-dispatch anchor ' +
            '(function X(){return process.platform,Y()}) not found');
        loadBearingFailed = true;
    }
}

// ---------------------------------------------------------------------
// Patch B: helper spawn swap.
//
// Official: IE.spawn(A,["-socket",Vie()],{stdio:["pipe","pipe","pipe"]})
//   A    = native helper path (kMt(), resources/cowork-linux-helper)
//   Vie  = $XDG_RUNTIME_DIR/claude-cowork-vm.sock
// When flagged, spawn the Node daemon instead: system node (from
// COWORK_NODE_PATH, exported by the launcher) running the daemon shipped
// at resources/cowork-vm-service.js, with the same -socket argv appended.
// The client's restart-backoff wraps this call, so respawns route
// through the swap too. Identifiers (IE, A, Vie) are captured, not
// hardcoded.
// ---------------------------------------------------------------------
if (code.includes('/*cowork-bwrap-spawn*/')) {
    console.log('  B: helper spawn swap already applied');
} else {
    const spawnRe =
        /([\w$]+)\.spawn\(([\w$]+),\[\s*"-socket"\s*,\s*([\w$]+)\(\)\s*\]\s*,\s*\{\s*stdio:\s*\[\s*"pipe"\s*,\s*"pipe"\s*,\s*"pipe"\s*\]\s*\}\)/;
    const m = code.match(spawnRe);
    if (m) {
        const spawnObj = m[1], helperPath = m[2], sockFn = m[3];
        const flagged = '(' + GATE + ')';
        const daemon =
            'require("path").join(process.resourcesPath,' +
            '"cowork-vm-service.js")';
        const cmd = flagged +
            '?(process.env.COWORK_NODE_PATH||"node"):' + helperPath;
        const args = flagged +
            '?[' + daemon + ',"-socket",' + sockFn + '()]' +
            ':["-socket",' + sockFn + '()]';
        const replacement = '/*cowork-bwrap-spawn*/' + spawnObj +
            '.spawn(' + cmd + ',' + args +
            ',{stdio:["pipe","pipe","pipe"]})';
        code = code.replace(spawnRe, replacement);
        console.log('  B: swapped helper spawn -> node daemon when ' +
            'flagged (' + spawnObj + '/' + helperPath + '/' + sockFn + ')');
    } else {
        console.log('  B: FATAL — helper spawn anchor ' +
            '(X.spawn(P,["-socket",S()],{stdio:[...]}))  not found');
        loadBearingFailed = true;
    }
}

// ---------------------------------------------------------------------
// Patch C: suppress the VM-image download on the bwrap path (best
// effort). Both the foreground downloader and the warm prefetch gate on
// yukonSilver being supported — which Patch A now makes true — so guard
// each at its function head. A miss here only wastes bandwidth/disk, so
// warn rather than fail.
// ---------------------------------------------------------------------
// Foreground: async function OzA(A,e){const{yukonSilver:t}=sM();return...
const dlRe =
    /(async function\s+[\w$]+\([\w$]+,[\w$]+\)\{)(const\{yukonSilver:[\w$]+\}=[\w$]+\(\);return\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported"\?!1:)/;
if (code.includes('/*cowork-bwrap-dl*/')) {
    console.log('  C1: foreground download block already applied');
} else if (dlRe.test(code)) {
    code = code.replace(dlRe,
        '$1/*cowork-bwrap-dl*/if(' + GATE + ')return!1;$2');
    console.log('  C1: blocked foreground VM download when flagged');
} else {
    console.log('  C1: WARNING — foreground download anchor not found; ' +
        'flagged runs may download an unused VM image');
}

// Warm prefetch: async function Vdo(A,e,t){if(!e){..."[warm] Warm download
const warmRe =
    /(async function\s+[\w$]+\([\w$]+,[\w$]+,[\w$]+\)\{)(if\(![\w$]+\)\{[\s\S]{0,120}?\[warm\] Warm download disabled)/;
if (code.includes('/*cowork-bwrap-warm*/')) {
    console.log('  C2: warm download block already applied');
} else if (warmRe.test(code)) {
    code = code.replace(warmRe,
        '$1/*cowork-bwrap-warm*/if(' + GATE + ')return;$2');
    console.log('  C2: blocked warm VM prefetch when flagged');
} else {
    console.log('  C2: WARNING — warm download anchor not found; flagged ' +
        'runs may prefetch an unused VM image');
}

if (loadBearingFailed) {
    console.log('  One or more load-bearing anchors (A/B) missed — ' +
        'refusing to ship a half-patched bwrap fallback.');
    process.exit(1);
}

fs.writeFileSync(indexJs, code);
COWORK_BWRAP_PATCH
	then
		echo 'Cowork bwrap fallback patch applied'
	else
		echo 'ERROR: Cowork bwrap patch failed. The opt-in' \
			'COWORK_VM_BACKEND=bwrap path (#772, ChromeOS/Crostini and' \
			'other KVM-less hosts) would be broken. Update the anchors' \
			'in scripts/patches/cowork-bwrap.sh against the new bundle' \
			'before shipping.' >&2
		return 1
	fi
	echo '##############################################################'
}
