import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { findItemByPid } from '../lib/sni.js';
import { retryUntil } from '../lib/retry.js';
import { disconnectBus } from '../lib/dbus.js';

test('T03 — Tray icon present', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Tray / StatusNotifierItem',
	});

	const app = await launchClaude();

	try {
		await app.waitForX11Window(15_000);

		// Tray registration may lag the first window by a few hundred ms.
		// Poll the SNI watcher until our pid shows up among registered items.
		const ourItem = await retryUntil(
			async () => findItemByPid(app.pid),
			{ timeout: 15_000, interval: 500 },
		);

		expect(
			ourItem,
			'a StatusNotifierItem registered by claude-desktop pid was found',
		).toBeTruthy();

		if (ourItem) {
			await testInfo.attach('sni-item', {
				body: JSON.stringify(ourItem, null, 2),
				contentType: 'application/json',
			});
		}
	} finally {
		await app.close();
		await disconnectBus();
	}
});
