#!/usr/bin/env bats
#
# cowork-bwrap-config.bats
# Tests for configurable bwrap mount points (issue #339)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

NODE_PREAMBLE='
const path = require("path");
const os = require("os");
const fs = require("fs");

const {
    FORBIDDEN_MOUNT_PATHS,
    CRITICAL_MOUNTS,
    validateMountPath,
    loadBwrapMountsConfig,
    buildDefaultBwrapArgs,
    mergeBwrapArgs,
} = require("'"${SCRIPT_DIR}"'/../cowork-vm-service.js");

function loadBwrapMountsConfigWithLog(configPath, logFn) {
    return loadBwrapMountsConfig(configPath, logFn);
}

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

function assertDeepEqual(actual, expected, msg) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    assert(a === e, msg + " expected=" + e + " actual=" + a);
}
'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# The doctor checks resolve config via ${XDG_CONFIG_HOME:-$HOME/.config}.
	# Sandboxing HOME alone is insufficient because GitHub Actions runners
	# (and many user environments) export XDG_CONFIG_HOME ambient, which
	# overrides the per-test HOME and makes the function read the wrong dir.
	unset XDG_CONFIG_HOME
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# validateMountPath
# =============================================================================

@test "validateMountPath: rejects non-absolute paths" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('relative/path');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'relative');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /' }, 'root');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /proc" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'proc');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /dev" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/dev');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /dev' }, 'dev');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /sys" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/sys');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /sys' }, 'sys');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects subpaths of forbidden paths" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/proc/self');
assertDeepEqual(r1, { valid: false, reason: 'Path is under forbidden path: /proc' }, 'proc/self');
const r2 = validateMountPath('/dev/shm');
assertDeepEqual(r2, { valid: false, reason: 'Path is under forbidden path: /dev' }, 'dev/shm');
const r3 = validateMountPath('/sys/class');
assertDeepEqual(r3, { valid: false, reason: 'Path is under forbidden path: /sys' }, 'sys/class');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/tools', { readWrite: true });
assertDeepEqual(result,
    { valid: false, reason: 'Read-write mounts must be under \$HOME' },
    'rw outside home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RW paths under HOME" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const result = validateMountPath(home + '/projects/data', { readWrite: true });
assertDeepEqual(result, { valid: true }, 'rw under home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RW paths under real HOME on immutable distros (Silverblue/Bazzite)" {
	# On Fedora Silverblue/Bazzite, /home is a symlink to /var/home.
	# os.homedir() returns /home/<user> but fs.realpathSync resolves it to
	# /var/home/<user>. Without resolving $HOME before comparing, both the
	# symlink form (/home/user/dir) and the real form (/var/home/user/dir)
	# were rejected with "Read-write mounts must be under $HOME".
	#
	# This test builds the layout in TEST_TMP so it exercises the fix on
	# every host (CI runs on Ubuntu, where /home is not a symlink and the
	# un-pinned test passes even without the fix).

	local fake_home fake_varhome
	fake_home="${TEST_TMP}/fake-home"
	fake_varhome="${TEST_TMP}/fake-varhome"
	mkdir -p "${fake_home}" "${fake_varhome}/cloud/dev"
	ln -s "${fake_varhome}" "${fake_home}/home_link"

	# Set HOME to the symlink form so os.homedir() returns the unresolved
	# path.  validateMountPath then sees the same situation as on
	# Silverblue/Bazzite: os.homedir() = "/home/<user>", but
	# realpathSync() = "/var/home/<user>".  Both forms must pass.
	local home_path
	home_path="${fake_home}/home_link"
	export HOME="${home_path}"
	run node -e "${NODE_PREAMBLE}

const home = require('os').homedir();
let realHome = home;
try { realHome = require('fs').realpathSync(home); } catch (_) {}

// Symlink form: must pass regardless of whether realpath differs
const r1 = validateMountPath(home + '/cloud/dev', { readWrite: true });
assert(r1.valid, 'symlink-form home path must be accepted: ' + home + '/cloud/dev');

// Real path form: must also pass when realHome differs from home
const r2 = validateMountPath(realHome + '/dev', { readWrite: true });
assert(r2.valid, 'realpath-form home path must be accepted: ' + realHome + '/dev');

// Non-home path must still be rejected
const r3 = validateMountPath('/opt/tools', { readWrite: true });
assert(!r3.valid, '/opt/tools must still be rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RO paths anywhere (not forbidden)" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/opt/my-tools');
assertDeepEqual(r1, { valid: true }, 'opt ro');
const r2 = validateMountPath('/nix/store');
assertDeepEqual(r2, { valid: true }, 'nix ro');
const r3 = validateMountPath('/media/shared');
assertDeepEqual(r3, { valid: true }, 'media ro');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects empty string" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'empty');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: normalizes path before checking" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/../proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'traversal to proc');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects symlink to forbidden path" {
	local link_path="${TEST_TMP}/sneaky-link"
	ln -s /proc "$link_path"
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('${link_path}');
assert(!result.valid, 'symlink to /proc should be rejected');
assert(result.reason.includes('forbidden'), 'reason: ' + result.reason);
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts symlink to safe path" {
	local link_path="${TEST_TMP}/safe-link"
	ln -s /opt "$link_path"
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('${link_path}');
assertDeepEqual(result, { valid: true }, 'symlink to /opt should be accepted');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects a dot-dot segment after a symlink (#895)" {
	# path.resolve() drops '..' lexically, but bwrap gets the raw string
	# and the kernel applies '..' after the symlink: ~/etclink/../etc
	# validated as ~/etc and bound /etc.
	mkdir -p "$TEST_TMP/home/a..b"
	ln -s /etc "$TEST_TMP/home/etclink"
	ln -s / "$TEST_TMP/home/rootlink"
	export HOME="$TEST_TMP/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const r1 = validateMountPath(h + '/etclink/../etc', { readWrite: true });
assert(!r1.valid && r1.reason.includes('segments'),
    'rw bind of /etc through ~/etclink/..: ' + r1.reason);
const r2 = validateMountPath(h + '/rootlink/../proc');
assert(!r2.valid && r2.reason.includes('segments'),
    'ro bind of /proc through ~/rootlink/..: ' + r2.reason);
// Near miss: '..' inside a name is not a '..' segment.
const r3 = validateMountPath(h + '/a..b', { readWrite: true });
assertDeepEqual(r3, { valid: true }, 'name containing ..');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: resolves a not-yet-created path through its existing parent (#895)" {
	# realpathSync() fails on a path that doesn't exist, and the old
	# fallback kept the lexical form, so ~/outlink/not-yet passed the
	# \$HOME check and would bind outside HOME once created.
	mkdir -p "$TEST_TMP/home" "$TEST_TMP/outside"
	ln -s "$TEST_TMP/outside" "$TEST_TMP/home/outlink"
	export HOME="$TEST_TMP/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const rw = (p) => validateMountPath(p, { readWrite: true }).valid;
assert(!rw(h + '/outlink/not-yet'), 'missing leaf under symlink out of HOME');
assert(!rw(h + '/outlink/not-yet/deeper'), 'missing chain under symlink out of HOME');
assert(rw(h + '/not-yet/deeper'), 'missing chain under HOME');
// The missing tail must be kept: resolving only the existing prefix
// would turn this into '/', which is forbidden.
assert(validateMountPath('/cowork-bats-895-not-yet').valid,
    'missing top-level RO path');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: follows a dangling symlink to where it will land (#895)" {
	# realpathSync() also fails on a symlink whose target doesn't exist
	# yet, and the parent fallback then kept the link's own name, so
	# ~/dangle -> outside/newdir passed the \$HOME check and would bind
	# outside HOME once the target is created.
	mkdir -p "$TEST_TMP/home" "$TEST_TMP/outside"
	ln -s "$TEST_TMP/outside/newdir" "$TEST_TMP/home/dangle"
	ln -s "$TEST_TMP/outside/newdir" "$TEST_TMP/home/dangledir"
	ln -s "$TEST_TMP/home/inside-new" "$TEST_TMP/home/dangle-in-abs"
	ln -s inside-new "$TEST_TMP/home/dangle-in-rel"
	ln -s loop-b "$TEST_TMP/home/loop-a"
	ln -s loop-a "$TEST_TMP/home/loop-b"
	export HOME="$TEST_TMP/home"
	run node -e "${NODE_PREAMBLE}
const h = os.homedir();
const rw = (p) => validateMountPath(p, { readWrite: true }).valid;
assert(!rw(h + '/dangle'), 'dangling link out of HOME');
assert(!rw(h + '/dangledir/sub'), 'missing path under dangling link out of HOME');
assert(rw(h + '/dangle-in-abs'), 'dangling absolute link inside HOME');
assert(rw(h + '/dangle-in-rel'), 'dangling relative link inside HOME');
// A symlink loop must stop at the kernel's 40-hop limit. Counting the
// reads is the only way to see it: an unbounded walk ends in a stack
// overflow that the fallback's own catch swallows, so it still returns.
const readlinkSync = fs.readlinkSync;
let reads = 0;
fs.readlinkSync = (...a) => { reads++; return readlinkSync(...a); };
validateMountPath(h + '/loop-a', { readWrite: true });
fs.readlinkSync = readlinkSync;
assert(reads > 0 && reads <= 41, 'loop followed ' + reads + ' links');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig
# =============================================================================

@test "loadBwrapMountsConfig: returns empty config when file does not exist" {
	run node -e "${NODE_PREAMBLE}
const result = loadBwrapMountsConfig('/nonexistent/path/config.json');
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'missing file');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when JSON has no preferences" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ mcpServers: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no preferences');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when coworkBwrapMounts is absent" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ preferences: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no coworkBwrapMounts');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: parses valid configuration" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/nix/store'],
            additionalBinds: [os.homedir() + '/shared-data'],
            disabledDefaultBinds: ['/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [os.homedir() + '/shared-data'],
    disabledDefaultBinds: ['/etc']
}, 'valid config');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config on invalid JSON" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, '{ invalid json }');
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'invalid json');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out invalid paths from additionalROBinds" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/proc', 'relative', '/dev', '/nix/store']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'filtered ro binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [home + '/valid', '/opt/invalid', home + '/also-valid']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalBinds, [home + '/valid', home + '/also-valid'],
    'filtered rw binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: ignores non-array values" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: 'not-an-array',
            additionalBinds: 42,
            disabledDefaultBinds: { bad: true }
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'non-array values');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters non-string entries from arrays" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', 42, null, '/nix/store', true]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'non-string entries filtered');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: normalizes disabledDefaultBinds paths" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['/etc/../usr', '/tmp/./']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.disabledDefaultBinds, ['/usr', '/tmp'],
    'paths should be normalized');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects critical mounts in disabledDefaultBinds" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }

