#!/usr/bin/env bats
#
# buddy-ble-stub.bats
# Application tests for scripts/patches/buddy-ble-stub.sh — the
# BuddyBleTransport eIPC handler stub (Patch 1) and the auto-updater
# onStateChange listener-leak guard (Patch 2).
#
# verify-patches.bats proves each marker regex matches its sample from
# scripts/cowork-patch-markers.tsv; this file proves patch_buddy_ble_stub
# actually PRODUCES those markers from an unpatched bundle and is
# idempotent on re-run.
#
# Targets Claude Desktop 1.15962.1 / wrapper 2.0.22.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PATCH_SH="$SCRIPT_DIR/../scripts/patches/buddy-ble-stub.sh"
INDEX='app.asar.contents/.vite/build/index.js'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	mkdir -p "$TEST_TMP/app.asar.contents/.vite/build"
	cd "$TEST_TMP" || return 1

	# project_root is referenced by the patch's failure branch (cd
	# back before exit). A bare TEST_TMP is fine for the tests.
	project_root="$TEST_TMP"
	export project_root

	# shellcheck source=scripts/patches/buddy-ble-stub.sh
	source "$PATCH_SH"
}

teardown() {
	if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Minimal minified fixture carrying the anchors patch_buddy_ble_stub
# needs:
#   * three $_claude.buddy_$_BuddyBleTransport_$_ channel literals
#     (rx / reportState / log) — sanity-check anchor.
#   * one qa.on("change", a) call inside an onStateChange:(a)=>{...}
#     arrow — the leak-guard anchor.
# Wrapped in a plausible "use strict" prologue so the IIFE injection
# path (which preserves the pragma at position 0) is exercised.
write_buddy_fixture() {
	cat > "$INDEX" <<'JS'
"use strict";var aA=require("electron");function _Fn(A){I9t.for(A).setImplementation({rx:()=>{},reportState:()=>{},log:()=>{}})}A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_rx",async(i,r)=>{});A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_reportState",async(i,r,n)=>{});A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_log",async(i,r)=>{});aGn({isReady:()=>qa.state.state==="ready",onStateChange:(a)=>{qa.on("change",a)},runTick:(a)=>{}});
JS
}

# Fixture WITHOUT the qa.on("change") site — used to prove Patch 2 is
# non-fatal (WARNING, exit 0). Patch 1 still runs and must land.
write_ipc_only_fixture() {
	cat > "$INDEX" <<'JS'
"use strict";var aA=require("electron");A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_rx",()=>{});A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_reportState",()=>{});A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_log",()=>{});
JS
}

# Fixture MISSING one of the channel literals — Patch 1 must FATAL
# because a missing anchor means upstream restructured the surface.
write_missing_channel_fixture() {
	# reportState is intentionally omitted from the channel literals.
	cat > "$INDEX" <<'JS'
"use strict";var aA=require("electron");A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_rx",()=>{});A.ipc.handle("$eipc_message$_d9a2148e-8f64-4767-9ba3-8a3140581f61_$_claude.buddy_$_BuddyBleTransport_$_log",()=>{});
JS
}

# =============================================================================
# Positive path
# =============================================================================

@test "patch_buddy_ble_stub injects the ipcMain fallback + listener guard markers" {
	write_buddy_fixture

	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || {
		echo "patch_buddy_ble_stub exited $status"
		echo "$output"
		return 1
	}

	# Patch 1: ipcMain fallback marker present exactly once.
	run grep -c '__CLAUDE_LINUX_BUDDY_BLE_STUB_v1__' "$INDEX"
	[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
		echo "ipcMain-fallback marker count: $output"
		cat "$INDEX"
		return 1
	}

	# Patch 1: the injected IIFE actually references ipcMain.handle
	# and the three channel names.
	grep -qF 'ipcMain' "$INDEX" || {
		echo 'ipcMain missing after Patch 1'
		return 1
	}
	grep -qF 'BuddyBleTransport_$_reportState' "$INDEX" || {
		echo 'reportState channel missing after Patch 1'
		return 1
	}

	# Patch 2: leak-guard marker present exactly once.
	run grep -c '__CLAUDE_LINUX_QA_ONCHANGE_GUARD_v1__' "$INDEX"
	[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
		echo "leak-guard marker count: $output"
		return 1
	}

	# Patch 2: the removeListener-before-add is wired to the same
	# emitter+param the original .on(...) used. Beautified/minified
	# tolerant.
	grep -qE 'qa\.removeListener\("change",\s*a\s*\)\s*;\s*qa\.on\("change",\s*a\s*\)' \
		"$INDEX" || {
		echo 'expected qa.removeListener("change",a);qa.on("change",a)'
		echo 'after Patch 2 but did not find it'
		cat "$INDEX"
		return 1
	}

	# The pragma must remain at position 0 — strict mode is only
	# recognised as the first statement of the source.
	head -c 13 "$INDEX" | grep -qF '"use strict";' || {
		echo '"use strict" no longer at file start after Patch 1'
		head -c 40 "$INDEX"
		return 1
	}
}

