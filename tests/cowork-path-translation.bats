#!/usr/bin/env bats
#
# cowork-path-translation.bats
# Tests for guest-path translation functions in cowork-vm-service.js
#
# Since the functions are not exported from the service file, we
# redefine the pure logic inline in each Node.js invocation. This
# avoids importing the full service (which starts a socket server).
#

# -- Shared Node.js preamble that defines the functions under test --------
# We store it in a variable so every test can prepend it.

NODE_PREAMBLE='
const path = require("path");
const fs = require("fs");
const os = require("os");

// Stub the log() function used inside the real code
function log() {}

function translateGuestPath(guestPath, mountMap) {
    if (!guestPath || !guestPath.startsWith("/sessions/")) return null;
    if (!mountMap || Object.keys(mountMap).length === 0) return null;

    const match = guestPath.match(
        /^\/sessions\/[^/]+\/mnt\/([^/]+)(\/.*)?$/
    );
    if (!match) return null;

    const mountName = match[1];
    const rest = match[2] || "";

    const hostBase = mountMap[mountName]
        || mountMap["." + mountName]
        || mountMap[mountName.replace(/^\./, "")];

    if (!hostBase) return null;

    const translated = rest ? path.join(hostBase, rest) : hostBase;
    const normalized = path.resolve(translated);

    // Prevent path traversal
    if (normalized !== hostBase &&
        !normalized.startsWith(hostBase + path.sep)) {
        return null;
    }

    return normalized;
}

function buildMountMap(additionalMounts, mountBinds) {
    const map = {};
    if (mountBinds) {
        for (const [name, hostPath] of mountBinds) {
            map[name] = hostPath;
        }
    }
    if (additionalMounts) {
        const homeDir = os.homedir();
        for (const [name, info] of Object.entries(additionalMounts)) {
            if (info && info.path) {
                const resolved = path.resolve(
                    path.join(homeDir, info.path)
                );
                if (resolved !== homeDir &&
                    !resolved.startsWith(homeDir + path.sep)) {
                    continue;
                }
                map[name] = resolved;
            }
        }
    }
    return map;
}

function resolvePluginRoot(pluginPath, mountBase) {
    let candidate = pluginPath;
    for (let i = 0; i < 3; i++) {
        const pluginJson = path.join(
            candidate, ".claude-plugin", "plugin.json"
        );
        const manifest = path.join(candidate, "manifest.json");
        try {
            if (fs.existsSync(pluginJson) || fs.existsSync(manifest)) {
                return candidate;
            }
        } catch (_) {
            break;
        }
        const parent = path.dirname(candidate);
        if (parent === candidate) break;
        if (mountBase && !parent.startsWith(mountBase)) break;
        candidate = parent;
    }
    return pluginPath;
}

function splitToolList(csv) {
    const result = [];
    if (!csv) return result;
    let depth = 0;
    let start = 0;
    for (let i = 0; i < csv.length; i++) {
        const ch = csv[i];
        if (ch === "(") depth++;
        else if (ch === ")") depth = Math.max(0, depth - 1);
        else if (ch === "," && depth === 0) {
            result.push(csv.slice(start, i));
            start = i + 1;
        }
    }
    result.push(csv.slice(start));
    return result;
}

function translateEmbeddedGuestPaths(csv, mountMap) {
    if (!csv) return csv;
    const out = [];
    for (const entry of splitToolList(csv)) {
        const m = entry.match(/^(\w+)\(([^)]+)\)$/);
        if (!m) {
            out.push(entry);
            continue;
        }
        const tool = m[1];
        const normalized = m[2].replace(/^\/+/, "/");
        if (!normalized.startsWith("/sessions/")) {
            out.push(entry);
            continue;
        }
        const translated = translateGuestPath(normalized, mountMap || {});
        if (!translated) continue;
        out.push(`${tool}(${translated})`);
    }
    return out.join(",");
}

