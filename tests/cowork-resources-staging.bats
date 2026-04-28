#!/usr/bin/env bats
#
# cowork-resources-staging.bats
# Tests for scripts/staging/cowork-resources.sh — specifically that the
# cowork-plugin-shim.sh staged into place has LF line endings regardless
# of what the upstream Windows .exe extract shipped (issue #499).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Fake the staging layout the script expects.
	claude_extract_dir="$TEST_TMP/extract"
	electron_resources_dest="$TEST_TMP/dest"
	architecture='x64'
	mkdir -p "$claude_extract_dir/lib/net45/resources" \
		"$electron_resources_dest"

	# shellcheck source=scripts/_common.sh
	source "$SCRIPT_DIR/../scripts/_common.sh"
	# shellcheck source=scripts/staging/cowork-resources.sh
	source "$SCRIPT_DIR/../scripts/staging/cowork-resources.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Build a shim file at the upstream extract location with the requested
# line-ending style. Contents are a minimal valid bash script.
write_shim_src() {
	local style="$1"
	local shim="$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	printf '#!/bin/bash\n# Cowork plugin shim.\ncowork_require_token() {\n\treturn 0\n}\n' \
		> "$shim"
	if [[ $style == 'crlf' ]]; then
		sed -i 's/$/\r/' "$shim"
	fi
}

# =============================================================================
# CRLF normalization (issue #499)
# =============================================================================

@test "copy_cowork_resources: strips CRLF from Windows-encoded shim" {
	write_shim_src crlf

	# Sanity: source really is CRLF before we run the staging step.
	run grep -c $'\r$' \
		"$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	[[ "$status" -eq 0 ]]
	[[ "$output" -gt 0 ]]

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	[[ -f "$dest" ]]

	# No carriage returns survive into the staged copy.
	run grep -c $'\r' "$dest"
	[[ "$status" -eq 1 ]]
}

@test "copy_cowork_resources: staged shim is executable and bash-parsable" {
	write_shim_src crlf

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	[[ -x "$dest" ]]

	# bash -n would have failed on CRLF ($'\r': command not found).
	run bash -n "$dest"
	[[ "$status" -eq 0 ]]
}

@test "copy_cowork_resources: LF-only shim passes through unchanged" {
	write_shim_src lf

	local src="$claude_extract_dir/lib/net45/resources/cowork-plugin-shim.sh"
	local src_sum _
	read -r src_sum _ < <(sha256sum "$src")

	run copy_cowork_resources
	[[ "$status" -eq 0 ]]

	local dest="$electron_resources_dest/cowork-plugin-shim.sh"
	local dest_sum
	read -r dest_sum _ < <(sha256sum "$dest")
	[[ "$src_sum" == "$dest_sum" ]]
}

@test "copy_cowork_resources: missing shim emits warning without failing" {
	run copy_cowork_resources
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'cowork-plugin-shim.sh not found'* ]]
}
