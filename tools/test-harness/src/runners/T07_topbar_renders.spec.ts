import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { retryUntil } from '../lib/retry.js';

// T07 — In-app topbar renders + clickable.
//
// Path: seed auth from the host's signed-in Claude Desktop config into
// a per-test tmpdir, launch the app against that hermetic config, wait
// for `userLoaded` (claude.ai past /login — the topbar is rendered by
// claude.ai's authenticated SPA, not the shell), then DOM-probe the
// topbar via the `data-testid="topbar-windows-menu"` anchor documented
// in docs/learnings/linux-topbar-shim.md.
//
// Side effect of `seedFromHost: true`: the host's running Claude
// Desktop is killed (SIGTERM, then SIGKILL on holdouts). This is
// required because LevelDB / SQLite hold writer locks that would
// torn-page the seed copy. The host config dir itself is left
// untouched — only an allowlisted subset is copied into the tmpdir,
// which is rm -rf'd on test close. See lib/isolation.ts for the
// allowlist and lib/host-claude.ts for the kill semantics.

interface TopbarButton {
	ariaLabel: string;
	testId: string | null;
	rect: { x: number; y: number; w: number; h: number };
	visible: boolean;
}

interface TopbarSnapshot {
	found: boolean;
	containerSelector: string | null;
	buttonCount: number;
	buttons: TopbarButton[];
}

test('T07 — In-app topbar renders with clickable buttons', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Window chrome / in-app topbar',
	});

	// No skipUnlessRow — T07 applies to all rows on PR #538 builds.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Seed auth from host: kills any running host Claude (writer-lock
	// release for LevelDB / SQLite), then copies the auth-relevant
	// subset of ~/.config/Claude into a per-test tmpdir. The host
	// config never gets mutated, and the tmpdir is rm -rf'd on
	// app.close(). Skip cleanly when no signed-in host config is
	// available — createIsolation throws with a clear message in that
	// case (no host dir, or dir present but missing the auth files).
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
		// userLoaded gates on claude.ai URL past /login. With seeded
		// auth this should fire well within the default budget on a
		// warm cache; if the seed was stale and the renderer bounces
		// to /login, postLoginUrl stays absent and we skip.
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

		// Topbar probe: anchor on the `topbar-windows-menu` test id (the
		// hamburger button — name reflects upstream's "this is for
		// Windows" framing per linux-topbar-shim.md gate 3). Sibling
		// buttons live in the same `div.absolute.top-0.inset-x-0`
		// container per the click-state diagnostic in that learning.
		// Fallback to `parentElement` if the closest() lookup misses
		// (defensive — tailwind class regen could shift the container).
		//
		// Wrap in retryUntil because the renderer can still be mid-
		// navigation when waitForReady('userLoaded') resolves (the gate
		// polls URL only — it doesn't wait for SPA route settle), and a
		// post-login client-side redirect during executeJavaScript
		// surfaces as `Execution context was destroyed`. Each retry
		// re-issues the eval against the now-current execution context.
		const topbar = await retryUntil(
			async () => {
				try {
					const r = await ready.inspector.evalInRenderer<TopbarSnapshot>(
						'claude.ai',
						`
						(() => {
							const menu = document.querySelector('[data-testid="topbar-windows-menu"]');
							if (!menu) {
								return { found: false, containerSelector: null, buttonCount: 0, buttons: [] };
							}
							const closest = menu.closest('div.absolute.top-0');
							const container = closest ?? menu.parentElement;
							if (!container) {
								return { found: false, containerSelector: null, buttonCount: 0, buttons: [] };
							}
							const buttons = Array.from(container.querySelectorAll('button'));
							return {
								found: true,
								containerSelector: closest
									? 'div.absolute.top-0 (closest)'
									: 'menu.parentElement (fallback)',
								buttonCount: buttons.length,
								buttons: buttons.map(b => {
									const rect = b.getBoundingClientRect();
									return {
										ariaLabel: b.getAttribute('aria-label') ?? '',
										testId: b.getAttribute('data-testid'),
										rect: {
											x: rect.x,
											y: rect.y,
											w: rect.width,
											h: rect.height,
										},
										visible: rect.width > 0 && rect.height > 0,
									};
								}),
							};
						})()
					`,
					);
					return r.found ? r : null;
				} catch (err) {
					// "Execution context was destroyed" during a route
					// transition is benign — the next iteration runs
					// against the new context.
					const msg = err instanceof Error ? err.message : String(err);
					if (msg.includes('context was destroyed')) return null;
					throw err;
				}
			},
			{ timeout: 15_000, interval: 500 },
		);

		if (!topbar) {
			throw new Error(
				'topbar probe never observed [data-testid="topbar-windows-menu"] ' +
					'within 15s after userLoaded',
			);
		}

		await testInfo.attach('topbar-snapshot', {
			body: JSON.stringify(topbar, null, 2),
			contentType: 'application/json',
		});

		expect(
			topbar.found,
			'data-testid="topbar-windows-menu" anchor was found in ' +
				'claude.ai renderer (gate 3 / shim UA spoof active)',
		).toBe(true);

		// Case-doc lists five buttons (hamburger, sidebar toggle, search,
		// back, forward) plus the Cowork ghost. The exact rendered count
		// depends on whether the Cowork ghost is materialised at probe
		// time, so assert the floor of five — the full button list is
		// captured in the topbar-snapshot attachment for case-doc anchor
		// refinement.
		expect(
			topbar.buttonCount,
			'topbar container has at least 5 buttons',
		).toBeGreaterThanOrEqual(5);

		for (const btn of topbar.buttons) {
			const id = btn.ariaLabel || btn.testId || '(unlabeled)';
			expect(
				btn.visible,
				`topbar button "${id}" has non-zero bounding rect`,
			).toBe(true);
		}
	} finally {
		await app.close();
	}
});
