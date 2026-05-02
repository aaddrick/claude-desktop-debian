import { test, expect } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry } from '../lib/quickentry.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S35 — Quick Entry popup position is persisted across invocations
// and across app restarts. Backs QE-22 in
// docs/testing/quick-entry-closeout.md.
//
// Upstream persists position via `an.set("quickWindowPosition", ...)`
// in the popup's `hide` handler (build-reference index.js:515468). On
// subsequent invocations the popup's construction reads the saved
// position from `an.get("quickWindowPosition")`. The test moves the
// popup to a known position, dismisses (triggering save), restarts
// the app with shared XDG_CONFIG_HOME, and verifies the popup
// reappears at the saved position — not the upstream default.
//
// Three-launch test:
//   1. open → move → dismiss → re-open → verify in-session memory
//   2. relaunch with same XDG_CONFIG_HOME → verify position persisted
//   3. wipe quickWindowPosition from on-disk config → relaunch →
//      verify popup lands at upstream default (NOT the cleared
//      target), proving the path is read-from-disk-not-just-memory
//
// The on-disk round-trip in (2) directly reads
// ${configDir}/Claude/config.json between launches to confirm the
// hide handler reached disk — distinct signal from "in-memory
// position survives restart" (an electron-store memory cache could
// in principle satisfy that without touching disk).
//
// All three launches share the same Isolation handle so
// XDG_CONFIG_HOME stays consistent across restarts. The first two
// calls don't own the handle, so close() leaves the dir intact for
// the next launch. The test owns cleanup.

const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';

// Three launches at ~60s each plus settle / waitForReady budget.
// 180s was tight for two; 240s gives the third a margin.
test.setTimeout(240_000);

