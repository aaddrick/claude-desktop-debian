#!/usr/bin/env bats
#
# patch_quick_window / patch_org_plugins_path / patch_virtiofsd_probe:
# the three asar patches that had no BATS coverage until #820. Each is
# exercised against BOTH shipped shapes, because 1.26832.0 swapped the
# bundler and re-emitted the same code differently:
#
#   1.24012.11 — double-quoted literals, const, bare identifiers,
#                downleveled optional chaining
#   1.26832.0  — backtick templates, let, module-binding callees
#                (`p.n()`, `i.s()`), preserved optional chaining
#
# Every fixture below is copied from the shipped minified bytes of the
# release named in its comment, not hand-written, so a passing test means
# the anchor matches what upstream actually emits. The near-miss fixtures
# sit one edit from the anchor on purpose: loosening a regex turns their
# expected failure into a pass and goes red
# (docs/learnings/test-methodology-and-coverage.md).

setup() {
	for p in quick-window org-plugins virtiofsd-probe cowork-bwrap; do
		# shellcheck source=/dev/null
		source "$BATS_TEST_DIRNAME/../scripts/patches/$p.sh"
	done
	# _resolve_anchor_file: each patch resolves its own file (#820).
	# shellcheck source=scripts/patches/app-asar.sh
	source "$BATS_TEST_DIRNAME/../scripts/patches/app-asar.sh"

	BUILD="$BATS_TEST_TMPDIR/app.asar.contents/.vite/build"
	mkdir -p "$BUILD"
}

# $1 = chunk basename, $2 = contents
_chunk() {
	printf '%s\n' "$2" > "$BUILD/$1"
	cd "$BATS_TEST_TMPDIR" || return 1
}

# =============================================================================
# quick-window
# =============================================================================

# 1.24012.11 shipped bytes: quick var `er`, double-quoted "pop-up-menu",
# the `N6()||er.hide()` site, and the QuickEntry submit path whose show()
# call reads `n1()||exports.mainWindow.show()`.
QW_OLD='function N6(){return!er||er.isDestroyed()}function nce(){N6()||er.hide()}
Il.QUICK_ENTRY),er.setAlwaysOnTop(!0,"pop-up-menu"),er.webContents;
_.info("[QuickEntry] Creating new chat with submit_quick_entry");n1()||exports.mainWindow.show()'

# 1.26832.0 shipped bytes: quick var `R`, backticked `pop-up-menu`, and a
# show() site whose focus check is the module binding `i.s`.
QW_NEW='function N6(){return!R||R.isDestroyed()}function nce(){N6()||R.hide()}
n.n.QUICK_ENTRY),R.setAlwaysOnTop(!0,`pop-up-menu`),R.webContents;
n.o.info(`[QuickEntry] Creating new chat with submit_quick_entry`);i.s()||i.f.show()'

@test "quick-window: applies to the 1.24012.11 double-quoted shape" {
	_chunk 'index.chunk-test.js' "$QW_OLD"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: er'* ]]
	grep -qF 'er.blur(),er.hide()' "$BUILD/index.chunk-test.js"
	grep -qF 'n1())||exports.mainWindow.show()' "$BUILD/index.chunk-test.js"
}

@test "quick-window: applies to the 1.26832.0 backticked shape" {
	# The delimiter flip alone took this anchor to zero matches (#820).
	_chunk 'index.chunk-test.js' "$QW_NEW"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'Found quick window variable: R'* ]]
	grep -qF 'R.blur(),R.hide()' "$BUILD/index.chunk-test.js"
}

@test "quick-window: captures a module-binding focus check (i.s)" {
	# 1.26832.0 moved the focus/visibility pair into a shared module, so
	# the call site sees `i.s()`, not a bare identifier. A capture
	# restricted to [\w$]+ silently fails to rewrite the show() call.
	_chunk 'index.chunk-test.js' "$QW_NEW"
	patch_quick_window
	grep -qF 'i.s())||i.f.show()' "$BUILD/index.chunk-test.js"
	# The KDE branch must test visibility on the captured handle.
	grep -qF 'i.f.isVisible()' "$BUILD/index.chunk-test.js"
}

