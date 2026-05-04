import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { retryUntil } from '../lib/retry.js';
import {
	type RawElement,
	snapshotAx,
	waitForAxTreeStable,
} from '../lib/ax.js';

// T26 — Routines page renders.
//
// Path: seed auth from the host's signed-in Claude Desktop config into a
// per-test tmpdir, launch the app against that hermetic config, wait
// for `userLoaded` (claude.ai past /login — the sidebar Routines entry
// is rendered by claude.ai's authenticated SPA), find the
// `complementary > button[name="Routines"]` AX node, click it, then
// poll the post-click AX tree for one of the inventory's documented
// page anchors:
//   - button[name="New routine"] (form trigger)
//   - button[name="All"] or button[name="Calendar"] (list-view tabs)
//
// The complementary-landmark filter isn't needed at the click site —
// "Routines" is a unique accessibleName in the AX tree (verified
// against docs/testing/ui-inventory.json:244). The post-click anchors
// (`New routine`, `All`, `Calendar`) live under
// `main > region[name="Primary pane"]` and only render when the
// Routines page is mounted, so they're a good post-click signal.
//
// Schedule presets (Hourly/Daily/etc.), permission-mode picker, model
// picker, working-folder picker, and worktree toggle live inside the
// New-routine modal — out of T26's scope per the case-doc inventory
// note. Driving into the modal would belong in a sibling test.

interface AxAnchorMatch {
	role: string;
	name: string;
	insideModalDialog: boolean;
}

interface AxAnchorSnapshot {
	totalNodes: number;
	totalInteractive: number;
	matches: AxAnchorMatch[];
}

// `snapshotAx` (and `waitForAxTreeStable`) come from `lib/ax.ts` —
// the shared AX-loading substrate. T26 was the second consumer to
// reach for the helper (after `lib/claudeai.ts`'s page-objects),
// which crossed the threshold for extraction in session 13.

// Find every interactive element whose role+accessibleName matches one
// of the supplied {role, name} pairs. Used both pre-click (to locate
// the Routines sidebar button) and post-click (to confirm the page
// rendered).
function findAnchors(
	elements: RawElement[],
	wanted: ReadonlyArray<{ role: string; name: string }>,
): AxAnchorMatch[] {
	const out: AxAnchorMatch[] = [];
	for (const el of elements) {
		for (const w of wanted) {
			if (el.computedRole !== w.role) continue;
			if (el.accessibleName !== w.name) continue;
			out.push({
				role: el.computedRole,
				name: el.accessibleName,
				insideModalDialog: el.insideModalDialog,
			});
		}
	}
	return out;
}

test('T26 — Routines page renders', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Routines page',
	});

	// No skipUnlessRow — T26 applies to all rows.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Seed auth from host (kills any running host Claude to release
	// LevelDB/SQLite writer locks before copy). Skip cleanly when no
	// signed-in host config is available — same pattern as T07.
	let isolation: Isolation;
	try {
		isolation = await createIsolation({ seedFromHost: true });
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		test.skip(true, `seedFromHost unavailable: ${msg}`);
		return;
	}

	const app = await launchClaude({ isolation });
	try {
		const ready = await app.waitForReady('userLoaded');
		await testInfo.attach('claude-ai-url', {
			body: ready.claudeAiUrl ?? '(no claude.ai webContents observed)',
			contentType: 'text/plain',
		});
		if (!ready.postLoginUrl) {
			test.skip(
				true,
				'seeded auth did not reach post-login URL — host config ' +
					'may be stale (signed out, expired session, etc.)',
			);
			return;
		}
		await testInfo.attach('post-login-url', {
			body: ready.postLoginUrl,
			contentType: 'text/plain',
		});

		// Pre-click probe: locate the sidebar Routines button. Wrapped in
		// retryUntil + try/catch for "Execution context was destroyed"
		// because the renderer can still be mid-navigation when
		// waitForReady('userLoaded') resolves (URL-only gate; SPA route
		// settle is separate). claude.ai's sidebar mounts a few hundred
		// ms after the URL stabilises.
		const preClick = await retryUntil(
			async () => {
				try {
					const elements = await snapshotAx(ready.inspector);
					const matches = findAnchors(elements, [
						{ role: 'button', name: 'Routines' },
					]);
					if (matches.length === 0) return null;
					const interactive = elements.length;
					return {
						totalNodes: interactive,
						totalInteractive: interactive,
						matches,
					} satisfies AxAnchorSnapshot;
				} catch (err) {
					const msg = err instanceof Error ? err.message : String(err);
					if (msg.includes('context was destroyed')) return null;
					throw err;
				}
			},
			{ timeout: 15_000, interval: 500 },
		);

		await testInfo.attach('routines-sidebar-candidates', {
			body: JSON.stringify(preClick, null, 2),
			contentType: 'application/json',
		});

		if (!preClick) {
			throw new Error(
				'Routines sidebar button never appeared in the AX tree ' +
					'within 15s after userLoaded',
			);
		}

		// Re-walk the AX tree to grab the actual RawElement (with the
		// backendDOMNodeId we need for the click) — preClick's
		// AxAnchorMatch is a diagnostic projection.
		const elementsForClick = await snapshotAx(ready.inspector);
		const target = elementsForClick.find(
			(el) =>
				el.computedRole === 'button' &&
				el.accessibleName === 'Routines',
		);
		if (!target || target.backendDOMNodeId === null) {
			throw new Error(
				'Routines button vanished between probe and click, or had ' +
					'no backendDOMNodeId',
			);
		}

		await ready.inspector.clickByBackendNodeId(
			'claude.ai',
			target.backendDOMNodeId,
		);

		// Post-click: gate once on AX-tree stability so the first poll
		// iteration sees the populated page tree, then poll fast for any
		// of the documented page anchors. Mirrors openPill's pattern in
		// lib/claudeai.ts — re-gating on every iteration would burn
		// ~800ms per cycle waiting for "no change" when what we want is
		// "page anchors appear".
		await waitForAxTreeStable(ready.inspector, {
			minNodes: 1,
			timeoutMs: 10_000,
		});

		const expected = [
			{ role: 'button', name: 'New routine' },
			{ role: 'button', name: 'All' },
			{ role: 'button', name: 'Calendar' },
		] as const;

		const postClick = await retryUntil(
			async () => {
				try {
					const elements = await snapshotAx(ready.inspector, {
						fast: true,
					});
					const matches = findAnchors(elements, expected);
					if (matches.length === 0) return null;
					return {
						totalNodes: elements.length,
						totalInteractive: elements.length,
						matches,
					} satisfies AxAnchorSnapshot;
				} catch (err) {
					const msg = err instanceof Error ? err.message : String(err);
					if (msg.includes('context was destroyed')) return null;
					throw err;
				}
			},
			{ timeout: 5_000, interval: 200 },
		);

		await testInfo.attach('routines-page-anchors', {
			body: JSON.stringify(
				postClick ?? { matches: [], note: 'no anchors observed' },
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			postClick,
			'one of [New routine | All | Calendar] appeared in the AX tree ' +
				'within 5s after clicking the Routines sidebar button',
		).not.toBeNull();
		expect((postClick?.matches ?? []).length).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
