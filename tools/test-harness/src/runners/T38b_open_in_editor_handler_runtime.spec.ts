import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { waitForEipcChannel } from '../lib/eipc.js';

// T38b — `LocalSessions.openInEditor` handler registered at runtime
// (Tier 2 sibling of T38's Tier 1 asar fingerprint).
//
// Backs T38 in docs/testing/cases/code-tab-handoff.md ("Continue in
// IDE" — click chooser → IDE opens at the working directory). T38 the
// Tier 1 fingerprint asserts the channel-name string is present in
// bundled `index.js`. T38b the Tier 2 runtime probe asserts the
// matching handler is actually registered on the claude.ai
// webContents at runtime — strictly stronger than string presence.
//
// Note vs T24
// -----------
// T24 (sibling test in code-tab-handoff.md) ships as a mock-then-call
// against the actual `shell.openExternal` egress. T24's assertion is
// strictly stronger than T38's static fingerprint AND than T38b's
// registry presence — it exercises the actual code path the IPC
// handler triggers. T38b's registry-presence check still has unique
// signal: it catches a regression where the upstream code path that
// REGISTERS the handler is removed (no IPC channel = no path to
// shell.openExternal at all), which would slip past T24 if T24 itself
// fell back to a skip on some other condition.
//
// See `lib/eipc.ts` for the eipc-registry primitive and the session 7
// finding that exposed it (`webContents.ipc._invokeHandlers`, not
// global `ipcMain._invokeHandlers`).
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — mirrors T22b / T31b / T33b /
// T16's pattern. Hosts with no signed-in Claude Desktop skip cleanly
// via createIsolation's throw.

test.setTimeout(60_000);

const EXPECTED_SUFFIX = 'LocalSessions_$_openInEditor';

test('T38b — LocalSessions.openInEditor handler registered at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — open in IDE (eipc registry)',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

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

		const channel = await waitForEipcChannel(
			ready.inspector,
			EXPECTED_SUFFIX,
		);

		await testInfo.attach('eipc-channel', {
			body: JSON.stringify(
				{
					expectedSuffix: EXPECTED_SUFFIX,
					resolved: channel,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			channel,
			`[T38b] eipc channel ending in '${EXPECTED_SUFFIX}' is registered ` +
				'on the claude.ai webContents (case-doc anchor index.js:68816 ' +
				'channel framing / :464011 shell.openExternal egress)',
		).not.toBeNull();
	} finally {
		await app.close();
	}
});
