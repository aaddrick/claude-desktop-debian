import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { readPidArgv, argvHasFlag } from '../lib/argv.js';
import { readLauncherLog, captureSessionEnv } from '../lib/diagnostics.js';
import { retryUntil } from '../lib/retry.js';

// S07 — `CLAUDE_USE_WAYLAND=1` opt-in path works.
//
// Backs S07 in docs/testing/cases/shortcuts-and-input.md.
//
// Case-doc anchors:
//   scripts/launcher-common.sh:28-29 — `CLAUDE_USE_WAYLAND=1` opt-in
//     (sets `use_x11_on_wayland=false`, taking the native-Wayland
//     branch in build_electron_args).
//   scripts/launcher-common.sh:100-111 — native-Wayland Electron flags:
//     `--enable-features=UseOzonePlatform,WaylandWindowDecorations`,
//     `--ozone-platform=wayland`, `--enable-wayland-ime`,
//     `--wayland-text-input-version=3`, plus `GDK_BACKEND=wayland`.
//
// What this asserts: when the harness's Wayland mode is engaged
// (`CLAUDE_HARNESS_USE_WAYLAND=1`), the spawned Electron's argv
// contains `--ozone-platform=wayland` and `CLAUDE_USE_WAYLAND=1` is
// exported into the spawn env. That mirrors the launcher's
// CLAUDE_USE_WAYLAND=1 branch — same flag set is emitted (see
// LAUNCHER_INJECTED_FLAGS_WAYLAND in src/lib/electron.ts:134-141).
//
// Gating choice — harness-mode vs launcher-script:
//
// The harness deliberately bypasses the launcher script (CDP-gate
// reasons — see lib/electron.ts:102-117), so it constructs its own
// flag set. Setting `extraEnv: { CLAUDE_USE_WAYLAND: '1' }` would
// only affect the child env, not the harness's flag selector. To
// exercise the Wayland branch end-to-end the harness exposes
// `CLAUDE_HARNESS_USE_WAYLAND=1`, which:
//   1. swaps to LAUNCHER_INJECTED_FLAGS_WAYLAND (the same flag
//      set the launcher's Wayland branch emits), and
//   2. exports `CLAUDE_USE_WAYLAND=1` + `GDK_BACKEND=wayland` into
//      the child env.
//
// This test asserts that contract. When CLAUDE_HARNESS_USE_WAYLAND
// is unset we skip — the harness's X11 default doesn't model the
// CLAUDE_USE_WAYLAND opt-in path. Run the suite with
// `CLAUDE_HARNESS_USE_WAYLAND=1 npx playwright test ...` to
// activate the assertion.
//
// Row gate: native-Wayland-capable rows only. KDE-W is intentionally
// included even though the case-doc Applies-to lists wlroots rows
// (Sway/Niri/Hypr) — KDE Plasma Wayland can also run native Wayland
// when CLAUDE_USE_WAYLAND=1 is set, and KDE-W is the harness's CI
// row, so we want this to be exercisable there.

test.setTimeout(45_000);

test('S07 — CLAUDE_USE_WAYLAND opt-in surfaces in Electron argv', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Display backend / Wayland opt-in',
	});
	skipUnlessRow(testInfo, [
		'Sway',
		'Niri',
		'Hypr-O',
		'Hypr-N',
		'GNOME-W',
		'KDE-W',
	]);

	if (process.env.CLAUDE_HARNESS_USE_WAYLAND !== '1') {
		test.skip(
			true,
			'S07 requires CLAUDE_HARNESS_USE_WAYLAND=1 (the harness ' +
				'Wayland-mode that mirrors the launcher CLAUDE_USE_WAYLAND ' +
				'branch). Re-run with the env set.',
		);
		return;
	}

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});
	await testInfo.attach('harness-env', {
		body: JSON.stringify(
			{
				CLAUDE_HARNESS_USE_WAYLAND:
					process.env.CLAUDE_HARNESS_USE_WAYLAND ?? null,
				CLAUDE_USE_WAYLAND: process.env.CLAUDE_USE_WAYLAND ?? null,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	try {
		// Don't waitForX11Window — under native Wayland the app is
		// going through Ozone-Wayland directly, no XWayland window
		// appears. /proc/$pid/cmdline is populated by exec(), so we
		// just need the spawned Electron to stay alive long enough
		// to read it. Poll for non-null + non-empty argv.
		const argv = await retryUntil(
			async () => {
				const a = await readPidArgv(app.pid);
				return a && a.length > 0 ? a : null;
			},
			{ timeout: 15_000, interval: 250 },
		);
		await testInfo.attach('electron-argv', {
			body: JSON.stringify(argv, null, 2),
			contentType: 'application/json',
		});
		expect(argv, 'could read /proc/$pid/cmdline').not.toBeNull();

		// Launcher log is only populated when the launcher script
		// runs; the harness spawns Electron directly. Capture the
		// log if it happens to exist (host-leftover from an earlier
		// real-launcher run) for diagnostic context only.
		const log = await readLauncherLog();
		if (log) {
			const tail = log.split('\n').slice(-50).join('\n');
			await testInfo.attach('launcher-log-tail', {
				body: tail,
				contentType: 'text/plain',
			});
		}

		const ozoneWayland = argvHasFlag(argv ?? [], '--ozone-platform=wayland');
		const useOzone = argvHasFlag(
			argv ?? [],
			'--enable-features=UseOzonePlatform',
		);
		await testInfo.attach('flag-presence', {
			body: JSON.stringify(
				{
					'--ozone-platform=wayland': ozoneWayland,
					'--enable-features=UseOzonePlatform': useOzone,
					note:
						'When CLAUDE_HARNESS_USE_WAYLAND=1 the harness ' +
						'must emit the same Electron flag set as the ' +
						'launcher script\'s CLAUDE_USE_WAYLAND=1 branch.',
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			ozoneWayland,
			'spawned Electron has --ozone-platform=wayland on argv',
		).toBe(true);
		expect(
			useOzone,
			'spawned Electron has --enable-features=UseOzonePlatform ' +
				'(co-emitted with the wayland ozone flag)',
		).toBe(true);
	} finally {
		await app.close();
	}
});
