#!/usr/bin/env bats
#
# frame-fix-wrapper.bats
# Focused coverage for the Electron main-process require() shims in
# scripts/frame-fix-wrapper.js.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
WRAPPER_JS="$SCRIPT_DIR/../scripts/frame-fix-wrapper.js"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n ${TEST_TMP:-} && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "frame-fix: shims missing claude-native readRegistryValues on Linux" {
	[[ "$(node -p 'process.platform')" != 'win32' ]] \
		|| skip 'Linux-only shim is intentionally inactive on Windows'

	mkdir -p "$TEST_TMP/node_modules/@ant/claude-native"
	cat > "$TEST_TMP/node_modules/@ant/claude-native/index.js" <<'JS'
module.exports = { existingExport: 42 };
JS

	cat > "$TEST_TMP/probe.js" <<'JS'
require(process.env.WRAPPER_JS);

const claudeNative = require('@ant/claude-native');
if (claudeNative.existingExport !== 42) {
  throw new Error('existing export was not preserved');
}
if (typeof claudeNative.readRegistryValues !== 'function') {
  throw new Error('readRegistryValues shim missing');
}
const values = claudeNative.readRegistryValues([
  'HKCU\\Software\\Anthropic\\Claude',
]);
if (!Array.isArray(values) || values.length !== 0) {
  throw new Error('readRegistryValues shim should return []');
}
JS

	WRAPPER_JS="$WRAPPER_JS" run node "$TEST_TMP/probe.js"
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}
}
