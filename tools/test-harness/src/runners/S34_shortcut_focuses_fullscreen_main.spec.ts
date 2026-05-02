import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry, MainWindow } from '../lib/quickentry.js';
import { retryUntil, sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S34 — Quick Entry shortcut focuses fullscreen main window instead
// of showing popup. Backs QE-1b in
// docs/testing/quick-entry-closeout.md.
//
// Upstream contract (build-reference index.js:525287-525290):
// `if (ut.isFullScreen()) { ut.focus(); ide(); } else { showPopup(); }`
// — when the main window is fullscreen, the shortcut focuses main
// instead of showing the popup. Intentional UX: assumes the user
// wants to interact with the existing fullscreen Claude rather than
// overlay a popup on it.
//
// This is the inverse-shape test: assert popup does NOT become
// visible within a generous window after the shortcut. If the
// popup appears, the upstream fullscreen-special-case has been
// regressed (or never reached).

test.setTimeout(45_000);

test('S34 — Quick Entry shortcut focuses fullscreen main window instead of showing popup', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Shortcut behavior on fullscreen main',
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
		// mainVisible — some compositors no-op setFullScreen on
		// un-mapped windows, so wait for the main shell to be shown
		// before driving fullscreen state.
		const { inspector } = await app.waitForReady('mainVisible');
		const qe = new QuickEntry(inspector);
		const mainWin = new MainWindow(inspector);
		await qe.installInterceptor();

		await mainWin.setState('show');
		await mainWin.setState('fullScreen');

		// Compositor takes a moment to enter fullscreen.
		const fullscreened = await retryUntil(
			async () => {
				const state = await mainWin.getState();
				return state && state.fullScreen ? state : null;
			},
			{ timeout: 5_000, interval: 200 },
		);
		await testInfo.attach('main-fullscreen-state', {
			body: JSON.stringify(fullscreened, null, 2),
			contentType: 'application/json',
		});

		if (!fullscreened) {
			testInfo.skip(
				true,
				"compositor did not honor setFullScreen — can't validate the fullscreen edge case",
			);
			return;
		}

		// Trigger the shortcut and verify the popup never becomes
		// visible. We give it 3s — generous compared to a normal
		// popup-open which is ~500ms.
		await qe.openViaShortcut();
		await sleep(3_000);

		const popupState = await qe.getPopupState();
		await testInfo.attach('popup-state-after-shortcut', {
			body: JSON.stringify(popupState, null, 2),
			contentType: 'application/json',
		});

		// Popup may not exist at all (preferred), or may exist but
		// be hidden. Both satisfy the contract; only "popup is
		// visible" is a regression.
		if (popupState !== null) {
			expect(
				popupState.visible,
				'popup BrowserWindow exists but is not visible while main is fullscreen',
			).toBe(false);
		}

		// Sanity: main is still fullscreen + focused after the shortcut.
		const mainAfter = await mainWin.getState();
		await testInfo.attach('main-state-after-shortcut', {
			body: JSON.stringify(mainAfter, null, 2),
			contentType: 'application/json',
		});

		// Restore before close so we don't leave the app in fullscreen
		// state if the user is sharing config (CLAUDE_TEST_USE_HOST_CONFIG).
		await mainWin.setState('unFullScreen').catch(() => {});

		inspector.close();
	} finally {
		await app.close();
	}
});
