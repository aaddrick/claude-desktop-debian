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
# Sourced globals: (none — each sub-patch resolves its own file via
#   _resolve_anchor_file, defined in app-asar.sh)
# Modifies globals: (none)
#
# All four sub-patches shared one file through 1.24012.11. 1.26832.0 put
# each in a different one: A in an index2.chunk-*, B and C1 in two
# separate index.chunk-*, and C2's anchor is gone from the bundle
# entirely (#820). They are resolved independently and may or may not
# coincide, so the node stage below reads and writes per file.
#===============================================================================

# Quote class: 1.26832.0 re-emitted nearly every string literal as a
# backtick template (#820).
_CB_Q='[`"'"'"']'

# C1's anchor shape. Read it as: the function head, then our own marker
# if a previous run left one, then up to 80 brace-free bytes of upstream
# prelude, then the yukonSilver destructure and its `return`.
#
# The node stage's `dlRe` spells the same shape a second time — it is a
# heredoc, so it cannot read these. The two must stay in step or the
# resolver picks a file the patch regex then declines to match; the
# cowork C1 tests in tests/patch-anchors.bats drive both through one
# call and are what actually pins them together.
#
# The prelude allowance is what 1.37937.1 needed — upstream inserted an
# `await X();` between the opening brace and the destructure, and the
# old anchor required them to be adjacent. `[^{}]` is deliberately
# brace-fenced rather than `.`: it cannot cross a nested block or leave
# the function body, so the 80-byte budget buys a couple of simple
# statements and nothing structural. It also absorbs `;` inside a
# template literal, which a statement-counting `(?:[^{};]*;){0,2}` would
# split on.
_CB_C1_MARKER='(?:/\*cowork-bwrap-dl\*/[^;]*;)?'
_CB_C1_PRELUDE='[^{}]{0,80}'
_CB_C1_TAIL='(?:const|let)\{yukonSilver:[\w$]+\}=[\w$]+(?:\.[\w$]+)*\(\);return'

