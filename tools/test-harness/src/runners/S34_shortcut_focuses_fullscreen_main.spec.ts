import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow, currentRow } from '../lib/row.js';
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
// Two-sided assertion: (1) popup does NOT become visible (the
// suppression half), and (2) main is focused + still fullscreen
// after the shortcut (the focus half). The original test only
// asserted (1); upstream's contract is `ut.focus(); ide()` not
// just "skip showPopup", so an asserts-suppression-only test
// could pass even if the focus() call regressed silently.
//
// Compositor honor of focus() on fullscreen windows is uneven:
// KDE-W / KDE-X are reliable, GNOME-W / Ubu-W routinely no-op
// focus requests on fullscreen surfaces (mutter "focus stealing
// prevention"). The focus assertion is hard on KDE rows and
// soft-fixme'd elsewhere — the suppression half still runs
// everywhere.

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

		// Focus half: upstream's contract is `ut.focus(); ide()` —
		// not just "skip showPopup". Assert the focus side too.
		const mainAfter = await mainWin.getState();
		await testInfo.attach('main-state-after-shortcut', {
			body: JSON.stringify(mainAfter, null, 2),
			contentType: 'application/json',
		});

		// fullScreen is unconditional — the shortcut should never
		// drop fullscreen state. (If main lost fullscreen, the
		// shortcut went through the showPopup branch instead of
		// the focus-and-ide branch — i.e. a different regression
		// shape than "popup visible".)
		expect(
			mainAfter && mainAfter.fullScreen,
			'main remains fullscreen after shortcut press (focus branch, not showPopup branch)',
		).toBe(true);

		// Focused is hard-asserted on KDE rows where focus() is
		// reliable; soft-fixme on GNOME-derived rows where mutter
		// routinely no-ops focus on fullscreen surfaces. The
		// distinction is the compositor, not the upstream contract
		// — upstream calls focus() either way.
		const row = currentRow();
		const hardFocusRows = ['KDE-W', 'KDE-X'];
		const focusOk = !!(mainAfter && mainAfter.focused);
		if (!focusOk) {
			if (hardFocusRows.includes(row)) {
				expect(
					focusOk,
					`main is focused after shortcut press on ${row} (focus() honored by KDE compositors)`,
				).toBe(true);
			} else {
				testInfo.fixme(
					true,
					`main not focused after shortcut on ${row}; upstream contract ` +
						`requires focus() but compositor honor on fullscreen ` +
						`surfaces is best-effort outside KDE. mainAfter=` +
						JSON.stringify(mainAfter),
				);
			}
		}

		// Restore before close so we don't leave the app in fullscreen
		// state if the user is sharing config (CLAUDE_TEST_USE_HOST_CONFIG).
		await mainWin.setState('unFullScreen').catch(() => {});

		inspector.close();
	} finally {
		await app.close();
	}
});
