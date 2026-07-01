#===============================================================================
# BuddyBleTransport stub — neutralise the Windows companion (Bluetooth
# Low Energy) transport that has no handler on Linux.
#
# Symptom without this patch (Claude 1.15962.1, wrapper 2.0.22):
#   * "$eipc_message$_…_claude.buddy_$_BuddyBleTransport_$_reportState:
#     Error: No handler registered" spam, once per tick.
#   * MaxListenersExceededWarning on a "change" event.
#   * Main-process V8 heap climbs to ~2 GB → OOM (exit 133) during
#     sustained Cowork/Dispatch use.
#
# This is a stub — do NOT implement BLE. Register a no-op handler for
# the claude.buddy / BuddyBleTransport eIPC methods and stop the
# runaway "change" listener from re-registering each tick. The
# Dispatch relay/websocket path is NOT touched — only the local
# companion transport that is dead on Linux.
#
# Sourced by: build.sh
# Sourced globals: (none — operates on the staged app.asar tree)
#===============================================================================

patch_buddy_ble_stub() {
	echo 'Patching BuddyBleTransport for Linux (scaffold — see PR)...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# NOTE: implementation follows. This scaffold exists so build.sh
	# can source the file while the PR is still WIP.

	echo '##############################################################'
}