@test "patch_buddy_ble_stub keeps the file parsing as valid JS" {
	write_buddy_fixture
	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	run node --check "$INDEX"
	[[ "$status" -eq 0 ]] || {
		echo 'patched fixture failed node --check'
		echo "$output"
		return 1
	}
}

# =============================================================================
# Idempotency — a second run must be byte-identical
# =============================================================================

@test "patch_buddy_ble_stub is byte-identical on a second run" {
	write_buddy_fixture
	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	cp "$INDEX" first.js

	# Second run must not double-inject and must produce identical bytes.
	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	run diff first.js "$INDEX"
	[[ "$status" -eq 0 ]] || {
		echo 're-run changed the bundle (not idempotent):'
		echo "$output"
		return 1
	}

	# The two markers must still be present exactly once each.
	for marker in \
		'__CLAUDE_LINUX_BUDDY_BLE_STUB_v1__' \
		'__CLAUDE_LINUX_QA_ONCHANGE_GUARD_v1__'; do
		run grep -c "$marker" "$INDEX"
		[[ "$status" -eq 0 && "$output" -eq 1 ]] || {
			echo "marker not unique after re-run: $marker (count $output)"
			return 1
		}
	done

	# And the re-run must log the "already applied" branch for both.
	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	echo "$output" | grep -q 'ipcMain fallback already applied' || {
		echo 'expected "ipcMain fallback already applied" on third run'
		echo "$output"
		return 1
	}
	echo "$output" | grep -q 'onStateChange remove-before-add guard already applied' || {
		echo 'expected "onStateChange remove-before-add guard already applied"'
		echo "$output"
		return 1
	}
}

# =============================================================================
# Fail-loud: missing anchors must not ship a silent no-op
# =============================================================================

@test "patch_buddy_ble_stub FATALs when a channel literal is missing" {
	write_missing_channel_fixture
	run patch_buddy_ble_stub
	[[ "$status" -ne 0 ]] || {
		echo 'missing channel literal should FATAL but exited 0'
		echo "$output"
		return 1
	}
	echo "$output" | grep -qi 'buddy channel literal missing' || {
		echo 'expected "buddy channel literal missing" in output'
		echo "$output"
		return 1
	}
}

# =============================================================================
# Non-fatal: Patch 2 anchor missing is a WARNING, not a hard fail
# =============================================================================

@test "patch_buddy_ble_stub WARNS but exits 0 when onStateChange site is absent" {
	write_ipc_only_fixture
	run patch_buddy_ble_stub
	[[ "$status" -eq 0 ]] || {
		echo 'expected exit 0 when only listener-leak anchor missing'
		echo "$output"
		return 1
	}
	echo "$output" | grep -qi 'onStateChange qa.on("change") site not found' || {
		echo 'expected WARNING for missing onStateChange site'
		echo "$output"
		return 1
	}

	# Patch 1 must still have landed.
	grep -qF '__CLAUDE_LINUX_BUDDY_BLE_STUB_v1__' "$INDEX" || {
		echo 'Patch 1 marker missing when Patch 2 anchor is absent'
		return 1
	}
	# Patch 2 marker must NOT be present.
	! grep -qF '__CLAUDE_LINUX_QA_ONCHANGE_GUARD_v1__' "$INDEX" || {
		echo 'Patch 2 marker present despite anchor missing'
		return 1
	}
}
