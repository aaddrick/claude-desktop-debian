import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import {
	installOpenExternalMock,
	getOpenExternalCalls,
} from '../lib/electron-mocks.js';

// T24 — `shell.openExternal('<scheme>://file/<path>')` is reachable
// from main with one of the editor URL schemes, accepts the URL arg,
// and the call terminates at the egress without throwing.
//
// Tier 2 reframe of the case-doc T24 ("Code tab → right-click →
// Open in → choose editor → editor opens at file"). The full
// click-chain version is Tier 3 (needs an editor installed, the
// `x-scheme-handler/<editor>` `xdg-mime` default registered, and the
// claude.ai right-click menu interaction); here we just prove the
// JS-level egress at index.js:464011
// (`shell.openExternal('<scheme>://file/<encoded-path>:<line>')`) is
// callable from main with one of the registered editor schemes
// (`vscode`/`cursor`/`zed`/`windsurf`/`xcode` per the `Mtt` registry
// at index.js:463902, editor enum at :59076).
//
// Mock-then-call shape (mirrors T25's installShowItemInFolderMock
// pattern): monkey-patch `shell.openExternal` to record invocations
// without performing the xdg-open / scheme-handler dispatch, then
// `evalInMain` calls it directly with a synthetic URL. Assertion is
// the recorded calls list contains our URL verbatim and the call
// didn't throw.
//
// We call `shell.openExternal` directly rather than invoking the
// `LocalSessions.openInEditor` IPC handler — the channel's origin
// validation (`le(i)` at index.js:68820, documented in T38's leading
// comment) rejects non-claude.ai senders, so an `evalInMain` call
// would never reach the impl. T38 introspects the handler-registered
// state for the same reason; here we one step further and exercise
// the actual egress.
//
// Why mock instead of invoking real: `shell.openExternal` returns
// `Promise<boolean>` (true on success, false otherwise — case-doc
// T34 anchor `:136233` `$a(url)` thin-wraps it). Invoking for real on
// a host with VS Code (or another editor in the enum) installed
// launches the editor app — disruptive for a JS-level regression
// detector. The mock returns a resolved Promise with a canned
// boolean, matching the documented contract, with no host side
// effect.
//
// This is the meaningful difference from T25: `showItemInFolder`
// returns void (mock returns undefined); `openExternal` returns
// Promise<boolean> (mock returns a Promise). With the mock installed,
// NO real editor launch happens.
//
// Applies to all rows. No skipUnlessRow gate.

test.setTimeout(120_000);

test('T24 — shell.openExternal(vscode://file/...) reachable, no throw', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Open in editor',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Synthetic URL — `vscode://file/<path>` shape per the case-doc
	// anchor index.js:464011. The mock doesn't touch xdg-open / scheme
	// handlers, so a non-existent path is fine. The `vscode` scheme is
	// in the editor enum (case-doc anchor :59076 / Mtt registry at
	// :463902); any of `vscode`/`cursor`/`zed`/`windsurf` would do.
	const syntheticUrl =
		'vscode://file/tmp/claude-t24-open-in-editor-target.txt';
	await testInfo.attach('synthetic-url', {
		body: syntheticUrl,
		contentType: 'text/plain',
	});

	const app = await launchClaude();
	try {
		// 'mainVisible' is the cheapest level that gives us an
		// inspector + a known-good main process. `shell` is a static
		// Electron module; doesn't depend on window/renderer state.
		const { inspector } = await app.waitForReady('mainVisible');

		await installOpenExternalMock(inspector);

		const start = Date.now();
		let threw: { message: string; stack?: string } | null = null;
		try {
			await inspector.evalInMain<null>(`
				const { shell } = process.mainModule.require('electron');
				await shell.openExternal(${JSON.stringify(syntheticUrl)});
				return null;
			`);
		} catch (err) {
			threw = {
				message: err instanceof Error ? err.message : String(err),
				stack: err instanceof Error ? err.stack : undefined,
			};
		}
		const elapsedMs = Date.now() - start;

		const calls = await getOpenExternalCalls(inspector);

		await testInfo.attach('open-external-result', {
			body: JSON.stringify(
				{
					url: syntheticUrl,
					elapsedMs,
					threw,
					calls,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			threw,
			'shell.openExternal(<editor-url>) returned without throwing',
		).toBeNull();
		expect(
			calls.length,
			'mock recorded the openExternal invocation',
		).toBe(1);
		expect(
			calls[0]?.url,
			'mock recorded the synthetic URL arg verbatim',
		).toBe(syntheticUrl);
	} finally {
		await app.close();
	}
});
