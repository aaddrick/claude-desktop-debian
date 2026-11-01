#!/usr/bin/env bats
#
# tools/patch-necessity-audit.sh, the report-only tool whose verdicts
# feed the deletion matrix in
# docs/learnings/official-deb-rebase-verification.md.
#
# The bug (#850): the tool followed a single require() out of index.js
# and grepped whatever it landed on, which is the 1.19367.0 shape — a
# stub plus ONE content-hashed chunk. 1.26832.0 dissolved that core into
# ~83 chunks across two families, so the capture became multi-line and
# the tool aborted.
#
# The abort is the safe failure. What these tests really guard is the
# unsafe fix: taking the first chunk instead. Every anchor living in
# another chunk would then read zero, and a zero here reports as
# `not-needed` — indistinguishable from an anchor upstream genuinely
# fixed. That verdict argues for deleting a patch that is still
# load-bearing, so "anchor in a non-first chunk is still found" is the
# assertion that matters most in this file.
#
# The probes read $bundle_js, so a fixture tree plus _resolve_bundle is
# the whole harness — no .deb, no asar, no network.

setup() {
	source "$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh"
	build_dir="$BATS_TEST_TMPDIR/.vite/build"
	mkdir -p "$build_dir"
	rows=()
}

# Write one .vite/build file. $1 = filename, $2… = its (minified) body.
_chunk() {
	local name="$1"
	shift
	printf '%s' "$*" > "$build_dir/$name"
}

# The matrix row a probe just appended — name, verdict and evidence.
_row() {
	printf '%s\n' "${rows[@]}"
}

# --- bundle shapes ---------------------------------------------------

# Pre-3.x: the whole main process in one index.js, no chunks.
_bundle_single_file() {
	_chunk index.js 'const a=1;frame:!1,setImage(x);TrayIconLinux'
}

# 1.19367.0: a stub that require()s exactly one content-hashed chunk.
_bundle_one_chunk() {
	_chunk index.js 'require("./index.chunk-abc123.js");'
	_chunk index.chunk-abc123.js 'frame:!1,setImage(x);TrayIconLinux'
}

# 1.26832.0+: index.js requires many chunks across two families and
# keeps code of its own. This is the shape that aborted.
_bundle_many_chunks() {
	_chunk index.js 'require("./index.chunk-aaa.js");' \
		'require("./index.chunk-bbb.js");' \
		'require("./index2.chunk-ccc.js");TrayIconLinux'
	_chunk index.chunk-aaa.js 'const noise=1;'
	_chunk index.chunk-bbb.js 'setImage(x);setImage(y);'
	_chunk index2.chunk-ccc.js 'frame:!1'
}

# ---------------------------------------------------------------------
# _resolve_bundle
# ---------------------------------------------------------------------

