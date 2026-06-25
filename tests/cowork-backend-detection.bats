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

# =============================================================================
# detectBackend — COWORK_VM_BACKEND override contract
#
# KVM uses a downloaded VM image; on Linux cowork normally runs through
# the bwrap daemon, and the renderer-gate fix (cowork.sh Patch 1b) is
# paired with a download block (Patch 1c) so the multi-GB VM bundle is
# never pulled. The daemon half of that policy is here: KVM is reachable
# only via an explicit COWORK_VM_BACKEND=kvm opt-in — auto-detect never
# selects it while bwrap works (#351). These pin the override contract;
# COWORK_VM_BACKEND is read at module load, so each case is a fresh
# process with the env preset.
# =============================================================================

# Resolve the backend class name for a given COWORK_VM_BACKEND value.
# detectBackend's log()/logError() chatter can land on stdout/stderr, so
# emit a sentinel and parse only that — robust against any log noise.
backend_name() {
	COWORK_VM_BACKEND="$1" node -e '
const { detectBackend } = require("'"${SCRIPT_DIR}"'/../scripts/cowork-vm-service.js");
const b = detectBackend(() => {});
process.stdout.write("\n__BACKEND__:" +
    (b && b.constructor ? b.constructor.name : "null") + "\n");
' 2>/dev/null | grep -oE '__BACKEND__:[A-Za-z]+' | cut -d: -f2
}

@test "detectBackend: COWORK_VM_BACKEND=kvm opts into KvmBackend" {
	[[ "$(backend_name kvm)" == "KvmBackend" ]] || {
		echo "expected KvmBackend, got: $(backend_name kvm)"
		return 1
	}
}

@test "detectBackend: COWORK_VM_BACKEND=bwrap selects BwrapBackend" {
	[[ "$(backend_name bwrap)" == "BwrapBackend" ]] || {
		echo "expected BwrapBackend, got: $(backend_name bwrap)"
		return 1
	}
}

@test "detectBackend: COWORK_VM_BACKEND=host selects HostBackend" {
	[[ "$(backend_name host)" == "HostBackend" ]] || {
		echo "expected HostBackend, got: $(backend_name host)"
		return 1
	}
}

@test "detectBackend: an unknown override never silently lands on KVM" {
	# Garbage override falls through to auto-detect, which prefers bwrap
	# and stops at host on probe failure — it must not become KVM (#351).
	local got
	got="$(backend_name not-a-backend)"
	[[ "$got" == "BwrapBackend" || "$got" == "HostBackend" ]] || {
		echo "unknown override resolved to unexpected backend: $got"
		return 1
	}
}
