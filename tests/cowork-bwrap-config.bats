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
    mergeBwrapArgs,
} = require("'"${SCRIPT_DIR}"'/../scripts/cowork-vm-service.js");

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
    '--ro-bind', '/opt/tools', '/opt/tools',
    '--ro-bind', '/nix/store', '/nix/store'];
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
    '--bind', home + '/data', home + '/data'];
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
    '--ro-bind', '/opt/tools', '/opt/tools',
    '--bind', home + '/shared', home + '/shared'];
assertDeepEqual(result, expected, 'combined');
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
