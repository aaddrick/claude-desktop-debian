import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry, MainWindow } from '../lib/quickentry.js';
import { retryUntil } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S29 — Quick Entry popup is created lazily on first shortcut press
// (closed-to-tray sanity). Backs QE-4 in
// docs/testing/quick-entry-closeout.md.
//
// Upstream constructs the popup BrowserWindow lazily on first
// shortcut invocation (`if (!Ko || ...) Ko = new BrowserWindow(...)`
// near index.js:515375), so the popup does not need a pre-existing
// main window. This test verifies that when the main window has
// been hidden-to-tray (no window mapped on the desktop), the
// shortcut still successfully creates and shows the popup.
//
// Subset of S31's QE-9 case but standalone for the closeout matrix
// — S31 covers submit-side correctness, this covers popup-creation
// correctness.

test.setTimeout(60_000);

test('S29 — Quick Entry popup is created lazily on first shortcut press (closed-to-tray sanity)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Quick Entry popup lifecycle',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	try {
		await app.waitForX11Window(15_000);
		const inspector = await app.attachInspector(15_000);
		const qe = new QuickEntry(inspector);
		const mainWin = new MainWindow(inspector);
		await qe.installInterceptor();

		// Wait for main to fully load before hiding it. Without this,
		// the inspector probe might race the initial `show()` and the
		// state we capture isn't representative.
		await retryUntil(
			async () => {
				const state = await mainWin.getState();
				return state && state.visible ? state : null;
			},
			{ timeout: 15_000, interval: 250 },
		);

		// Hide-to-tray. Project's frame-fix-wrapper turns the X-button
		// close into hide(); we replicate that explicitly so the test
		// doesn't depend on simulating window-manager close.
		await mainWin.setState('hide');

		const hiddenState = await mainWin.getState();
		await testInfo.attach('main-state-after-hide', {
			body: JSON.stringify(hiddenState, null, 2),
			contentType: 'application/json',
		});
		expect(
			hiddenState && !hiddenState.visible,
			'main window is not visible after hide-to-tray',
		).toBe(true);

		// Confirm popup does NOT yet exist (we never triggered the
		// shortcut). This is the lazy-creation precondition.
		const beforeShortcut = await qe.getPopupWebContents();
		expect(
			beforeShortcut,
			'popup webContents does not exist before first shortcut press',
		).toBeNull();

		// Trigger Quick Entry. The popup should be lazily constructed
		// and made visible even though no main window is mapped.
		await qe.openAndWaitReady();

		const popupState = await qe.getPopupState();
		await testInfo.attach('popup-state', {
			body: JSON.stringify(popupState, null, 2),
			contentType: 'application/json',
		});
		expect(
			popupState && popupState.visible,
			'popup is visible after first shortcut press from closed-to-tray',
		).toBe(true);

		inspector.close();
	} finally {
		await app.close();
	}
});