const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['/', '/dev', '/proc', '/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath, logWarn);
assertDeepEqual(result.disabledDefaultBinds, ['/etc'],
    'only /etc should survive');
assertEqual(warnings.length, 3, 'three critical mount warnings');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects relative disabledDefaultBinds" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            disabledDefaultBinds: ['relative/path', '/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.disabledDefaultBinds, ['/etc'],
    'relative path should be rejected');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# mergeBwrapArgs — disabled default binds
# =============================================================================

@test "mergeBwrapArgs: returns default args when config is empty" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: []
});
assertDeepEqual(result, defaults, 'unchanged');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: removes disabled default ro-bind" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
assertDeepEqual(result, expected, 'etc removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: refuses to disable --tmpfs /, --dev /dev, --proc /proc" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/', '/dev', '/proc']
});
assertDeepEqual(result, defaults, 'critical mounts preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: can disable /tmp and /run" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/tmp', '/run']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
assertDeepEqual(result, expected, 'tmp and run removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RO binds" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dir', '/opt', '--ro-bind', '/opt/tools', '/opt/tools',
    '--dir', '/nix', '--ro-bind', '/nix/store', '/nix/store'];
assertDeepEqual(result, expected, 'ro appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RW binds" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [home + '/data'],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dir', home, '--bind', home + '/data', home + '/data'];
assertDeepEqual(result, expected, 'rw appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: combined disable + add" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [home + '/shared'],
    disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run',
    '--dir', '/opt', '--ro-bind', '/opt/tools', '/opt/tools',
    '--dir', home, '--bind', home + '/shared', home + '/shared'];
