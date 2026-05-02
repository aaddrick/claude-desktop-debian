import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { readPidArgv, argvHasFlag } from '../lib/argv.js';
import { readLauncherLog, captureSessionEnv } from '../lib/diagnostics.js';

// S12 — `--enable-features=GlobalShortcutsPortal` launcher flag
// wired up for GNOME Wayland. Backs QE-6 in
// docs/testing/quick-entry-closeout.md.
//
// On GNOME Wayland, mutter no longer honors XWayland-side key grabs,
// so the Quick Entry global shortcut fails from unfocused state
// (#404). The fix is to route global shortcuts through XDG Desktop
// Portal: pass `--enable-features=GlobalShortcutsPortal` to Electron
// from the launcher when XDG_CURRENT_DESKTOP includes GNOME and
// XDG_SESSION_TYPE is wayland.
//
// As of writing, this fix is NOT implemented. The test asserts the
// fix's signature (the flag is in the spawned Electron's argv) and
// will therefore FAIL on GNOME-W until the launcher patch lands.
// That's intentional — it's the regression detector, not a smoke
// test. Once the patch is in, this becomes a Critical green cell.
//
// Row gate: GNOME Wayland only. KDE rows skip with `-`.

test.setTimeout(45_000);

test('S12 — --enable-features=GlobalShortcutsPortal launcher flag wired up for GNOME Wayland', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Launcher flag wiring',
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
		await app.waitForX11Window(15_000);

		const argv = await readPidArgv(app.pid);
		await testInfo.attach('electron-argv', {
			body: JSON.stringify(argv, null, 2),
			contentType: 'application/json',
		});
		expect(argv, 'could read /proc/$pid/cmdline').not.toBeNull();

		// Launcher log carries a stable line — see
		// scripts/launcher-common.sh:98, 102 — that says which backend
		// was selected. Capture it for diagnostic context.
		const log = await readLauncherLog();
		if (log) {
			const tail = log.split('\n').slice(-50).join('\n');
			await testInfo.attach('launcher-log-tail', {
				body: tail,
				contentType: 'text/plain',
			});
		}

		const present = argvHasFlag(
			argv ?? [],
			'--enable-features=GlobalShortcutsPortal',
		);
		await testInfo.attach('flag-presence', {
			body: JSON.stringify(
				{
					flag: '--enable-features=GlobalShortcutsPortal',
					present,
					note:
						'On GNOME Wayland this flag must be present for ' +
						'#404 to be closeable. Until the launcher patch ' +
						'lands, this test fails as a regression detector.',
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			present,
			'--enable-features=GlobalShortcutsPortal is in Electron argv on GNOME Wayland',
		).toBe(true);
	} finally {
		await app.close();
	}
});
