#!/usr/bin/env bats
#
# launcher-xrdp-detection.bats
# Tests for the XRDP detection block in build_electron_args
# (scripts/launcher-common.sh). Remote XRDP sessions must disable GPU
# compositing or the Electron window renders blank (issue #319).
#
# The block detects XRDP via two independent signals:
#   1. XRDP_SESSION env var (set by xrdp's session init)
#   2. `loginctl show-session $XDG_SESSION_ID -p Type --value` == xrdp
#
# These tests mock loginctl with a PATH shim and inspect the
# electron_args array plus the log file after calling
# build_electron_args.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LAUNCHER_COMMON="${SCRIPT_DIR}/../scripts/launcher-common.sh"

setup() {
	# Isolated temp dir for PATH shim + log file
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Mock loginctl via PATH prepend. MOCK_LOGINCTL_TYPE controls
	# the stdout value; MOCK_LOGINCTL_EXIT controls the exit code.
	# Both are read from env at invocation time so each @test can
	# set them independently.
	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/loginctl" <<'SHIM'
#!/usr/bin/env bash
# Test shim for loginctl. Honours MOCK_LOGINCTL_TYPE and
# MOCK_LOGINCTL_EXIT from the environment.
if [[ -n ${MOCK_LOGINCTL_TRACE:-} ]]; then
	printf 'loginctl %s\n' "$*" >> "$MOCK_LOGINCTL_TRACE"
fi
if [[ ${MOCK_LOGINCTL_EXIT:-0} -ne 0 ]]; then
	exit "$MOCK_LOGINCTL_EXIT"
fi
printf '%s\n' "${MOCK_LOGINCTL_TYPE:-}"
SHIM
	chmod +x "$TEST_TMP/bin/loginctl"
	export PATH="$TEST_TMP/bin:$PATH"

	# log_message() appends to $log_file — point at /dev/null by
	# default, override in individual tests that need to inspect it.
	log_file="$TEST_TMP/launcher.log"
	: > "$log_file"

	# Scrub any XRDP/session env inherited from the outer shell so
	# tests start from a known baseline.
	unset XRDP_SESSION
	unset XDG_SESSION_ID
	unset MOCK_LOGINCTL_TYPE
	unset MOCK_LOGINCTL_EXIT
	unset MOCK_LOGINCTL_TRACE

	# shellcheck disable=SC1090
	source "$LAUNCHER_COMMON"

	# build_electron_args reads is_wayland / use_x11_on_wayland.
	# The XRDP block runs before they matter, but they must be set
	# to avoid unbound-variable errors on the later branches.
	is_wayland=false
	use_x11_on_wayland=true
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: true if electron_args contains the given flag.
args_contain() {
	local needle="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && return 0
	done
	return 1
}

# Helper: count occurrences of flag in electron_args.
args_count() {
	local needle="$1"
	local arg count=0
	for arg in "${electron_args[@]}"; do
		[[ $arg == "$needle" ]] && ((count++))
	done
	printf '%d' "$count"
}

# =============================================================================
# XRDP detected — flags must be added
# =============================================================================

@test "xrdp: XRDP_SESSION set, loginctl reports x11 — flags added" {
	export XRDP_SESSION=1
	export XDG_SESSION_ID=5
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
	grep -q 'XRDP session detected' "$log_file"
}

@test "xrdp: XRDP_SESSION unset, loginctl reports xrdp — flags added" {
	export XDG_SESSION_ID=7
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args deb

	args_contain '--disable-gpu'
	args_contain '--disable-software-rasterizer'
	grep -q 'XRDP session detected' "$log_file"
}

@test "xrdp: both signals fire — flags added exactly once (no dup)" {
	export XRDP_SESSION=1
	export XDG_SESSION_ID=9
	export MOCK_LOGINCTL_TYPE=xrdp

	build_electron_args deb

	[[ "$(args_count '--disable-gpu')" -eq 1 ]]
	[[ "$(args_count '--disable-software-rasterizer')" -eq 1 ]]
	[[ "$(grep -c 'XRDP session detected' "$log_file")" -eq 1 ]]
}

# =============================================================================
# Local session — flags must NOT be added
# =============================================================================

@test "local: XRDP_SESSION unset, loginctl reports x11 — flags NOT added" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
	run grep -q 'XRDP session detected' "$log_file"
	[[ "$status" -ne 0 ]]
}

@test "local: XRDP_SESSION unset, loginctl reports wayland — flags NOT added" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=wayland

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: loginctl exits nonzero — flags NOT added (graceful)" {
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_EXIT=1

	# When loginctl fails, the command substitution's nonzero exit
	# propagates up the `&&` chain; bats' errexit-in-tests would
	# abort if we called build_electron_args directly. In real
	# launchers (no set -e) this is harmless; absorb the status
	# explicitly so this test verifies behaviour, not strict-mode
	# policy.
	build_electron_args deb || true

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: XDG_SESSION_ID unset — loginctl not invoked, flags NOT added" {
	export MOCK_LOGINCTL_TRACE="$TEST_TMP/loginctl-trace.log"
	: > "$MOCK_LOGINCTL_TRACE"

	build_electron_args deb

	# loginctl shim must never have been invoked
	[[ ! -s "$MOCK_LOGINCTL_TRACE" ]]

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}

@test "local: XRDP_SESSION empty string — flags NOT added" {
	# Documents that [[ -n ${XRDP_SESSION:-} ]] is false for an
	# exported-but-empty var. If this test ever fails, the semantics
	# of the guard changed.
	export XRDP_SESSION=''
	export XDG_SESSION_ID=3
	export MOCK_LOGINCTL_TYPE=x11

	build_electron_args deb

	run args_contain '--disable-gpu'
	[[ "$status" -ne 0 ]]
	run args_contain '--disable-software-rasterizer'
	[[ "$status" -ne 0 ]]
}