function cleanSpawnArgs(rawArgs, mountMap) {
    const cleanArgs = [];
    const guestPathFlags = new Set(["--add-dir", "--plugin-dir"]);
    const toolListFlags = new Set(["--allowedTools", "--disallowedTools"]);
    for (let i = 0; i < rawArgs.length; i++) {
        const flag = rawArgs[i];
        const value = rawArgs[i + 1];

        if (guestPathFlags.has(flag) &&
            i + 1 < rawArgs.length &&
            value.startsWith("/sessions/")) {
            let hostPath = translateGuestPath(value, mountMap || {});
            if (hostPath) {
                if (flag === "--plugin-dir") {
                    hostPath = resolvePluginRoot(
                        hostPath, os.homedir()
                    );
                }
                cleanArgs.push(flag, hostPath);
            } else {
                // no mapping -- strip the flag entirely
            }
            i++;
            continue;
        }

        if (toolListFlags.has(flag) && i + 1 < rawArgs.length) {
            cleanArgs.push(
                flag,
                translateEmbeddedGuestPaths(value, mountMap),
            );
            i++;
            continue;
        }

        cleanArgs.push(flag);
    }
    return cleanArgs;
}

function findPrimaryMount(mountMap) {
    if (!mountMap) return null;
    return Object.keys(mountMap).find(
        n => !n.startsWith(".") && n !== "uploads",
    ) || null;
}

function resolveWorkDir(cwd, sharedCwdPath, mountMap) {
    let workDir = cwd || os.homedir();
    if (sharedCwdPath) {
        workDir = path.join(os.homedir(), sharedCwdPath);
    } else if (cwd && cwd.startsWith("/sessions/")) {
        const translated = translateGuestPath(cwd, mountMap || {});
        if (translated) {
            workDir = translated;
        } else {
            const primaryMount = findPrimaryMount(mountMap);
            if (primaryMount && mountMap[primaryMount]) {
                workDir = mountMap[primaryMount];
            } else {
                workDir = os.homedir();
            }
        }
    }
    if (!fs.existsSync(workDir)) {
        workDir = os.homedir();
    }
    return workDir;
}

const BLOCKED_ENV_KEYS = new Set([
    "CLAUDECODE", "ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ASAR",
]);

const FORWARDED_ENV_KEYS = ["CLAUDE_CODE_OAUTH_TOKEN"];

function filterEnv(source, stripPrefixes = []) {
    const result = {};
    for (const [k, v] of Object.entries(source)) {
        if (BLOCKED_ENV_KEYS.has(k)) continue;
        if (stripPrefixes.some(p => k.startsWith(p))) continue;
        result[k] = v;
    }
    return result;
}

function buildBaseSpawnEnv(appEnv) {
    const mergedEnv = {
        ...filterEnv(process.env, ["CLAUDE_CODE_"]),
        ...filterEnv(appEnv || {}),
        TERM: "xterm-256color",
    };
    for (const key of FORWARDED_ENV_KEYS) {
        if (process.env[key] && mergedEnv[key] === undefined) {
            mergedEnv[key] = process.env[key];
        }
    }
    return mergedEnv;
}

function buildSpawnEnv(appEnv, mountMap) {
    const mergedEnv = buildBaseSpawnEnv(appEnv);
    if (mergedEnv.CLAUDE_CONFIG_DIR &&
        mergedEnv.CLAUDE_CONFIG_DIR.startsWith("/sessions/")) {
        const translated = translateGuestPath(
            mergedEnv.CLAUDE_CONFIG_DIR, mountMap || {}
        );
        if (translated) {
            mergedEnv.CLAUDE_CONFIG_DIR = translated;
        } else {
            delete mergedEnv.CLAUDE_CONFIG_DIR;
        }
    }
    return mergedEnv;
}

// Helper: simple assertion
function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
}

