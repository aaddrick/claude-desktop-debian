import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { waitForEipcChannels } from '../lib/eipc.js';

// T31b — Side-chat handler trio registered at runtime (Tier 2 sibling
// of T31's Tier 1 asar fingerprint).
//
// Backs T31 in docs/testing/cases/code-tab-workflow.md ("Side chat
// opens" — `Ctrl+;` / `/btw` opens an overlay that forks the current
// Code-tab session, exchanges messages without polluting the main
// transcript, then closes cleanly). T31 the Tier 1 fingerprint
// asserts the three channel-name strings are present in bundled
// `index.js`. T31b the Tier 2 runtime probe asserts all three
// matching handlers are actually registered on the claude.ai
// webContents at runtime — strictly stronger than string presence.
//
// The trio is load-bearing as a UNIT — side chat is broken if any
// one of the three is missing. `waitForEipcChannels` (plural) holds
// the whole list against a single budget; the diagnostic attachment
// shows per-channel resolution so partial registration surfaces
// cleanly.
//
// See `lib/eipc.ts` for the eipc-registry primitive and the session 7
// finding that exposed it (`webContents.ipc._invokeHandlers`, not
// global `ipcMain._invokeHandlers`).
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the eipc handler init never completes. Mirrors T22b/T16's pattern:
// hosts with no signed-in Claude Desktop skip cleanly via
// createIsolation's throw.

test.setTimeout(60_000);

const EXPECTED_SUFFIXES = [
	'LocalSessions_$_startSideChat',
	'LocalSessions_$_sendSideChatMessage',
	'LocalSessions_$_stopSideChat',
] as const;

test('T31b — Side-chat handler trio registered at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Side chat overlay (eipc registry)',
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

		const resolved = await waitForEipcChannels(
			ready.inspector,
			EXPECTED_SUFFIXES,
		);

		// Convert Map → object for the JSON attachment. Per-suffix entry
		// shows resolved channel (or null) so a partial-registration
		// failure surfaces "which two of three landed" without forcing
		// the reader to diff strings.
		const resolvedObj: Record<string, unknown> = {};
		for (const suffix of EXPECTED_SUFFIXES) {
			resolvedObj[suffix] = resolved.get(suffix);
		}
		await testInfo.attach('eipc-channels', {
			body: JSON.stringify(
				{
					expectedSuffixes: EXPECTED_SUFFIXES,
					resolved: resolvedObj,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T31b] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the side-chat ' +
					'trio (case-doc anchors index.js:487025 / :487265)',
			).not.toBeNull();
		}
	} finally {
		await app.close();
	}
});
