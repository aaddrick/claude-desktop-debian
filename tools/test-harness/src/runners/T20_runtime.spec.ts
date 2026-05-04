import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T20 — File pane IPC surface registered + LocalSessions foundational
// read-side invocable (Tier 2 reframe of the Tier 3 case-doc claim
// "file pane opens and saves with sha256 conflict detection"). First
// runtime probe for T20 — no fingerprint sibling shipped (case-doc
// anchors are channel names + impl line numbers, not user-facing
// literals).
//
// Backs T20 in docs/testing/cases/code-tab-foundations.md ("File pane
// opens and saves"). The case-doc Code anchors point at:
//   - `claude.web_LocalSessions_readSessionFile` (:68922) — read-side
//   - `claude.web_LocalSessions_writeSessionFile` (:69003) — write-
//     side, with sha256 `expectedHash` arg at position 3 enforcing
//     on-disk-changed detection
//   - impls at :492874 / :492954
// The reframe asserts the file-pane IPC surface (read + write +
// picker) is registered on the claude.ai webContents at runtime, plus
// the foundational `LocalSessions/getAll` returns the documented
// array shape. Case-doc connection: the file pane operates on session-
// bound files; the session enumeration handler is the foundational
// read-side surrogate that proves the LocalSessions impl object — the
// same `A` reference all 117 LocalSessions handlers close over — is
// reachable through the renderer wrapper.
//
// Invoking `readSessionFile` / `writeSessionFile` directly would need
// (sessionId, path) args that aren't reliably constructible from a
// fresh seedFromHost isolation (no Code session opened in the
// harness). `writeSessionFile` is also a write-side handler — would
// mutate user content if invoked. Registration probes plus the
// foundational read-side `getAll` invocation is the strongest non-
// destructive Tier 2 layer. Same shape T19 ships against the terminal
// IPC surface.
//
// Why these 3 suffixes
// --------------------
// The file pane needs: read existing content (`readSessionFile`),
// write back on Save (`writeSessionFile` with sha256 conflict
// detection), and pick a file from the session tree
// (`pickSessionFile`). All three are load-bearing for the click-chain
// the case-doc describes; partial registration would break either
// "open file" (no readSessionFile) or "Save" (no writeSessionFile)
// or "click a file path in chat" (no pickSessionFile).
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the LocalSessions
// wrapper isn't exposed (mirrors T22b / T31b / T33b / T33c / T35b /
// T37b / T38b / T19 pattern).

test.setTimeout(90_000);

const EXPECTED_SUFFIXES = [
	'LocalSessions_$_readSessionFile',
	'LocalSessions_$_writeSessionFile',
	'LocalSessions_$_pickSessionFile',
] as const;

// Foundational session enumeration. `[]` args; returns
// `Array<Session>`. Both empty and non-empty arrays pass the shape
// assertion — the case-doc claim is wiring presence, not session
// count.
const INVOKE_SUFFIX = 'LocalSessions_$_getAll';
const INVOKE_ARGS: readonly unknown[] = [];

test('T20 — File pane IPC surface + getAll invocable', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — File pane (eipc registration + invocation)',
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

		// Invoke `getAll`. Response shape captured for the diagnostic
		// (never the session bodies — session metadata may include
		// user-account-scoped paths and titles, mirrors T37b's
		// defensive default).
		let invokeResponseShape = 'not-invoked';
		let invokeResponseLength: number | null = null;
		const invokeResult = await invokeEipcChannel<unknown>(
			ready.inspector,
			INVOKE_SUFFIX,
			INVOKE_ARGS,
		);
		if (Array.isArray(invokeResult)) {
			invokeResponseShape = `array(length=${invokeResult.length})`;
			invokeResponseLength = invokeResult.length;
		} else if (invokeResult === null) {
			invokeResponseShape = 'null';
		} else {
			invokeResponseShape = typeof invokeResult;
		}

		const registration: Record<string, unknown> = {};
		for (const suffix of EXPECTED_SUFFIXES) {
			registration[suffix] = resolved.get(suffix);
		}

		await testInfo.attach('t20-runtime', {
			body: JSON.stringify(
				{
					expectedRegistrationSuffixes: EXPECTED_SUFFIXES,
					registration,
					invocation: {
						suffix: INVOKE_SUFFIX,
						args: INVOKE_ARGS,
						responseShape: invokeResponseShape,
						responseLength: invokeResponseLength,
					},
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T20] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the file pane ' +
					'(case-doc anchors index.js:68922 readSessionFile / :69003 ' +
					'writeSessionFile / impls :492874 / :492954)',
			).not.toBeNull();
		}

		expect(
			Array.isArray(invokeResult),
			`[T20] LocalSessions/getAll response is an array ` +
				`(got ${invokeResponseShape}) — the file pane operates on ` +
				'session-bound files; getAll is the foundational session ' +
				'enumeration handler that proves the LocalSessions impl ' +
				'object is reachable through the renderer wrapper',
		).toBe(true);
	} finally {
		await app.close();
	}
});
