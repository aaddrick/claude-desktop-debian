import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { getFrameExtents, getWindowTitle } from '../lib/wm.js';

test('T04 — Window decorations draw', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Window chrome',
	});

	// On KDE Wayland (Decision 6: project default is X11/XWayland), the app
	// window is reachable via xprop. Native-Wayland window-state queries are a
	// later iteration — see Still open #5 in docs/testing/automation.md.
	const app = await launchClaude();

	try {
		const wid = await app.waitForX11Window(15_000);
		expect(wid, 'X11 window for claude-desktop pid was found').toBeTruthy();

		await testInfo.attach('window-id', {
			body: wid,
			contentType: 'text/plain',
		});

		const title = await getWindowTitle(wid);
		expect(title ?? '', 'window title contains "Claude"').toMatch(/claude/i);

		// _NET_FRAME_EXTENTS is set by the WM when it draws decorations.
		// All-zero extents (or absent property) indicates an undecorated window.
		const extents = await getFrameExtents(wid);
		await testInfo.attach('frame-extents', {
			body: JSON.stringify(extents, null, 2),
			contentType: 'application/json',
		});

		expect(extents, 'window has _NET_FRAME_EXTENTS set by WM').toBeTruthy();
		if (extents) {
			const total =
				extents.left + extents.right + extents.top + extents.bottom;
			expect(total, 'sum of frame extents > 0 (window is decorated)')
				.toBeGreaterThan(0);
		}
	} finally {
		await app.close();
	}
});
