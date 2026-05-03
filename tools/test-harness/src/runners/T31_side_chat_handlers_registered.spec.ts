import { test, expect } from '@playwright/test';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T31 — Side-chat eipc channel-name fingerprints.
//
// Backs T31 in docs/testing/cases/code-tab-workflow.md ("Side chat
// opens" — `Ctrl+;` / `/btw` opens an overlay that forks the
// current Code-tab session, exchanges messages without polluting
// the main transcript, then closes cleanly). The full click-chain
// version is Tier 3 — needs a logged-in claude.ai session, an OPEN
// Code-tab session, and renderer interaction with a UI surface
// that lives in claude.ai's remote bundle (not in build-reference).
//
// **Session 3 reclassification.** This started as a Tier 2 reframe
// using `ipcMain._invokeHandlers` introspection (T38 pattern from
// session 2). KDE-W run revealed that registry holds only 3 chat-
// tab MCP-bridge handlers; the `LocalSessions_*` channels use a
// separate **eipc** custom protocol (see `:68816` framing) that
// doesn't go through Electron's standard `ipcMain.handle()`. T38
// inherited the same flaw and is being reclassified alongside this
// runner. See plan-doc session 3 status section.
//
// The Tier 1 fingerprint slice asserts the three side-chat eipc
// channel-name strings are present in the bundled `index.js`. The
// trio is load-bearing — the side chat is broken without all three:
// `startSideChat` opens the fork (case-doc anchor `:487025` for the
// system-prompt suffix; `:487265` for the per-session
// `this.sideChats = new Map()` registry), `sendSideChatMessage`
// carries each turn, `stopSideChat` tears the fork down. Missing
// any one regresses the surface silently with no compile-time
// signal.
//
// The string-presence check is the Tier 1 form of "is the wiring
// in the bundle"; the runtime "is the handler installed" needs the
// eipc-registry surface reverse-engineered first (deferred to a
// future session — same gap that forced T22/T33/T38 reclassification).
//
// Pure file probe, no app launch — Tier 1 in plan-doc terms.
//
// Applies to all rows. No skipUnlessRow gate.

const SIDE_CHAT_CHANNELS = [
	'LocalSessions_$_startSideChat',
	'LocalSessions_$_sendSideChatMessage',
	'LocalSessions_$_stopSideChat',
] as const;

test.setTimeout(15_000);

test('T31 — side-chat eipc channel fingerprints', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Side chat overlay',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	let asarPath: string;
	try {
		asarPath = resolveAsarPath();
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		test.skip(true, `asar not resolvable: ${msg}`);
		return;
	}
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const results = SIDE_CHAT_CHANNELS.map((needle) => ({
		needle,
		found: asarContains('.vite/build/index.js', needle, asarPath),
	}));

	await testInfo.attach('asar-fingerprints', {
		body: JSON.stringify(
			{ asarPath, file: '.vite/build/index.js', channels: results },
			null,
			2,
		),
		contentType: 'application/json',
	});

	for (const r of results) {
		expect(
			r.found,
			`[T31] eipc channel name '${r.needle}' present in bundled ` +
				'index.js — load-bearing for the side-chat trio (case-doc ' +
				'anchors :487025 / :487265)',
		).toBe(true);
	}
});
