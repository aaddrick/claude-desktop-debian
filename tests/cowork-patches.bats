#!/usr/bin/env bats
#
# cowork-patches.bats
# Application tests for the Cowork index.js patches in
# scripts/patches/cowork.sh — specifically the yukonSilver
# renderer-gate fix (Patch 1b) and the paired VM-download block
# (Patch 1c). verify-patches.bats proves each marker regex matches its
# sample; this proves patch_cowork_linux() actually PRODUCES those
# markers from an unpatched bundle and is idempotent on re-run.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PATCH_SH="$SCRIPT_DIR/../scripts/patches/cowork.sh"
INDEX='app.asar.contents/.vite/build/index.js'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	mkdir -p "$TEST_TMP/app.asar.contents/.vite/build"
	cd "$TEST_TMP" || return 1
	# cowork-vm-service.js path is read by SVC_PATH-aware patches; a
	# bare placeholder is enough for the index.js transforms.
	: > "$TEST_TMP/cowork-vm-service.js"
	# shellcheck source=scripts/patches/cowork.sh
	source "$PATCH_SH"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Minimal minified fixture carrying the anchors patch_cowork_linux()
# needs: the "vmClient (TypeScript)" guard, the FATAL startVM gate
# (Patch 1), the q4r support evaluator (Patch 1b), and the two
# download gates u8A / mzn (Patch 1c-A / 1c-B). Other patches warn
# harmlessly on this fixture; only Patch 1 is fatal-on-miss.
write_cowork_fixture() {
	{
		printf '%s' \
'function VF(A,e,t){const{yukonSilver:r}=D_();if((r==null?void 0:r.status)!=="supported"){Ve.warn("[startVM] VM not supported ("+(r==null?void 0:r.status)+")");return}return ov()}'
		printf '%s' \
'function q4r(){var i;const A="win32",e=process.arch;if(e!=="x64"&&e!=="arm64")return{status:"unsupported",unsupportedCode:"unsupported_architecture"};if(!bl())return{status:"unsupported",unsupportedCode:"msix_required"};return{status:"supported"}}'
		printf '%s' \
'function u8A(A,e){const{yukonSilver:t}=z_();return(t==null?void 0:t.status)!=="supported"?!1:(ul(x,y).catch(()=>{}),TP?(Ve.info("[downloadVM] Download already in progress, waiting..."),TP):f6()?!1:P8r(A,e))}'
		printf '%s' \
'async function mzn(A,e,t){const{yukonSilver:i}=z_();if(!i||i.status!=="supported"){await YcA([]);return}if(!nOt()){await YcA([ao.sha]);return}}'
		printf '%s' \
'async function YBt(){return bl()?(QL||(Ve.info("vmClient (TypeScript)"),QL={vm:hji}),QL):null}'
	} > "$INDEX"
}

@test "patch_cowork_linux injects the evaluator + download-block markers" {
	write_cowork_fixture

	run patch_cowork_linux
	[[ "$status" -eq 0 ]] || {
		echo "patch_cowork_linux exited $status"
		echo "$output"
		return 1
	}

	# Patch 1b: evaluator reports supported on Linux at q4r's top.
	run grep -cP 'if\(process\.platform==="linux"\)return\{status:"supported"\};const [\w$]+="win32"' "$INDEX"
	[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
		echo "evaluator marker count: $output"
		return 1
	}

	# Patch 1c-A: VM-download driver short-circuits on Linux.
	run grep -cP 'process\.platform==="linux"\|\|\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported"\)\?!1:' "$INDEX"
	[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
		echo "vm-download-block marker count: $output"
		return 1
	}

	# Patch 1c-B: warm prefetch early-returns on Linux.
	run grep -cP 'if\(process\.platform==="linux"\|\|![\w$]+\|\|[\w$]+\.status!=="supported"\)\{await [\w$]+\(\[\]\);return\}' "$INDEX"
	[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
		echo "warm-download-block marker count: $output"
		return 1
	}
}

@test "patch_cowork_linux still parses as valid JS after patching" {
	write_cowork_fixture
	run patch_cowork_linux
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	run node --check "$INDEX"
	[[ "$status" -eq 0 ]] || {
		echo "patched fixture failed node --check"
		echo "$output"
		return 1
	}
}

@test "patch_cowork_linux is idempotent for the new markers" {
	write_cowork_fixture
	run patch_cowork_linux
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	cp "$INDEX" first.js

	# Second run must not double-inject and must be byte-identical.
	run patch_cowork_linux
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	run diff first.js "$INDEX"
	[[ "$status" -eq 0 ]] || {
		echo "re-run changed the bundle (not idempotent):"
		echo "$output"
		return 1
	}

	for marker in \
		'if\(process\.platform==="linux"\)return\{status:"supported"\}' \
		'process\.platform==="linux"\|\|\([\w$]+==null\?void 0:[\w$]+\.status\)!=="supported"\)\?!1:' \
		'if\(process\.platform==="linux"\|\|![\w$]+\|\|[\w$]+\.status!=="supported"\)'; do
		run grep -cP "$marker" "$INDEX"
		[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
			echo "marker not unique after re-run: $marker (count $output)"
			return 1
		}
	done
}