test('S35 — Quick Entry popup position is persisted across invocations and across app restarts', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Popup placement memory',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// In useHostConfig mode, the host's persisted state is shared
	// across launches automatically. In default isolation mode, we
	// pin a handle and pass it to both launches so XDG_CONFIG_HOME
	// matches.
	let isolation: Isolation | null = null;
	if (!useHostConfig) {
		isolation = await createIsolation();
	}

	// The position we'll move the popup to. Picked to be unambiguously
	// distinct from any default — far from the bottom-center area
	// where upstream's default placement lands.
	const TARGET_X = 80;
	const TARGET_Y = 80;

	try {
		// First launch: open popup, move, dismiss (save fires), re-open,
		// confirm position1 matches TARGET. This is the in-session-
		// memory half.
		const app1 = await launchClaude({ isolation });
		let position1: { x: number; y: number } | null = null;
		try {
			// userLoaded — Upstream's shortcut handler calls Ko.show()
			// only when lHn() is true (`!user.isLoggedOut`); if the
			// renderer hasn't loaded the user yet, the popup gets
			// constructed but not shown.
			const { inspector, postLoginUrl } = await app1.waitForReady('userLoaded');
			if (!postLoginUrl) {
				testInfo.skip(
					true,
					'claude.ai user did not load past /login within 30s — ' +
						'CLAUDE_TEST_USE_HOST_CONFIG=1 needs a signed-in account',
				);
				return;
			}
			const qe = new QuickEntry(inspector);
			await qe.installInterceptor();

			// URL change is renderer-driven; the main-process user
			// object that lHn() reads loads on a separate timeline.
			// 3s margin is empirical — without it, the first shortcut
			// hits before the auth state propagates and Ko.show() is
			// silently skipped. openAndWaitReady's retry would catch
			// this too, but eating one full attempt + retryDelayMs is
			// slower than the upfront sleep.
			await sleep(3_000);

			await qe.openAndWaitReady();

			// Move the popup. setBounds is the most reliable way; the
			// constructor uses it internally too.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (!popup || !popup.ref || popup.ref.isDestroyed()) {
					throw new Error('popup ref unavailable for setBounds');
				}
				popup.ref.setPosition(${TARGET_X}, ${TARGET_Y});
				return null;
			`);
			await sleep(150);

			// Dismiss the popup — hide handler fires, save runs.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (popup && popup.ref && !popup.ref.isDestroyed()) {
					popup.ref.hide();
				}
				return null;
			`);
			await qe.waitForPopupClosed(5_000);
			await sleep(300); // give the save handler time to write

			// Re-open. Should appear at TARGET (in-session memory).
			await qe.openAndWaitReady();
			const state1 = await qe.getPopupState();
			position1 = state1
				? { x: state1.bounds.x, y: state1.bounds.y }
				: null;
			await testInfo.attach('position-after-move', {
				body: JSON.stringify({ position1, target: { x: TARGET_X, y: TARGET_Y } }, null, 2),
				contentType: 'application/json',
			});

			// Dismiss for clean exit.
			await inspector.evalInMain<null>(`
				const wins = globalThis.__qeWindows || [];
				const popup = wins.find(${popupSelectorJs()});
				if (popup && popup.ref && !popup.ref.isDestroyed()) {
					popup.ref.hide();
				}
				return null;
			`);
			await qe.waitForPopupClosed(5_000);
			await sleep(300);

			inspector.close();
		} finally {
			await app1.close();
		}

		expect(
			position1,
			'popup position observable after first launch',
		).not.toBeNull();
		expect(
			position1!.x,
			'popup x matches target after move + re-open',
		).toBe(TARGET_X);
		expect(
			position1!.y,
			'popup y matches target after move + re-open',
		).toBe(TARGET_Y);

		// On-disk round-trip. Read config.json directly between
		// launches to confirm the hide handler reached disk — distinct
		// signal from "in-memory position survives restart" (an
		// electron-store memory cache could in principle satisfy the
		// post-restart assertion without ever flushing). Skipped under
		// useHostConfig because we don't know the host's configDir.
		if (isolation) {
			const configPath = join(isolation.configDir, 'Claude/config.json');
			let parsed: { quickWindowPosition?: { x?: number; y?: number } } = {};
			let rawForAttach = '';
			try {
				rawForAttach = readFileSync(configPath, 'utf8');
				parsed = JSON.parse(rawForAttach);
			} catch (err) {
				rawForAttach =
					'<read error: ' +
					(err instanceof Error ? err.message : String(err)) +
					'>';
			}
			await testInfo.attach('config-json-after-launch1', {
				body: JSON.stringify(
					{
						configPath,
						parsed,
						raw: rawForAttach.slice(0, 4_000),
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
			expect(
				parsed.quickWindowPosition,
				'quickWindowPosition key written to on-disk config.json by hide handler',
			).toBeTruthy();
			expect(
				parsed.quickWindowPosition?.x,
				'on-disk x matches TARGET_X',
			).toBe(TARGET_X);
			expect(
				parsed.quickWindowPosition?.y,
				'on-disk y matches TARGET_Y',
			).toBe(TARGET_Y);
		}

		// Second launch: same XDG_CONFIG_HOME (or host config). Open
		// popup; should appear at the saved position from the first
		// launch's hide handler.
		const app2 = await launchClaude({ isolation });
		let position2: { x: number; y: number } | null = null;
		try {
			// userLoaded — same race as the first launch. Settings
			// load is part of main's startup, so by the time the user
			// has loaded, `an.get("quickWindowPosition")` returns the
			// saved value.
			const { inspector, postLoginUrl } = await app2.waitForReady('userLoaded');
			if (!postLoginUrl) {
				testInfo.skip(
					true,
					'claude.ai user did not load past /login within 30s on second launch',
				);
				return;
			}
			const qe = new QuickEntry(inspector);
			await qe.installInterceptor();

			await qe.openAndWaitReady();

			const state2 = await qe.getPopupState();
			position2 = state2
				? { x: state2.bounds.x, y: state2.bounds.y }
				: null;
			await testInfo.attach('position-after-restart', {
				body: JSON.stringify(
					{
						position1,
						position2,
						match: !!position2 && position2.x === position1!.x && position2.y === position1!.y,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});

			inspector.close();
		} finally {
			await app2.close();
		}

		expect(
			position2,
			'popup position observable after restart',
		).not.toBeNull();
		expect(
			position2!.x,
			'popup x persisted across restart',
		).toBe(position1!.x);
		expect(
			position2!.y,
			'popup y persisted across restart',
		).toBe(position1!.y);

		// Third launch: clear-and-default. Wipe the
		// quickWindowPosition key from on-disk config and confirm
		// the popup lands somewhere OTHER than TARGET. This proves
		// the read path actually consults disk — if the popup still
		// appeared at TARGET after the key was cleared, upstream
		// would be sourcing position from somewhere we don't know
		// about (env, hard-coded fallback shape, in-memory leak
		// across the close/spawn boundary).
		//
		// Don't assert exact default coordinates — those depend on
		// display geometry. Just assert "not the cleared target".
		// Skipped under useHostConfig (no known configDir to mutate).
		if (isolation) {
			const configPath = join(isolation.configDir, 'Claude/config.json');
			let beforeRaw = '';
			try {
				beforeRaw = readFileSync(configPath, 'utf8');
				const parsed = JSON.parse(beforeRaw) as Record<string, unknown>;
				delete parsed.quickWindowPosition;
				writeFileSync(configPath, JSON.stringify(parsed, null, 2), 'utf8');
			} catch (err) {
				await testInfo.attach('config-clear-error', {
					body:
						'configPath=' + configPath + '\n' +
						(err instanceof Error ? err.stack ?? err.message : String(err)),
					contentType: 'text/plain',
				});
				throw err;
			}

			const app3 = await launchClaude({ isolation });
			let position3: { x: number; y: number } | null = null;
			try {
				const { inspector, postLoginUrl } =
					await app3.waitForReady('userLoaded');
				if (!postLoginUrl) {
					testInfo.skip(
						true,
						'claude.ai user did not load past /login on third launch',
					);
					return;
				}
				const qe = new QuickEntry(inspector);
				await qe.installInterceptor();

				await qe.openAndWaitReady();

				const state3 = await qe.getPopupState();
				position3 = state3
					? { x: state3.bounds.x, y: state3.bounds.y }
					: null;

				await testInfo.attach('position-after-clear', {
					body: JSON.stringify(
						{
							configPath,
							beforeRawSnippet: beforeRaw.slice(0, 2_000),
							target: { x: TARGET_X, y: TARGET_Y },
							position3,
							note:
								'position3 should NOT equal target — that would ' +
								'imply the read path bypassed disk.',
						},
						null,
						2,
					),
					contentType: 'application/json',
				});

				inspector.close();
			} finally {
				await app3.close();
			}

			expect(
				position3,
				'popup position observable after third launch',
			).not.toBeNull();
			const matchedTarget =
				!!position3 &&
				position3.x === TARGET_X &&
				position3.y === TARGET_Y;
			expect(
				matchedTarget,
				'popup did NOT reappear at the cleared target — confirms ' +
					'upstream reads position from disk, not an in-memory cache',
			).toBe(false);
		}
	} finally {
		if (isolation) await isolation.cleanup();
	}
});

// The popup-selector logic is duplicated from quickentry.ts because
// it's a private method there; expressing it inline here keeps S35
// self-contained without making the helper public for one caller.
function popupSelectorJs(): string {
	return `(w => {
		if (!w || !w.ref || w.ref.isDestroyed()) return false;
		const f = String(w.loadedFile || '');
		return f.indexOf('quick-window.html') !== -1
			|| f.indexOf('quick_window/') !== -1;
	})`;
}