assertDeepEqual(result, expected, 'combined');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: pre-creates parent dir for immutable-distro home paths" {
	# On Fedora Silverblue/Bazzite, os.homedir() returns /var/home/<user>.
	# bwrap auto-creates missing bind-destination parents itself, so the
	# preceding --dir is path-creation hardening, not a fix for a dropped
	# mount (#702's real cause is the /home vs /var/home symlink mismatch;
	# see docs/configuration.md). The --dir must target the parent, never
	# the destination itself, or file binds break (next two tests).
	run node -e "${NODE_PREAMBLE}
const varHome = '/var/home/cloud';
const defaults = ['--tmpfs', '/'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [varHome + '/dev'],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/',
    '--dir', varHome, '--bind', varHome + '/dev', varHome + '/dev'
], 'immutable-distro dir bind');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: file bind targets --dir at parent, not the file dst" {
	# additionalBinds may name a single file (e.g. ~/.gitconfig).
	# Emitting --dir on the file dst itself would pre-create it as a
	# directory and bwrap would die with 'Can't create file at ...: Is a
	# directory'. Only the parent may be pre-created.
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [home + '/.gitconfig'],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/',
    '--dir', home, '--bind', home + '/.gitconfig', home + '/.gitconfig'
], 'file bind');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: file overlay onto RO parent emits --dir on existing parent only" {
	# Overlaying a file onto a default RO mount (e.g. a custom /etc/hosts
	# over the default /etc ro-bind) works today. --dir /etc/hosts would
	# die with 'Can't mkdir /etc/hosts: Not a directory'; --dir /etc is a
	# no-op on the already-mounted parent.
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/etc', '/etc'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [{ src: home + '/hosts', dst: '/etc/hosts' }],
    additionalBinds: [],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/', '--ro-bind', '/etc', '/etc',
    '--dir', '/etc', '--ro-bind', home + '/hosts', '/etc/hosts'
], 'file overlay onto RO parent');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: handles extended bwrap flags correctly" {
	run node -e "${NODE_PREAMBLE}
