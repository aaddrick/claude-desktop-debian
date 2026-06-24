#!/usr/bin/env bats
#
# claude-native-stub.bats
# Tests for the Linux @ant/claude-native stub (scripts/claude-native-stub.js)
# copied into app.asar and app.asar.unpacked during packaging.
#
# The Windows-only registry / MSIX / UAC methods are the load-bearing
# part here: upstream (>= 1.13576.0) calls readRegistryValues() and
# getWindowsElevationType() unconditionally at startup, so a missing
# method throws before any window is created and the app hangs (#729).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
STUB_JS="${SCRIPT_DIR}/../scripts/claude-native-stub.js"

# Evaluate a snippet of JS with the stub loaded as `stub`. The snippet
# must `process.exit(1)` (via thrown error) on failure; a clean exit is
# a pass. Keeps each @test to a single Node spawn.
run_stub_js() {
	run node -e "
		const stub = require('${STUB_JS}');
		$1
	"
	[[ "$status" -eq 0 ]] || {
		echo "$output"
		return 1
	}
}

@test "claude-native stub: readRegistryValues returns an empty array" {
	run_stub_js '
		const v = stub.readRegistryValues(["HKCU\\\\Software\\\\Anthropic"]);
		if (!Array.isArray(v) || v.length !== 0) {
			throw new Error("expected [], got " + JSON.stringify(v));
		}
	'
}

@test "claude-native stub: getWindowsElevationType returns \"default\"" {
	run_stub_js '
		if (stub.getWindowsElevationType() !== "default") {
			throw new Error("expected default");
		}
	'
}

@test "claude-native stub: getCurrentPackageFamilyName returns null" {
	run_stub_js '
		if (stub.getCurrentPackageFamilyName() !== null) {
			throw new Error("expected null");
		}
	'
}

@test "claude-native stub: registry writers are callable no-ops" {
	run_stub_js '
		stub.writeRegistryValue("k", "v");
		stub.writeRegistryDword("k", 1);
	'
}

@test "claude-native stub: all Windows-only policy methods are functions" {
	run_stub_js '
		const required = [
			"readRegistryValues",
			"writeRegistryValue",
			"writeRegistryDword",
			"getWindowsElevationType",
			"getCurrentPackageFamilyName",
		];
		for (const name of required) {
			if (typeof stub[name] !== "function") {
				throw new Error(name + " is not a function");
			}
		}
	'
}

@test "claude-native stub: existing exports are preserved" {
	run_stub_js '
		if (stub.getWindowsVersion() !== "10.0.0") {
			throw new Error("getWindowsVersion regressed");
		}
		if (typeof stub.flashFrame !== "function") {
			throw new Error("flashFrame missing");
		}
		if (!stub.KeyboardKey || stub.KeyboardKey.Enter !== 261) {
			throw new Error("KeyboardKey regressed");
		}
	'
}
