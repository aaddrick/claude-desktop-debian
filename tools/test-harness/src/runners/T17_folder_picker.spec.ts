import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { retryUntil } from '../lib/retry.js';
import { CodeTab } from '../lib/claudeai.js';
import {
	installOpenDialogMock,
	getOpenDialogCalls,
} from '../lib/electron-mocks.js';

// T17 — Folder picker opens.
//
// Path: launch the app, wait for `userLoaded` (claude.ai past /login —
// Code-tab UI doesn't render before then), install a
// dialog.showOpenDialog mock, then drive the renderer through the
// env-pill → Local → Select-folder → Open-folder chain via the CodeTab
// abstraction in lib/claudeai.ts. Assert the mock fired.
//
// All renderer-DOM walking lives in lib/claudeai.ts — when claude.ai
// rerenders the Code tab in a future release and this test breaks, the
// fix is one file over, not here.

test('T17 — Folder picker opens', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab / folder picker',
	});

	// Without CLAUDE_TEST_USE_HOST_CONFIG=1, the fresh isolation has no
	// auth tokens, so claude.ai redirects to /login and the Code-tab
	// click chain has nothing to grab. Match the QE runners' pattern:
	// share host config when the env var is set, fresh isolation
	// otherwise (where the test will skip on /login).
	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	try {
		const { inspector, postLoginUrl } = await app.waitForReady('userLoaded');
		if (!postLoginUrl) {
			testInfo.skip(
				true,
				'not signed in — set CLAUDE_TEST_USE_HOST_CONFIG=1 with a ' +
					'signed-in host config',
			);
			return;
		}
		await testInfo.attach('renderer-url', {
			body: postLoginUrl,
			contentType: 'text/plain',
		});

		await installOpenDialogMock(inspector);

		const codeTab = new CodeTab(inspector);
		await codeTab.activate();
		try {
			await codeTab.openFolderPicker();
		} catch (err) {
			// Lib threw mid-chain — likely a renderer drift. Attach the
			// underlying message so the failure log says exactly which
			// step decayed.
			await testInfo.attach('open-folder-picker-error', {
				body: err instanceof Error ? err.message : String(err),
				contentType: 'text/plain',
			});
			throw err;
		}

		const calls = await retryUntil(
			async () => {
				const c = await getOpenDialogCalls(inspector);
				return c.length > 0 ? c : null;
			},
			{ timeout: 5_000, interval: 250 },
		);
		await testInfo.attach('dialog-calls', {
			body: JSON.stringify(calls, null, 2),
			contentType: 'application/json',
		});
		expect(
			calls,
			'dialog.showOpenDialog was invoked after clicking Open folder',
		).toBeTruthy();
		expect((calls ?? []).length).toBeGreaterThan(0);

		inspector.close();
	} finally {
		await app.close();
	}
});
