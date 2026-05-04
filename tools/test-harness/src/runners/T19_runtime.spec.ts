import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T19 — Integrated terminal IPC surface registered + LocalSessions
// foundational read-side invocable (Tier 2 reframe of the Tier 3 case-
// doc claim "integrated terminal opens in the session's working
// directory"). First runtime probe for T19 — no fingerprint sibling
// shipped; the case-doc anchors are minified-symbol-shaped (channel
// names + impl line numbers, not user-facing literals) so the bundle-
// string fingerprint layer adds little over the registry probe.
//
// Backs T19 in docs/testing/cases/code-tab-foundations.md ("Integrated
// terminal"). The case-doc Code anchors point at write-side handlers —
// `claude.web_LocalSessions_startShellPty` (:69135) plus its
// `resizeShellPty` / `writeShellPty` siblings — which spawn / drive
// node-pty and would mutate host state if invoked. The reframe asserts
// the FULL terminal IPC surface is registered (5-suffix presence
// probe) plus the foundational `LocalSessions/getAll` read-side
// returns the documented array shape. The case-doc connection: the
// integrated terminal binds to an existing LocalSession; the session
// enumeration handler is the read-side surrogate that proves the
// LocalSessions interface impl object is wired through, not just the
// channel-registration block running.
//
// Why both layers — registration AND invocation
// ---------------------------------------------
// Registration of `startShellPty` etc. proves the handler is wired
// (strictly stronger than the bundle-string fingerprint sibling that
// session 3 didn't ship for T19). Invocation of `getAll` proves the
// LocalSessions impl object — the same `A` reference all 117
// LocalSessions handlers close over — is reachable through the
// renderer wrapper and returns the documented `Array<Session>` shape.
// A half-applied refactor where the registration block runs but the
// impl object is missing methods would pass registration-only and
// fail invocation. T33c's pattern (registration + invocation of
// case-doc-anchored read-side suffixes) doesn't directly apply
// because T19's case-doc anchors are write-side; using `getAll` as
// the foundational read-side surrogate is the closest equivalent.
//
// Read-only by design — `getAll` enumerates the user's existing
// sessions without mutating; empty list (no active sessions) and
// non-empty list (active sessions present) both pass.
//
// Why these 5 suffixes
// --------------------
// The integrated terminal pane needs: spawn (`startShellPty`), input
// (`writeShellPty`), output rendering (`getShellPtyBuffer`), window
// resize (`resizeShellPty`), and teardown (`stopShellPty`). All five
// are load-bearing as a unit; partial registration would break the
// terminal silently.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the LocalSessions
// wrapper isn't exposed (mirrors T22b / T31b / T33b / T33c / T35b /
// T37b / T38b pattern).

test.setTimeout(90_000);

const EXPECTED_SUFFIXES = [
	'LocalSessions_$_startShellPty',
	'LocalSessions_$_writeShellPty',
	'LocalSessions_$_stopShellPty',
	'LocalSessions_$_resizeShellPty',
	'LocalSessions_$_getShellPtyBuffer',
] as const;

// Foundational session enumeration. `[]` args; returns
// `Array<Session>`. Both empty and non-empty arrays pass the shape
// assertion — the case-doc claim is wiring presence, not session
// count.
const INVOKE_SUFFIX = 'LocalSessions_$_getAll';
const INVOKE_ARGS: readonly unknown[] = [];

test('T19 — Integrated terminal IPC surface + getAll invocable', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Terminal pane (eipc registration + invocation)',
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

		// Invoke `getAll`. Any exception (rejection, validation fail,
		// wrapper-exposure miss) bubbles up as a test failure; the
		// JSON diagnostic captures the response shape (never the
		// session bodies — session metadata may include user-account-
		// scoped paths and titles, mirrors T37b's defensive default).
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

		await testInfo.attach('t19-runtime', {
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
				`[T19] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the integrated ' +
					'terminal pane (case-doc anchors index.js:69135 / :69184 / ' +
					':69210 / :486438)',
			).not.toBeNull();
		}

		expect(
			Array.isArray(invokeResult),
			`[T19] LocalSessions/getAll response is an array ` +
				`(got ${invokeResponseShape}) — the integrated terminal ` +
				'binds to an existing LocalSession; getAll is the foundational ' +
				'session enumeration handler that proves the LocalSessions impl ' +
				'object is reachable through the renderer wrapper',
		).toBe(true);
	} finally {
		await app.close();
	}
});
