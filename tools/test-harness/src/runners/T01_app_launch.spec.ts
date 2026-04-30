import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { readLauncherLog, captureSessionEnv } from '../lib/diagnostics.js';
import { getEnv } from '../lib/env.js';

test('T01 — App launch', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({ type: 'surface', description: 'App startup' });

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude({ timeout: 30_000 });

	try {
		const window = await app.firstWindow({ timeout: 10_000 });
		expect(window, 'first window appeared within 10s').toBeTruthy();

		await window.waitForLoadState('domcontentloaded', { timeout: 10_000 });

		const title = await window.title();
		await testInfo.attach('window-title', {
			body: title,
			contentType: 'text/plain',
		});

		const screenshot = await window.screenshot();
		await testInfo.attach('main-window', {
			body: screenshot,
			contentType: 'image/png',
		});

		// Decision 6: project default is X11/XWayland on Wayland sessions.
		// Verify the launcher log reflects the chosen backend.
		const log = await readLauncherLog();
		if (log) {
			await testInfo.attach('launcher-log', {
				body: log,
				contentType: 'text/plain',
			});
			const env = getEnv();
			if (env.isWayland) {
				expect(
					log,
					'launcher log mentions X11/XWayland on Wayland session (Decision 6: X11 default)',
				).toMatch(/x11|xwayland/i);
			}
		}
	} finally {
		await app.close();
	}
});