function assertNull(val, msg) {
    assert(val === null, msg + " (got: " + JSON.stringify(val) + ")");
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
# translateGuestPath
# =============================================================================

@test "translateGuestPath: returns null for null input" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(null, {'.skills': '/x'}), 'null input');
assertNull(translateGuestPath(undefined, {'.skills': '/x'}), 'undefined input');
assertNull(translateGuestPath('', {'.skills': '/x'}), 'empty input');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null for non-/sessions/ paths" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath('/home/user/file', {'.skills': '/x'}),
    'regular path');
assertNull(translateGuestPath('/tmp/sessions/abc/mnt/skills/f', {'.skills': '/x'}),
    'tmp prefix');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null for empty mountMap" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath('/sessions/abc/mnt/skills/file', null),
    'null map');
assertNull(translateGuestPath('/sessions/abc/mnt/skills/file', {}),
    'empty map');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: translates with exact mount name match" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/.skills/somefile',
    {'.skills': '/home/user/.config/Claude/skills'}
);
assertEqual(result, '/home/user/.config/Claude/skills/somefile',
    'exact match');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: matches mount name without leading dot" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/x/mnt/skills/file',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills/file',
    'no-dot mount name');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: dot-prefix fallback matches stripped name" {
	run node -e "${NODE_PREAMBLE}
// mountMap has '.skills' but path has 'skills' (no dot)
const result = translateGuestPath(
    '/sessions/x/mnt/skills/file',
    {'.skills': '/home/user/.config/Claude/skills'}
);
assertEqual(result, '/home/user/.config/Claude/skills/file',
    'dot-prefix fallback');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns hostBase when no rest path" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/skills',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills',
    'no rest path');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: returns null when mount name not in map" {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(
    '/sessions/abc/mnt/unknown/file',
    {'skills': '/home/user/skills'}
), 'unknown mount');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: handles deeply nested rest path" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/data/a/b/c/d.txt',
    {'data': '/opt/data'}
);
assertEqual(result, '/opt/data/a/b/c/d.txt', 'deep rest');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: blocks path traversal via .." {
	run node -e "${NODE_PREAMBLE}
assertNull(translateGuestPath(
    '/sessions/abc/mnt/data/../../../etc/passwd',
    {'data': '/home/user/data'}
), 'traversal blocked');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: normalizes path with ./ segments" {
	run node -e "${NODE_PREAMBLE}
const result = translateGuestPath(
    '/sessions/abc/mnt/data/./subdir/./file',
    {'data': '/home/user/data'}
);
assertEqual(result, '/home/user/data/subdir/file', 'normalized dots');
"
	[[ "$status" -eq 0 ]]
}

@test "translateGuestPath: dot-stripped fallback matches dotted path to plain key" {
	run node -e "${NODE_PREAMBLE}
// Guest path has .skills (with dot), map key is skills (no dot)
const result = translateGuestPath(
    '/sessions/x/mnt/.skills/file',
    {'skills': '/home/user/skills'}
);
assertEqual(result, '/home/user/skills/file', 'dot-stripped fallback');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildMountMap
# =============================================================================

@test "buildMountMap: returns empty object when both args null" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(buildMountMap(null, null), {}, 'both null');
assertDeepEqual(buildMountMap(undefined, undefined), {}, 'both undefined');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: builds from mountBinds Map only" {
	run node -e "${NODE_PREAMBLE}
const binds = new Map([['skills', '/host/skills'], ['data', '/host/data']]);
const result = buildMountMap(null, binds);
assertDeepEqual(result, {'skills': '/host/skills', 'data': '/host/data'},
    'mountBinds only');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: builds from additionalMounts only" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    '.skills': { path: '.config/Claude/skills', mode: 'ro' },
    '.claude': { path: '.claude', mode: 'rw' }
};
const result = buildMountMap(additional, null);
const home = os.homedir();
assertEqual(result['.skills'],
    path.join(home, '.config/Claude/skills'),
    'skills path');
assertEqual(result['.claude'],
    path.join(home, '.claude'),
    'claude path');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: additionalMounts takes precedence over mountBinds" {
	run node -e "${NODE_PREAMBLE}
