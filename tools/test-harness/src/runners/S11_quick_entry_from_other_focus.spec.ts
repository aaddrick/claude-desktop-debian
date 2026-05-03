import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry } from '../lib/quickentry.js';
import {
	focusOtherWindow,
	getFocusedWindowId,
	spawnMarkerWindow,
	WaylandFocusUnavailable,
	XdotoolUnavailable,
	type MarkerWindow,
} from '../lib/input.js';
import { captureSessionEnv, readLauncherLog } from '../lib/diagnostics.js';
import { sleep } from '../lib/retry.js';

// S11 — Quick Entry shortcut fires from any focus on Wayland
// (mutter XWayland key-grab). Backs the S11 row in
// docs/testing/cases/shortcuts-and-input.md (severity: Critical).
//
// What this catches vs what it doesn't
// ------------------------------------
// The case-doc's load-bearing concern is the GNOME-W mutter
// XWayland key-grab regression — issue #404 — where mutter under
// native Wayland refuses to honour the XWayland-side global key
// grab, so the shortcut becomes focus-bound. This spec CANNOT
// detect that regression: there is no portable focus-injection
// path on native Wayland (each compositor exposes its own IPC
// and the libei input-emulation portal isn't universally
// honored). The lib/input.ts focus-shifter primitive throws
// `WaylandFocusUnavailable` on native Wayland rows by design —
// see its leading comment for the full reasoning. The Wayland-
// side regression detector is a primitive-gap; it stays manual
// until libei adoption broadens.
//
// What this spec DOES catch is a regression in the X11-side of
// the global-shortcut path (the side that currently works on
// GNOME-X / Ubu-X — `🔧` and `✅` respectively in the matrix).
// If the X11 grab broke on those rows, S11 would catch it. So
// this is a regression detector on a CURRENTLY-PASSING path,
// unlike S12 which is a currently-failing detector for the
// `--enable-features=GlobalShortcutsPortal` wiring.
//
// Row gate
// --------
// Case-doc applies-to is "GNOME, Ubu" (both W and X variants),
// but the focus-shifter primitive is X11-only, gated strictly on
// `XDG_SESSION_TYPE === 'x11'`. Wayland rows can't be exercised
// here — they would either skip via the row gate or trip
// `WaylandFocusUnavailable` from the primitive. So the runner's
// row gate is the X11 subset only: GNOME-X, Ubu-X. The Wayland
// rows for S11 stay manual / matrix-cell-from-doc until a
// libei-based primitive lands.

test.setTimeout(60_000);

test('S11 — Quick Entry shortcut fires from any focus (X11 path)', async ({}, testInfo) => {
	skipUnlessRow(testInfo, ['GNOME-X', 'Ubu-X']);
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Quick Entry / global shortcut',
	});

	// Single-shot diagnostic record. We attach this once at the
	// end (or on early throw) rather than spreading five separate
	// attachments — mirrors S31's results shape so matrix-regen
	// has one well-known JSON to scrape per spec.
	const diag: {
		sessionEnv: Record<string, string>;
		markerTitle: string | null;
		activeWidBeforeFocus: string | null;
		activeWidAfterFocus: string | null;
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
		await testInfo.attach('s11-diagnostics', {
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

		// Capture pre-focus active WID for the diagnostic record.
		// On a healthy X11 session this is the Claude main window
		// (we just `mainVisible`-readied it). If null, xprop is
		// missing or _NET_ACTIVE_WINDOW is unset — neither is a
		// blocker for the test, just less useful diagnostics.
		diag.activeWidBeforeFocus = await getFocusedWindowId();

		// Marker title is unique-per-test to avoid colliding with
		// any leftover xterm from a previous run (xterm exits its
		// `sleep 600` after 10min so leaks are bounded, but a
		// re-run inside that window would otherwise match the
		// stale window).
		const markerTitle =
			`claude-test-s11-marker-${testInfo.testId}-${Date.now()}`;
		diag.markerTitle = markerTitle;

		try {
			marker = await spawnMarkerWindow(markerTitle);
		} catch (err) {
			// Most likely cause: xterm not on PATH. The primitive
			// throws a plain Error with the install hint. Skip
			// rather than fail — this is an environment gap.
			const msg = err instanceof Error ? err.message : String(err);
			diag.focusError = `spawnMarkerWindow: ${msg}`;
			await attachDiag();
			testInfo.skip(
				true,
				'xterm not installed; required for the focus-shift target. ' +
					`Underlying: ${msg}`,
			);
			return;
		}

		// `focusOtherWindow` calls `xdotool search --name <title>`
		// once and throws if there are zero matches; only the
		// post-focus _NET_ACTIVE_WINDOW verification has its own
		// retry. So we need a brief readiness poll for the marker
		// window to actually map into the X tree before we attempt
		// the focus shift — and the focus shift itself must
		// eventually succeed within the budget.
		//
		// We capture the LAST error (rather than rethrowing on the
		// first) so the diagnostic carries the real cause if every
		// attempt fails. WaylandFocusUnavailable / XdotoolUnavailable
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
				if (err instanceof WaylandFocusUnavailable) {
					earlySkipReason =
						'WaylandFocusUnavailable on a row that was ' +
						'supposed to be X11-gated. Check XDG_SESSION_TYPE.';
					break;
				}
				if (err instanceof XdotoolUnavailable) {
					earlySkipReason =
						'xdotool not installed; required for the ' +
						'focus-shift step. ' +
						(err instanceof Error ? err.message : String(err));
					break;
				}
				// "no X11 window matches" (marker not mapped yet) or
				// "compositor refused activation" — both can resolve on
				// retry. Brief pause then loop.
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

		// At this point focus is on the marker xterm. Capture the
		// post-focus active WID — should equal the marker's WID,
		// not Claude's. (We don't have a clean way to fetch the
		// marker's WID independently here without re-running
		// xdotool; the value-vs-pre comparison in the diagnostic
		// is sufficient evidence of the shift.)
		diag.activeWidAfterFocus = await getFocusedWindowId();

		// Now press the global shortcut. The whole point of S11:
		// even though the marker xterm holds focus (and Claude
		// does not), the OS-level grab should fire the popup.
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
		// the X11 grab didn't fire. visible === false means it
		// constructed but show() was suppressed (the upstream
		// lHn() short-circuit, or a regression in the visibility
		// flow). Either is a fail for S11's contract.
		expect(
			popupState && popupState.visible,
			'Quick Entry popup is visible after shortcut press from ' +
				'non-Claude focus (X11 path)',
		).toBe(true);
	} finally {
		// Marker xterm cleanup is idempotent. Always run before
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
