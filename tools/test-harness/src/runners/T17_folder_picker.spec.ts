import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { retryUntil } from '../lib/retry.js';
import { CodeTab } from '../lib/claudeai.js';
import {
	installOpenDialogMock,
	getOpenDialogCalls,
} from '../lib/electron-mocks.js';

// T17 — Folder picker opens.
//
// Path: seed auth from the host's signed-in Claude Desktop config into
// a per-test tmpdir, launch the app against that hermetic config, wait
// for `userLoaded` (claude.ai past /login — the Code-tab UI doesn't
// render before then), install a dialog.showOpenDialog mock, then
// drive the renderer through the env-pill → Local → Select-folder →
// Open-folder chain via the CodeTab abstraction in lib/claudeai.ts.
// Assert the mock fired.
//
// Side effect of `seedFromHost: true`: the host's running Claude
// Desktop is killed (writer-lock release for LevelDB / SQLite); the
// host config dir itself is left untouched, only an allowlisted subset
// is copied into the per-test tmpdir which is rm -rf'd on app.close().
// See lib/isolation.ts for the allowlist and lib/host-claude.ts for
// the kill semantics. Same pattern as T07 / T16 / T26.
//
// Session 15 migration: previously this spec gated on the older
// `CLAUDE_TEST_USE_HOST_CONFIG=1` env var path (with `isolation: null`,
// sharing host config in-place). That path collides with Playwright's
// 60s spec timeout: a fresh isolation has no auth, `waitForReady(
// 'userLoaded')` polls until its 90s budget which the spec timeout
// preempts, producing a bare "Test timeout of 60000ms exceeded" with
// no diagnostic attachment. The seedFromHost shape mirrors T16/T26
// and gives a clean skip path when the host has no auth.
//
// All renderer-DOM walking lives in lib/claudeai.ts — when claude.ai
// rerenders the Code tab in a future release and this test breaks, the
// fix is one file over, not here.

test('T17 — Folder picker opens', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab / folder picker',
	});

	// Seed auth from host (same handshake as T16). Skip cleanly when no
	// signed-in host config is available — createIsolation throws with
	// a clear message in that case (no host dir, or dir present but
	// missing the auth files).
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
		await testInfo.attach('renderer-url', {
			body: ready.postLoginUrl,
			contentType: 'text/plain',
		});

		await installOpenDialogMock(ready.inspector);

		const codeTab = new CodeTab(ready.inspector);
		await codeTab.activate({ timeout: 15_000 });
		try {
			await codeTab.openFolderPicker();
		} catch (err) {
			// Lib threw mid-chain — likely a renderer drift. Attach the
			// underlying message so the failure log says exactly which
			// step decayed.
			await testInfo.attach('open-folder-picker-error', {
				body: err instanceof Error ? err.message : String(err),
				contentType: 'text/plain',
			});
			throw err;
		}

		const calls = await retryUntil(
			async () => {
				const c = await getOpenDialogCalls(ready.inspector);
				return c.length > 0 ? c : null;
			},
			{ timeout: 5_000, interval: 250 },
		);
		await testInfo.attach('dialog-calls', {
			body: JSON.stringify(calls, null, 2),
			contentType: 'application/json',
		});
		expect(
			calls,
			'dialog.showOpenDialog was invoked after clicking Open folder',
		).toBeTruthy();
		expect((calls ?? []).length).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
