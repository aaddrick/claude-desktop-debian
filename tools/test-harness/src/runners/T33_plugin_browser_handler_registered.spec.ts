import { test, expect } from '@playwright/test';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T33 — Plugin browser eipc channel-name fingerprints.
//
// Backs T33 in docs/testing/cases/extensibility.md ("Plugin
// browser" — click + → Plugins → Add plugin, marketplace listings
// appear, install completes end-to-end). The full click-chain is
// Tier 3 — login + the plugin browser dialog open in a renderer
// surface that's not present in the local asar at idle + a real
// install round-trip against the Anthropic marketplace backend.
//
// **Session 3 reclassification.** This started as a Tier 2 reframe
// using `ipcMain._invokeHandlers` introspection (T38 pattern from
// session 2). KDE-W run revealed that registry holds only 3 chat-
// tab MCP-bridge handlers; the `CustomPlugins_*` channels use a
// separate **eipc** custom protocol that doesn't go through
// Electron's standard `ipcMain.handle()`. T38 inherited the same
// flaw and is being reclassified alongside this runner. See plan-
// doc session 3 status section for the broader eipc-registry
// finding.
//
// The Tier 1 fingerprint slice asserts the two load-bearing
// channel-name strings are present in the bundled `index.js`:
//   - `CustomPlugins_$_listMarketplaces` (case-doc anchor
//     `:71392`, main-process handler at `:507176`) — without this
//     the plugin browser modal can't fetch the marketplace list
//     and the entire flow regresses silently.
//   - `CustomPlugins_$_listAvailablePlugins` (case-doc anchor
//     `:71534`) — paired secondary; needed for per-marketplace
//     plugin listings to populate.
//
// The string-presence check is the Tier 1 form of "is the wiring
// in the bundle"; the runtime "is the handler installed" needs the
// eipc-registry surface reverse-engineered first (deferred to a
// future session — same gap that forced T22/T31/T38 reclassification).
//
// Pure file probe, no app launch — Tier 1 in plan-doc terms.
//
// Applies to all rows. No skipUnlessRow gate.

const PLUGIN_BROWSER_CHANNELS = [
	{
		needle: 'CustomPlugins_$_listMarketplaces',
		caseDocAnchor: 'index.js:71392 / :507176',
		rationale: 'marketplace-listing eipc channel — load-bearing',
	},
	{
		needle: 'CustomPlugins_$_listAvailablePlugins',
		caseDocAnchor: 'index.js:71534',
		rationale:
			'available-plugins eipc channel — paired with marketplace ' +
			'list; both are needed for the browser to populate',
	},
] as const;

test.setTimeout(15_000);

test('T33 — CustomPlugins marketplace eipc fingerprints', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Plugin browser UI',
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

	const results = PLUGIN_BROWSER_CHANNELS.map((c) => ({
		...c,
		found: asarContains('.vite/build/index.js', c.needle, asarPath),
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
			`[T33] eipc channel name '${r.needle}' present in bundled ` +
				`index.js (case-doc anchor ${r.caseDocAnchor}; ` +
				`${r.rationale})`,
		).toBe(true);
	}
});
