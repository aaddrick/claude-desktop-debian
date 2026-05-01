import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { getWindowTitle } from '../lib/wm.js';

test('T01 — App launch', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({ type: 'surface', description: 'App startup' });

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude();

	try {
		// Anti-debug gate (see lib/electron.ts) prevents CDP / Playwright
		// renderer access. We verify launch via the X11 window appearing —
		// which simultaneously confirms (a) Electron started, (b) it picked
		// the X11 backend (Decision 6: --ozone-platform=x11 was honored),
		// and (c) the WM accepted the window.
		const wid = await app.waitForX11Window(15_000);
		expect(wid, 'X11 window appeared for claude-desktop pid').toBeTruthy();
		await testInfo.attach('window-id', {
			body: wid,
			contentType: 'text/plain',
		});

		const title = await getWindowTitle(wid);
		await testInfo.attach('window-title', {
			body: title ?? '',
			contentType: 'text/plain',
		});
		expect(title ?? '', 'window title contains "Claude"').toMatch(/claude/i);
	} finally {
		await app.close();
	}
});
