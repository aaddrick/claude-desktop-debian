import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry } from '../lib/quickentry.js';
import {
	focusOtherWindow,
	getFocusedWindowId,
	spawnMarkerWindow,
	NiriIpcUnavailable,
	FootUnavailable,
	type MarkerWindow,
} from '../lib/input-niri.js';
import { captureSessionEnv, readLauncherLog } from '../lib/diagnostics.js';
import { sleep } from '../lib/retry.js';

// S14 — Quick Entry shortcut fires from any focus on Niri
// (XDG portal BindShortcuts path). Backs the S14 row in
// docs/testing/cases/shortcuts-and-input.md (severity: Critical
// for Niri users).
//
// What this catches vs what it doesn't
// ------------------------------------
// On Niri the launcher special-cases the app to native Wayland
// (`scripts/launcher-common.sh:41-44`), so upstream's
// `globalShortcut.register` (`index.js:499416`) routes through
// Electron's `xdg-desktop-portal` `BindShortcuts` path inside
// Chromium rather than an X11 grab. The case-doc records this
// path as currently failing on Niri:
// `Failed to call BindShortcuts (error code 5)`. So this spec
// is a known-failing detector — the shape mirrors S12's
// `--enable-features=GlobalShortcutsPortal` GNOME-W detector:
// the assertion encodes the contract, and the test will start
// passing automatically once the upstream / portal-side issue
// is resolved on Niri without any spec edit.
//
// The user-visible symptom (Quick Entry shortcut doesn't fire
// on Niri) is the same as #404 (mutter XWayland key-grab on
// GNOME-W) but the root cause is different: Niri is wlroots
// Wayland with no XWayland by default, so the X11-side
// `lib/input.ts` focus-shifter cannot exercise this path.
// `lib/input-niri.ts` is the substrate — `niri msg --json`
// for the focus-injection + readback chain, `foot --title` for
// the Wayland-native marker window. The mutter / GNOME-W
// regression detector remains a separate primitive gap (libei
// when broadly available, or a per-compositor mutter-IPC
// primitive — neither shipped).
//
// Row gate
// --------
// Niri only. Other Wayland rows (KDE-W, GNOME-W, Ubu-W) each
// need their own compositor IPC and stay manual / matrix-cell-
// from-doc until a libei-based primitive lands.

test.setTimeout(60_000);