const defaults = [
    '--ro-bind', '/usr', '/usr',
    '--ro-bind-try', '/opt/lib', '/opt/lib',
    '--dev-bind', '/dev/dri', '/dev/dri',
    '--setenv', 'DISPLAY', ':0',
    '--chdir', '/home/user',
    '--unshare-pid', '--die-with-parent',
];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/opt/lib']
});
const expected = [
    '--ro-bind', '/usr', '/usr',
    '--dev-bind', '/dev/dri', '/dev/dri',
    '--setenv', 'DISPLAY', ':0',
    '--chdir', '/home/user',
    '--unshare-pid', '--die-with-parent',
];
assertDeepEqual(result, expected, 'extended flags parsed correctly');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildBwrapArgsWithConfig (integration)
# =============================================================================

@test "buildBwrapArgsWithConfig: includes user mounts in final args" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/my-sdk'],
            additionalBinds: [home + '/workspace'],
            disabledDefaultBinds: []
        }
    }
}));
const config = loadBwrapMountsConfig(configPath);
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
const result = mergeBwrapArgs(defaults, config);

const roIdx = result.indexOf('--ro-bind', result.indexOf('/usr') + 1);
assertEqual(result[roIdx + 1], '/opt/my-sdk', 'ro-bind src');
assertEqual(result[roIdx + 2], '/opt/my-sdk', 'ro-bind dest');

const rwIdx = result.indexOf('--bind');
assertEqual(result[rwIdx + 1], home + '/workspace', 'bind src');
assertEqual(result[rwIdx + 2], home + '/workspace', 'bind dest');
"
	[[ "$status" -eq 0 ]]
}

@test "buildBwrapArgsWithConfig: user RO mounts come before session mounts" {
	run node -e "${NODE_PREAMBLE}
const config = {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [],
    disabledDefaultBinds: []
};
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const merged = mergeBwrapArgs(defaults, config);

const fullArgs = [...merged, '--bind', '/home/user/project', '/sessions/s/mnt/project',
    '--unshare-pid', '--die-with-parent', '--new-session'];

const optIdx = fullArgs.indexOf('/opt/tools');
const sessionBindIdx = fullArgs.indexOf('--bind');
assert(optIdx < sessionBindIdx,
    'user RO mount (' + optIdx + ') before session bind (' + sessionBindIdx + ')');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig: logging
# =============================================================================

@test "loadBwrapMountsConfig: logs rejected paths" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }

