#!/usr/bin/env bats
#
# launcher-disable-gpu.bats
# Tests for the CLAUDE_DISABLE_GPU env var handling in
# build_electron_args (scripts/launcher-common.sh). The var is an
# opt-in workaround for the Chromium GPU process FATAL exhaustion
# tracked in #583. CLAUDE_DISABLE_GPU=1 adds --disable-gpu and
# --disable-software-rasterizer; co-occurrence with XRDP must not
# stack duplicate flags.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LAUNCHER_COMMON="${SCRIPT_DIR}/../scripts/launcher-common.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# loginctl shim — same pattern as launcher-xrdp-detection.bats.
	# Defaults to a non-XRDP session so CLAUDE_DISABLE_GPU is the
	# only signal in play unless a test overrides MOCK_LOGINCTL_TYPE.
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/loginctl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_LOGINCTL_TYPE:-x11}"
SHIM
	chmod +x "$TEST_TMP/bin/loginctl"
	export PATH="$TEST_TMP/bin:$PATH"

	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"

	unset CLAUDE_DISABLE_GPU
	unset XRDP_SESSION
	unset XDG_SESSION_ID
	unset MOCK_LOGINCTL_TYPE

	# shellcheck disable=SC1090
	source "$LAUNCHER_COMMON"

	is_wayland=false
	use_x11_on_wayland=true
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

args_contain() {
	local needle="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && return 0
	done
	return 1
}

args_count() {
	local needle="$1"
	local arg count=0
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && ((count++))
	done
	printf '%d' "$count"
}

# =============================================================================
# CLAUDE_DISABLE_GPU=1 — flags must be added
# =============================================================================

@test "disable-gpu: CLAUDE_DISABLE_GPU=1 adds flags + logs message" {
	export CLAUDE_DISABLE_GPU=1

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
	grep -q 'CLAUDE_DISABLE_GPU=1' "$log_file"
}

# =============================================================================
# Co-occurrence with XRDP — no duplicate flags
# =============================================================================

@test "disable-gpu: with XRDP_SESSION, flags added exactly once (no dup)" {
	export CLAUDE_DISABLE_GPU=1
	export XRDP_SESSION=1
	export XDG_SESSION_ID=5
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args deb

	[[ "$(args_count '--disable-gpu')" -eq 1 ]]
	[[ "$(args_count '--disable-software-rasterizer')" -eq 1 ]]
	# Both signals should still log (independent diagnostic value),
	# but only one set of flags should reach electron_args.
	grep -q 'XRDP session detected' "$log_file"
	grep -q 'CLAUDE_DISABLE_GPU=1' "$log_file"
}

# =============================================================================
# Off-states — flags must NOT be added
# =============================================================================

@test "disable-gpu: unset — flags NOT added" {
	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: empty string — flags NOT added" {
	export CLAUDE_DISABLE_GPU=''

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: =0 — flags NOT added (only literal '1' opts in)" {
	export CLAUDE_DISABLE_GPU=0

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: =true — flags NOT added (no boolean aliases)" {
	# Documents the strict equality check. If we ever add aliases,
	# update this test to match. Strict-only matches the existing
	# CLAUDE_USE_WAYLAND pattern.
	export CLAUDE_DISABLE_GPU=true

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}

@test "disable-gpu: prior GPU fatal auto-disables on next launch" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start ---
LOG

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
	grep -q 'Previous launch hit GPU process FATAL' "$log_file"
}

@test "disable-gpu: recovery stays sticky on launch N+2 (no oscillation)" {
	# A recovered launch runs with --disable-gpu and writes no GPU
	# output, so the crash signature alone would re-enable GPU on
	# launch N+2 (crash/work/crash forever). The launcher's own
	# "disabling GPU" marker in the penultimate section must keep
	# recovery tripped.
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start ---
Previous launch hit GPU process FATAL - disabling GPU
--- Claude Desktop Launcher Start ---
LOG

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
}

@test "disable-gpu: NixOS launcher header sections are detected" {
	# nix/claude-desktop.nix writes "Launcher Start (NixOS)" headers;
	# the section regex must match them or recovery silently no-ops
	# on Nix.
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start (NixOS) ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start (NixOS) ---
LOG

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
	grep -q 'Previous launch hit GPU process FATAL' "$log_file"
}

@test "disable-gpu: CLAUDE_DISABLE_GPU=0 suppresses auto fallback" {
	cat > "$log_file" <<'LOG'
--- Claude Desktop Launcher Start ---
GPU process launch failed: error_code=1002
GPU process isn't usable. Goodbye.
--- Claude Desktop Launcher Start ---
LOG
	export CLAUDE_DISABLE_GPU=0

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
}
