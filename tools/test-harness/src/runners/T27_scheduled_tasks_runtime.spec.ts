import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T27 — Scheduled task readback handlers invocable at runtime (Tier 2
// reframe of the case-doc T27 "Scheduled task fires and notifies"
// case; full case-doc form requires login + creating a Manual task +
// clicking Run now and observing notification, which is Tier 3 work).
//
// Backs T27 in docs/testing/cases/routines.md. The case-doc anchors
// are `:282332` (`runNow(A)` — manual dispatch), `:512837`
// (`Rc.showNotification(...,scheduled-${l},...)` — desktop
// notification on completion), and `:282654`
// (`getJitterSecondsForTask` — deterministic per-task offset). The
// natural Tier 2 reframe is the read-side handler that lists scheduled
// tasks at runtime — wire-confirming that the scheduling registry is
// plumbed through to a reachable read endpoint, which is what feeds
// the Routines sidebar list and the Run-now dispatch path.
//
// Two parallel scopes register the same `getAllScheduledTasks` shape:
// - `claude.web/CoworkScheduledTasks` — Cowork (chat-side / Routines
//   sidebar) scheduled tasks.
// - `claude.web/CCDScheduledTasks` — Claude Code Desktop (Code-tab)
//   scheduled tasks.
// Both register on the claude.ai webContents per session 7's
// eipc-registry probe. Asserting both as a load-bearing pair captures
// the case-doc surface that mentions both Manual tasks (Cowork-shaped)
// and Hourly tasks across the next-hour boundary (CCD-shaped).
//
// Why no Tier 1 fingerprint sibling
// ---------------------------------
// Sessions 1-7 didn't ship a T27 fingerprint runner — the case-doc
// anchors lean on `runNow(A)` / `Rc.showNotification` / `getJitter`,
// which are minified-symbol-shaped (single-letter callsites) and
// don't form a high-confidence string fingerprint. The eipc registry
// names ARE high-confidence (full case-doc-shape strings), so T27
// ships directly as the runtime probe — same shape as T26's
// "Routines page renders" runner that also has no fingerprint
// sibling.
//
// Why the runtime probe is meaningful
// -----------------------------------
// `getAllScheduledTasks` returning an array shape proves the handler
// is wired AND the read path through to the per-account scheduled-
// tasks store works. The Routines sidebar list (case-doc T26 case)
// and the Run-now dispatch path (case-doc T27 case) both depend on
// this read endpoint. A wiring regression that breaks either case
// would surface as a thrown error / wrong-type response here.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — same reasoning as T35b/T37b.

test.setTimeout(60_000);

const EXPECTED_SUFFIXES = [
	'CoworkScheduledTasks_$_getAllScheduledTasks',
	'CCDScheduledTasks_$_getAllScheduledTasks',
] as const;

test('T27 — Scheduled task readback handlers invocable at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Routines runtime (eipc invocation)',
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

		// First confirm registration of the pair, then invoke each.
		const resolved = await waitForEipcChannels(
			ready.inspector,
			EXPECTED_SUFFIXES,
		);

		// Per-suffix invocation result for the diagnostic attachment.
		// Empty arrays on the dev box (no scheduled tasks created); a
		// configured-host run would produce non-empty arrays.
		const invocations: Record<string, {
			channelResolved: unknown;
			responseShape: string;
			responseLength: number | null;
		}> = {};

		for (const suffix of EXPECTED_SUFFIXES) {
			const channel = resolved.get(suffix);
			let responseShape = 'not-invoked';
			let responseLength: number | null = null;
			if (channel) {
				const result = await invokeEipcChannel<unknown>(
					ready.inspector,
					suffix,
					[],
				);
				if (Array.isArray(result)) {
					responseShape = `array(length=${result.length})`;
					responseLength = result.length;
				} else if (result === null) {
					responseShape = 'null';
				} else {
					responseShape = typeof result;
				}
				// Per-suffix expectation, attached BEFORE expect() so a
				// failure carries the partial diagnostics in JUnit.
				invocations[suffix] = {
					channelResolved: channel,
					responseShape,
					responseLength,
				};
				expect(
					Array.isArray(result),
					`[T27] ${suffix} response is an array ` +
						`(got ${responseShape}) — case-doc anchor ` +
						':282332 (`runNow(A)`) and :512837 ' +
						'(`Rc.showNotification(...,scheduled-${l},...)`) ' +
						'both consume an array-shaped scheduled-tasks list',
				).toBe(true);
			} else {
				invocations[suffix] = {
					channelResolved: null,
					responseShape,
					responseLength,
				};
			}
		}

		await testInfo.attach('scheduled-tasks-invocations', {
			body: JSON.stringify(
				{
					expectedSuffixes: EXPECTED_SUFFIXES,
					invocations,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T27] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the ' +
					'Routines sidebar list (Cowork) and Code-tab scheduled ' +
					'tasks (CCD); case-doc anchors index.js:282332 / :512837',
			).not.toBeNull();
		}
	} finally {
		await app.close();
	}
});
