import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import {
	QuickEntry,
	MainWindow,
	waitForNewChat,
} from '../lib/quickentry.js';
import { retryUntil } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S32 — Quick Entry submit on GNOME mutter doesn't trip Electron
// stale-isFocused. Backs QE-11 / QE-12 in
// docs/testing/quick-entry-closeout.md.
//
// Andrej730's #393 root cause: Electron's `BrowserWindow.isFocused()`
// returns stale-true on Linux mutter after `hide()`, which causes
// upstream's `h1() || ut.show()` short-circuit (index.js:515566) to
// skip `show()` — so submit creates a new chat session but the main
// window never reappears, and the chat is unreachable.
//
// Differs from S31 in TWO ways:
//   1. Row-gated to GNOME Wayland (KDE-W is excluded; the post-#406
//      patch handles KDE specifically).
//   2. Adds two regression-detector assertions independent of S31:
//      (a) the popup is not still visible after submit (the bug
//          can also leave Ko on screen because the close-on-dismiss
//          handler is downstream of the show() that short-circuits),
//      (b) the main window becomes visible (the original symptom
//          Andrej730 reported).
//      Each assertion is a separate failure shape — popup-stuck and
//      main-stuck can occur together or independently.
//
// Expected to FAIL on GNOME-W today until the fix lands (either
// widening the patch beyond KDE, or upstream Electron fixing
// isFocused() on Linux). That's the regression-detector use of this
// test — green it cell once the fix is in.

test.setTimeout(180_000);

test('S32 — Quick Entry submit on GNOME mutter does not trip Electron stale-isFocused', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Electron BrowserWindow.isFocused() on Linux',
	});
	skipUnlessRow(testInfo, ['GNOME-W', 'Ubu-W']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	try {
		// claudeAi level — submit makes no sense before claude.ai
		// loads. Soft-fails to skip when not signed in.
		const { inspector, claudeAiUrl } = await app.waitForReady('claudeAi');
		if (!claudeAiUrl) {
			testInfo.skip(
				true,
				'claude.ai webContents never loaded — likely not signed in. ' +
					'Set CLAUDE_TEST_USE_HOST_CONFIG=1 to share host config.',
			);
			return;
		}

		const qe = new QuickEntry(inspector);
		const mainWin = new MainWindow(inspector);
		await qe.installInterceptor();

		// Reproduce the tray-only state Andrej730 traced.
		await mainWin.setState('show');
		await retryUntil(
			async () => {
				const s = await mainWin.getState();
				return s && s.visible ? s : null;
			},
			{ timeout: 5_000, interval: 200 },
		);
		await mainWin.setState('hide');

		const hidden = await mainWin.getState();
		await testInfo.attach('main-state-hidden', {
			body: JSON.stringify(hidden, null, 2),
			contentType: 'application/json',
		});
		expect(hidden && !hidden.visible, 'main is hidden before submit').toBe(true);

		// Submit a prompt. This is the moment the stale-isFocused
		// bug bites — h1() returns true (because isFocused() lies),
		// so show() is skipped, and main never reappears.
		const prompt = `s32-${Date.now()}`;
		await qe.openAndWaitReady();
		await qe.typeAndSubmit(prompt);

		// Capture popup-close outcome instead of swallowing it. The
		// pre-fix S31 pattern catches-and-discards because S31 uses
		// popupClosed as its Critical assertion already; here we
		// want the boolean for an independent assertion below.
		let popupClosed = false;
		try {
			await qe.waitForPopupClosed(8_000);
			popupClosed = true;
		} catch {
			// timeout — leave popupClosed=false; the explicit popup-
			// state assertion below will surface the regression shape.
		}

		// Popup-stuck assertion. The same short-circuit that skips
		// `show()` for main can leave the popup on screen because
		// the close-on-dismiss path (popup.hide()) sits downstream
		// of the show() call that returned early. Treat either
		// destroyed (state === null) or hidden (visible === false)
		// as "popup not stuck."
		const popupStateAfterSubmit = await qe.getPopupState();
		await testInfo.attach('popup-state-after-submit', {
			body: JSON.stringify(
				{
					popupClosed,
					popupState: popupStateAfterSubmit,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
		const popupNotVisible =
			popupStateAfterSubmit === null || !popupStateAfterSubmit.visible;
		expect(
			popupNotVisible,
			'popup is not visible after submit (regression detector ' +
				'for the stale-isFocused short-circuit leaving Ko on screen)',
		).toBe(true);

		// Should signal — chat created (network).
		const navUrl = await waitForNewChat(inspector, 15_000);

		// Critical signal — main reappears. The stale-isFocused bug
		// causes this to remain false even though submit physically
		// succeeded.
		const mainBecameVisible = await retryUntil(
			async () => {
				const s = await mainWin.getState();
				return s && s.visible ? s : null;
			},
			{ timeout: 8_000, interval: 200 },
		);

		await testInfo.attach('s32-result', {
			body: JSON.stringify(
				{
					navUrl,
					popupClosed,
					popupStateAfterSubmit,
					mainBecameVisible: !!mainBecameVisible,
					mainStateAfterSubmit: mainBecameVisible,
					note: 'GNOME-W today is expected to show navUrl=set ' +
						'AND mainBecameVisible=false until the fix lands.',
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			mainBecameVisible,
			'main window becomes visible after Quick Entry submit (no stale-isFocused short-circuit)',
		).toBeTruthy();

		// Reset. Run with show before scenario re-runs so any post-
		// test inspector activity sees a clean window.
		await mainWin.setState('show').catch(() => {});

		inspector.close();
	} finally {
		await app.close();
	}
});

// Note on QE-12 (Dash-pinned vs not pinned): the closeout doc says
// the Dash distinction is empirical, not code-driven — upstream has
// no notion of Dash presence. So we only run the not-pinned case
// here (the harder repro from the #393 traces). If the not-pinned
// case green-cells, the pinned case will too. Adding a separate
// scenario for QE-12 specifically would require Dash-pin
// orchestration, which has no scriptable API on GNOME Wayland.
// Treat S32 as covering both QE-11 and QE-12 for the matrix.