patch_cowork_bwrap() {
	echo 'Patching Cowork bwrap fallback (opt-in COWORK_VM_BACKEND=bwrap)...'

	local a_js b_js c1_js c2_js
	# Each resolution anchor below is deliberately chosen to survive its
	# own patch: patch A rewrites the function head, patch B rewrites the
	# spawn arguments, patch C1 injects after the opening brace. Anchoring
	# on the rewritten text would make the second run fail to resolve the
	# file at all, before the idempotency guards could fire.
	a_js=$(_resolve_anchor_file 'cowork A (platform dispatch)' \
		'return process\.platform,[\w$]+\(\)\}') || return 1
	b_js=$(_resolve_anchor_file 'cowork B (helper socket argv)' \
		"${_CB_Q}-socket${_CB_Q}") || return 1
	c1_js=$(_resolve_anchor_file 'cowork C1 (foreground download)' \
		"async function\s+[\w\$]+\([\w\$]+,[\w\$]+\)\{${_CB_C1_MARKER}${_CB_C1_PRELUDE}${_CB_C1_TAIL}") \
		|| return 1

	# C2 is best-effort and its anchor is absent from 1.26832.0, so an
	# unresolved warm file is a warning rather than a build failure. Not
	# routed through _resolve_anchor_file: that helper fails loud by
	# design, which is the wrong contract for an optional sub-patch.
	c2_js=$(grep -rlF --include='*.js' '[warm] Warm download disabled' \
		'app.asar.contents/.vite/build' 2>/dev/null | head -1)

	if A_JS="$a_js" B_JS="$b_js" C1_JS="$c1_js" C2_JS="$c2_js" \
		node << 'COWORK_BWRAP_PATCH'
const fs = require('fs');

// Sub-patches may share a file or not, depending on release. Route every
// read and write through one cache so a shared file is not read twice
// (which would drop the earlier sub-patch's edit) and each file is
// written exactly once at the end.
const files = new Map();
const load = p => {
    if (!files.has(p)) files.set(p, fs.readFileSync(p, 'utf8'));
    return files.get(p);
};
const save = (p, c) => files.set(p, c);

const aJs = process.env.A_JS;
const bJs = process.env.B_JS;
const c1Js = process.env.C1_JS;
const c2Js = process.env.C2_JS;

// The runtime gate shared by every injected branch. Unflagged launches
// never enter any of them, so the official path ships unchanged. Our own
// injected JS keeps double quotes: it is valid under either upstream
// emission style.
const GATE =
    'process.platform==="linux"&&process.env.COWORK_VM_BACKEND==="bwrap"';

// q(): match an upstream literal under any delimiter. 1.26832.0 swapped
// the minifier and re-emitted nearly every string as a backtick template
// (#820).
const q = s => '[`"\']' + s + '[`"\']';

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
let codeA = load(aJs);
if (new RegExp('return\\{status:"supported"\\};return process\\.platform,')
        .test(codeA)) {
    console.log('  A: evaluator already gated (supported when flagged)');
} else {
    // Fail loud if upstream ever grows a second platform-dispatch of
    // this exact shape — a blind first-match swap would be wrong.
    const evalAll = [...codeA.matchAll(new RegExp(evalRe, 'g'))];
    const m = evalAll.length === 1 ? evalAll[0] : null;
    if (evalAll.length > 1) {
        console.log('  A: FATAL — yukonSilver platform-dispatch anchor ' +
            'matched ' + evalAll.length + ' sites, expected exactly 1');
        loadBearingFailed = true;
    } else if (m) {
        const replacement = 'function ' + m[1] + '(){if(' + GATE +
            ')return{status:"supported"};return process.platform,' +
            m[2] + '()}';
        // () => replacement: "$" is legal in minified identifiers, and
        // a string replacement would reinterpret $1/$&-style sequences
        // inside a captured name as substitution patterns — silently
        // corrupting the bundle (the $ trap in
        // docs/learnings/patching-minified-js.md, replacement side).
        save(aJs, codeA.replace(evalRe, () => replacement));
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
let codeB = load(bJs);
if (codeB.includes('/*cowork-bwrap-spawn*/')) {
    console.log('  B: helper spawn swap already applied');
} else {
    // The callee is captured whole rather than as an object plus a
    // literal `.spawn`: 1.24012.11 emitted `IE.spawn(`, 1.26832.0 emits
    // the bundler's indirect-call form `(0,ye.spawn)(`. Both are valid
    // call expressions, so re-emitting the captured text verbatim works
    // for either.
    const callee = String.raw`((?:\(0,\s*[\w$]+(?:\.[\w$]+)*\)|[\w$]+\.spawn))`;
    const spawnRe = new RegExp(
        callee + String.raw`\(([\w$]+),\[\s*` + q('-socket') +
        String.raw`\s*,\s*([\w$]+)\(\)\s*\]\s*,\s*\{\s*stdio:\s*\[\s*` +
        q('pipe') + '\\s*,\\s*' + q('pipe') + '\\s*,\\s*' + q('pipe') +
        String.raw`\s*\]\s*\}\)`);
    // Assert the helper-spawn shape is unique before swapping — a blind
    // first-match replace would half-patch if upstream duplicates it.
    const spawnAll = [...codeB.matchAll(new RegExp(spawnRe, 'g'))];
    const m = spawnAll.length === 1 ? spawnAll[0] : null;
    if (spawnAll.length > 1) {
        console.log('  B: FATAL — helper spawn anchor matched ' +
            spawnAll.length + ' sites, expected exactly 1');
        loadBearingFailed = true;
    } else if (m) {
        const spawnCall = m[1], helperPath = m[2], sockFn = m[3];
        const flagged = '(' + GATE + ')';
        const daemon =
            'require("path").join(process.resourcesPath,' +
            '"cowork-vm-service.js")';
        const cmd = flagged +
            '?(process.env.COWORK_NODE_PATH||"node"):' + helperPath;
        const args = flagged +
            '?[' + daemon + ',"-socket",' + sockFn + '()]' +
            ':["-socket",' + sockFn + '()]';
        const replacement = '/*cowork-bwrap-spawn*/' + spawnCall +
            '(' + cmd + ',' + args +
            ',{stdio:["pipe","pipe","pipe"]})';
        // () => replacement: same $-in-identifier trap as Patch A.
        save(bJs, codeB.replace(spawnRe, () => replacement));
        console.log('  B: swapped helper spawn -> node daemon when ' +
            'flagged (' + spawnCall + '/' + helperPath + '/' + sockFn + ')');
    } else {
        console.log('  B: FATAL — helper spawn anchor ' +
            '(X.spawn(P,[`-socket`,S()],{stdio:[...]}))  not found');
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
// Foreground:
//   1.24012.11: async function OzA(A,e){const{yukonSilver:t}=sM();
//               return(A==null?void 0:A.status)!=="supported"?!1:...
//   1.26832.0:  async function ut(e,n){let{yukonSilver:r}=p.n();
//               return r?.status===`supported`?(...)
//   1.37937.1:  async function QH(e,t){await nB();let{yukonSilver:r}=iB();
//               return r?.status===`supported`&&(...)
//
// 1.37937.1 inserted a statement between the opening brace and the
// destructure, which the old adjacency requirement rejected outright —
// the whole build went red on that one anchor for four upstream bumps.
// The prelude allowance is spelled once more in `_CB_C1_PRELUDE` on the
// shell side, for the file resolver; keep the two in step. See that
// comment for why it is brace-fenced rather than `.`-based.
//
// The status guard INVERTED between those releases (a !== early-false
// became a === proceed), so the anchor deliberately stops at the
// `return` and never spans the comparison. Matching only the function
// head plus the destructure keeps the injection polarity-agnostic: the
// gate is inserted before upstream's check runs, so it short-circuits
// either shape. Widening this regex to cover both comparisons would be
// the dangerous fix — a pattern loose enough to match both could bind
// the wrong one and install the gate backwards.
// The destructure initialiser is a plain call (`=sM()`) on 1.24012.11
// and a module-binding call (`=p.n()`) on 1.26832.0, so the callee
// tolerates a property chain.
const dlSrc =
    String.raw`(async function\s+[\w$]+\([\w$]+,[\w$]+\)\{)` +
    String.raw`([^{}]{0,80}(?:const|let)\{yukonSilver:[\w$]+\}=` +
    String.raw`[\w$]+(?:\.[\w$]+)*\(\);return)`;
const dlRe = new RegExp(dlSrc);
let codeC1 = load(c1Js);
// The prelude allowance widened this pattern, so assert it still binds
// exactly one function rather than trusting `replace()`'s first match.
// A second same-shaped call site is upstream growing a consumer we have
// not reasoned about, which is a warn-and-skip, not a coin flip.
const dlAll = [...codeC1.matchAll(new RegExp(dlSrc, 'g'))];
if (codeC1.includes('/*cowork-bwrap-dl*/')) {
    console.log('  C1: foreground download block already applied');
} else if (dlAll.length > 1) {
    console.log('  C1: WARNING — foreground download anchor matched ' +
        dlAll.length + ' sites; refusing to guess. Re-derive the anchor.');
} else if (dlAll.length === 1) {
    save(c1Js, codeC1.replace(dlRe,
        '$1/*cowork-bwrap-dl*/if(' + GATE + ')return!1;$2'));
    console.log('  C1: blocked foreground VM download when flagged');
} else {
    console.log('  C1: WARNING — foreground download anchor not found; ' +
        'flagged runs may download an unused VM image');
}

// Warm prefetch: async function Vdo(A,e,t){if(!e){..."[warm] Warm download
// Absent from 1.26832.0: that release dropped the log line this anchors
// on, and with it VM_BUNDLE_SPEC and every warm-file identifier, so the
// prefetch subsystem looks restructured rather than merely re-minified.
// No replacement anchor is asserted here on purpose — inventing one
// risks gating unrelated code. C2 only saves bandwidth, so it warns.
const warmRe =
    /(async function\s+[\w$]+\([\w$]+,[\w$]+,[\w$]+\)\{)(if\(![\w$]+\)\{[\s\S]{0,120}?\[warm\] Warm download disabled)/;
if (!c2Js) {
    console.log('  C2: WARNING — warm download anchor not present in this ' +
        'bundle; flagged runs may prefetch an unused VM image');
} else {
    const codeC2 = load(c2Js);
    if (codeC2.includes('/*cowork-bwrap-warm*/')) {
        console.log('  C2: warm download block already applied');
    } else if (warmRe.test(codeC2)) {
        save(c2Js, codeC2.replace(warmRe,
            '$1/*cowork-bwrap-warm*/if(' + GATE + ')return;$2'));
        console.log('  C2: blocked warm VM prefetch when flagged');
    } else {
        console.log('  C2: WARNING — warm download anchor not found; ' +
            'flagged runs may prefetch an unused VM image');
    }
}

if (loadBearingFailed) {
    console.log('  One or more load-bearing anchors (A/B) missed — ' +
        'refusing to ship a half-patched bwrap fallback.');
    process.exit(1);
}

for (const [path, contents] of files) fs.writeFileSync(path, contents);
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
