import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T06 — Quick Entry global shortcut is registered after main visible.
//
// Tier 2 form of T06 (case-doc:
// docs/testing/cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused).
// The shortcut-delivery half (press → popup appears) is covered by
// S29 (lazy-create from tray), S30 (post-exit no-op), and S31 (submit
// reaches new chat). T06 here is purely the registration-state probe:
// after the app is visible, `globalShortcut.isRegistered(accelerator)`
// must return true. Registration succeeds even on portal-grabbed
// Wayland sessions; only delivery is portal-gated, so this assertion
// applies to all rows.
//
// Accelerator string is hardcoded to "Ctrl+Alt+Space" per the
// case-doc Code anchor (build-reference index.js:499376 — `ort`
// default accelerator: `"Ctrl+Alt+Space"` non-mac, `"Alt+Space"` on
// mac). Linux always takes the non-mac branch. If the user remaps
// the shortcut via Settings, this test would fail; the harness
// always launches into a fresh isolated config (no remap).

// 90s test timeout matches waitForReady's own default budget — main
// visibility on a fresh isolation can take ~30-50s on a cold cache
// (Electron unpack + claude.ai initial nav).
test.setTimeout(90_000);

test('T06 — Quick Entry global shortcut is registered after main visible', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Quick Entry / global shortcut',
	});

	// No skipUnlessRow — applies to all rows. Registration succeeds
	// even where delivery is portal-gated; T06's contract is the
	// registration state alone.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	try {
		// mainVisible — registration happens during upstream's
		// `app.on('ready')` chain (build-reference index.js:499416,
		// 525287-525290), which lands before the main BrowserWindow
		// becomes visible. Querying after mainVisible guarantees the
		// register() call has run.
		const { inspector } = await app.waitForReady('mainVisible');

		const result = await inspector.evalInMain<{
			accelerator: string;
			isRegistered: boolean;
		}>(`
			const { globalShortcut } = process.mainModule.require('electron');
			const accelerator = 'Ctrl+Alt+Space';
			return {
				accelerator,
				isRegistered: globalShortcut.isRegistered(accelerator),
			};
		`);

		await testInfo.attach('shortcut-registration', {
			body: JSON.stringify(result, null, 2),
			contentType: 'application/json',
		});

		expect(
			result.isRegistered,
			`globalShortcut.isRegistered('${result.accelerator}') is true ` +
				'after main visible',
		).toBe(true);
	} finally {
		await app.close();
	}
});
