#!/usr/bin/env bats
#
# cowork-session-mounts.bats
# Tests for session mount validation in the bwrap fallback (#676)
#
# The app sends every mount subpath as path.relative('/', abs), so a
# project folder outside $HOME arrives as e.g. "mnt/storage/proj".
# Before #676 the daemon fell back to ~/mnt/storage/proj, created it
# empty and bound that. These tests drive the real exported functions
# against a sandboxed $HOME and real directories under $TEST_TMP.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const path = require("path");
const os = require("os");
const fs = require("fs");

const {
    resolveAppSubpath,
    resolveHomeSubpath,
    validateSessionMount,
    buildMountMap,
    buildSpawnEnv,
    BwrapBackend,
} = require("'"${SCRIPT_DIR}"'/../cowork-vm-service.js");

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

// The app-side encoding of an absolute path (fD in the bundle).
const sub = (abs) => path.relative("/", abs);
const home = os.homedir();
const offHome = process.env.OFF_HOME;
'

setup() {
	TEST_TMP=$(mktemp -d)
	# A sandboxed $HOME and an off-home tree beside it, both real dirs.
	export HOME="$TEST_TMP/home/user"
	export OFF_HOME="$TEST_TMP/mnt/storage"
	mkdir -p "$HOME" "$OFF_HOME/proj"
	unset XDG_CONFIG_HOME COWORK_VM_DEBUG
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# resolveAppSubpath / resolveHomeSubpath (condition 5)
# =============================================================================

@test "resolveAppSubpath: off-home subpath stays off-home (#676)" {
	run node -e "${NODE_PREAMBLE}
assertEqual(resolveAppSubpath(sub(offHome + '/proj')), offHome + '/proj',
    'off-home root-relative subpath');
assertEqual(resolveAppSubpath(sub(home + '/proj')), home + '/proj',
    'home root-relative subpath');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "resolveHomeSubpath: internal names resolve under \$HOME" {
	run node -e "${NODE_PREAMBLE}
assertEqual(resolveHomeSubpath('.auto-memory'), home + '/.auto-memory', 'auto-memory');
assertEqual(resolveHomeSubpath('.claude'), home + '/.claude', 'claude');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildSpawnEnv: .auto-memory fallback stays under \$HOME (#676)" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({
    CLAUDE_COWORK_MEMORY_PATH_OVERRIDE: '/sessions/s1/mnt/.auto-memory/notes',
}, {});
assertEqual(env.CLAUDE_COWORK_MEMORY_PATH_OVERRIDE,
    home + '/.auto-memory/notes', 'memory override');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildSpawnEnv: CLAUDE_CONFIG_DIR ~/.claude is left alone (#676)" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({ CLAUDE_CONFIG_DIR: home + '/.claude' }, {});
assertEqual(env.CLAUDE_CONFIG_DIR, home + '/.claude', 'not doubled');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildSpawnEnv: a doubled CLAUDE_CONFIG_DIR is still fixed (#373)" {
	run node -e "${NODE_PREAMBLE}
const doubled = path.join(home, sub(home + '/.config/Claude/x'));
const env = buildSpawnEnv({ CLAUDE_CONFIG_DIR: doubled }, {});
assertEqual(env.CLAUDE_CONFIG_DIR, home + '/.config/Claude/x', 'undoubled');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

# =============================================================================
# validateSessionMount (conditions 2, 3, 4)
# =============================================================================

@test "validateSessionMount: accepts an existing off-home directory (#676)" {
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(offHome + '/proj'));
assert(r.valid, 'valid: ' + JSON.stringify(r));
assertEqual(r.hostPath, offHome + '/proj', 'bound path');
assertEqual(r.offHome, true, 'flagged off-home');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: rejects a missing off-home path (#676)" {
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(offHome + '/missing'));
assert(!r.valid, 'missing off-home must be rejected: ' + JSON.stringify(r));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: rejects an off-home file (#676)" {
	touch "$OFF_HOME/file"
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(offHome + '/file'));
assert(!r.valid, 'off-home file must be rejected: ' + JSON.stringify(r));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: a missing path under \$HOME is still accepted" {
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(home + '/.auto-memory'));
assert(r.valid, 'home path: ' + JSON.stringify(r));
assertEqual(r.hostPath, home + '/.auto-memory', 'bound path');
assertEqual(r.offHome, false, 'not off-home');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: rejects / and /proc, /sys, /dev (#676)" {
	run node -e "${NODE_PREAMBLE}
for (const p of ['/', '/proc', '/sys', '/dev', '/proc/1', '/dev/shm']) {
    const r = validateSessionMount(p === '/' ? '.' : sub(p));
    assert(!r.valid, p + ' must be rejected: ' + JSON.stringify(r));
}
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: rejects .. segments in the subpath (#676)" {
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(offHome + '/proj') + '/../proj');
assert(!r.valid, 'dot-dot must be rejected: ' + JSON.stringify(r));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: binds the symlink target, not the link (#676)" {
	ln -s "$OFF_HOME/proj" "$HOME/proj-link"
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(home + '/proj-link'));
assert(r.valid, 'link to existing off-home dir: ' + JSON.stringify(r));
assertEqual(r.hostPath, offHome + '/proj', 'resolved target is what binds');
assertEqual(r.offHome, true, 'judged by its target');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: a link within \$HOME binds its target (#676)" {
	mkdir -p "$HOME/real"
	ln -s "$HOME/real" "$HOME/home-link"
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(home + '/home-link'));
assert(r.valid, 'link within home: ' + JSON.stringify(r));
assertEqual(r.hostPath, fs.realpathSync(home + '/real'), 'resolved target is what binds');
assertEqual(r.offHome, false, 'still under home');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: a home link into /proc is rejected (#676)" {
	ln -s /proc/self "$HOME/proc-link"
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(home + '/proc-link'));
assert(!r.valid, 'link into /proc must be rejected: ' + JSON.stringify(r));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "validateSessionMount: a dangling home link is judged by its target (#676)" {
	# #896's resolution follows a dangling link's text, so the link
	# can't later grow a target outside the checked location.
	ln -s "$OFF_HOME/not-yet" "$HOME/dangling"
	run node -e "${NODE_PREAMBLE}
const r = validateSessionMount(sub(home + '/dangling'));
assert(!r.valid, 'dangling link to a missing off-home dir: ' + JSON.stringify(r));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

# =============================================================================
# Both routes share the validator (condition 1) and log (condition 6)
# =============================================================================

@test "buildMountMap: binds an existing off-home project folder (#676)" {
	run node -e "${NODE_PREAMBLE}
const map = buildMountMap({
    proj: { path: sub(offHome + '/proj'), mode: 'rw' },
    gone: { path: sub(offHome + '/missing'), mode: 'rw' },
    root: { path: '.', mode: 'rw' },
}, null);
assertEqual(map.proj, offHome + '/proj', 'off-home folder bound');
assert(!('gone' in map), 'missing off-home rejected');
assert(!('root' in map), 'root rejected');
assert(!fs.existsSync(home + offHome), 'no ~/<path> created');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "BwrapBackend.mountPath: binds an existing off-home folder (#676)" {
	run node -e "${NODE_PREAMBLE}
(async () => {
    const b = new BwrapBackend(() => {});
    const res = await b.mountPath({ subpath: sub(offHome + '/proj'), mountName: 'proj' });
    assertEqual(res.guestPath, offHome + '/proj', 'returned path');
    assertEqual(b.mountBinds.get('proj'), offHome + '/proj', 'stored bind');
    assert(!fs.existsSync(home + offHome), 'no ~/<path> created');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "BwrapBackend.mountPath: rejects what buildMountMap rejects (#676)" {
	run node -e "${NODE_PREAMBLE}
(async () => {
    const b = new BwrapBackend(() => {});
    for (const subpath of [sub(offHome + '/missing'), '.', 'proc/1',
            sub(offHome + '/proj') + '/../proj']) {
        let threw = false;
        try { await b.mountPath({ subpath, mountName: 'x' }); }
        catch (_) { threw = true; }
        assert(threw, 'must reject ' + subpath);
    }
    assertEqual(b.mountBinds.size, 0, 'nothing stored');
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "off-home binds are logged on both routes (#676)" {
	COWORK_VM_DEBUG=1 run node -e "${NODE_PREAMBLE}
(async () => {
    buildMountMap({ proj: { path: sub(offHome + '/proj'), mode: 'rw' } }, null);
    const b = new BwrapBackend(() => {});
    await b.mountPath({ subpath: sub(offHome + '/proj'), mountName: 'proj2' });
})().catch(e => { console.error(e); process.exit(1); });
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
	[[ "$output" == *"buildMountMap: accepting off-home mount \"proj\""* ]]
	[[ "$output" == *"BwrapBackend mountPath: accepting off-home mount \"proj2\""* ]]
}

# BwrapBackend.spawn execs bwrap, so pin its mkdir structurally: the
# recursive mkdir that used to create an empty ~/<path> must sit behind
# an isUnderHome() guard (condition 2).
@test "BwrapBackend spawn: mkdir only under \$HOME (#676)" {
	local svc="${SCRIPT_DIR}/../cowork-vm-service.js"
	run perl -0ne 'exit(!(
		/if\s*\(\s*!isUnderHome\(hostPath\)\s*\)\s*\{.*?continue;\s*\}\s*
		 fs\.mkdirSync\(hostPath,\s*\{\s*recursive:\s*true\s*\}\)/sx
	))' "$svc"
	[[ "$status" -eq 0 ]]
}
