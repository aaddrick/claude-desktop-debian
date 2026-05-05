import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import {
	installShowItemInFolderMock,
	getShowItemInFolderCalls,
} from '../lib/electron-mocks.js';

// T25 — `shell.showItemInFolder` is reachable from main, accepts a
// path arg, and the IPC layer terminates at it without throwing.
//
// Tier 2 reframe of the case-doc T25 ("Code tab → right-click → Show
// in Files opens system file manager with file pre-selected"). The
// full click-chain version is Tier 3 and lives elsewhere; here we
// just prove the JS-level egress at index.js:509431
// (`hA.shell.showItemInFolder(Tc(path))`) is callable from main.
//
// Mock-then-call shape (mirrors T17's installOpenDialogMock pattern):
// monkey-patch `shell.showItemInFolder` to record invocations
// without performing the DBus FileManager1 / xdg-open dispatch, then
// `evalInMain` calls it with a synthetic path. Assertion is the
// recorded calls list contains our path and the call didn't throw.
//
// Why mock instead of invoking real: `showItemInFolder` returns void
// on Linux and gives no success signal, so the only thing the
// real-call form actually tests is "the JS layer is reachable" —
// which the mock tests equally well, without a host-side file-manager
// pop-up firing during the run. The xdg-open layer is OS-dependent
// and out of scope for a JS-level regression detector.
//
// Applies to all rows. No skipUnlessRow gate.

test.setTimeout(120_000);

test('T25 — shell.showItemInFolder reachable, no throw', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — show in files',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Synthetic path — the mock doesn't touch the filesystem, so a
	// non-existent path is fine. A `/tmp/...` shape mirrors what the
	// real IPC handler at index.js:509431 would receive after `Tc()`
	// path normalisation.
	const syntheticPath = '/tmp/claude-t25-show-in-files-target.txt';
	await testInfo.attach('synthetic-path', {
		body: syntheticPath,
		contentType: 'text/plain',
	});

	const app = await launchClaude();
	try {
		// 'mainVisible' is the cheapest level that gives us an
		// inspector + a known-good main process. `shell` is a static
		// Electron module; doesn't depend on window/renderer state.
		const { inspector } = await app.waitForReady('mainVisible');

		await installShowItemInFolderMock(inspector);

		const start = Date.now();
		let threw: { message: string; stack?: string } | null = null;
		try {
			await inspector.evalInMain<null>(`
				const { shell } = process.mainModule.require('electron');
				shell.showItemInFolder(${JSON.stringify(syntheticPath)});
				return null;
			`);
		} catch (err) {
			threw = {
				message: err instanceof Error ? err.message : String(err),
				stack: err instanceof Error ? err.stack : undefined,
			};
		}
		const elapsedMs = Date.now() - start;

		const calls = await getShowItemInFolderCalls(inspector);

		await testInfo.attach('show-item-in-folder-result', {
			body: JSON.stringify(
				{
					path: syntheticPath,
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
			'shell.showItemInFolder(<path>) returned without throwing',
		).toBeNull();
		expect(
			calls.length,
			'mock recorded the showItemInFolder invocation',
		).toBe(1);
		expect(
			calls[0]?.path,
			'mock recorded the synthetic path arg verbatim',
		).toBe(syntheticPath);
	} finally {
		await app.close();
	}
});
