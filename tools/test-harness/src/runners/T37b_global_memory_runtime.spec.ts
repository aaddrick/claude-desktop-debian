import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannel } from '../lib/eipc.js';

// T37b — Global CLAUDE.md memory readback handler invocable at
// runtime (Tier 2 sibling of T37's Tier 1 asar fingerprint).
//
// Backs T37 in docs/testing/cases/extensibility.md ("`CLAUDE.md`
// memory loads"). T37 the Tier 1 fingerprint asserts three load-
// bearing strings in the bundle: `[GlobalMemory] Copied CLAUDE.md`
// (the log line at :455188 emitted when `zhA(accountId, orgId)` copies
// global account memory to per-session `.claude/CLAUDE.md`),
// `CLAUDE.md` (the filename literal, both project and global), and
// `CLAUDE_CONFIG_DIR` (the env-var resolver `cE()` at :283107).
//
// T37b the Tier 2 runtime probe asserts the read-side handler that
// exposes the global memory store — `claude.web/CoworkMemory/
// readGlobalMemory` — is registered AND callable, returning the
// documented `string | null` shape (string = stored memory body, null
// = no global memory written for this account).
//
// Why this is the right Tier 2 handler for T37
// --------------------------------------------
// The case-doc anchor `:455188` describes the memory-COPY path: at
// session start, the global account memory `zhA(accountId, orgId)` is
// COPIED into the per-session `.claude/CLAUDE.md`. The READ-side
// handler that exposes the same global-memory store is
// `CoworkMemory/readGlobalMemory` (read-only, no side effects). Wire-
// confirming that handler at runtime is the natural Tier 2 reframe of
// the case-doc anchor — it proves the global-memory store is plumbed
// through to a reachable read endpoint, which is the same store the
// `:455188` copy path reads from.
//
// The other anchors (`:259691` working-dir scan; `:283107`
// `CLAUDE_CONFIG_DIR` resolver) are file-system-side and stay in the
// Tier 1 fingerprint — there's no runtime IPC handler that reads
// project `CLAUDE.md` or resolves the config dir on demand.
//
// Why the fingerprint is not enough
// ---------------------------------
// String presence in the bundle survives a half-applied refactor.
// Runtime invocation proves the handler is wired through to a real
// account-memory store (whatever that is — server-side or local
// cache) and returns the documented type. If the wiring regresses
// (the impl throws on a missing schema, returns a serialized envelope
// instead of plain string, etc.), the fingerprint still passes but
// T37b fails.
//
// Why this works (session 8 finding)
// ----------------------------------
// Same path as T35b — `claude.web/*` handlers expose to the renderer
// via `window['claude.web'].<Iface>.<method>`; `lib/eipc.ts`'s
// `invokeEipcChannel` calls through the wrapper via
// `inspector.evalInRenderer('claude.ai', ...)`. See
// `lib/eipc.ts`'s leading comment for the full path.
//
// Assertion shape
// ---------------
// Returns `string | null`:
// - `string` = stored global memory body for this account
// - `null` = no global memory written for this account (the dev box
//   sees this when seedFromHost copies an account that hasn't written
//   global memory)
// Either is a clean Tier 2 wire-confirmation.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — same reasoning as T35b/T22b.

test.setTimeout(60_000);

const EXPECTED_SUFFIX = 'CoworkMemory_$_readGlobalMemory';

test('T37b — Global memory readback handler invocable at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Memory / Code tab session prompt (eipc invocation)',
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
		expect(
			channel,
			`[T37b] eipc channel ending in '${EXPECTED_SUFFIX}' is registered ` +
				'on the claude.ai webContents (case-doc anchor ' +
				'index.js:455188 — global account memory ' +
				'`zhA(accountId, orgId)` copied to per-session ' +
				'`.claude/CLAUDE.md`)',
		).not.toBeNull();

		const result = await invokeEipcChannel<unknown>(
			ready.inspector,
			EXPECTED_SUFFIX,
			[],
		);

		await testInfo.attach('global-memory-response', {
			body: JSON.stringify(
				{
					expectedSuffix: EXPECTED_SUFFIX,
					resolvedChannel: channel,
					responseType: result === null ? 'null' : typeof result,
					// Memory body could contain personal or sensitive
					// content — record only the type + length; never
					// dump the body into JUnit.
					responseLength:
						typeof result === 'string' ? result.length : null,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		// `string | null` is the documented type. Reject anything else
		// — an envelope, an object, a number — as a wiring regression.
		const isStringOrNull = result === null || typeof result === 'string';
		expect(
			isStringOrNull,
			`[T37b] readGlobalMemory response is string|null ` +
				`(got ${result === null ? 'null' : typeof result}) ` +
				'— case-doc anchor :455188 reads global account memory ' +
				'as a single string body',
		).toBe(true);
	} finally {
		await app.close();
	}
});