test('S14 — Quick Entry shortcut fires from any focus (Niri Wayland path)', async ({}, testInfo) => {
	skipUnlessRow(testInfo, ['Niri']);
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'XDG Desktop Portal BindShortcuts',
	});

	// Single-shot diagnostic record. We attach this once at the
	// end (or on early throw) rather than spreading five separate
	// attachments — mirrors S31's results shape so matrix-regen
	// has one well-known JSON to scrape per spec.
	const diag: {
		sessionEnv: Record<string, string>;
		markerTitle: string | null;
		activeWidBeforeFocus: number | null;
		activeWidAfterFocus: number | null;
		popupState: unknown;
		openError: string | null;
		focusError: string | null;
		launcherLogTail: string | null;
	} = {
		sessionEnv: captureSessionEnv(),
		markerTitle: null,
		activeWidBeforeFocus: null,
		activeWidAfterFocus: null,
		popupState: null,
		openError: null,
		focusError: null,
		launcherLogTail: null,
	};

	const attachDiag = async () => {
		await testInfo.attach('s14-diagnostics', {
			body: JSON.stringify(diag, null, 2),
			contentType: 'application/json',
		});
	};

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	let marker: MarkerWindow | null = null;
	try {
		// `mainVisible` is the cheapest level that gives us a
		// registered global shortcut. Upstream registers via
		// globalShortcut.register early in main-process startup
		// (build-reference index.js:499416), but we still want
		// the main window mapped so the popup-construction path
		// has something to anchor to.
		const { inspector } = await app.waitForReady('mainVisible');
		const qe = new QuickEntry(inspector);
		await qe.installInterceptor();

		// Capture pre-focus active window id for the diagnostic
		// record. On a healthy Niri session this is the Claude
		// main window (we just `mainVisible`-readied it). If
		// null, `niri msg` is unavailable or there is no focused
		// window — neither blocks the test, just less useful
		// diagnostics.
		diag.activeWidBeforeFocus = await getFocusedWindowId();

		// Marker title is unique-per-test to avoid colliding with
		// any leftover foot from a previous run (foot exits its
		// `sleep 600` after 10min so leaks are bounded, but a
		// re-run inside that window would otherwise match the
		// stale window).
		const markerTitle =
			`claude-test-s14-marker-${testInfo.testId}-${Date.now()}`;
		diag.markerTitle = markerTitle;

		try {
			marker = await spawnMarkerWindow(markerTitle);
		} catch (err) {
			// Most likely cause: foot not on PATH. The primitive
			// throws `FootUnavailable` with the install hint. Skip
			// rather than fail — this is an environment gap.
			const msg = err instanceof Error ? err.message : String(err);
			diag.focusError = `spawnMarkerWindow: ${msg}`;
			await attachDiag();
			testInfo.skip(
				true,
				'foot not installed; required for the focus-shift target. ' +
					`Underlying: ${msg}`,
			);
			return;
		}

		// `focusOtherWindow` queries `niri msg --json windows`
		// once and throws if there are zero matches; only the
		// post-focus focused-window verification has its own
		// retry. So we need a brief readiness poll for the
		// marker window to actually appear in the niri window
		// list before we attempt the focus shift — and the focus
		// shift itself must eventually succeed within the budget.
		//
		// We capture the LAST error (rather than rethrowing on
		// the first) so the diagnostic carries the real cause if
		// every attempt fails. NiriIpcUnavailable / FootUnavailable
		// are sticky — they won't change between retries — so we
		// short-circuit out on the first occurrence and skip.
		let focusOk = false;
		let lastFocusErr: unknown = null;
		let earlySkipReason: string | null = null;
		const focusBudgetMs = 5_000;
		const focusStart = Date.now();
		while (Date.now() - focusStart < focusBudgetMs) {
			try {
				await focusOtherWindow(markerTitle);
				focusOk = true;
				break;
			} catch (err) {
				lastFocusErr = err;
				if (err instanceof NiriIpcUnavailable) {
					earlySkipReason =
						'NiriIpcUnavailable on a row that was ' +
						'supposed to be Niri-gated. Check NIRI_SOCKET / ' +
						'`niri msg` availability.';
					break;
				}
				if (err instanceof FootUnavailable) {
					earlySkipReason =
						'foot not installed; required for the ' +
						'focus-shift step. ' +
						(err instanceof Error ? err.message : String(err));
					break;
				}
				// "no window matches" (marker not yet listed by
				// niri) or "focus-window action did not stick" —
				// both can resolve on retry. Brief pause then loop.
				await sleep(100);
			}
		}

		if (earlySkipReason) {
			diag.focusError =
				lastFocusErr instanceof Error
					? lastFocusErr.message
					: String(lastFocusErr);
			await attachDiag();
			testInfo.skip(true, earlySkipReason);
			return;
		}

		if (!focusOk) {
			const msg =
				lastFocusErr instanceof Error
					? lastFocusErr.message
					: String(lastFocusErr);
			diag.focusError = msg;
			diag.launcherLogTail = await readLauncherLog();
			await attachDiag();
			throw new Error(
				`focusOtherWindow failed within ${focusBudgetMs}ms: ${msg}`,
			);
		}

		// At this point focus is on the marker foot. Capture the
		// post-focus focused-window id — should equal the
		// marker's id, not Claude's. (We don't have a clean way
		// to fetch the marker's id independently here without
		// re-running `niri msg`; the value-vs-pre comparison in
		// the diagnostic is sufficient evidence of the shift.)
		diag.activeWidAfterFocus = await getFocusedWindowId();

		// Now press the global shortcut. The whole point of S14:
		// even though the marker foot holds focus (and Claude
		// does not), the portal-routed BindShortcuts grab should
		// fire the popup. Currently known-failing per case-doc
		// S14 (`Failed to call BindShortcuts (error code 5)`).
		try {
			await qe.openAndWaitReady();
		} catch (err) {
			diag.openError = err instanceof Error ? err.message : String(err);
			diag.popupState = await qe.getPopupState();
			diag.launcherLogTail = await readLauncherLog();
			await attachDiag();
			throw err;
		}

		const popupState = await qe.getPopupState();
		diag.popupState = popupState;
		diag.launcherLogTail = await readLauncherLog();
		await attachDiag();

		// Single critical assertion: popup exists AND is visible
		// after the shortcut press from non-Claude focus. A null
		// state means the BrowserWindow was never constructed —
		// the portal grab didn't fire. visible === false means
		// it constructed but show() was suppressed (the upstream
		// lHn() short-circuit, or a regression in the visibility
		// flow). Either is a fail for S14's contract.
		expect(
			popupState && popupState.visible,
			'Quick Entry popup is visible after shortcut press from ' +
				'non-Claude focus (Niri Wayland path)',
		).toBe(true);
	} finally {
		// Marker foot cleanup is idempotent. Always run before
		// app.close() so the kill happens even if the spec
		// throws between the two.
		if (marker) {
			await marker.kill().catch(() => {
				// best-effort — process may already be dead
			});
		}
		await app.close();
	}
});
