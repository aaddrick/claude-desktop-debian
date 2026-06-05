import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { readPidArgv, argvHasFlag } from '../lib/argv.js';
import { readLauncherLog, captureSessionEnv } from '../lib/diagnostics.js';

// S12 — `--enable-features=GlobalShortcutsPortal` launcher flag
// wired up for the native-Wayland path. Backs QE-6 in
// docs/testing/quick-entry-closeout.md.
//
// On GNOME Wayland, mutter no longer honors XWayland-side key grabs,
// so the Quick Entry global shortcut fails from unfocused state
// (#404). The launcher routes global shortcuts through XDG Desktop
// Portal by adding `GlobalShortcutsPortal` to the native-Wayland
// `--enable-features` set.
//
// GNOME native Wayland is opt-in (CLAUDE_USE_WAYLAND=1), NOT the
// default — flipping the default GNOME session off XWayland is a
// rendering/IME risk, and on GNOME 50 the portal route is a no-op
// upstream (electron/electron#51875). So this test launches with
// CLAUDE_USE_WAYLAND=1 and asserts the flag is present on that
// opt-in path. The portal feature is comma-joined with the ozone
// features (Chromium honors only the last `--enable-features`), so we
// match the subkey, not an exact token.
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
		// GNOME native+portal is opt-in; exercise that path explicitly.
		extraEnv: { CLAUDE_USE_WAYLAND: '1' },
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
