import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { CodeTab, findCompactPills } from '../lib/claudeai.js';

// T16 — Code tab loads.
//
// Path: seed auth from the host's signed-in Claude Desktop config into
// a per-test tmpdir, launch the app against that hermetic config, wait
// for `userLoaded` (claude.ai past /login — the Code tab isn't
// reachable from /login), then click the Code tab via the AX-tree-
// backed CodeTab.activate() page-object. activate() polls for at
// least one compact pill (the env pill is the cheapest "Code-tab body
// mounted" signal — the URL doesn't change on Code-tab activation, so
// there's no navigation event to anchor on).
//
// Side effect of `seedFromHost: true`: the host's running Claude
// Desktop is killed (writer-lock release for LevelDB / SQLite); the
// host config dir itself is left untouched, only an allowlisted
// subset is copied into the per-test tmpdir which is rm -rf'd on
// app.close(). See lib/isolation.ts for the allowlist and
// lib/host-claude.ts for the kill semantics. Same pattern as T07.

test('T16 — Code tab loads', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — top-level UI',
	});

	// No skipUnlessRow — T16 applies to all rows.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Seed auth from host (same handshake as T07). Skip cleanly when no
	// signed-in host config is available — createIsolation throws with a
	// clear message in that case (no host dir, or dir present but
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
		await testInfo.attach('post-login-url', {
			body: ready.postLoginUrl,
			contentType: 'text/plain',
		});

		// Click the Code tab and wait for the Code-tab body to mount.
		// CodeTab.activate() does the AX-tree click (role: button,
		// accessibleName: "Code") then polls findCompactPills() — the
		// env pill rendering is the cheapest signal that the Code-tab
		// body is up and interactive. Throws on miss with the candidate
		// count for triage. Generous timeout: the Code-tab body has
		// more wiring than Chat, and on a cold cache the first
		// activation can take a few seconds.
		const codeTab = new CodeTab(ready.inspector);
		try {
			await codeTab.activate({ timeout: 15_000 });
		} catch (err) {
			// On miss, capture the post-click compact-pill snapshot so
			// the failure log shows what (if anything) was on the page
			// instead of just "no pills found".
			const fallback = await findCompactPills(ready.inspector).catch(
				() => [],
			);
			await testInfo.attach('compact-pills-on-failure', {
				body: JSON.stringify(fallback, null, 2),
				contentType: 'application/json',
			});
			throw err;
		}

		// Diagnostic: the post-activate compact pill list. The env pill
		// being present is the assertion (encoded by activate() not
		// throwing); the snapshot is captured for case-doc anchor
		// refinement and drift detection.
		const pills = await findCompactPills(ready.inspector);
		await testInfo.attach('compact-pills', {
			body: JSON.stringify(pills, null, 2),
			contentType: 'application/json',
		});

		expect(
			pills.length,
			'at least one compact pill rendered after activating the Code tab ' +
				'(env pill is the cheapest "Code-tab body mounted" signal)',
		).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
