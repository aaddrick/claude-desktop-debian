import { test } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S36 — Quick Entry popup falls back to primary display when saved
// monitor is gone. Backs QE-23 in
// docs/testing/quick-entry-closeout.md.
//
// Per the closeout doc § Mandatory matrix, this is "Skip when:
// Single-monitor VM or host." Active multi-monitor disconnect mid-
// test requires libvirt device-detach orchestration that's outside
// the harness today (and largely orthogonal — the failure mode is
// the popup landing at off-screen coordinates after a saved-monitor
// loss, which needs real disconnect, not just a state mock).
//
// This runner detects multi-monitor at launch time and:
//   - skips with `-` if single-monitor (the closeout doc explicitly
//     marks this row N/A in the dashboard for those hosts);
//   - skips with `?` (test.fail unimplemented) on multi-monitor
//     hosts until the disconnect orchestration is built. JUnit
//     <error> maps to `?` per the matrix.md legend, signaling
//     "untested" rather than passing or failing.
//
// When implemented, the procedure is:
//   1. boot test VM with two displays attached
//   2. invoke QE on the secondary, save (S35 establishes the path)
//   3. detach the secondary display via libvirt
//   4. invoke QE
//   5. assert popup appears on the primary display via
//      hA.screen.getDisplayMatching(bounds) === primary

test.setTimeout(45_000);

test('S36 — Quick Entry popup falls back to primary display when saved monitor is gone', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Multi-monitor placement',
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
		await app.waitForX11Window(15_000);
		const inspector = await app.attachInspector(15_000);
		const displays = await inspector.evalInMain<
			Array<{ id: number; bounds: { x: number; y: number; width: number; height: number } }>
		>(`
			const { screen } = process.mainModule.require('electron');
			return screen.getAllDisplays().map(d => ({ id: d.id, bounds: d.bounds }));
		`);
		await testInfo.attach('displays', {
			body: JSON.stringify(displays, null, 2),
			contentType: 'application/json',
		});
		inspector.close();

		if (displays.length < 2) {
			testInfo.skip(
				true,
				'single-monitor host — S36 requires multi-monitor + libvirt ' +
					'detach orchestration. Per quick-entry-closeout.md, mark `-` ' +
					'in the dashboard for single-monitor rows.',
			);
			return;
		}

		// Multi-monitor host detected. Active disconnect mid-test isn't
		// implemented yet — surface an explicit unimplemented status so
		// the matrix shows `?` rather than a misleading green.
		testInfo.fixme(
			true,
			`multi-monitor host (${displays.length} displays) — disconnect ` +
				'orchestration not yet implemented. See spec body for the ' +
				'required steps when adding it.',
		);
	} finally {
		await app.close();
	}
});
