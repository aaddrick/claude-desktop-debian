import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T21 — Dev server preview pane IPC surface registered + Launch read-
// side handlers invocable (Tier 2 reframe of the case-doc claim "Click
// Preview → Start; configured dev server starts, embedded browser
// renders, auto-verify takes screenshots, Stop actually stops"). First
// runtime probe for T21 — no fingerprint sibling shipped; the case-doc
// anchors point at impl-side function names (`setAutoVerify`,
// `parseLaunchJson`, `capturePage`/`captureViaCDP`) plus an MCP tool
// table (`preview_*`), not the user-facing channel names.
//
// Backs T21 in docs/testing/cases/code-tab-workflow.md ("Dev server
// preview pane"). Session 7's per-interface registry walk did not list
// `claude.web/Launch`; session 10 re-ran the probe with an active
// session and saw all 25 invokeHandlers register on the claude.ai
// webContents. Smoke-test against a debugger-attached running Claude
// (session 11) confirmed the wrapper at
// `window['claude.web'].Launch` exposes 30 callable members (25
// invokeHandlers + 5 `on*` event subscribers + `isAvailable` +
// `activeServersStore`) and that the `cwd` arg validator on the
// read-side getters is `typeof cwd === 'string'` only — no path
// existence check, no absolute-path requirement, empty / relative /
// non-existent strings all pass.
//
// Why both layers — registration AND invocation
// ---------------------------------------------
// Registration of the 5 case-doc-anchored Launch suffixes proves the
// preview pane's IPC surface is wired (start / stop / screenshot /
// auto-verify / configured-services). Invocation of `getConfiguredServices`
// and `getAutoVerify` proves the Launch impl object is reachable
// through the renderer wrapper and returns the documented shapes
// (array of services, boolean auto-verify state). A half-applied
// refactor where the registration block runs but the impl object is
// missing methods would pass registration-only and fail invocation.
// Different shape from T19 / T20 (which use `LocalSessions/getAll` as
// a foundational read-side surrogate because their case-doc anchors
// are write-side); T21's case-doc anchors include native read-side
// handlers, so the invocation is on a case-doc-anchored handler
// directly — same pattern as T33c's dual-handler invocation.
//
// Why these 5 registration suffixes
// ---------------------------------
// The preview pane's user flow per the case-doc steps:
//   1. Configure `.claude/launch.json` (auto-detect populates it) →
//      `getConfiguredServices` reads it.
//   2. Click Preview → Start → `startFromConfig` spawns the dev
//      server.
//   3. Auto-verify takes screenshots → `capturePreviewScreenshot` +
//      `getAutoVerify` reads the `autoVerify: true` flag.
//   4. Stop the server from the dropdown → `stopServer` kills the
//      process.
// All five are load-bearing as a unit; partial registration would
// break either "Start" / "Stop" / auto-verify reads / screenshot /
// initial config read.
//
// Why these 2 invocation targets
// ------------------------------
// Both `getConfiguredServices(cwd) → Array<…>` and
// `getAutoVerify(cwd) → boolean` are pure read-side handlers — no
// process spawn, no fs writes. `getConfiguredServices` reads
// `<cwd>/.claude/launch.json` and returns an empty array when missing
// (the test's harness CWD has no `.claude/launch.json`, so the
// observed value is `[]`); `getAutoVerify` returns the boolean value
// of the `autoVerify` flag, defaulting to false on a missing config.
// Invoking both gives an array-shape assertion AND a boolean-type
// assertion — strictly stronger than either alone, and the dual-
// invocation cost is negligible (~200ms).
//
// Read-only by design — neither handler spawns subprocesses, mutates
// fs, or performs network egress. The cwd arg is the test process's
// own working directory; no user content is read.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the Launch wrapper
// isn't exposed (mirrors T22b / T31b / T33b / T33c / T35b / T37b /
// T38b / T19 / T20 pattern).

test.setTimeout(90_000);

const EXPECTED_SUFFIXES = [
	'Launch_$_getConfiguredServices',
	'Launch_$_startFromConfig',
	'Launch_$_stopServer',
	'Launch_$_getAutoVerify',
	'Launch_$_capturePreviewScreenshot',
] as const;

