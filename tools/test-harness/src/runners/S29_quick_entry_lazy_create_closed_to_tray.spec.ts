import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry, MainWindow } from '../lib/quickentry.js';
import type { InspectorClient } from '../lib/inspector.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S29 — Quick Entry popup is created lazily on first shortcut press
// (closed-to-tray sanity), and the BrowserWindow is reused across
// subsequent presses. Backs QE-4 in
// docs/testing/quick-entry-closeout.md.
//
// Upstream constructs the popup BrowserWindow lazily on first
// shortcut invocation (`if (!Ko || ...) Ko = new BrowserWindow(...)`
// near index.js:515375), so the popup does not need a pre-existing
// main window. This test verifies that when the main window has
// been hidden-to-tray (no window mapped on the desktop), the
// shortcut still successfully creates and shows the popup.
//
// Reuse half: after the first press constructs Ko, every later press
// must hit `Ko.show()` rather than `new BrowserWindow(...)`. The
// interceptor records every `loadFile` call, so a fresh
// construction would push a SECOND entry into `__qeWindows` matching
// the popup selector. We assert the count stays at 1 across the
// hide / re-press cycle. See lib/quickentry.ts:215 for the
// "Ko stays alive" comment.
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
		// Wait for main to fully load before hiding it. Without this,
		// the inspector probe races the initial `show()` and the
		// state we capture isn't representative.
		const { inspector } = await app.waitForReady('mainVisible');
		const qe = new QuickEntry(inspector);
		const mainWin = new MainWindow(inspector);
		await qe.installInterceptor();

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
		await testInfo.attach('popup-state-first-press', {
			body: JSON.stringify(popupState, null, 2),
			contentType: 'application/json',
		});
		expect(
			popupState && popupState.visible,
			'popup is visible after first shortcut press from closed-to-tray',
		).toBe(true);

		// Reuse precondition: exactly one popup-shaped entry sits in
		// `__qeWindows` after the first press. The interceptor pushes
		// on every loadFile/loadURL, so anything beyond 1 means the
		// popup was constructed more than once already.
		const popupCountAfterFirst = await countPopupWindows(inspector);
		await testInfo.attach('popup-window-count-after-first', {
			body: JSON.stringify({ count: popupCountAfterFirst }, null, 2),
			contentType: 'application/json',
		});
		expect(
			popupCountAfterFirst,
			'exactly one popup BrowserWindow recorded after first shortcut press',
		).toBe(1);

		// Dismiss the popup directly via the captured ref — no need to
		// involve the OS shortcut grab a second time for the dismiss
		// step. waitForPopupClosed reads `isVisible()` on the same ref,
		// which flips false as soon as `hide()` returns.
		await inspector.evalInMain<null>(`
			const wins = globalThis.__qeWindows || [];
			const popup = wins.find(w => {
				if (!w || !w.ref || w.ref.isDestroyed()) return false;
				const f = String(w.loadedFile || '');
				return f.indexOf('quick-window.html') !== -1
					|| f.indexOf('quick_window/') !== -1;
			});
			if (popup && popup.ref && !popup.ref.isDestroyed()) {
				popup.ref.hide();
			}
			return null;
		`);
		await qe.waitForPopupClosed(5_000);

		// Second shortcut press. Upstream's lazy-init branch must take
		// the existing-Ko path here; if it instead constructed a new
		// BrowserWindow, `__qeWindows` would gain a second
		// quick-window.html entry and the count below would jump to 2.
		await qe.openAndWaitReady();

		const popupStateSecond = await qe.getPopupState();
		await testInfo.attach('popup-state-second-press', {
			body: JSON.stringify(popupStateSecond, null, 2),
			contentType: 'application/json',
		});
		expect(
			popupStateSecond && popupStateSecond.visible,
			'popup is visible after second shortcut press (reuse path)',
		).toBe(true);

		const popupCountAfterSecond = await countPopupWindows(inspector);
		await testInfo.attach('popup-window-count-after-second', {
			body: JSON.stringify({ count: popupCountAfterSecond }, null, 2),
			contentType: 'application/json',
		});
		expect(
			popupCountAfterSecond,
			'popup BrowserWindow is reused — second shortcut press did not ' +
				'construct a new window (regression guard for the lifecycle ' +
				'comment in lib/quickentry.ts)',
		).toBe(1);

		inspector.close();
	} finally {
		await app.close();
	}
});

// Count entries in `globalThis.__qeWindows` whose loadFile target
// matches the popup selector. Mirrors the private popupSelector in
// lib/quickentry.ts — kept inline rather than exposing a new helper
// because this is the only caller and the shape is one line.
async function countPopupWindows(inspector: InspectorClient): Promise<number> {
	return await inspector.evalInMain<number>(`
		const wins = globalThis.__qeWindows || [];
		let n = 0;
		for (const w of wins) {
			if (!w || !w.ref || w.ref.isDestroyed()) continue;
			const f = String(w.loadedFile || '');
			if (f.indexOf('quick-window.html') !== -1
				|| f.indexOf('quick_window/') !== -1) {
				n++;
			}
		}
		return n;
	`);
}
