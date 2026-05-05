import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry } from '../lib/quickentry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S10 — Quick Entry popup is transparent (no opaque square frame).
// Backs the KDE-W row of S10 in
// docs/testing/cases/shortcuts-and-input.md.
//
// Upstream constructs the popup BrowserWindow with
//   transparent: true, backgroundColor: "#00000000", frame: false
// at build-reference index.js:515380, 515383, 515381. On KDE Plasma
// Wayland the compositor honours the alpha channel and the popup
// renders with a transparent background; on broken-Electron versions
// (electron/electron#50213, the 41.0.4-41.x.y bisect window per
// @noctuum on #370) the alpha is dropped and an opaque square frame
// shows behind the rounded prompt UI.
//
// Construction-time options aren't observable through the prototype-
// method hook in lib/quickentry.ts (the Proxy from frame-fix-wrapper
// returns the closure-captured PatchedBrowserWindow on `electron.
// BrowserWindow` reads — see the doc-comment on
// QuickEntry.installInterceptor and CLAUDE.md "Test harness Electron
// hooks" learning). Runtime-side, `getBackgroundColor()` reflects
// what the BrowserWindow was actually constructed with — so we read
// it via getPopupRuntimeProps() and assert
//   transparent === true && backgroundColor in {'#00000000','#0000'}
// matching the predicate in lib/quickentry.ts:266.
//
// Gated to KDE-W: other KDE rows (KDE-X) don't have the same
// compositor / Electron-Wayland concern that the case-doc S10
// surfaces. If S10 fails on a host whose bundled Electron is in the
// 41.0.4-41.x.y window, that's the upstream regression — see S33 for
// the version-capture half. Don't wrap in skip on failure; surface
// it as a regression-detector signal.

test.setTimeout(60_000);

test('S10 — Quick Entry popup is transparent (no opaque square frame)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Quick Entry window (KDE Wayland)',
	});
	skipUnlessRow(testInfo, ['KDE-W']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	await testInfo.attach('isolation', {
		body: JSON.stringify(
			{
				useHostConfig,
				configDir: app.isolation?.configDir ?? null,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	try {
		// Main needs to be up before the shortcut can lazily construct
		// the popup — the popup-show path reads renderer state via
		// upstream's lHn() user-loaded check (see openAndWaitReady's
		// retry-loop comment in lib/quickentry.ts).
		const { inspector } = await app.waitForReady('mainVisible');
		const qe = new QuickEntry(inspector);
		await qe.installInterceptor();

		// Fire the OS shortcut and wait for the popup BrowserWindow to
		// be visible with its textarea mounted — same handshake S29
		// uses. If ydotool isn't reachable, openAndWaitReady throws
		// the install-instructions error from ensureYdotool — that
		// surfaces as a clear test failure (acceptable per the
		// case-doc; not wrapped in a skip).
		await qe.openAndWaitReady();

		const props = await qe.getPopupRuntimeProps();
		await testInfo.attach('popup-runtime-props', {
			body: JSON.stringify(props, null, 2),
			contentType: 'application/json',
		});

		expect(
			props,
			'getPopupRuntimeProps returned null — interceptor did not ' +
				'capture the popup BrowserWindow ref',
		).not.toBeNull();
		// Predicate matches lib/quickentry.ts:266 — '#00000000' is the
		// canonical 8-digit form Electron returns for the upstream
		// construction value, '#0000' is the short form some Electron
		// builds normalise to. Either is acceptable.
		expect(
			props!.backgroundColor === '#00000000'
				|| props!.backgroundColor === '#0000',
			`popup backgroundColor must be transparent (#00000000 or ` +
				`#0000), got ${JSON.stringify(props!.backgroundColor)}. ` +
				`If the bundled Electron is in the 41.0.4-41.x.y window ` +
				`(see S33), this is the electron#50213 regression ` +
				`tracked under issue #370.`,
		).toBe(true);
		expect(
			props!.transparent,
			'popup transparent flag (derived from backgroundColor) is ' +
				'false — opaque square frame would render behind the ' +
				'rounded prompt UI',
		).toBe(true);

		inspector.close();
	} finally {
		await app.close();
	}
});