const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/proc', '/opt/ok'],
            additionalBinds: ['/outside/home']
        }
    }
}));
const result = loadBwrapMountsConfigWithLog(configPath, logWarn);
assertEqual(result.additionalROBinds.length, 1, 'one valid ro');
assertEqual(warnings.length, 2, 'two warnings logged');
assert(warnings[0].includes('/proc'), 'warns about /proc');
assert(warnings[1].includes('/outside/home'), 'warns about rw outside home');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# {src, dst} mount form — distinct host/sandbox paths
# =============================================================================

@test "loadBwrapMountsConfig: accepts RO {src,dst} with src outside HOME" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [{ src: '/opt/tools', dst: '/sandbox/tools' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds,
    [{ src: '/opt/tools', dst: '/sandbox/tools' }],
    'object form preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: accepts RW {src,dst} with src under HOME and dst outside HOME" {
	# This is the /tmp persistence use case: src under \$HOME (passes RW
	# constraint) but dst can be anywhere (e.g. /tmp inside the sandbox).
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [{ src: home + '/persistent-tmp', dst: '/tmp' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalBinds,
    [{ src: home + '/persistent-tmp', dst: '/tmp' }],
    'persistent /tmp mapping accepted');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects RW {src,dst} with src outside HOME" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [{ src: '/opt/anywhere', dst: '/sandbox/x' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath, logWarn);
assertDeepEqual(result.additionalBinds, [], 'rejected');
assertEqual(warnings.length, 1, 'one warning');
assert(warnings[0].includes('/opt/anywhere'), 'warns about src');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects {src,dst} with forbidden src" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [{ src: '/proc', dst: '/sandbox/p' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [], 'forbidden src rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects {src,dst} with forbidden dst" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [{ src: '/opt/tools', dst: '/proc' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [], 'forbidden dst rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects {src,dst} with dst under forbidden path" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [{ src: '/opt/tools', dst: '/proc/self' }]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [], 'dst under /proc rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects {src,dst} with non-absolute paths" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [
                { src: 'rel/src', dst: '/abs/dst' },
                { src: '/abs/src', dst: 'rel/dst' }
            ]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [], 'both rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: rejects malformed mount objects" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [
                { src: '/opt/a' },
                { dst: '/sandbox/b' },
                { src: 42, dst: '/sandbox/c' },
                {},
                null
            ]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [], 'all malformed rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: accepts mix of string and {src,dst} forms" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: [
                '/opt/tools',
                { src: '/nix/store', dst: '/sandbox/nix' }
            ],
            additionalBinds: [
                home + '/data',
                { src: home + '/cache', dst: '/tmp' }
            ]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, [
    '/opt/tools',
    { src: '/nix/store', dst: '/sandbox/nix' }
], 'ro mix preserved');
assertDeepEqual(result.additionalBinds, [
    home + '/data',
    { src: home + '/cache', dst: '/tmp' }
], 'rw mix preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: emits --ro-bind src dst for object form" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [{ src: '/opt/tools', dst: '/sandbox/tools' }],
    additionalBinds: [],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/',
    '--dir', '/sandbox', '--ro-bind', '/opt/tools', '/sandbox/tools'
], 'ro object form');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: emits --bind src dst for object form" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [{ src: home + '/persistent', dst: '/tmp' }],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/',
    '--dir', '/', '--bind', home + '/persistent', '/tmp'
], 'rw object form');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: mixes string and object forms in same config" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [
        '/opt/tools',
        { src: '/nix/store', dst: '/sandbox/nix' }
    ],
    additionalBinds: [
        home + '/data',
        { src: home + '/cache', dst: '/tmp' }
    ],
    disabledDefaultBinds: []
});
assertDeepEqual(result, [
    '--tmpfs', '/',
    '--dir', '/opt', '--ro-bind', '/opt/tools', '/opt/tools',
    '--dir', '/sandbox', '--ro-bind', '/nix/store', '/sandbox/nix',
    '--dir', home, '--bind', home + '/data', home + '/data',
    '--dir', '/', '--bind', home + '/cache', '/tmp'
], 'mixed forms');
"
	[[ "$status" -eq 0 ]]
}