const binds = new Map([['skills', '/host/old-skills']]);
const additional = {
    'skills': { path: 'new-skills', mode: 'ro' }
};
const result = buildMountMap(additional, binds);
const expected = path.join(os.homedir(), 'new-skills');
assertEqual(result['skills'], expected, 'precedence');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: rejects paths that escape home directory" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    'good': { path: '.config/Claude/skills', mode: 'ro' },
    'bad': { path: '../../etc', mode: 'rw' }
};
const result = buildMountMap(additional, null);
assert(Object.keys(result).length === 1, 'only good entry');
assert('good' in result, 'good present');
assert(!('bad' in result), 'bad rejected');
"
	[[ "$status" -eq 0 ]]
}

@test "buildMountMap: skips entries without .path" {
	run node -e "${NODE_PREAMBLE}
const additional = {
    'good': { path: 'valid/path', mode: 'ro' },
    'bad1': { mode: 'rw' },
    'bad2': null
};
const result = buildMountMap(additional, null);
assert(Object.keys(result).length === 1, 'only one entry');
assert('good' in result, 'good entry present');
assert(!('bad1' in result), 'bad1 excluded');
assert(!('bad2' in result), 'bad2 excluded');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# cleanSpawnArgs
# =============================================================================

@test "cleanSpawnArgs: passes through args with no guest paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--flag', 'value', '--other'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, ['--flag', 'value', '--other'],
    'passthrough');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --plugin-dir with valid mapping" {
	# Create a temp plugin structure so resolvePluginRoot finds it
	mkdir -p "${TEST_TMP}/skills/.claude-plugin"
	printf '{}' > "${TEST_TMP}/skills/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/sessions/abc/mnt/skills'],
    {'skills': '${TEST_TMP}/skills'}
);
assertDeepEqual(result,
    ['--plugin-dir', '${TEST_TMP}/skills'],
    'plugin-dir translated');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --add-dir with valid mapping" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--add-dir', '/sessions/abc/mnt/data/subdir'],
    {'data': '/host/data'}
);
assertDeepEqual(result,
    ['--add-dir', '/host/data/subdir'],
    'add-dir translated');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: strips --plugin-dir when no mapping found" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/sessions/abc/mnt/unknown/dir'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, [], 'stripped');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: passes through --plugin-dir with non-/sessions/ paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--plugin-dir', '/usr/local/plugins'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result,
    ['--plugin-dir', '/usr/local/plugins'],
    'non-sessions passthrough');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: handles multiple --add-dir and --plugin-dir flags" {
	mkdir -p "${TEST_TMP}/plug/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plug/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    [
        '--add-dir', '/sessions/s/mnt/data/a',
        '--plugin-dir', '/sessions/s/mnt/plug',
        '--add-dir', '/sessions/s/mnt/data/b',
        '--plugin-dir', '/sessions/s/mnt/missing'
    ],
    {'data': '/host/data', 'plug': '${TEST_TMP}/plug'}
);
assertDeepEqual(result,
    [
        '--add-dir', '/host/data/a',
        '--plugin-dir', '${TEST_TMP}/plug',
        '--add-dir', '/host/data/b'
    ],
    'multiple flags');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: preserves other args around translated flags" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--verbose', '--add-dir', '/sessions/s/mnt/data/x', '--output', 'json'],
    {'data': '/host/data'}
);
assertDeepEqual(result,
    ['--verbose', '--add-dir', '/host/data/x', '--output', 'json'],
    'surrounding args preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --allowedTools embedded guest paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    [
        '--allowedTools',
        'Read,Edit,Edit(//sessions/abc/mnt/.auto-memory/**),Write(//sessions/abc/mnt/.auto-memory/**)'
    ],
    {'.auto-memory': '/host/memory'}
);
assertDeepEqual(result,
    [
        '--allowedTools',
        'Read,Edit,Edit(/host/memory/**),Write(/host/memory/**)'
    ],
    '--allowedTools translated, plain entries preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: translates --disallowedTools embedded guest paths" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    [
        '--disallowedTools',
        'Bash(rm),Edit(//sessions/abc/mnt/data/secret/**)'
    ],
    {'data': '/host/data'}
);
assertDeepEqual(result,
    [
        '--disallowedTools',
        'Bash(rm),Edit(/host/data/secret/**)'
    ],
    '--disallowedTools translated');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# splitToolList