// `cwd` arg shape on Launch read-side handlers: positional string at
// position 0. Validator is `typeof cwd === 'string'` only (smoke-tested
// session 11 against a debugger-attached running Claude — empty,
// relative, and non-existent paths all pass; `null`, `undefined`, and
// object wraps reject). Using `process.cwd()` makes the invocation
// path defensible (the test process is definitely running there) and
// non-sensitive (the harness CWD is the project root, never a user-
// account-scoped path).
const INVOKE_CWD = process.cwd();

test('T21 — Dev server preview pane IPC surface + Launch read-sides invocable', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Preview pane (eipc registration + invocation)',
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

		// Invoke `getConfiguredServices` — array of configured dev server
		// services. The harness CWD has no `.claude/launch.json`, so
		// the observed value is `[]`. Service config bodies may include
		// user-account-scoped paths (e.g. project workspace paths from
		// auto-detect); log length only, never bodies (mirrors T19/T20/
		// T33c/T37b's defensive default).
		let servicesShape = 'not-invoked';
		let servicesLength: number | null = null;
		const servicesResult = await invokeEipcChannel<unknown>(
			ready.inspector,
			'Launch_$_getConfiguredServices',
			[INVOKE_CWD],
		);
		if (Array.isArray(servicesResult)) {
			servicesShape = `array(length=${servicesResult.length})`;
			servicesLength = servicesResult.length;
		} else if (servicesResult === null) {
			servicesShape = 'null';
		} else {
			servicesShape = typeof servicesResult;
		}

		// Invoke `getAutoVerify` — boolean. The cwd's launch.json
		// `autoVerify` flag defaults to false on missing config.
		let autoVerifyShape = 'not-invoked';
		let autoVerifyValue: boolean | null = null;
		const autoVerifyResult = await invokeEipcChannel<unknown>(
			ready.inspector,
			'Launch_$_getAutoVerify',
			[INVOKE_CWD],
		);
		if (typeof autoVerifyResult === 'boolean') {
			autoVerifyShape = 'boolean';
			autoVerifyValue = autoVerifyResult;
		} else if (autoVerifyResult === null) {
			autoVerifyShape = 'null';
		} else {
			autoVerifyShape = typeof autoVerifyResult;
		}

		const registration: Record<string, unknown> = {};
		for (const suffix of EXPECTED_SUFFIXES) {
			registration[suffix] = resolved.get(suffix);
		}

		await testInfo.attach('t21-runtime', {
			body: JSON.stringify(
				{
					expectedRegistrationSuffixes: EXPECTED_SUFFIXES,
					registration,
					invocations: [
						{
							suffix: 'Launch_$_getConfiguredServices',
							args: [INVOKE_CWD],
							responseShape: servicesShape,
							responseLength: servicesLength,
						},
						{
							suffix: 'Launch_$_getAutoVerify',
							args: [INVOKE_CWD],
							responseShape: autoVerifyShape,
							responseValue: autoVerifyValue,
						},
					],
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T21] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the dev ' +
					'server preview pane (case-doc anchors index.js:259604 / ' +
					':260015 / :262175)',
			).not.toBeNull();
		}

		expect(
			Array.isArray(servicesResult),
			`[T21] Launch/getConfiguredServices response is an array ` +
				`(got ${servicesShape}) — the preview pane reads the ` +
				'configured dev server list from `<cwd>/.claude/launch.json`; ' +
				'an array result (empty or non-empty) proves the Launch impl ' +
				'object is reachable through the renderer wrapper',
		).toBe(true);

		expect(
			typeof autoVerifyResult,
			`[T21] Launch/getAutoVerify response is a boolean ` +
				`(got ${autoVerifyShape}) — auto-verify drives the ` +
				'preview-pane screenshot loop; a boolean result proves the ' +
				'`autoVerify` flag read path is wired through the Launch impl',
		).toBe('boolean');
	} finally {
		await app.close();
	}
});
