#!/usr/bin/env bats
#
# cowork-mount-hide.bats
# Tests for mount modes and protected subpaths in the bwrap fallback
#
# For every granted folder the app sends a mode ("ro", "rw", "rwd",
# with "+hide" or "+hide+glob" appended when the folder holds protected
# subpaths) and a "hide" list of those subpaths (credential stores,
# keys, browser profiles), on both routes: spawn-time additionalMounts
# and mountPath(). These tests drive the real exported functions and a
# real BwrapBackend.spawn() against real directories, with only
# _spawnLocal stubbed to capture the bwrap argv.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const path = require("path");
const fs = require("fs");

const {
    parseMountMode,
    buildHideArgs,
    BwrapBackend,
} = require("'"${SCRIPT_DIR}"'/../cowork-vm-service.js");

function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
}

function assertEqual(actual, expected, msg) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    assert(a === e, msg + " expected=" + e + " actual=" + a);
}

const proj = process.env.PROJ;
const guest = "/sessions/s1/mnt/proj";
const sub = (abs) => path.relative("/", abs);

// Run the real spawn() and return the bwrap argv it would exec.
async function spawnArgs(backend, additionalMounts) {
    let captured = null;
    backend._spawnLocal = (id, cmd, args) => { captured = args; };
    await backend.spawn({
        id: "p1", name: "s1", command: process.execPath, args: [],
        additionalMounts,
    });
    assert(captured !== null, "spawn did not reach _spawnLocal");
    return captured;
}

// The triple [flag, src, dest] at its first occurrence, or -1.
function indexOfTriple(args, a, b, c) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === a && args[i + 1] === b && args[i + 2] === c) {
            return i;
        }
    }
    return -1;
}
'