# =============================================================================

@test "splitToolList: empty / null input" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(splitToolList(''), [], 'empty string -> []');
assertDeepEqual(splitToolList(null), [], 'null -> []');
assertDeepEqual(splitToolList(undefined), [], 'undefined -> []');
"
	[[ "$status" -eq 0 ]]
}

@test "splitToolList: simple CSV with no parens" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(
    splitToolList('Read,Edit,Write'),
    ['Read', 'Edit', 'Write'],
    'plain CSV');
"
	[[ "$status" -eq 0 ]]
}

@test "splitToolList: respects parentheses around commas" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(
    splitToolList('Bash(npm test, npm build),Edit,Read'),
    ['Bash(npm test, npm build)', 'Edit', 'Read'],
    'commas inside parens are preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "splitToolList: handles trailing entry without comma" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(
    splitToolList('A,B(c,d)'),
    ['A', 'B(c,d)'],
    'final entry includes nested commas');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# translateEmbeddedGuestPaths
# =============================================================================

@test "translateEmbeddedGuestPaths: passes through entries without parens" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'Read,Edit,Write',
        {'.auto-memory': '/host/memory'}
    ),
    'Read,Edit,Write',
    'plain tool names unchanged');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: translates Edit() with double-slash guest path" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'Edit(//sessions/abc/mnt/.auto-memory/**)',
        {'.auto-memory': '/host/memory'}
    ),
    'Edit(/host/memory/**)',
    'leading // normalized and translated');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: translates entry with single-slash guest path" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'Write(/sessions/abc/mnt/.auto-memory/**)',
        {'.auto-memory': '/host/memory'}
    ),
    'Write(/host/memory/**)',
    'single-slash variant also translated');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: drops entries whose mount is unknown" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'Read,Edit(//sessions/abc/mnt/unknown/**),Write',
        {'.auto-memory': '/host/memory'}
    ),
    'Read,Write',
    'unresolvable entry is dropped, others retained');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: leaves non-/sessions paths alone" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'Bash(rm),Edit(/home/user/explicit/file)',
        {'.auto-memory': '/host/memory'}
    ),
    'Bash(rm),Edit(/home/user/explicit/file)',
    'host paths and non-paths unchanged');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: handles MCP-style tool names with underscores" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    translateEmbeddedGuestPaths(
        'mcp__server__tool(//sessions/abc/mnt/data/**)',
        {'data': '/host/data'}
    ),
    'mcp__server__tool(/host/data/**)',
    'mcp-style tool name preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "translateEmbeddedGuestPaths: empty / null input" {
	run node -e "${NODE_PREAMBLE}
assertEqual(translateEmbeddedGuestPaths('', {}), '', 'empty -> empty');
assertEqual(translateEmbeddedGuestPaths(null, {}), null, 'null -> null');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# resolvePluginRoot
# =============================================================================

@test "resolvePluginRoot: returns path when .claude-plugin/plugin.json exists at that level" {
	mkdir -p "${TEST_TMP}/plugin/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plugin/.claude-plugin/plugin.json"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/plugin'),
    '${TEST_TMP}/plugin',
    'same level');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: walks up to parent with .claude-plugin/plugin.json" {
	mkdir -p "${TEST_TMP}/plugin/.claude-plugin"
	printf '{}' > "${TEST_TMP}/plugin/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/plugin/skills/subdir"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/plugin/skills'),
    '${TEST_TMP}/plugin',
    'walked up one');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: walks up to grandparent with manifest.json" {
	printf '{}' > "${TEST_TMP}/manifest.json"
	mkdir -p "${TEST_TMP}/a/b"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/a/b'),
    '${TEST_TMP}',
    'walked up two');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: returns original path when no plugin root found" {
	mkdir -p "${TEST_TMP}/empty/dir"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot('${TEST_TMP}/empty/dir'),
    '${TEST_TMP}/empty/dir',
    'no root found');
