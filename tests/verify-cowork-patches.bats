#!/usr/bin/env bats
#
# verify-cowork-patches.bats
# Tests for scripts/verify-cowork-patches.sh — the post-build static
# grep that confirms the 9 cowork patch markers (issue #559 D6 / PR
# #555) are present in the shipped index.js.
#
# Both these tests and the verify script consume the marker list from
# scripts/cowork-patch-markers.tsv, so adding a marker there
# automatically expands the test matrix below.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
VERIFY_SH="$SCRIPT_DIR/../scripts/verify-cowork-patches.sh"
MARKERS_TSV="$SCRIPT_DIR/../scripts/cowork-patch-markers.tsv"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	marker_names=()
	marker_patterns=()
	marker_samples=()
	local name pattern sample
	while IFS=$'\t' read -r name pattern sample; do
		[[ -z $name || $name == '#'* ]] && continue
		marker_names+=("$name")
		marker_patterns+=("$pattern")
		marker_samples+=("$sample")
	done < "$MARKERS_TSV"
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Build a fixture index.js containing every sample. If $1 is given,
# the marker with that name is omitted (used to drive the missing-
# marker negative tests).
write_fixture() {
	local omit="${1:-}"
	local fixture="$TEST_TMP/index.js"
	: > "$fixture"
	local i=0
	while [[ $i -lt ${#marker_names[@]} ]]; do
		if [[ ${marker_names[$i]} != "$omit" ]]; then
			printf '%s\n' "${marker_samples[$i]}" >> "$fixture"
		fi
		i=$((i + 1))
	done
	printf '%s\n' "$fixture"
}

# =============================================================================
# Marker file integrity
# =============================================================================

@test "markers file: every regex matches its sample" {
	local i=0
	while [[ $i -lt ${#marker_names[@]} ]]; do
		run grep -qP -- "${marker_patterns[$i]}" \
			<(printf '%s\n' "${marker_samples[$i]}")
		[[ "$status" -eq 0 ]] || {
			echo "regex did not match own sample: ${marker_names[$i]}"
			echo "pattern: ${marker_patterns[$i]}"
			echo "sample:  ${marker_samples[$i]}"
			return 1
		}
		i=$((i + 1))
	done
}

@test "markers file: at least 9 markers loaded" {
	[[ "${#marker_names[@]}" -ge 9 ]] || {
		echo "expected >= 9 markers, got ${#marker_names[@]}"
		return 1
	}
}

# =============================================================================
# Positive path: full fixture passes
# =============================================================================

@test "verify: exits 0 when every marker present" {
	local fixture
	fixture="$(write_fixture)"

	run "$VERIFY_SH" "$fixture"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected a fully-marked fixture'
		echo "$output"
		return 1
	}

	run grep -c 'OK ' <<< "$output"
	[[ "$output" -eq "${#marker_names[@]}" ]] || {
		echo "expected ${#marker_names[@]} OK lines, got: $output"
		return 1
	}
}

# =============================================================================
# Negative path: per-marker missing fixture
# =============================================================================

@test "verify: exits 2 and names the missing marker (each)" {
	local i=0
	local failures=0
	while [[ $i -lt ${#marker_names[@]} ]]; do
		local name="${marker_names[$i]}"
		local fixture
		fixture="$(write_fixture "$name")"

		run "$VERIFY_SH" "$fixture"
		if [[ "$status" -ne 2 ]]; then
			echo "missing $name should exit 2, got $status"
			echo "$output"
			failures=$((failures + 1))
		fi
		if ! grep -q "$name" <<< "$output"; then
			echo "missing $name not named in output"
			echo "$output"
			failures=$((failures + 1))
		fi
		i=$((i + 1))
	done
	[[ "$failures" -eq 0 ]]
}

# =============================================================================
# Input shapes
# =============================================================================

@test "verify: accepts a directory containing the asar layout" {
	local layout="$TEST_TMP/staging/app.asar.contents/.vite/build"
	mkdir -p "$layout"
	local i=0
	: > "$layout/index.js"
	while [[ $i -lt ${#marker_names[@]} ]]; do
		printf '%s\n' "${marker_samples[$i]}" >> "$layout/index.js"
		i=$((i + 1))
	done

	run "$VERIFY_SH" "$TEST_TMP/staging"
	[[ "$status" -eq 0 ]] || {
		echo 'verify rejected directory-shaped input'
		echo "$output"
		return 1
	}
}

@test "verify: rejects missing path with exit 1" {
	run "$VERIFY_SH" "$TEST_TMP/does-not-exist.js"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'not found'* ]]
}

@test "verify: rejects directory without expected layout" {
	mkdir -p "$TEST_TMP/empty"
	run "$VERIFY_SH" "$TEST_TMP/empty"
	[[ "$status" -eq 1 ]]
}

@test "verify: prints usage on no args and exits 1" {
	run "$VERIFY_SH"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'Usage:'* ]]
}

@test "verify: --help prints usage and exits 0" {
	run "$VERIFY_SH" --help
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'Usage:'* ]]
}
