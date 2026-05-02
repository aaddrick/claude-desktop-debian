import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry, MainWindow, waitForUserLoaded } from '../lib/quickentry.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { retryUntil, sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S35 — Quick Entry popup position is persisted across invocations
// and across app restarts. Backs QE-22 in
// docs/testing/quick-entry-closeout.md.
//
// Upstream persists position via `an.set("quickWindowPosition", ...)`
// in the popup's `hide` handler (build-reference index.js:515468). On
// subsequent invocations the popup's construction reads the saved
// position from `an.get("quickWindowPosition")`. The test moves the
// popup to a known position, dismisses (triggering save), restarts
// the app with shared XDG_CONFIG_HOME, and verifies the popup
// reappears at the saved position — not the upstream default.
//
// Two-launch test: the same Isolation handle is passed to
// launchClaude twice so XDG_CONFIG_HOME stays the same across the
// restart. The first call doesn't own the handle, so close() leaves
// the dir intact for the second launch. The test owns cleanup.

const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';

test.setTimeout(180_000);

test('S35 — Quick Entry popup position is persisted across invocations and across app restarts', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Popup placement memory',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// In useHostConfig mode, the host's persisted state is shared
	// across launches automatically. In default isolation mode, we
	// pin a handle and pass it to both launches so XDG_CONFIG_HOME
	// matches.
	let isolation: Isolation | null = null;
	if (!useHostConfig) {
		isolation = await createIsolation();
	}

	// The position we'll move the popup to. Picked to be unambiguously
	// distinct from any default — far from the bottom-center area
	// where upstream's default placement lands.
	const TARGET_X = 80;
	const TARGET_Y = 80;

	try {
		// First launch: open popup, move, dismiss (save fires), re-open,
		// confirm position1 matches TARGET. This is the in-session-
		// memory half.
		const app1 = await launchClaude({ isolation });
		let position1: { x: number; y: number } | null = null;
		try {
			await app1.waitForX11Window(15_000);
			const inspector = await app1.attachInspector(15_000);
			const qe = new QuickEntry(inspector);
			const mainWin = new MainWindow(inspector);
			await qe.installInterceptor();

			// Wait for main visible AND user-loaded. Upstream's
			// shortcut handler calls Ko.show() only when lHn() is
			// true (`!user.isLoggedOut`); if the renderer hasn't
			// loaded the user yet, the popup gets constructed but
			// not shown.
			await retryUntil(
				async () => {
					const s = await mainWin.getState();
					return s && s.visible ? s : null;
				},
				{ timeout: 15_000, interval: 250 },
			);
			const postLoginUrl = await waitForUserLoaded(inspector, 30_000);
			if (!postLoginUrl) {
				testInfo.skip(
					true,
					'claude.ai user did not load past /login within 30s — ' +
						'CLAUDE_TEST_USE_HOST_CONFIG=1 needs a signed-in account',
				);
				return;
			}
			// URL change is renderer-driven; the main-process user
			// object that lHn() reads loads on a separate timeline.
			// 3s margin is empirical — without it, the first shortcut
			// hits before the auth state propagates and Ko.show() is
			// silently skipped.
			await sleep(3_000);

			await qe.openAndWaitReady();

			// Move the popup. setBounds is the most reliable way; the
			// constructor uses it internally too.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (!popup || !popup.ref || popup.ref.isDestroyed()) {
					throw new Error('popup ref unavailable for setBounds');
				}
				popup.ref.setPosition(${TARGET_X}, ${TARGET_Y});
				return null;
			`);
			await sleep(150);

			// Dismiss the popup — hide handler fires, save runs.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (popup && popup.ref && !popup.ref.isDestroyed()) {
					popup.ref.hide();
				}
				return null;
			`);
			await qe.waitForPopupClosed(5_000);
			await sleep(300); // give the save handler time to write

			// Re-open. Should appear at TARGET (in-session memory).
			await qe.openAndWaitReady();
			const state1 = await qe.getPopupState();
			position1 = state1
				? { x: state1.bounds.x, y: state1.bounds.y }
				: null;
			await testInfo.attach('position-after-move', {
				body: JSON.stringify({ position1, target: { x: TARGET_X, y: TARGET_Y } }, null, 2),
				contentType: 'application/json',
			});

			// Dismiss for clean exit.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (popup && popup.ref && !popup.ref.isDestroyed()) {
					popup.ref.hide();
				}
				return null;
			`);
			await qe.waitForPopupClosed(5_000);
			await sleep(300);

			inspector.close();
		} finally {
			await app1.close();
		}

		expect(
			position1,
			'popup position observable after first launch',
		).not.toBeNull();
		expect(
			position1!.x,
			'popup x matches target after move + re-open',
		).toBe(TARGET_X);
		expect(
			position1!.y,
			'popup y matches target after move + re-open',
		).toBe(TARGET_Y);

		// Second launch: same XDG_CONFIG_HOME (or host config). Open
		// popup; should appear at the saved position from the first
		// launch's hide handler.
		const app2 = await launchClaude({ isolation });
		let position2: { x: number; y: number } | null = null;
		try {
			await app2.waitForX11Window(15_000);
			const inspector = await app2.attachInspector(15_000);
			const qe = new QuickEntry(inspector);
			const mainWin = new MainWindow(inspector);
			await qe.installInterceptor();

			// Wait for main visible AND user-loaded — same race as
			// the first launch. Settings load is part of main's
			// startup, so by the time the user has loaded,
			// `an.get("quickWindowPosition")` returns the saved value.
			await retryUntil(
				async () => {
					const s = await mainWin.getState();
					return s && s.visible ? s : null;
				},
				{ timeout: 15_000, interval: 250 },
			);
			const postLoginUrl = await waitForUserLoaded(inspector, 30_000);
			if (!postLoginUrl) {
				testInfo.skip(
					true,
					'claude.ai user did not load past /login within 30s on second launch',
				);
				return;
			}

			await qe.openAndWaitReady();

			const state2 = await qe.getPopupState();
			position2 = state2
				? { x: state2.bounds.x, y: state2.bounds.y }
				: null;
			await testInfo.attach('position-after-restart', {
				body: JSON.stringify(
					{
						position1,
						position2,
						match: !!position2 && position2.x === position1!.x && position2.y === position1!.y,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});

			inspector.close();
		} finally {
			await app2.close();
		}

		expect(
			position2,
			'popup position observable after restart',
		).not.toBeNull();
		expect(
			position2!.x,
			'popup x persisted across restart',
		).toBe(position1!.x);
		expect(
			position2!.y,
			'popup y persisted across restart',
		).toBe(position1!.y);
	} finally {
		if (isolation) await isolation.cleanup();
	}
});

// The popup-selector logic is duplicated from quickentry.ts because
// it's a private method there; expressing it inline here keeps S35
// self-contained without making the helper public for one caller.
function popupSelectorJs(): string {
	return `(w => {
		if (!w || !w.ref || w.ref.isDestroyed()) return false;
		const f = String(w.loadedFile || '');
		return f.indexOf('quick-window.html') !== -1
			|| f.indexOf('quick_window/') !== -1;
	})`;
}
