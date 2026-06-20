#!/usr/bin/env bats
#
# claude-native-stub.bats
# Tests for the Linux @ant/claude-native stub copied into app.asar and
# app.asar.unpacked during packaging.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
STUB_JS="$SCRIPT_DIR/../scripts/claude-native-stub.js"

@test "claude-native stub: Windows registry reads are a Linux no-op" {
	run node - "$STUB_JS" <<'JS'
const stub = require(process.argv[2]);
if (typeof stub.readRegistryValues !== 'function') {
  throw new Error('readRegistryValues is missing');
}
const values = stub.readRegistryValues([
  'HKCU\\Software\\Anthropic\\Claude',
]);
if (!Array.isArray(values) || values.length !== 0) {
  throw new Error('readRegistryValues should return []');
}
JS
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}
}
