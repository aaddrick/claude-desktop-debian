import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T12 — WebGL warn-only on Linux: GPU acceleration may be limited
// (virtio-gpu in VMs, hybrid-GPU laptops, blocklisted drivers) but
// the app must still launch and render the main UI without
// crashing. Per the case-doc, the chrome://gpu page is informational
// — there's no hard "enabled" requirement, just "doesn't crash and
// no feature breaks".
//
// The case-doc steps point a human at chrome://gpu via DevTools.
// Automating chrome:// navigation against a live BrowserView is
// blocked by Electron's chrome-scheme guard, so this runner does the
// equivalent capture from the main process via
// `app.getGPUFeatureStatus()` (and `app.getGPUInfo('basic')` for
// vendor/renderer breadcrumbs). The hard signal is "we got past
// waitForReady('mainVisible') and read the status without the
// renderer dying"; the JSON capture is the matrix-regen artifact.
//
// Code anchors driving the assertion shape:
//   - index.js:524809 — upstream gates `disableHardwareAcceleration`
//     on a user toggle, never passes `--ignore-gpu-blocklist` /
//     `--use-gl=*`, so chrome://gpu reflects Chromium's stock
//     blocklist behaviour.
//   - index.js:500571 — only `webgl:!1` override is scoped to the
//     in-memory feedback popup; main UI does not disable WebGL.
//
// Applies to all rows. No skipUnlessRow gate.

// Default 60s test timeout doesn't leave any margin around
// waitForReady('mainVisible')'s 90s budget. Cold-start GPU
// initialisation on virtio-gpu / blocklisted-driver rows is the
// reason that budget exists.
test.setTimeout(120_000);

test('T12 — GPU feature status captured, no crash', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Could' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Platform integration / GPU',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude();
	try {
		// 'mainVisible' rather than 'window' because the load-bearing
		// claim is "main UI rendered" — if the GPU stack were broken
		// hard enough to block compositing, MainWindow.getState()
		// wouldn't report visible:true and we'd fail here, before
		// the GPU probe runs.
		const { inspector } = await app.waitForReady('mainVisible');

		const gpuStatus = await inspector.evalInMain<Record<string, string>>(`
			const { app } = process.mainModule.require('electron');
			return app.getGPUFeatureStatus();
		`);
		await testInfo.attach('gpu-feature-status', {
			body: JSON.stringify(gpuStatus, null, 2),
			contentType: 'application/json',
		});

		// `getGPUInfo('basic')` is async and returns vendor / device /
		// driver fields. 'complete' is much heavier (full Chromium
		// GPU diagnostic dump) and not needed for the matrix
		// breadcrumb — 'basic' is the documented default for
		// per-row capture.
		const gpuInfo = await inspector.evalInMain<unknown>(`
			const { app } = process.mainModule.require('electron');
			return await app.getGPUInfo('basic');
		`);
		await testInfo.attach('gpu-info-basic', {
			body: JSON.stringify(gpuInfo, null, 2),
			contentType: 'application/json',
		});

		// Sanity assertion: `getGPUFeatureStatus()` returned a populated
		// object. An empty result would mean the API itself broke (a
		// real regression worth catching), distinct from any individual
		// feature being blocklisted (which the case-doc explicitly
		// allows on VM / hybrid-GPU rows).
		//
		// We deliberately do NOT assert any specific feature key is
		// 'enabled' — case-doc T12 calls out that webgl/webgl2 may
		// report blocklisted on virtio-gpu and hybrid GPUs and that's
		// expected. Reaching this line at all means waitForReady
		// already proved the renderer is alive; the JSON capture is
		// the load-bearing artifact for matrix regen.
		expect(
			Object.keys(gpuStatus).length,
			'app.getGPUFeatureStatus() returned a populated object',
		).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