@test "quick-window: re-run is a no-op and warns about nothing" {
	_chunk 'index.chunk-test.js' "$QW_NEW"
	patch_quick_window
	local first; first="$(cat "$BUILD/index.chunk-test.js")"
	run patch_quick_window
	[[ $status -eq 0 ]]
	[[ $output == *'already patched'* ]]
	# A fully patched bundle must not emit a WARNING; a standing warning
	# on every rebuild trains the eye to ignore real ones.
	[[ $output != *'WARNING'* ]]
	[[ "$(cat "$BUILD/index.chunk-test.js")" == "$first" ]]
}

@test "quick-window: decoy chunk without the call site is not selected" {
	# `pop-up-menu` occurs in two 1.26832.0 chunks; only one has the
	# setAlwaysOnTop call. Resolving on the bare string picks a decoy.
	_chunk 'index.chunk-decoy.js' 'n.o.info(`pop-up-menu opened`)'
	_chunk 'index.chunk-real.js' "$QW_NEW"
	run patch_quick_window
	[[ $status -eq 0 ]]
	grep -qF 'R.blur(),R.hide()' "$BUILD/index.chunk-real.js"
	run grep -qF 'blur()' "$BUILD/index.chunk-decoy.js"
	[[ $status -ne 0 ]]
}

# =============================================================================
# org-plugins
# =============================================================================

# 1.24012.11 shipped bytes.
ORG_OLD='return"/Library/Application Support/Claude/org-plugins";case"win32":return C.join("C:\\Program Files","Claude","org-plugins");default:return null}}'

# 1.26832.0 shipped bytes: backticks throughout, indirect join callee.
ORG_NEW='return`/Library/Application Support/Claude/org-plugins`;case`win32`:return(0,j.join)(`C:\\Program Files`,`Claude`,`org-plugins`);default:return null}}'

@test "org-plugins: injects the linux case on the 1.24012.11 shape" {
	_chunk 'index.chunk-test.js' "$ORG_OLD"
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$BUILD/index.chunk-test.js"
}

@test "org-plugins: injects the linux case on the 1.26832.0 shape" {
	_chunk 'index.chunk-test.js' "$ORG_NEW"
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	# Injected ahead of default:, and our own JS stays double-quoted.
	grep -qF 'case"linux":return"/etc/claude/org-plugins";default:return null' \
		"$BUILD/index.chunk-test.js"
}

@test "org-plugins: idempotent and byte-identical on re-run" {
	# The insertion splits the compound switch anchor, so a resolution
	# anchor keyed on that shape would fail to find the file at all on
	# the second pass, before the idempotency guard could fire (#820).
	_chunk 'index.chunk-test.js' "$ORG_NEW"
	patch_org_plugins_path
	local first; first="$(cat "$BUILD/index.chunk-test.js")"
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	[[ $output == *'already present'* ]]
	[[ "$(cat "$BUILD/index.chunk-test.js")" == "$first" ]]
}

@test "org-plugins: switch without the default arm is left alone" {
	# One edit short: the resolver still finds the file via the darwin
	# path, but the compound switch anchor must not match.
	_chunk 'index.chunk-test.js' \
		'return`/Library/Application Support/Claude/org-plugins`;case`win32`:return`x`}}'
	run patch_org_plugins_path
	[[ $status -eq 0 ]]
	run grep -qF '/etc/claude/org-plugins' "$BUILD/index.chunk-test.js"
	[[ $status -ne 0 ]]
}

# =============================================================================
# virtiofsd-probe
# =============================================================================

# 1.24012.11 shipped bytes: double-quoted probe array, and a resolver
# whose left operand is a bare identifier holding an awaited result.
VFSD_OLD='Gon=["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"];async function Zon(){try{const e=await Ome();return(e==null?void 0:e.id)==="ubuntu"&&(e.versionId??"").startsWith("22.")}catch{return!1}}async function Kon(e){const t=await Qot(Gon);return t||(e?loe(Won,Y.constants.X_OK):null)}'

