#!/usr/bin/env bats
#
# cowork-protocol.bats
# End-to-end guard for the bwrap fallback daemon's wire protocol: spawns
# the daemon and drives it over the length-prefixed-JSON socket the
# official client uses (see PROTOCOL.md). Delegates to protocol-smoke.js,
# which spawns and reaps its own daemon.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

@test "protocol: daemon speaks the official helper socket contract" {
	run node "${SCRIPT_DIR}/protocol-smoke.js"
	echo "$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALL PASS"* ]]
}