@test "buildBwrapArgsWithConfig: persistent /tmp via {src,dst} and disabled default" {
	# The full /tmp persistence recipe: disable the default --tmpfs /tmp,
	# then bind a host path under \$HOME onto /tmp inside the sandbox.
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [{ src: home + '/claude-tmp', dst: '/tmp' }],
            disabledDefaultBinds: ['/tmp']
        }
    }
}));
const config = loadBwrapMountsConfig(configPath);
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, config);

assert(!result.includes('/tmp')
    || result.indexOf('--tmpfs') !== result.lastIndexOf('--tmpfs')
    || result[result.indexOf('--tmpfs') + 1] !== '/tmp',
    'default --tmpfs /tmp must be removed');

const bindIdx = result.indexOf('--bind');
assertEqual(result[bindIdx + 1], home + '/claude-tmp', 'bind src');
assertEqual(result[bindIdx + 2], '/tmp', 'bind dst');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# --doctor integration (bash)
# =============================================================================

@test "doctor: reports custom bwrap mounts" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalROBinds": ["/opt/tools"],
	            "additionalBinds": ["${home_tmp}/data"],
	            "disabledDefaultBinds": ["/etc"]
	        }
	    }
	}
	ENDJSON

	# Source launcher-common.sh and run the doctor check function
	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	# Override HOME for config path resolution
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"/opt/tools"* ]]
	[[ "$output" == *"data"* ]]
	[[ "$output" == *"/etc"* ]]
	[[ "$output" == *"WARN"* ]]
}

@test "doctor: warns about disabled critical mount /usr" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "disabledDefaultBinds": ["/usr"]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"WARN"* ]]
	[[ "$output" == *"/usr"* ]]
}

@test "doctor: renders {src,dst} mounts as 'src -> dst'" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalROBinds": [
	                { "src": "/opt/tools", "dst": "/sandbox/tools" }
	            ],
	            "additionalBinds": [
	                { "src": "${home_tmp}/persistent-tmp", "dst": "/tmp" }
	            ]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"/opt/tools -> /sandbox/tools"* ]]
	[[ "$output" == *"persistent-tmp -> /tmp"* ]]
}

@test "doctor: warns when {src,dst} dst shadows a default RO mount" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalBinds": [
	                { "src": "${home_tmp}/fake-etc", "dst": "/etc/foo" }
	            ]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"WARN"* ]]
	[[ "$output" == *"/etc/foo"* ]]
	[[ "$output" == *"shadows a default sandbox mount"* ]]
}

@test "doctor: does not warn when {src,dst} dst is safe (e.g. /tmp, /sandbox/...)" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalBinds": [
	                { "src": "${home_tmp}/cache", "dst": "/tmp" }
	            ],
	            "additionalROBinds": [
	                { "src": "/opt/tools", "dst": "/sandbox/tools" }
	            ]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" != *"shadows a default sandbox mount"* ]]
}

@test "doctor: no output when no custom mounts configured" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	echo '{}' > "$config_file"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	# Should just show info that no custom mounts are configured
	[[ "$output" != *"FAIL"* ]]
}

# =============================================================================
# _find_virtiofsd (issue #447)
# =============================================================================

@test "_find_virtiofsd: finds virtiofsd on PATH" {
	mkdir -p "${TEST_TMP}/bin"
	local stub="${TEST_TMP}/bin/virtiofsd"
	printf '#!/bin/sh\nexit 0\n' > "$stub"
	chmod +x "$stub"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	PATH="${TEST_TMP}/bin" \
		_COWORK_VFSD_PATHS='/nonexistent/virtiofsd' \
		run _find_virtiofsd
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$stub" ]]
}