# 1.26832.0 shipped bytes: backticked array, preserved optional chaining,
# and the await inlined into the left operand of the ||.
VFSD_NEW='kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];async function AT(){try{let e=await fT();return e?.id===`ubuntu`&&(e.versionId??``).startsWith(`22.`)}catch{return!1}}async function jT(e){return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)}'

@test "virtiofsd: un-gates the fallback on the 1.24012.11 shape" {
	_chunk 'index.chunk-test.js' "$VFSD_OLD"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return t||loe(Won,Y.constants.X_OK)' \
		"$BUILD/index.chunk-test.js"
}

@test "virtiofsd: un-gates the fallback on the 1.26832.0 shape" {
	# The left operand became `await FT(kT)`; an anchor expecting a bare
	# identifier there leaves the Ubuntu-22 gate in place and re-opens
	# #771 on every other distro.
	_chunk 'index.chunk-test.js' "$VFSD_NEW"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	grep -qF 'return await FT(kT)||IT(TT,N.constants.X_OK)' \
		"$BUILD/index.chunk-test.js"
	# The Ubuntu-only ternary must be gone, not merely bypassed.
	run grep -qF '(e?IT(TT,N.constants.X_OK):null)' \
		"$BUILD/index.chunk-test.js"
	[[ $status -ne 0 ]]
}

@test "virtiofsd: idempotent and byte-identical on re-run" {
	_chunk 'index.chunk-test.js' "$VFSD_NEW"
	patch_virtiofsd_probe
	local first; first="$(cat "$BUILD/index.chunk-test.js")"
	run patch_virtiofsd_probe
	[[ $status -eq 0 ]]
	[[ $output == *'already un-gated'* ]]
	[[ "$(cat "$BUILD/index.chunk-test.js")" == "$first" ]]
}

@test "virtiofsd: missing probe array fails the build" {
	# An anchor miss here must stop the build, not warn: shipping without
	# the patch silently re-opens #771.
	_chunk 'index.chunk-test.js' 'var x=[`/usr/bin/qemu-system-x86_64`];'
	run patch_virtiofsd_probe
	[[ $status -ne 0 ]]
	[[ $output == *'matched no file'* ]]
}

@test "virtiofsd: duplicated probe array fails the exactly-1 guard" {
	_chunk 'index.chunk-test.js' "$VFSD_NEW$VFSD_NEW"
	run patch_virtiofsd_probe
	[[ $status -ne 0 ]]
	[[ $output == *'found 2'* ]]
}

# =============================================================================
# cowork-bwrap (C1 — foreground VM download)
#
# C1 is the anchor that took the whole build red from 1.37937.1 through
# 1.40609.1: upstream inserted an `await X();` between the function head
# and the yukonSilver destructure, and both the file resolver and the
# patch regex required those two to be adjacent. The fixtures below pin
# the prelude allowance that fixed it, from both sides — the shapes it
# must now match, and the near-misses it must still refuse.
#
# A and B resolve fatally before C1 runs, so every fixture carries all
# three anchors in one chunk (which is also how 1.40609.1 ships them).
# =============================================================================

# 1.40609.1 shipped bytes (A: qon/Kon, B: (0,t.spawn)/mIt, C1: QH with the
# `await nB();` prelude that broke the old anchor).
CB_NEW='function qon(){return process.platform,Kon()}
(0,t.spawn)(e,[`-socket`,mIt()],{stdio:[`pipe`,`pipe`,`pipe`]})
async function QH(e,t){await nB();let{yukonSilver:r}=iB();return r?.status===`supported`&&(GH(Kb.Downloading),BH)}'

# 1.26832.0 C1 shape — no prelude, ternary rather than `&&`. Transcribed
# from the shape recorded in scripts/patches/cowork-bwrap.sh's own header
# (that bundle is no longer pinned, so these bytes are not re-extracted).
# Kept as a fixture because the prelude allowance must stay a superset:
# widening for 1.40609.1 must not drop the shape it already handled.
CB_OLD='function qon(){return process.platform,Kon()}
(0,t.spawn)(e,[`-socket`,mIt()],{stdio:[`pipe`,`pipe`,`pipe`]})
async function ut(e,n){let{yukonSilver:r}=p.n();return r?.status===`supported`?(x(),y):!1}'