"
	[[ "$status" -eq 0 ]]
}

@test "resolvePluginRoot: stops at 3 levels" {
	# plugin.json is 4 levels up -- should not be found
	mkdir -p "${TEST_TMP}/root/.claude-plugin"
	printf '{}' > "${TEST_TMP}/root/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/root/a/b/c/d"

	run node -e "${NODE_PREAMBLE}
// Starting from root/a/b/c/d: checks d, c, b (3 levels). root is 4th.
assertEqual(
    resolvePluginRoot('${TEST_TMP}/root/a/b/c/d'),
    '${TEST_TMP}/root/a/b/c/d',
    'too deep');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# resolveWorkDir
# =============================================================================

@test "resolveWorkDir: returns translated path when cwd is guest path with valid mapping" {
	mkdir -p "${TEST_TMP}/workspace"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/project',
        null,
        {'project': '${TEST_TMP}/workspace'}
    ),
    '${TEST_TMP}/workspace',
    'translated cwd');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: falls back to homedir when cwd is guest path with no mapping" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/nomatch/dir',
        null,
        {'other': '/host/other'}
    ),
    os.homedir(),
    'fallback to homedir');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: uses sharedCwdPath when provided" {
	# Use TEST_TMP as HOME so we don't pollute the real homedir
	mkdir -p "${TEST_TMP}/resolveWorkDir-bats-test"

	HOME="${TEST_TMP}" run node -e "${NODE_PREAMBLE}
const result = resolveWorkDir(
    '/sessions/abc/mnt/whatever',
    'resolveWorkDir-bats-test',
    {'whatever': '/host/whatever'}
);
assertEqual(result,
    path.join(os.homedir(), 'resolveWorkDir-bats-test'),
    'sharedCwdPath takes priority');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: falls back to homedir when sharedCwdPath is non-existent" {
	HOME="${TEST_TMP}" run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/whatever',
        'nonexistent-dir-bats-test',
        {'whatever': '/host/whatever'}
    ),
    os.homedir(),
    'nonexistent sharedCwdPath falls back');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns homedir for non-existent translated path" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc/mnt/project/deep/missing',
        null,
        {'project': '/nonexistent-bats-test-path'}
    ),
    os.homedir(),
    'nonexistent falls back');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns homedir when cwd is null" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(null, null, {}),
    os.homedir(),
    'null cwd -> homedir');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: returns real local path unchanged when it exists" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir('/tmp', null, {}),
    '/tmp',
    'local path passthrough');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: session-root cwd uses primary user mount" {
	mkdir -p "${TEST_TMP}/project"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/bold-sharp-clarke',
        null,
        {'project': '${TEST_TMP}/project'}
    ),
    '${TEST_TMP}/project',
    'session-root falls through to primary mount');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: session-root cwd skips dotfile and uploads mounts" {
	mkdir -p "${TEST_TMP}/project"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc',
        null,
        {
            '.claude': '${TEST_TMP}/dotclaude',
            '.auto-memory': '${TEST_TMP}/automem',
            'uploads': '${TEST_TMP}/uploads',
            'project': '${TEST_TMP}/project'
        }
    ),
    '${TEST_TMP}/project',
    'dotfile and uploads mounts are skipped');
"
	[[ "$status" -eq 0 ]]
}

@test "resolveWorkDir: session-root cwd with no user mount falls back to home" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolveWorkDir(
        '/sessions/abc',
        null,
        {
            '.claude': '/host/dotclaude',
            'uploads': '/host/uploads'
        }
    ),
    os.homedir(),
    'no user mount -> homedir fallback');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# findPrimaryMount