@test "_find_virtiofsd: falls back to /usr/libexec-like path" {
	mkdir -p "${TEST_TMP}/libexec"
	local stub="${TEST_TMP}/libexec/virtiofsd"
	printf '#!/bin/sh\nexit 0\n' > "$stub"
	chmod +x "$stub"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	# Empty PATH so `command -v` cannot resolve virtiofsd
	PATH='' \
		_COWORK_VFSD_PATHS="$stub" \
		run _find_virtiofsd
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$stub" ]]
}

@test "_find_virtiofsd: tries fallback paths in order" {
	mkdir -p "${TEST_TMP}/alt"
	local stub="${TEST_TMP}/alt/virtiofsd"
	printf '#!/bin/sh\nexit 0\n' > "$stub"
	chmod +x "$stub"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	# First fallback is missing; second is present. Expect second.
	PATH='' \
		_COWORK_VFSD_PATHS="/nonexistent/virtiofsd:$stub" \
		run _find_virtiofsd
	[[ "$status" -eq 0 ]]
	[[ "$output" == "$stub" ]]
}

@test "_find_virtiofsd: returns non-zero and empty when missing" {
	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	PATH='' \
		_COWORK_VFSD_PATHS='/nonexistent/a:/nonexistent/b' \
		run _find_virtiofsd
	[[ "$status" -eq 1 ]]
	[[ -z "$output" ]]
}

@test "_find_virtiofsd: skips non-executable fallback paths" {
	mkdir -p "${TEST_TMP}/libexec"
	local stub="${TEST_TMP}/libexec/virtiofsd"
	# Create a readable but NOT executable file — must be rejected
	printf 'not executable\n' > "$stub"
	chmod 644 "$stub"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	PATH='' \
		_COWORK_VFSD_PATHS="$stub" \
		run _find_virtiofsd
	[[ "$status" -eq 1 ]]
	[[ -z "$output" ]]
}

@test "_find_virtiofsd: default path list covers deb/rpm/arch" {
	# Guard against regression: the built-in fallback list (used when
	# _COWORK_VFSD_PATHS is unset) must include the off-PATH
	# install locations for Debian/Ubuntu, legacy Debian, and Arch.
	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	local body
	body=$(declare -f _find_virtiofsd)
	[[ "$body" == *'/usr/libexec/virtiofsd'* ]]
	[[ "$body" == *'/usr/lib/qemu/virtiofsd'* ]]
	[[ "$body" == *'/usr/lib/virtiofsd'* ]]
}

# =============================================================================
# Session teardown flags (#369)
#
# The fallback daemon must take its sessions down with it on quit. Two
# things guarantee that; this file's live tests cover the mount-arg
# merge, but nothing pinned the isolation flags on the actual session
# spawn. BwrapBackend.spawn is not exported and execs bwrap, so this is
# a structural pin on the spawn call's argv: the session must be
# unshared into its own PID namespace AND carry --die-with-parent, which
# is what makes bwrap SIGKILL the whole sandbox when the daemon dies —
# covering even the launcher reaper's SIGTERM-timeout SIGKILL of a stuck
# daemon (a plain SIGKILL runs no graceful stopVM). Drop the flag and a
# quit that SIGKILLs the daemon orphans the sandbox; this reds.
# =============================================================================

@test "BwrapBackend session spawn carries PID-namespace + die-with-parent" {
	local svc="${SCRIPT_DIR}/../cowork-vm-service.js"
	# The four tokens must appear in this order in a single push() on the
	# session command, unshare-pid immediately guarding die-with-parent
	# and new-session, then the -- command separator.
	run perl -0ne 'exit(!(
		/bwrapArgs\.push\(\s*
		 .--unshare-pid.,\s*
		 .--die-with-parent.,\s*
		 .--new-session.,\s*
		 .--.,/sx
	))' "$svc"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildDefaultBwrapArgs (#667)
#
# On NixOS every binary lives in /nix/store, and inside a buildFHSEnv
# (appimage-run) /usr/bin/* points there while most /etc entries point
# into /.host-etc. The session sandbox must bind both, read-only, when
# they exist, or /usr/bin/bash is a dangling link. A fake fs stands in
# for the host so the cases don't depend on where the suite runs.
# =============================================================================

