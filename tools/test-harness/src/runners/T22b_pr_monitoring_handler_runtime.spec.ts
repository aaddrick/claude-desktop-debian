import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { waitForEipcChannel } from '../lib/eipc.js';

// T22b — PR monitoring handler registered at runtime (Tier 2 sibling of
// T22's Tier 1 asar fingerprint).
//
// Backs T22 in docs/testing/cases/code-tab-workflow.md ("PR monitoring
// via `gh`"). T22 the Tier 1 fingerprint asserts the
// `LocalSessions_$_getPrChecks` channel name is a string in the bundled
// `index.js`. T22b the Tier 2 runtime probe asserts the matching
// handler is actually REGISTERED on the claude.ai webContents at
// runtime — a strictly stronger signal than string presence.
//
// Why the fingerprint is not enough
// ---------------------------------
// String presence in the bundle survives a half-applied refactor or a
// dead-code path that retains the constant but no longer wires it up.
// Runtime registration proves the upstream code actually executed
// `e.ipc.handle("$eipc_message$_..._$_LocalSessions_$_getPrChecks", fn)`
// during webContents init — a real handler function exists in
// `webContents.ipc._invokeHandlers` keyed by the framed channel
// name. If the wiring regresses (e.g. the `setImplementation` block
// that registers the LocalSessions interface throws on a side
// effect), the fingerprint still passes but T22b fails.
//
// Why this works (session 7 finding)
// ----------------------------------
// `claude.web_$_*` handlers register on `webContents.ipc` (the per-
// `WebContents` IPC scope, Electron 17+), NOT on the global
// `ipcMain`. Sessions 2-6 missed this — `ipcMain._invokeHandlers`
// only carries 3 chat-tab MCP-bridge handlers. The probe at
// `tools/test-harness/eipc-registry-probe.ts` confirmed the claude.ai
// webContents holds 117 LocalSessions methods + 16 CustomPlugins
// methods + the rest of the `claude.web` surface, and the registry is
// sticky across route changes (registers on init, persists). See
// `lib/eipc.ts` for the primitive that wraps the registry walk.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the claude.ai webContents loads but bounces to /login and the eipc
// handler init never runs (or runs against a different surface). Hosts
// with no signed-in Claude Desktop skip cleanly via createIsolation's
// throw, mirroring T16's pattern.
//
// The `seedFromHost` side effect (kills the running host Claude
// Desktop to release LevelDB / SQLite writer locks) is documented in
// `lib/host-claude.ts`. The host config dir itself is left untouched.

test.setTimeout(60_000);

const EXPECTED_SUFFIX = 'LocalSessions_$_getPrChecks';

test('T22b — PR monitoring handler registered at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — CI status bar (eipc registry)',
	});

	// Applies to all rows. No skipUnlessRow gate — the eipc registry
	// is platform-independent (Electron stdlib IPC, not an OS API).

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
		// userLoaded gates on claude.ai URL past /login. Once that
		// fires, the claude.ai webContents has finished its initial
		// handler registration block (verified by session 7 probe:
		// all 7 expected case-doc suffixes register at webContents
		// init, not on first navigation).
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
			`[T22b] eipc channel ending in '${EXPECTED_SUFFIX}' is registered ` +
				'on the claude.ai webContents (case-doc anchor index.js:464281 ' +
				'GitHubPrManager / :464964 getPrChecks)',
		).not.toBeNull();
	} finally {
		await app.close();
	}
});
