#!/usr/bin/env bats
#
# cowork-backend-detection.bats
# Tests for classifyBwrapProbeError — diagnoses why the bwrap sandbox
# probe failed so the daemon can emit actionable errors instead of
# silently falling through to a broken KVM backend (issue #351).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const {
    classifyBwrapProbeError,
} = require("'"${SCRIPT_DIR}"'/../scripts/cowork-vm-service.js");

function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
}

function assertEqual(actual, expected, msg) {
    assert(actual === expected,
        msg + " expected=" + JSON.stringify(expected) +
        " actual=" + JSON.stringify(actual));
}

function mkErr(stderr, message) {
    return {
        message: message || "Command failed",
        stderr: Buffer.from(stderr || ""),
        stdout: Buffer.from(""),
    };
}
'

# =============================================================================
# classifyBwrapProbeError — AppArmor / userns denials (the #351 case)
# =============================================================================

@test "classifyBwrapProbeError: bwrap EPERM on user namespace" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('bwrap: Creating new user namespace: Operation not permitted');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'userns', 'EPERM on userns should classify as userns');
assert(r.stderr.includes('user namespace'), 'stderr is preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: AppArmor denial message" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('bwrap: setting up uid map: Permission denied');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'userns', 'uid map denial should classify as userns');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: explicit apparmor keyword" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('denied by AppArmor policy');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'userns', 'apparmor keyword should classify as userns');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: CLONE_NEWUSER keyword in kernel log" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('bwrap: unshare: CLONE_NEWUSER failed: EPERM');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'userns', 'CLONE_NEW* should classify as userns');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: CAP_SYS_ADMIN hint" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('need CAP_SYS_ADMIN to create user namespace');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'userns', 'CAP_SYS_ADMIN hint should classify as userns');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# classifyBwrapProbeError — non-userns failures
# =============================================================================

@test "classifyBwrapProbeError: unrelated bwrap failure" {
	run node -e "${NODE_PREAMBLE}
const e = mkErr('bwrap: No such file or directory: /does-not-exist');
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'unknown', 'unrelated errors should classify as unknown');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: spawn ENOENT has no stderr" {
	run node -e "${NODE_PREAMBLE}
const e = { message: 'spawn bwrap ENOENT', code: 'ENOENT' };
const r = classifyBwrapProbeError(e);
assertEqual(r.kind, 'unknown', 'ENOENT without userns text is unknown');
assertEqual(r.stderr, '', 'missing stderr normalized to empty string');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: empty error object" {
	run node -e "${NODE_PREAMBLE}
const r = classifyBwrapProbeError({});
assertEqual(r.kind, 'unknown', 'empty error is unknown, not a crash');
assertEqual(r.stderr, '', 'missing stderr normalized to empty string');
"
	[[ "$status" -eq 0 ]]
}

@test "classifyBwrapProbeError: null-safe" {
	run node -e "${NODE_PREAMBLE}
const r = classifyBwrapProbeError(null);
assertEqual(r.kind, 'unknown', 'null error does not crash');
"
	[[ "$status" -eq 0 ]]
}
