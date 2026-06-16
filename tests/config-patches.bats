#!/usr/bin/env bats
#
# config-patches.bats
# Tests for scripts/patches/config.sh patch helpers.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PATCH_SH="$SCRIPT_DIR/../scripts/patches/config.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	project_root="$TEST_TMP"
	export project_root
	mkdir -p "$TEST_TMP/app.asar.contents/.vite/build"
	cd "$TEST_TMP" || return 1

	# shellcheck source=scripts/patches/config.sh
	source "$PATCH_SH"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

write_index_js() {
	local fixture='app.asar.contents/.vite/build/index.js'
	{
		printf '%s' \
			'function a(A,Y){for(let O of A)Y.push("--add-dir",O)}'
		printf '%s' \
			'function b(A,Y){for(let O of A)Y.push("--add-dir",O)}'
		printf '%s' \
			'function c(S){(S.userSelectedFolders||[]).filter(p=>true);'
		printf '%s' \
			'console.log("Filtering out deleted folder from session")}'
	} > "$fixture"
}

@test "additional dirs guard filters every --add-dir dispatch loop" {
	write_index_js

	run patch_asar_additional_dirs_guard
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}

	local patched='app.asar.contents/.vite/build/index.js'
	run grep -oF '.filter(_d=>!_d.endsWith(".asar"))' "$patched"
	[[ "$status" -eq 0 ]] || {
		echo 'expected .asar filters to be injected'
		return 1
	}
	[[ "${#lines[@]}" -eq 2 ]] || {
		echo "expected 2 dispatch filters, got ${#lines[@]}"
		return 1
	}

	run grep -qF 'for(let O of A)Y.push("--add-dir",O)' "$patched"
	[[ "$status" -eq 1 ]] || {
		echo 'unfiltered --add-dir dispatch remained'
		return 1
	}
}
