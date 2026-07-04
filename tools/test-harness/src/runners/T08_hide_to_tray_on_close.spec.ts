import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { MainWindow } from '../lib/quickentry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { retryUntil } from '../lib/retry.js';

// T08 — Closing the main window hides to tray instead of quitting.
//
// Since the v3.0.0 rebase the official build owns close-to-tray on
// Linux — the 2.x frame-fix-wrapper close interceptor (PR #451) is
// deleted because upstream converged on the same user-visible
// behavior. T08 therefore pins the CONTRACT, not the mechanism:
// clicking the X-button must hide the window and leave the process
// alive; only tray-Quit / Ctrl+Q / SIGTERM exit the app. If an
// upstream release regresses Linux back to quit-on-last-window-
// closed, this is the spec that catches it.
//
// Test shape: launch, capture pre-state, fire `'close'` on the main
// BrowserWindow (MainWindow.setState('close') calls win.close(),
// which fires the same 'close' event a real X-button click does),
// then assert the window flipped to invisible AND the Electron
// process is still running. The `'hide'` action would also flip
// visible:false but bypasses the close path — that's what S29
// tests, and it deliberately does NOT exercise the regression
// detection T08 cares about.
//
// Applies to all rows. No skipUnlessRow gate.

test.setTimeout(60_000);

test('T08 — Closing main window hides to tray, app stays alive', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Window chrome / close-to-tray',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude();
	try {
		const { inspector } = await app.waitForReady('mainVisible');
		const mainWin = new MainWindow(inspector);

		const before = await mainWin.getState();
		await testInfo.attach('main-state-before-close', {
			body: JSON.stringify(before, null, 2),
			contentType: 'application/json',
		});
		expect(before, 'main window state reachable pre-close').toBeTruthy();
		expect(before?.visible, 'main window visible before close').toBe(true);

		// Fire the BrowserWindow 'close' event. The official build's
		// close handler should preventDefault + hide() rather than
		// letting the window destroy + the app quit via the
		// 'window-all-closed' path.
		await mainWin.setState('close');

		// Poll for visible:false. The close-to-tray transition is
		// synchronous in the close handler, but compositor side
		// effects (unmap + isVisible() flip) can lag a beat — 5s is
		// generous for the runtime check.
		const after = await retryUntil(
			async () => {
				const s = await mainWin.getState();
				return s && !s.visible ? s : null;
			},
			{ timeout: 5_000, interval: 200 },
		);
		await testInfo.attach('main-state-after-close', {
			body: JSON.stringify(after, null, 2),
			contentType: 'application/json',
		});
		await testInfo.attach('proc-state', {
			body: JSON.stringify(
				{
					exitCode: app.process.exitCode,
					signalCode: app.process.signalCode,
					pid: app.pid,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(after, 'main window state reachable post-close').toBeTruthy();
		expect(after?.visible, 'main window hidden after close').toBe(false);
		expect(
			app.process.exitCode,
			'app process did not quit (close-to-tray)',
		).toBe(null);
		expect(
			app.process.signalCode,
			'app process not killed by signal',
		).toBe(null);
	} finally {
		await app.close();
	}
});