# =============================================================================

@test "findPrimaryMount: returns null for null mountMap" {
	run node -e "${NODE_PREAMBLE}
assert(findPrimaryMount(null) === null, 'null mountMap');
assert(findPrimaryMount(undefined) === null, 'undefined mountMap');
assert(findPrimaryMount({}) === null, 'empty mountMap');
"
	[[ "$status" -eq 0 ]]
}

@test "findPrimaryMount: returns first non-dotfile non-uploads key" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    findPrimaryMount({'project': '/h/p'}),
    'project',
    'single user mount');
assertEqual(
    findPrimaryMount({
        '.claude': '/h/c',
        'uploads': '/h/u',
        'project': '/h/p'
    }),
    'project',
    'skips dotfiles and uploads');
"
	[[ "$status" -eq 0 ]]
}

@test "findPrimaryMount: returns null when all mounts are dotfiles or uploads" {
	run node -e "${NODE_PREAMBLE}
assert(
    findPrimaryMount({'.claude': '/h/c', 'uploads': '/h/u'}) === null,
    'no user mount -> null');
"
	[[ "$status" -eq 0 ]]
}

@test "findPrimaryMount: insertion order determines primary when multiple exist" {
	run node -e "${NODE_PREAMBLE}
assertEqual(
    findPrimaryMount({'first': '/h/1', 'second': '/h/2'}),
    'first',
    'first inserted user mount wins');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildSpawnEnv
# =============================================================================

@test "buildSpawnEnv: translates CLAUDE_CONFIG_DIR guest path" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/sessions/abc/mnt/.claude/config' },
    { '.claude': '/home/user/.claude' }
);
assertEqual(env.CLAUDE_CONFIG_DIR,
    '/home/user/.claude/config',
    'translated config dir');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: deletes CLAUDE_CONFIG_DIR when no mapping" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/sessions/abc/mnt/.claude/config' },
    {}
);
assert(!('CLAUDE_CONFIG_DIR' in env),
    'config dir deleted');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: preserves non-guest CLAUDE_CONFIG_DIR" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CONFIG_DIR: '/home/user/.claude' },
    {}
);
assertEqual(env.CLAUDE_CONFIG_DIR,
    '/home/user/.claude',
    'local config dir preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: strips CLAUDECODE and ELECTRON vars from appEnv" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    {
        CLAUDECODE: '1',
        ELECTRON_RUN_AS_NODE: '1',
        ELECTRON_NO_ASAR: '1',
        GOOD_VAR: 'keep'
    },
    {}
);
assert(!('CLAUDECODE' in env), 'CLAUDECODE stripped');
assert(!('ELECTRON_RUN_AS_NODE' in env), 'ELECTRON_RUN_AS_NODE stripped');
assert(!('ELECTRON_NO_ASAR' in env), 'ELECTRON_NO_ASAR stripped');
assertEqual(env.GOOD_VAR, 'keep', 'non-blocked kept');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: forces TERM to xterm-256color" {
	run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({ TERM: 'dumb' }, {});
assertEqual(env.TERM, 'xterm-256color', 'TERM forced');
"
	[[ "$status" -eq 0 ]]
}

# Regression coverage for issue #482: the CLAUDE_CODE_ prefix strip used to
# remove CLAUDE_CODE_OAUTH_TOKEN from process.env, severing the only auth
# channel available to the in-VM claude binary.

