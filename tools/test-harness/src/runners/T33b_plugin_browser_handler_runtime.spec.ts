import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { waitForEipcChannels } from '../lib/eipc.js';

// T33b — Plugin browser handler pair registered at runtime (Tier 2
// sibling of T33's Tier 1 asar fingerprint).
//
// Backs T33 in docs/testing/cases/extensibility.md ("Plugin browser"
// — click + → Plugins → Add plugin, marketplace listings appear,
// install completes end-to-end). T33 the Tier 1 fingerprint asserts
// the two channel-name strings are present in bundled `index.js`.
// T33b the Tier 2 runtime probe asserts both matching handlers are
// actually registered on the claude.ai webContents at runtime —
// strictly stronger than string presence.
//
// Both channels are needed for the browser to populate:
// `listMarketplaces` fetches the marketplace list, `listAvailablePlugins`
// fetches the per-marketplace plugin listings. Either missing breaks
// the modal silently. `waitForEipcChannels` (plural) holds the pair
// against a single budget.
//
// See `lib/eipc.ts` for the eipc-registry primitive and the session 7
// finding that exposed it (`webContents.ipc._invokeHandlers`, not
// global `ipcMain._invokeHandlers`).
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — mirrors T22b / T31b / T16's
// pattern. Hosts with no signed-in Claude Desktop skip cleanly via
// createIsolation's throw.

test.setTimeout(60_000);

const EXPECTED_SUFFIXES = [
	'CustomPlugins_$_listMarketplaces',
	'CustomPlugins_$_listAvailablePlugins',
] as const;

test('T33b — Plugin browser handler pair registered at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Plugin browser UI (eipc registry)',
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
				`[T33b] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the plugin ' +
					'browser populate flow (case-doc anchors index.js:71392 ' +
					'/ :71534 / :507176)',
			).not.toBeNull();
		}
	} finally {
		await app.close();
	}
});