@test "cowork C1: applies to the 1.40609.1 await-prelude shape" {
	# The regression: the prelude took this anchor to zero matches and
	# _resolve_anchor_file failed the build for four upstream bumps.
	_chunk 'index.chunk-test.js' "$CB_NEW"
	run patch_cowork_bwrap
	[[ $status -eq 0 ]]
	[[ $output == *'C1: blocked foreground VM download when flagged'* ]]
	# The gate lands ahead of the prelude, so upstream's status check
	# never runs on a flagged launch — polarity-agnostic by position.
	grep -qF 'async function QH(e,t){/*cowork-bwrap-dl*/if(process.platform==="linux"&&process.env.COWORK_VM_BACKEND==="bwrap")return!1;await nB();let{yukonSilver:r}=iB();' \
		"$BUILD/index.chunk-test.js"
}

@test "cowork C1: still applies to the 1.26832.0 no-prelude shape" {
	_chunk 'index.chunk-test.js' "$CB_OLD"
	run patch_cowork_bwrap
	[[ $status -eq 0 ]]
	[[ $output == *'C1: blocked foreground VM download when flagged'* ]]
	grep -qF 'async function ut(e,n){/*cowork-bwrap-dl*/if(process.platform==="linux"&&process.env.COWORK_VM_BACKEND==="bwrap")return!1;let{yukonSilver:r}=p.n();' \
		"$BUILD/index.chunk-test.js"
}

@test "cowork C1: idempotent and byte-identical on re-run" {
	# The resolution anchor has to survive its own patch: it tolerates
	# the injected /*cowork-bwrap-dl*/ marker AND the prelude behind it,
	# or the second pass fails at resolution before the idempotency
	# guards can fire (docs/learnings/patching-minified-js.md).
	_chunk 'index.chunk-test.js' "$CB_NEW"
	patch_cowork_bwrap
	local first; first="$(cat "$BUILD/index.chunk-test.js")"
	run patch_cowork_bwrap
	[[ $status -eq 0 ]]
	[[ $output == *'C1: foreground download block already applied'* ]]
	[[ "$(cat "$BUILD/index.chunk-test.js")" == "$first" ]]
}

@test "cowork C1: does not bind startVM's destructure (near-miss)" {
	# startVM reads the same destructure but continues into `if(`, not
	# `return`. Dropping the `\(\);return` tail from the anchor makes
	# this fixture match and the gate installs on the wrong function.
	local start_vm='async function aU(e,t){await nB();let{yukonSilver:r}=iB();if(r?.status!==`supported`){J.warn(`[startVM] no`);return}}'
	_chunk 'index.chunk-test.js' "${CB_NEW%$'\n'*}
$start_vm"
	run patch_cowork_bwrap
	[[ $status -ne 0 ]]
	[[ $output == *'matched no file'* ]]
}

@test "cowork C1: prelude budget does not cross a nested block" {
	# `[^{}]{0,80}` is brace-fenced on purpose. A `.`-based prelude of
	# the same budget would reach past this inner block and gate a
	# function whose head is 80 bytes away from an unrelated destructure.
	local fenced='async function QH(e,t){if(e){t()}let{yukonSilver:r}=iB();return r}'
	_chunk 'index.chunk-test.js' "${CB_NEW%$'\n'*}
$fenced"
	run patch_cowork_bwrap
	[[ $status -ne 0 ]]
	[[ $output == *'matched no file'* ]]
}

@test "cowork C1: two same-shaped sites warn instead of guessing" {
	# Widening the regex made a second binding possible, so the exactly-1
	# assertion is the compensating control: replace() would silently
	# take the first match.
	local dup='async function XH(e,t){await nB();let{yukonSilver:r}=iB();return r?.status===`supported`&&(z(),1)}'
	_chunk 'index.chunk-test.js' "$CB_NEW
$dup"
	run patch_cowork_bwrap
	[[ $status -eq 0 ]]
	[[ $output == *'C1: WARNING'* ]]
	[[ $output == *'matched 2 sites'* ]]
	run grep -qF '/*cowork-bwrap-dl*/' "$BUILD/index.chunk-test.js"
	[[ $status -ne 0 ]]
}
