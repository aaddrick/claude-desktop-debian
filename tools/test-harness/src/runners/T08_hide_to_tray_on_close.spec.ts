import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { MainWindow } from '../lib/quickentry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { retryUntil } from '../lib/retry.js';

// T08 — Closing the main window hides to tray instead of quitting.
//
// On Linux, upstream's quit-on-last-window-closed handler at
// build-reference/app-extracted/.vite/build/index.js:525550-525552
// (`hA.app.on("window-all-closed", () => { Zr || Ap() })` — `Zr` is
// the darwin guard) would otherwise call into the quit path the
// first time the user clicks the X-button. PR #451 plumbed
// scripts/frame-fix-wrapper.js:178-185:
//   this.on('close', e => {
//     if (!result.app._quittingIntentionally && !this.isDestroyed()) {
//       e.preventDefault();
//       this.hide();
//     }
//   });
// armed by the `before-quit` handler at frame-fix-wrapper.js:370-374
// which sets `_quittingIntentionally = true` for the tray-Quit /
// Ctrl+Q / SIGTERM exits. So the X-button path takes the
// preventDefault + hide() branch; the tray-Quit path bypasses it.
//
// Test shape: launch, capture pre-state, fire `'close'` on the main
// BrowserWindow (MainWindow.setState('close') calls win.close(),
// which fires the same 'close' event the wrapper intercepts on a
// real X-button click), then assert the window flipped to invisible
// AND the Electron process is still running. The `'hide'` action
// would also flip visible:false but bypasses the wrapper — that's
// what S29 tests, and it deliberately does NOT exercise the
// regression-detection T08 cares about.
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

		// Fire the BrowserWindow 'close' event. The wrapper at
		// frame-fix-wrapper.js:178-185 should preventDefault +
		// hide() rather than letting the window destroy + the app
		// quit via the 'window-all-closed' path.
		await mainWin.setState('close');

		// Poll for visible:false. The close-to-tray transition is
		// synchronous in the wrapper's interceptor, but compositor
		// side effects (unmap + isVisible() flip) can lag a beat —
		// 5s is generous for the runtime check.
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
