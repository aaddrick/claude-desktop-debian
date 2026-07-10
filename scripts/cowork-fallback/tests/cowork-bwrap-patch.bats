#!/usr/bin/env bats
#
# cowork-bwrap-patch.bats
# Guards patch_cowork_bwrap against a fixture carrying the four anchor
# shapes (copied verbatim from the official 1.18286.0 bundle): all
# injections land, the swapped spawn selects node+daemon only when
# flagged, re-runs are no-ops, and a missing or duplicated load-bearing
# anchor fails the build with the file left untouched.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PATCH_SH="${SCRIPT_DIR}/../../patches/cowork-bwrap.sh"

# Minimal fixture reproducing the exact anchor shapes the patch targets.
# The spawn site is wrapped in a callable so the injected expression can
# be evaluated with stub IE/A/Vie bindings.
fixture() {
	cat <<'JS'
function Ben(){return process.platform,Cen()}
function Cen(){return{status:"unsupported"}}
function ygi(A){return IE.spawn(A,["-socket",Vie()],{stdio:["pipe","pipe","pipe"]})}
async function OzA(A,e){const{yukonSilver:t}=sM();return(t==null?void 0:t.status)!=="supported"?!1:doDownload()}
async function Vdo(A,e,t){if(!e){log("[warm] Warm download disabled");return}return warmPrefetch()}
JS
}

setup() {
	WORK="$(mktemp -d)"
	mkdir -p "$WORK/app.asar.contents/.vite/build"
	fixture > "$WORK/app.asar.contents/.vite/build/index.js"
	# shellcheck source=scripts/patches/cowork-bwrap.sh
	source "$PATCH_SH"
}

teardown() {
	rm -rf "$WORK"
}

target() { printf '%s' "$WORK/app.asar.contents/.vite/build/index.js"; }

@test "patch: applies all four injections and reports success" {
	cd "$WORK"
	run patch_cowork_bwrap
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"A: gated yukonSilver"* ]]
	[[ "$output" == *"B: swapped helper spawn"* ]]
	[[ "$output" == *"C1: blocked foreground"* ]]
	[[ "$output" == *"C2: blocked warm"* ]]
}

@test "patch: injected markers present and bundle still parses" {
	cd "$WORK"
	patch_cowork_bwrap
	run node --check "$(target)"
	[ "$status" -eq 0 ]
	grep -q '/\*cowork-bwrap-spawn\*/' "$(target)"
	grep -q '/\*cowork-bwrap-dl\*/' "$(target)"
	grep -q '/\*cowork-bwrap-warm\*/' "$(target)"
	grep -q 'COWORK_VM_BACKEND==="bwrap")return{status:"supported"}' "$(target)"
}

@test "patch: evaluator returns supported only when flagged" {
	cd "$WORK"
	patch_cowork_bwrap
	# flagged -> supported
	run env COWORK_VM_BACKEND=bwrap node -e "
		$(cat "$(target)")
		process.exit(Ben().status==='supported'?0:1)"
	[ "$status" -eq 0 ]
	# unflagged -> falls through to the real (unsupported) evaluator
	run env -u COWORK_VM_BACKEND node -e "
		$(cat "$(target)")
		process.exit(Ben().status==='unsupported'?0:1)"
	[ "$status" -eq 0 ]
}

@test "patch: spawn picks node+daemon when flagged, helper when not" {
	cd "$WORK"
	patch_cowork_bwrap
	# Evaluate the patched ygi() with stub IE/Vie and a resourcesPath,
	# capturing the (command, args) the swap chose without spawning.
	run node -e "
		global.IE={spawn:(c,a)=>({c,a})};
		global.Vie=()=>'/run/sock';
		Object.defineProperty(process,'resourcesPath',{value:'/RES'});
		$(cat "$(target)")
		process.env.COWORK_VM_BACKEND='bwrap';
		process.env.COWORK_NODE_PATH='/usr/bin/node';
		const f=ygi('/HELPER');
		const okFlagged=f.c==='/usr/bin/node'
			&& f.a[0]==='/RES/cowork-vm-service.js'
			&& f.a[1]==='-socket' && f.a[2]==='/run/sock';
		delete process.env.COWORK_VM_BACKEND;
		const u=ygi('/HELPER');
		const okUnflagged=u.c==='/HELPER'
			&& u.a[0]==='-socket' && u.a[1]==='/run/sock'
			&& !u.a.some(x=>String(x).endsWith('cowork-vm-service.js'));
		process.exit(okFlagged&&okUnflagged?0:1)"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "patch: re-run is a clean no-op (idempotent)" {
	cd "$WORK"
	patch_cowork_bwrap
	local first
	first="$(cat "$(target)")"
	run patch_cowork_bwrap
	[ "$status" -eq 0 ]
	[[ "$output" == *"already"* ]]
	[ "$(cat "$(target)")" == "$first" ]
}

@test "patch: missing load-bearing anchor (B) fails, file untouched" {
	cd "$WORK"
	# Remove the spawn anchor; A stays so only B is missing.
	local t; t="$(target)"
	grep -v 'IE.spawn' "$t" > "$t.tmp" && mv "$t.tmp" "$t"
	local before; before="$(cat "$t")"
	run patch_cowork_bwrap
	[ "$status" -ne 0 ]
	[[ "$output" == *"B: FATAL"* ]]
	# A load-bearing miss must not write a half-patched file.
	[ "$(cat "$t")" == "$before" ]
}

@test "patch: duplicated spawn anchor fails loud (exactly-1 guard)" {
	cd "$WORK"
	local t; t="$(target)"
	# Append a second identical spawn shape.
	printf '\nfunction ygi2(A){return IE.spawn(A,["-socket",Vie()],{stdio:["pipe","pipe","pipe"]})}\n' >> "$t"
	run patch_cowork_bwrap
	[ "$status" -ne 0 ]
	[[ "$output" == *"B: FATAL"* ]]
	[[ "$output" == *"expected exactly 1"* ]]
}