setup() {
	TEST_TMP=$(mktemp -d)
	export HOME="$TEST_TMP/home/user"
	export PROJ="$HOME/proj"
	mkdir -p "$PROJ/.ssh" "$PROJ/src" "$PROJ/certs"
	echo key > "$PROJ/.ssh/id_ed25519"
	echo TOKEN=x > "$PROJ/.env"
	echo pem > "$PROJ/certs/server.PEM"
	echo ok > "$PROJ/certs/readme.txt"
	echo code > "$PROJ/src/main.js"
	unset XDG_CONFIG_HOME COWORK_VM_DEBUG
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

run_node() {
	node -e "${NODE_PREAMBLE}
$1"
}

# =============================================================================
# parseMountMode
# =============================================================================

@test "parseMountMode: every mode the app sends maps to its base" {
	run run_node '
const cases = {
    "ro": "--ro-bind", "ro+hide": "--ro-bind", "ro+hide+glob": "--ro-bind",
    "rw": "--bind", "rw+hide": "--bind", "rw+hide+glob": "--bind",
    "rwd": "--bind", "rwd+hide": "--bind", "rwd+hide+glob": "--bind",
};
for (const [mode, bind] of Object.entries(cases)) {
    const r = parseMountMode(mode);
    assertEqual(r.bindType, bind, mode);
    assert(r.known, mode + " should be known");
}
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "parseMountMode: a missing mode keeps the read-write default" {
	run run_node '
for (const m of [undefined, null, ""]) {
    assertEqual(parseMountMode(m).bindType, "--bind", String(m));
}
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "parseMountMode: an unknown mode fails closed to read-only" {
	run run_node '
const r = parseMountMode("bogus+hide");
assertEqual(r.bindType, "--ro-bind", "bogus");
assert(!r.known, "bogus should be flagged unknown");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

# =============================================================================
# buildHideArgs
# =============================================================================

@test "buildHideArgs: a protected directory gets a read-only empty tmpfs" {
	run run_node '
const r = buildHideArgs(proj, guest, [{ path: ".ssh" }]);
assert(r.ok, "should be ok");
assertEqual(r.args,
    ["--tmpfs", guest + "/.ssh", "--remount-ro", guest + "/.ssh"],
    "dir hide");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: a protected file is covered by /dev/null" {
	run run_node '
const r = buildHideArgs(proj, guest, [{ path: ".env" }]);
assertEqual(r.args, ["--ro-bind", "/dev/null", guest + "/.env"], "file hide");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: a leaf glob matches case-insensitively and nothing else" {
	run run_node '
const r = buildHideArgs(proj, guest,
    [{ path: "certs/*.pem", match: "leaf-glob" }]);
assert(r.ok, "should be ok");
assertEqual(r.hidden, ["certs/server.PEM"], "only the .PEM file");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: a symlink inside the mount is hidden where it lands" {
	ln -s .ssh "$PROJ/sshlink"
	run run_node '
const r = buildHideArgs(proj, guest, [{ path: "sshlink" }]);
assertEqual(r.hidden, [".ssh"], "resolved to the target");
assertEqual(r.args[1], guest + "/.ssh", "dest is the target, not the link");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: one location named twice is hidden once" {
	ln -s .ssh "$PROJ/sshlink"
	run run_node '
const r = buildHideArgs(proj, guest, [{ path: ".ssh" }, { path: "sshlink" }]);
assertEqual(r.hidden, [".ssh"], "deduplicated");
assertEqual(r.args.length, 4, "one tmpfs + remount");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: absent paths and links leaving the mount add nothing" {
	ln -s /etc/hostname "$PROJ/outside"
	run run_node '
const r = buildHideArgs(proj, guest,
    [{ path: "missing" }, { path: "outside" }, { path: "nodir/*.key", match: "leaf-glob" }]);
assert(r.ok, "should be ok");
assertEqual(r.args, [], "nothing to hide");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: a malformed entry fails the mount" {
	run run_node '
for (const bad of [[{ path: "../x" }], [{ path: "/abs" }], [{ path: "" }],
                   [{ path: "a/./b" }], [{ path: "a//b" }], [{}],
                   [{ path: "a", match: "regex" }]]) {
    const r = buildHideArgs(proj, guest, bad);
    assert(!r.ok, "should reject " + JSON.stringify(bad));
}
assert(!buildHideArgs(proj, guest, "not-a-list").ok, "non-list");
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "buildHideArgs: no hide list means no extra args" {
	run run_node '
for (const h of [undefined, null, []]) {
    const r = buildHideArgs(proj, guest, h);
    assert(r.ok, "ok for " + JSON.stringify(h));
    assertEqual(r.args, [], "no args for " + JSON.stringify(h));
}
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

# =============================================================================
# BwrapBackend.spawn, both routes
# =============================================================================

@test "spawn: an ro+hide mount is bound read-only with its hides after it" {
	run run_node '
(async () => {
    const b = new BwrapBackend(() => {});
    const args = await spawnArgs(b, {
        proj: { path: sub(proj), mode: "ro+hide", hide: [{ path: ".ssh" }] },
    });
    const bind = indexOfTriple(args, "--ro-bind", proj, guest);
    assert(bind >= 0, "proj must be --ro-bind: " + JSON.stringify(args));
    assertEqual(indexOfTriple(args, "--bind", proj, guest), -1, "not --bind");
    const hide = args.indexOf("--tmpfs", bind);
    assert(hide > bind && args[hide + 1] === guest + "/.ssh",
        ".ssh tmpfs must follow the bind");
})().catch((e) => { console.error(e); process.exit(1); });
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "spawn: an rw+hide+glob mount stays writable and hides the matches" {
	run run_node '
(async () => {
    const b = new BwrapBackend(() => {});
    const args = await spawnArgs(b, {
        proj: { path: sub(proj), mode: "rw+hide+glob",
                hide: [{ path: "certs/*.pem", match: "leaf-glob" }] },
    });
    assert(indexOfTriple(args, "--bind", proj, guest) >= 0, "rw bind");
    assert(indexOfTriple(args, "--ro-bind", "/dev/null",
        guest + "/certs/server.PEM") >= 0, "PEM hidden");
})().catch((e) => { console.error(e); process.exit(1); });
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "spawn: a mount with a malformed hide list is not bound" {
	run run_node '
(async () => {
    const b = new BwrapBackend(() => {});
    const args = await spawnArgs(b, {
        proj: { path: sub(proj), mode: "rw+hide", hide: [{ path: "../x" }] },
    });
    assertEqual(indexOfTriple(args, "--bind", proj, guest), -1, "no rw bind");
    assertEqual(indexOfTriple(args, "--ro-bind", proj, guest), -1, "no ro bind");
    // The skipped mount must not be the cwd either: bwrap would fail to
    // chdir into a directory it never created.
    assertEqual(args.slice(0, 2), ["--chdir", "/sessions/s1/mnt"],
        "cwd falls back to the mount root");
})().catch((e) => { console.error(e); process.exit(1); });
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "spawn: mountPath keeps the mode and hide list it was sent" {
	run run_node '
(async () => {
    const b = new BwrapBackend(() => {});
    await b.mountPath({ subpath: sub(proj), mountName: "proj",
        mode: "ro+hide", hide: [{ path: ".env" }] });
    const args = await spawnArgs(b, undefined);
    assert(indexOfTriple(args, "--ro-bind", proj, guest) >= 0,
        "mountPath mount must be read-only: " + JSON.stringify(args));
    assert(indexOfTriple(args, "--ro-bind", "/dev/null", guest + "/.env") >= 0,
        ".env hidden");
})().catch((e) => { console.error(e); process.exit(1); });
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}

@test "spawn: stopVM forgets mountPath options with the binds" {
	run run_node '
(async () => {
    const b = new BwrapBackend(() => {});
    await b.mountPath({ subpath: sub(proj), mountName: "proj",
        mode: "ro+hide", hide: [{ path: ".env" }] });
    await b.stopVM();
    assertEqual(b.mountOptions.size, 0, "options cleared");
    assertEqual(b.mountBinds.size, 0, "binds cleared");
})().catch((e) => { console.error(e); process.exit(1); });
'
	[[ $status -eq 0 ]] || { echo "$output"; false; }
}
