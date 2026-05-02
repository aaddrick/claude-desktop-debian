import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import {
	QuickEntry,
	MainWindow,
	waitForNewChat,
} from '../lib/quickentry.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S31 — Quick Entry submit makes the new chat reachable from any
// main-window state. Backs QE-7, QE-8, QE-9, QE-10 in
// docs/testing/quick-entry-closeout.md (covers #393 close-out).
//
// Layered assertion per the closeout's "test as black-box" guidance:
//   - LOCAL (Critical): popup opens after the shortcut AND popup
//     closes within ~5s of submit. Per QE-13, upstream silently
//     drops <3-char inputs without dismissing the popup, so
//     "popup closed" is the upstream-defined "submit accepted"
//     signal — pure local, no minified-symbol introspection.
//   - NETWORK (Should-not-Critical): a /chat/<uuid> URL loaded into
//     the claude.ai webContents within 15s. Coupled to claude.ai
//     reachability + chat-creation API latency; a failure here on
//     its own does NOT block the row.
//
// Sign-in: requires real signed-in claude.ai state. Default isolation
// gives a fresh CLAUDE_CONFIG_DIR with no auth tokens, so set
// CLAUDE_TEST_USE_HOST_CONFIG=1 to share ~/.config/Claude with the
// host (which carries the signed-in account on test VMs). The runner
// skips with a clear message if claude.ai never loads.
//
// QE-10 (workspace) requires WM-specific helpers (wmctrl / swaymsg /
// kdotool) and is deferred — see TODO at the bottom.

const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';

// 3 scenarios × (~5s open + ~10s submit + up to 15s nav) + 30s startup
// fits in ~120s realistically. Bump the per-test budget so we don't
// race the global default.
test.setTimeout(180_000);

test('S31 — Quick Entry submit reaches new chat from any main-window state', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Quick Entry submit / main window',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude({ isolation: useHostConfig ? null : undefined });

	try {
		// claudeAi level: main visible AND a claude.ai webContents
		// exists. Soft-fails (claudeAiUrl absent) when claude.ai
		// never loads — typically the not-signed-in case.
		const { inspector, claudeAiUrl } = await app.waitForReady('claudeAi');
		if (!claudeAiUrl) {
			testInfo.skip(
				true,
				'claude.ai webContents never loaded — likely not signed in. ' +
					'Set CLAUDE_TEST_USE_HOST_CONFIG=1 to share host config.',
			);
			return;
		}

		const qe = new QuickEntry(inspector);
		const mainWin = new MainWindow(inspector);
		await qe.installInterceptor();

		// Each scenario sets a precondition, then submits a prompt.
		// Run them in sequence on the same app instance — the sweep
		// pattern has no implicit cross-test cleanup, but the popup
		// dismisses cleanly between submits and the main window is
		// always returned to a known state.
		const scenarios: Array<{ id: string; setup: () => Promise<void> }> = [
			{
				id: 'QE-7 visible-and-focused',
				setup: async () => {
					await mainWin.setState('show');
					await mainWin.setState('focus');
				},
			},
			{
				id: 'QE-8 minimized',
				setup: async () => {
					await mainWin.setState('show');
					await mainWin.setState('minimize');
				},
			},
			{
				id: 'QE-9 hidden-to-tray',
				setup: async () => {
					await mainWin.setState('hide');
				},
			},
			// QE-10 (different workspace) deferred — see TODO below.
			// QE-11 / QE-12 (Dash-pinned vs not) is GNOME-only and
			// belongs in S32, not here.
		];

		const results: Array<{
			id: string;
			popupOpened: boolean;
			popupClosed: boolean;
			navUrl: string | null;
		}> = [];

		for (const sc of scenarios) {
			const prompt = `s31-${sc.id.split(' ')[0]}-${Date.now()}`;
			console.log(`[S31] scenario ${sc.id} → prompt "${prompt}"`);

			await sc.setup();
			await sleep(250);

			// Open popup. ydotool sends the OS-level shortcut; the popup
			// should appear within a couple of seconds even with main
			// hidden/minimized (closeout doc S29 covers the lazy-create
			// path).
			let popupOpened = false;
			try {
				await qe.openAndWaitReady();
				popupOpened = true;
			} catch (err) {
				console.log(
					`[S31] ${sc.id} popup-open failed: ${
						err instanceof Error ? err.message : String(err)
					}`,
				);
			}

			let popupClosed = false;
			let navUrl: string | null = null;
			if (popupOpened) {
				await qe.typeAndSubmit(prompt);
				try {
					await qe.waitForPopupClosed(8_000);
					popupClosed = true;
				} catch (err) {
					console.log(
						`[S31] ${sc.id} popup-close failed: ${
							err instanceof Error ? err.message : String(err)
						}`,
					);
				}
				navUrl = await waitForNewChat(inspector, 15_000);
			}

			results.push({ id: sc.id, popupOpened, popupClosed, navUrl });

			// Reset main window before next scenario.
			await mainWin.setState('show').catch(() => {});
			await mainWin.setState('restore').catch(() => {});
		}

		await testInfo.attach('s31-results', {
			body: JSON.stringify(results, null, 2),
			contentType: 'application/json',
		});

		// Critical: popup must open and submit must be accepted (popup
		// dismisses) in every scenario. Together these verify the
		// shortcut → popup → submit pathway is intact end-to-end on
		// the local side.
		for (const r of results) {
			expect(r.popupOpened, `popup opened for ${r.id}`).toBe(true);
			expect(r.popupClosed, `popup closed (submit accepted) for ${r.id}`).toBe(true);
		}

		// Should-not-Critical assertion — network nav. If claude.ai
		// flakes, mark the row Should rather than Critical fail. We
		// surface this by only annotating, not failing, when nav misses.
		const navMisses = results.filter((r) => !r.navUrl);
		if (navMisses.length > 0) {
			testInfo.annotations.push({
				type: 'should-failure',
				description:
					`network nav missed for ${navMisses.map((r) => r.id).join(', ')} — ` +
					'claude.ai reachability or chat-API latency; not a #393 regression on its own',
			});
		}

		inspector.close();
	} finally {
		await app.close();
	}
});

// TODO: QE-10 (different workspace). Needs WM-specific helpers:
//   - X11: wmctrl -s <n> to switch workspace, wmctrl -i -r <wid> -t <n>
//     to move main window
//   - KDE Wayland: kdotool / kwin-mcp
//   - GNOME Wayland: no scriptable workspace API; manual or skip
//   - Sway/Hypr/Niri: native CLI (swaymsg, hyprctl, niri msg)
// Add as lib/workspace.ts when the first non-S31 test needs it too;
// premature now.