@test "bundle: a single-file bundle resolves to one file" {
	_bundle_single_file

	_resolve_bundle || return 1
	[[ ${#bundle_js[@]} -eq 1 ]]
}

@test "bundle: a stub plus one chunk resolves to both" {
	# The old code resolved to the chunk ALONE and threw the stub away.
	# Even on the shape it was written for that was wrong: 1.26832.0
	# left the tray anchor in index.js itself.
	_bundle_one_chunk

	_resolve_bundle || return 1
	[[ ${#bundle_js[@]} -eq 2 ]]
}

@test "bundle: a multi-chunk tree resolves instead of aborting" {
	# The #850 symptom. Two chunk families and a stub that requires
	# three files: the old grep -oP captured three filenames into one
	# string and the -f test on it failed.
	_bundle_many_chunks

	_resolve_bundle || return 1
	[[ ${#bundle_js[@]} -eq 4 ]]
}

@test "bundle: the file list is in C order, not the operator's locale" {
	# extract() answers with the first match in this order, so the
	# order cannot depend on the environment. It nearly did: a
	# locale-aware collation ignores punctuation, so en_US sorts
	# index2.chunk-* BEFORE index.chunk-* and C sorts it after. A
	# bare `sort` therefore hands two operators different answers.
	_bundle_many_chunks
	_resolve_bundle || return 1

	local want
	want=$(printf '%s\n' "${bundle_js[@]}" | LC_ALL=C sort)
	[[ $(printf '%s\n' "${bundle_js[@]}") == "$want" ]] || return 1
	# Byte order puts the dotted names ahead of index2.
	[[ ${bundle_js[0]##*/} == 'index.chunk-aaa.js' ]] || return 1
	[[ ${bundle_js[-1]##*/} == 'index2.chunk-ccc.js' ]]
}

@test "bundle: a locale that reorders the chunks changes nothing" {
	# The mutation guard for the line above: under en_US a bare sort
	# flips index2 to the front, and this fixture puts the anchor
	# there, so a locale-dependent resolver would answer differently
	# in the two locales.
	_bundle_many_chunks

	LC_ALL=C _resolve_bundle || return 1
	local c_order="${bundle_js[*]##*/}"
	LC_ALL=en_US.UTF-8 _resolve_bundle || return 1
	[[ ${bundle_js[*]##*/} == "$c_order" ]]
}

@test "bundle: an empty build dir is an error, not an empty probe run" {
	# Without this the whole matrix would read `not-needed` off a tree
	# that was never unpacked.
	run _resolve_bundle
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'layout changed'* ]]
}

# ---------------------------------------------------------------------
# The false-not-needed trap
# ---------------------------------------------------------------------

@test "anchors: an anchor in a non-first chunk is still found" {
	# THE regression guard. `frame:!1` lives in index2.chunk-ccc.js,
	# the LAST file sorted. A first-match fix reports 0 occurrences,
	# which probe_frame_fix renders as `not-needed` — the verdict that
	# argues for deleting a live patch.
	_bundle_many_chunks
	_resolve_bundle || return 1

	[[ $(count 'frame:!1') -eq 1 ]]
}

@test "anchors: occurrences are summed across chunks, not per file" {
	# setImage twice in one chunk, TrayIconLinux once in the stub.
	_bundle_many_chunks
	_resolve_bundle || return 1

	[[ $(count 'setImage') -eq 2 ]] || return 1
	[[ $(count 'TrayIconLinux') -eq 1 ]]
}

@test "anchors: a minified one-line chunk is not undercounted" {
	# grep -c answers "files with a match", so a chunk carrying twelve
	# occurrences on its single minified line counts as 1. The shipped
	# bytes are exactly that shape, so -c is the wrong tool here.
	_chunk index.js 'a(setImage);b(setImage);c(setImage);'
	_resolve_bundle || return 1

	[[ $(count 'setImage') -eq 3 ]]
}

@test "anchors: an absent anchor really is zero" {
	# The other direction: the counting change must not turn every
	# probe green by accident.
	_bundle_many_chunks
	_resolve_bundle || return 1

	[[ $(count 'nonexistentAnchorXyz') -eq 0 ]]
}

@test "anchors: has() spans chunks the same way count() does" {
	_bundle_many_chunks
	_resolve_bundle || return 1
	# frame:!1 lives in index2.chunk-ccc.js, last in C order — so a
	# has() narrowed to the first file cannot pass this.
	[[ ${bundle_js[0]##*/} != 'index2.chunk-ccc.js' ]] || return 1

	has 'frame:!1' || return 1
	if has 'nonexistentAnchorXyz'; then return 1; fi
}

@test "anchors: extract() reaches a capture in a later chunk" {
	# The anchor must NOT be in bundle_js[0], or a resolver narrowed to
	# the first file passes this by accident. In C order
	# index.chunk-aaa sorts first, so the capture goes in index.js.
	_chunk index.chunk-aaa.js 'const noise=1;'
	_chunk index.js 'w.setAlwaysOnTop(!0,"pop-up-menu")'
	_resolve_bundle || return 1
	[[ ${bundle_js[0]##*/} == 'index.chunk-aaa.js' ]] || return 1

	[[ $(extract \
		'[$\w]+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))') \
		== 'w' ]]
}

# ---------------------------------------------------------------------
# Probe verdicts across bundle shapes
# ---------------------------------------------------------------------

@test "verdict: frame-fix reads the same on every bundle shape" {
	# The point of the fix: a tool whose answer depends on how upstream
	# happened to split its bundle is not measuring what it claims to.
	local shape verdicts=()
	for shape in _bundle_single_file _bundle_one_chunk \
		_bundle_many_chunks; do
		rm -f "$build_dir"/*.js
		"$shape"
		rows=()
		_resolve_bundle > /dev/null || return 1
		probe_frame_fix
		verdicts+=("$(_row | awk '{print $2}')")
	done
	[[ ${verdicts[0]} == "${verdicts[1]}" ]] || return 1
	[[ ${verdicts[1]} == "${verdicts[2]}" ]]
}

@test "verdict: a present frame:!1 is never reported not-needed" {
	_bundle_many_chunks
	_resolve_bundle > /dev/null || return 1

	probe_frame_fix
	[[ $(_row) != *'not-needed'* ]] || return 1
	[[ $(_row) == *'check'* ]]
}

@test "verdict: a genuinely absent frame:!1 IS reported not-needed" {
	# Blast-radius guard. If the fix made every probe say `check`, the
	# tool would be useless in the other direction.
	_chunk index.js 'const a=1;'
	_resolve_bundle > /dev/null || return 1

	probe_frame_fix
	[[ $(_row) == *'not-needed'* ]]
}

@test "verdict: the updater probe tracks the renamed telemetry reason" {
	# Upstream renamed apt_channel_pending -> managed_by_package_manager
	# in the 1.18286.2 -> 1.19367.0 window. The build's AU-1 tripwire
	# moved with it; this probe had not, so it reported a false `check`
	# against every current bundle — invisible until the tool could run
	# on one at all.
	_chunk index.js 'reason:"managed_by_package_manager"'
	_resolve_bundle > /dev/null || return 1

	probe_auto_updater
	[[ $(_row) == *'not-needed'* ]] || return 1
	[[ $(_row) == *'managed_by_package_manager'* ]]
}

@test "verdict: the updater probe survives the BRE-to-PCRE move" {
	# The old grep was plain (BRE), where `\|` is alternation. Carried
	# into grep -P unchanged it becomes a LITERAL pipe and silently
	# stops matching — a not-needed patch would start reading `check`.
	_chunk index.js 'log("apt channel not yet live")'
	_resolve_bundle > /dev/null || return 1

	probe_auto_updater
	[[ $(_row) == *'not-needed'* ]]
}

@test "verdict: the updater probe still matches the other alternative" {
	_chunk index.js 'const x="apt_channel_pending";'
	_resolve_bundle > /dev/null || return 1

	probe_auto_updater
	[[ $(_row) == *'not-needed'* ]]
}

@test "verdict: the updater probe does not match a literal pipe" {
	# The mutation the two tests above cannot see on their own: a
	# pattern that matched `a|b` literally would still pass them.
	_chunk index.js 'const x="apt_channel_pending|apt channel";'
	_resolve_bundle > /dev/null || return 1

	probe_auto_updater
	[[ $(_row) == *'not-needed'* ]]
}

@test "verdict: the preload probe stays scoped to mainView.js" {
	# wco-shim is about a preload, not the main process. Widening it to
	# the bundle would count main-process hits as preload evidence.
	main_view_js="$build_dir/mainView.js"
	_chunk mainView.js 'const a=1;'
	_chunk index.js 'windowControlsOverlay;isWindows;'
	_resolve_bundle > /dev/null || return 1

	probe_wco_shim
	[[ $(_row) == *'mainView refs: 0'* ]]
}

# ---------------------------------------------------------------------
# Sourceability
# ---------------------------------------------------------------------

@test "harness: sourcing the tool runs no probes and fetches nothing" {
	# The guard that makes every test above possible. If main ran on
	# source, this file would try to download a 170 MB .deb.
	run bash -c \
		"source '$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh'"
	[[ $status -eq 0 ]] || return 1
	[[ $output != *'Patch-necessity matrix'* ]] || return 1
	[[ $output != *'Extracting'* ]]
}

@test "harness: --help prints the whole header, not a stale range" {
	# The range was hardcoded as '2,20p' and the block had grown to 21
	# lines, so --help cut off after the `needed?` verdict and dropped
	# `check` — the verdict most rows in the matrix actually carry.
	run "$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh" --help
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'not-needed'* ]] || return 1
	[[ $output == *'needed?'* ]] || return 1
	[[ $output == *'ambiguous'* ]]
}

@test "harness: --help stops at the header, not in the code" {
	# The other direction: deriving the range must not run away past
	# the closing banner and start printing the script itself. The
	# OPENING banner is part of the header and always present, so the
	# test is that exactly one survives, not zero.
	run "$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh" --help
	[[ $output != *'script_dir='* ]] || return 1
	[[ $(grep -c '^#====' <<< "$output") -eq 1 ]]
}

@test "harness: the run guard names main, so argv reaches it" {
	# `main "$@"` and not a bare `main` — the --deb/--tree flags are
	# parsed inside _stage_tree now.
	grep -q 'main "\$@"' \
		"$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh"
}

# ---------------------------------------------------------------------
# probe_active_patches: dry-run every active patch on a bundle copy
# ---------------------------------------------------------------------
#
# The hand-written rows drift (by 4.4212.0 the quick-window one read a
# sibling pop-up window and reported `check`), and only two of six
# active patches had one. The dry-run rows come from the patch
# functions themselves, so these pin the verdict mapping and the
# sandbox, using stub patches that edit relative to CWD the way the
# real ones do.

_dry_fixture() {
	work_dir="$BATS_TEST_TMPDIR/work"
	mkdir -p "$work_dir"
	_chunk index.js "${*:-const a=1;}"
	_resolve_bundle > /dev/null || return 1
}

_stub_change() { echo '//x' >> app.asar.contents/.vite/build/index.js; }
_stub_noop() { :; }
_stub_fail() { echo '  WARNING: anchor gone from this bundle'; return 1; }
_stub_wipe() { rm -rf app.asar.contents/.vite/build; }

# The patch under test runs whichever stub _dry_as picked.
patch_demo() { "$_dry_stub"; }

# $1 = patch name, $2 = retirement row, $3 = stub for it to run
_dry_as() {
	_dry_stub="$3"
	patch_retirement[$1]="$2"
	dry_run_patch "$1"
}

@test "dry-run: a bytes patch that changes the bundle is needed?" {
	_dry_fixture
	_dry_as patch_demo 'bytes: demo' _stub_change
	[[ $(_row) == patch_demo*needed?*'retires by: bytes: demo'* ]]
}

@test "dry-run: a bytes patch that changes nothing is not-needed" {
	_dry_fixture
	_dry_as patch_demo 'bytes: demo' _stub_noop
	[[ $(_row) == patch_demo*not-needed*'changed nothing'* ]]
}

@test "dry-run: a behavior no-op is an anchor reshape, not a fix" {
	_dry_fixture
	_dry_as patch_demo 'behavior: demo' _stub_noop
	[[ $(_row) == patch_demo*check*'changed nothing'* ]]
}

@test "dry-run: our own feature reads diverges, and a no-op is check" {
	_dry_fixture
	_dry_as patch_demo 'never: demo' _stub_change
	[[ $(_row) == patch_demo*diverges* ]]
	rows=()
	_dry_as patch_demo 'never: demo' _stub_noop
	[[ $(_row) == patch_demo*check* ]]
}

@test "dry-run: a failing patch is check and quotes its warning" {
	_dry_fixture
	_dry_as patch_demo 'bytes: demo' _stub_fail
	[[ $(_row) == patch_demo*check*'WARNING: anchor gone'* ]]
}

@test "dry-run: a bundle the patch destroys is check, not needed?" {
	_dry_fixture
	_dry_as patch_demo 'bytes: demo' _stub_wipe
	[[ $(_row) == patch_demo*check*'could not digest'* ]]
}

@test "dry-run: an undefined active patch is check" {
	_dry_fixture
	dry_run_patch patch_never_defined
	[[ $(_row) == patch_never_defined*check*'never defined'* ]]
}

@test "dry-run: the real bundle and CWD are left untouched" {
	_dry_fixture
	local before here="$PWD"
	before=$(sha256sum "$build_dir/index.js")
	_dry_as patch_demo 'bytes: demo' _stub_change
	[[ $(sha256sum "$build_dir/index.js") == "$before" ]]
	[[ $PWD == "$here" ]]
	[[ -z $(ls -A "$work_dir/dry-run") ]]
}

@test "dry-run: every active patch gets a row" {
	# The real list, run on a bundle none of them can patch: each must
	# still produce its own row (as check), so a patch wired into the
	# build can never be missing from the audit.
	_dry_fixture
	probe_active_patches
	(( ${#rows[@]} == ${#active_patches[@]} ))
	local patch_fn
	for patch_fn in "${active_patches[@]}"; do
		[[ $(_row) == *"$patch_fn "*check* ]] || {
			echo "no check row for $patch_fn" >&2
			return 1
		}
	done
}

@test "dry-run: a quoted Cinnamon literal turns tray needed? into check" {
	_dry_fixture 'const d="X-Cinnamon";'
	patch_tray_icon_env_override() { "$_dry_stub"; }
	_dry_as patch_tray_icon_env_override 'bytes: demo' _stub_change
	[[ $(_row) == *check*'cinnamon refs: 1'* ]]
}

@test "dry-run: cinnamon-settings alone does not trip the tray hint" {
	# 4.4212.0 ships this in a settings-app list unrelated to the tray.
	_dry_fixture 'const y=new Set(["nemo","cinnamon-settings"]);'
	patch_tray_icon_env_override() { "$_dry_stub"; }
	_dry_as patch_tray_icon_env_override 'bytes: demo' _stub_change
	[[ $(_row) == *needed?*'cinnamon refs: 0'* ]]
}

# The real virtiofsd patch, on the 1.26832.0+ resolver shape.
_virtiofsd_body() {
	printf '%s' 'var kT=[`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`];' \
		'function u(){return 1}async function r(){return await FT(kT)||' \
		"$1}"
}

@test "dry-run: the real virtiofsd patch reads needed? on the gated shape" {
	_dry_fixture "$(_virtiofsd_body '(e?IT(TT,N.constants.X_OK):null)')"
	dry_run_patch patch_virtiofsd_probe
	[[ $(_row) == patch_virtiofsd_probe*needed?* ]]
}

@test "dry-run: the real virtiofsd patch reads not-needed once ungated" {
	_dry_fixture "$(_virtiofsd_body 'IT(TT,N.constants.X_OK)')"
	dry_run_patch patch_virtiofsd_probe
	[[ $(_row) == patch_virtiofsd_probe*not-needed* ]]
}

@test "dry-run: the full probe run includes every active patch" {
	# probe_active_patches pinned on its own is not enough: dropping it
	# from run_probes would leave the matrix without these rows.
	_dry_fixture
	app_dir="$BATS_TEST_TMPDIR"
	main_view_js="$build_dir/mainView.js"
	run_probes
	local patch_fn
	for patch_fn in "${active_patches[@]}"; do
		[[ $(_row) == *"$patch_fn "* ]] || {
			echo "run_probes left out $patch_fn" >&2
			return 1
		}
	done
}

# A bytes no-op argues for deleting the patch, so the patches whose
# no-op is ambiguous need upstream's fix in the bytes before the row
# may read not-needed.
_org_switch() {
	printf '%s' 'function v(){switch(process.platform){case"darwin":' \
		'return"/Library/Application Support/Claude/org-plugins";' \
		"$1" 'default:return null}}'
}

@test "dry-run: an org-plugins no-op without a linux case is check" {
	# org-plugins' sed can miss silently, which also reads as a no-op.
	_dry_fixture "$(_org_switch '')"
	patch_org_plugins_path() { "$_dry_stub"; }
	_dry_as patch_org_plugins_path 'bytes: demo' _stub_noop
	[[ $(_row) == *check*'linux case in the org-plugins switch: 0'* ]]
}

@test "dry-run: an org-plugins no-op with upstream's linux case is fixed" {
	_dry_fixture "$(_org_switch 'case"linux":return"/etc/x/org-plugins";')"
	patch_org_plugins_path() { "$_dry_stub"; }
	_dry_as patch_org_plugins_path 'bytes: demo' _stub_noop
	[[ $(_row) == *not-needed*'switch: 1'* ]]
}

@test "dry-run: a linux case ahead of darwin counts too" {
	_dry_fixture 'switch(process.platform){case"linux":return"/x";' \
		'case"darwin":return"/L/Claude/org-plugins";}'
	patch_org_plugins_path() { "$_dry_stub"; }
	_dry_as patch_org_plugins_path 'bytes: demo' _stub_change
	[[ $(_row) == *check*'switch: 1'* ]]
}

@test "dry-run: a linux case in another switch is not the fix" {
	_dry_fixture "$(_org_switch '')"'switch(p){case"linux":return"/y"}'
	patch_org_plugins_path() { "$_dry_stub"; }
	_dry_as patch_org_plugins_path 'bytes: demo' _stub_change
	[[ $(_row) == *needed?*'switch: 0'* ]]
}

@test "dry-run: a tray no-op without a Cinnamon literal is check" {
	_dry_fixture
	patch_tray_icon_env_override() { "$_dry_stub"; }
	_dry_as patch_tray_icon_env_override 'bytes: demo' _stub_noop
	[[ $(_row) == *check*'cinnamon refs: 0'* ]]
}

@test "dry-run: a tray no-op with a Cinnamon literal is fixed" {
	_dry_fixture 'if(d===`cinnamon`)'
	patch_tray_icon_env_override() { "$_dry_stub"; }
	_dry_as patch_tray_icon_env_override 'bytes: demo' _stub_noop
	[[ $(_row) == *not-needed*'cinnamon refs: 1'* ]]
}