@test "buildSpawnEnv: forwards CLAUDE_CODE_OAUTH_TOKEN from process.env" {
	CLAUDE_CODE_OAUTH_TOKEN='tok-from-daemon' run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({}, {});
assertEqual(env.CLAUDE_CODE_OAUTH_TOKEN,
    'tok-from-daemon',
    'OAUTH_TOKEN forwarded from process.env');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: appEnv CLAUDE_CODE_OAUTH_TOKEN wins over process.env" {
	CLAUDE_CODE_OAUTH_TOKEN='tok-from-daemon' run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CODE_OAUTH_TOKEN: 'tok-from-app' },
    {}
);
assertEqual(env.CLAUDE_CODE_OAUTH_TOKEN,
    'tok-from-app',
    'appEnv token takes precedence');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: explicit empty appEnv token wins over process.env" {
	CLAUDE_CODE_OAUTH_TOKEN='tok-from-daemon' run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv(
    { CLAUDE_CODE_OAUTH_TOKEN: '' },
    {}
);
assertEqual(env.CLAUDE_CODE_OAUTH_TOKEN,
    '',
    'explicit empty-string preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "buildSpawnEnv: still strips unrelated CLAUDE_CODE_* from process.env" {
	CLAUDE_CODE_SSE_PORT='9999' run node -e "${NODE_PREAMBLE}
const env = buildSpawnEnv({}, {});
assert(!('CLAUDE_CODE_SSE_PORT' in env),
    'non-allowlisted CLAUDE_CODE_ var still stripped');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# cleanSpawnArgs edge cases
# =============================================================================

@test "cleanSpawnArgs: dangling flag at end of args is preserved" {
	run node -e "${NODE_PREAMBLE}
const result = cleanSpawnArgs(
    ['--verbose', '--plugin-dir'],
    {'skills': '/host/skills'}
);
assertDeepEqual(result, ['--verbose', '--plugin-dir'], 'dangling flag');
"
	[[ "$status" -eq 0 ]]
}

@test "cleanSpawnArgs: empty args returns empty array" {
	run node -e "${NODE_PREAMBLE}
assertDeepEqual(cleanSpawnArgs([], {}), [], 'empty args');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# resolvePluginRoot mountBase boundary
# =============================================================================

@test "resolvePluginRoot: respects mountBase boundary" {
	# plugin.json exists at TEST_TMP level, but mountBase is one level down
	mkdir -p "${TEST_TMP}/.claude-plugin"
	printf '{}' > "${TEST_TMP}/.claude-plugin/plugin.json"
	mkdir -p "${TEST_TMP}/mount/sub"

	run node -e "${NODE_PREAMBLE}
assertEqual(
    resolvePluginRoot(
        '${TEST_TMP}/mount/sub',
        '${TEST_TMP}/mount'
    ),
    '${TEST_TMP}/mount/sub',
    'mountBase boundary respected');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# mountPath — subpath is root-relative, must NOT be joined with homedir
# =============================================================================

# These tests replicate the mountPath() logic from HostBackend and
# BwrapBackend to verify that root-relative subpaths resolve correctly
# (fix for #373: double-nested home directory paths).

@test "mountPath: root-relative subpath resolves to absolute path, not double-nested" {
	run node -e "${NODE_PREAMBLE}
// Simulate what the caller sends: path.relative('/', '/home/user/.config/Claude')
const subpath = 'home/user/.config/Claude';

// Fixed logic: join with '/' (root), not os.homedir()
const guestPath = path.join('/', subpath);
assertEqual(guestPath, '/home/user/.config/Claude',
    'root-relative subpath should resolve to single absolute path');
"
	[[ "$status" -eq 0 ]]
}

@test "mountPath: empty subpath resolves to root" {
	run node -e "${NODE_PREAMBLE}
const guestPath = path.join('/', '');
assertEqual(guestPath, '/', 'empty subpath -> root');
"
	[[ "$status" -eq 0 ]]
}

@test "mountPath: subpath with nested directories resolves correctly" {
	run node -e "${NODE_PREAMBLE}
const subpath = 'home/raycharlizard/.config/Claude/local-agent-mode-sessions/outputs';
const guestPath = path.join('/', subpath);
assertEqual(guestPath,
    '/home/raycharlizard/.config/Claude/local-agent-mode-sessions/outputs',
    'nested subpath should not double the home prefix');
"
	[[ "$status" -eq 0 ]]
}
