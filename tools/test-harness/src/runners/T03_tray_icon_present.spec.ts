import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import {
	findItemByPid,
	listRegisteredItems,
	type SniItem,
} from '../lib/sni.js';
import { disconnectBus, getConnectionPid } from '../lib/dbus.js';
import { retryUntil, sleep } from '../lib/retry.js';

// T03 — Tray icon present + tray-rebuild idempotency.
//
// Two assertions in one test, sharing the same launched app:
//
//   1. After startup, exactly ONE StatusNotifierItem on the session
//      bus is owned by the claude-desktop pid. Presence-only would
//      pass if the pid registered two items, which is the exact
//      shape of the bug below.
//   2. After toggling `nativeTheme.themeSource`, still exactly ONE
//      SNI item is owned by the pid. This guards the
//      tray-rebuild-race fixed in scripts/patches/tray.sh:
//      destroy()+sleep(250)+new Tray() can transiently leave two
//      SNIs registered for the pid because KDE Plasma's systemtray
//      observer reacts to UnregisterItem after the new Register
//      call lands. See docs/learnings/tray-rebuild-race.md for the
//      full timing story.
//
// The fast-path patch swaps destroy/recreate for in-place
// setImage/setContextMenu on the existing Tray, which never
// touches StatusNotifierWatcher registration — so the count
// stays at 1 across the toggle. If the patch ever regresses (or
// the rebuild path is reached for some other reason), the
// post-toggle count climbs and this test catches it.

test('T03 — Tray icon present (and rebuild leaves exactly one SNI)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Tray / StatusNotifierItem',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'Tray rebuild idempotency',
	});

	const app = await launchClaude();

	try {
		await app.waitForX11Window(15_000);

		// Tray registration may lag the first window by a few hundred ms.
		// Poll the SNI watcher until our pid shows up among registered items.
		const ourItem = await retryUntil(
			async () => findItemByPid(app.pid),
			{ timeout: 15_000, interval: 500 },
		);

		expect(
			ourItem,
			'a StatusNotifierItem registered by claude-desktop pid was found',
		).toBeTruthy();

		if (ourItem) {
			await testInfo.attach('sni-item', {
				body: JSON.stringify(ourItem, null, 2),
				contentType: 'application/json',
			});
		}

		// Walk the full registry and count items owned by our pid.
		// Presence-only (above) doesn't catch the duplicate-registration
		// shape — we'd have found one and stopped.
		const preToggleItems = await listRegisteredItems();
		const preToggleOwners = await collectItemsForPid(preToggleItems, app.pid);
		await testInfo.attach('sni-items-pre-toggle', {
			body: JSON.stringify(preToggleOwners, null, 2),
			contentType: 'application/json',
		});
		expect(
			preToggleOwners.length,
			'exactly one SNI item is owned by claude-desktop pid before theme toggle',
		).toBe(1);

		// Exercise the rebuild path. nativeTheme.themeSource flip is
		// the user-visible trigger from docs/learnings/tray-rebuild-
		// race.md (Appearance → Colors / Plasma Style / Global Theme
		// all funnel through nativeTheme::updated). The fast-path
		// patch should keep this in-place; the unpatched slow-path
		// would destroy + recreate, transiently registering a second
		// SNI.
		const inspector = await app.attachInspector();
		const originalThemeSource = await inspector.evalInMain<string>(`
			const { nativeTheme } = process.mainModule.require('electron');
			return nativeTheme.themeSource;
		`);
		const flipped = originalThemeSource === 'dark' ? 'light' : 'dark';
		try {
			await inspector.evalInMain<null>(`
				const { nativeTheme } = process.mainModule.require('electron');
				nativeTheme.themeSource = ${JSON.stringify(flipped)};
				return null;
			`);

			// Settle window for any rebuild churn — the unpatched path
			// has a built-in 250ms sleep between destroy() and new
			// Tray(); 500ms covers that plus DBus signal propagation.
			await sleep(500);

			const postToggleItems = await listRegisteredItems();
			const postToggleOwners = await collectItemsForPid(
				postToggleItems,
				app.pid,
			);
			await testInfo.attach('sni-items-post-toggle', {
				body: JSON.stringify(
					{
						originalThemeSource,
						flippedTo: flipped,
						owners: postToggleOwners,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
			expect(
				postToggleOwners.length,
				'exactly one SNI item is owned by claude-desktop pid after theme toggle ' +
					'(tray-rebuild race regression — see docs/learnings/tray-rebuild-race.md)',
			).toBe(1);
		} finally {
			// Reset themeSource so we don't leave the test host with a
			// flipped theme override on the off-chance the isolation
			// boundary leaks.
			await inspector
				.evalInMain<null>(`
					const { nativeTheme } = process.mainModule.require('electron');
					nativeTheme.themeSource = ${JSON.stringify(originalThemeSource)};
					return null;
				`)
				.catch(() => {});
			inspector.close();
		}
	} finally {
		await app.close();
		await disconnectBus();
	}
});

// Walk the SNI item list and return only those whose owning DBus
// connection has the given pid. Mirrors findItemByPid but keeps every
// match instead of returning the first.
async function collectItemsForPid(
	items: SniItem[],
	pid: number,
): Promise<SniItem[]> {
	const owned: SniItem[] = [];
	for (const item of items) {
		try {
			const itemPid = await getConnectionPid(item.service);
			if (itemPid === pid) owned.push(item);
		} catch {
			// connection may have gone away mid-iteration; skip
		}
	}
	return owned;
}