# Fake fs: $1 = JS array of paths that exist, $2 = JS object of
# symlink -> target. Defines fakeFs and hasBind in the node script.
_fake_fs() {
	printf '%s' "
const present = new Set($1);
const links = $2;
const fakeFs = {
    existsSync: p => present.has(p) || p in links,
    readlinkSync: p => {
        if (p in links) return links[p];
        const e = new Error('EINVAL: ' + p); e.code = 'EINVAL'; throw e;
    },
};
function hasBind(args, flag, src, dst) {
    for (let i = 0; i + 2 < args.length; i++) {
        if (args[i] === flag && args[i + 1] === src && args[i + 2] === dst) {
            return true;
        }
    }
    return false;
}
"
}

@test "buildDefaultBwrapArgs: binds /nix read-only when present (#667)" {
	run node -e "${NODE_PREAMBLE}
$(_fake_fs "['/nix']" '{}')
const args = buildDefaultBwrapArgs(fakeFs);
assert(hasBind(args, '--ro-bind', '/nix', '/nix'), 'ro-bind /nix: ' + JSON.stringify(args));
assert(!hasBind(args, '--bind', '/nix', '/nix'), '/nix must not be writable');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildDefaultBwrapArgs: binds /.host-etc read-only when present (#667)" {
	run node -e "${NODE_PREAMBLE}
$(_fake_fs "['/.host-etc']" '{}')
const args = buildDefaultBwrapArgs(fakeFs);
assert(hasBind(args, '--ro-bind', '/.host-etc', '/.host-etc'), 'ro-bind /.host-etc: ' + JSON.stringify(args));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildDefaultBwrapArgs: no /nix or /.host-etc bind when absent (#667)" {
	run node -e "${NODE_PREAMBLE}
$(_fake_fs '[]' '{}')
const args = buildDefaultBwrapArgs(fakeFs);
assert(!args.includes('/nix'), 'no /nix: ' + JSON.stringify(args));
assert(!args.includes('/.host-etc'), 'no /.host-etc: ' + JSON.stringify(args));
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildDefaultBwrapArgs: base layout and merged-usr handling unchanged" {
	run node -e "${NODE_PREAMBLE}
$(_fake_fs "['/lib64']" "{'/bin': 'usr/bin', '/lib': 'usr/lib', '/sbin': 'usr/sbin'}")
const args = buildDefaultBwrapArgs(fakeFs);
assertDeepEqual(args, [
    '--tmpfs', '/',
    '--ro-bind', '/usr', '/usr',
    '--ro-bind', '/etc', '/etc',
    '--dev', '/dev',
    '--proc', '/proc',
    '--tmpfs', '/tmp',
    '--tmpfs', '/run',
    '--symlink', 'usr/bin', '/bin',
    '--symlink', 'usr/lib', '/lib',
    '--ro-bind', '/lib64', '/lib64',
    '--symlink', 'usr/sbin', '/sbin',
], 'default layout');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

@test "buildDefaultBwrapArgs: disabledDefaultBinds can still drop /nix (#667)" {
	run node -e "${NODE_PREAMBLE}
$(_fake_fs "['/nix', '/.host-etc']" '{}')
const merged = mergeBwrapArgs(buildDefaultBwrapArgs(fakeFs), {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/nix'],
});
assert(!merged.includes('/nix'), '/nix dropped: ' + JSON.stringify(merged));
assert(hasBind(merged, '--ro-bind', '/.host-etc', '/.host-etc'), '/.host-etc kept');
"
	[[ "$status" -eq 0 ]] || { echo "$output"; false; }
}

# BwrapBackend.spawn is not exported, so pin that it builds its defaults
# with buildDefaultBwrapArgs and merges user config on top of them;
# otherwise the cases above test a function the session never calls.
@test "BwrapBackend session spawn uses buildDefaultBwrapArgs (#667)" {
	local svc="${SCRIPT_DIR}/../cowork-vm-service.js"
	run perl -0ne 'exit(!(
		/const\s+defaultBwrapArgs\s*=\s*buildDefaultBwrapArgs\(\s*\)/s
		&& /mergeBwrapArgs\(\s*defaultBwrapArgs\s*,/s
	))' "$svc"
	[[ "$status" -eq 0 ]]
}
