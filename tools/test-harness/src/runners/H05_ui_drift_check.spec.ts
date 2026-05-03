import { test, expect } from '@playwright/test';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { launchClaude } from '../lib/electron.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { capture, type Snapshot } from '../../explore/snapshot.js';
import { diff } from '../../explore/diff.js';
import type { InspectorClient } from '../lib/inspector.js';

// H05 — claude.ai UI drift detection.
//
// docs/testing/claudeai-ui-mapping-plan.md Phase 5: catch upstream
// renderer changes that would break the page-object selectors in
// lib/claudeai.ts BEFORE they fail a real spec mid-sweep.
//
// For each baseline JSON under docs/testing/ui-snapshots/:
//   1. Navigate the renderer to the captured claudeAiUrl (if any).
//   2. Capture a fresh Snapshot via the same `capture()` the explore
//      CLI uses — no forked logic.
//   3. Compare against the baseline via the same `diff()` the explore
//      CLI uses. Attach the per-snapshot diff if non-empty.
//   4. A snapshot is "clean" if `diff(...).entries.length === 0`.
//
// Pass criterion: ≥80% of snapshots clean (per the plan). The
// threshold is forgiving on purpose — a single rendered surface
// shifting class names shouldn't block CI; we want a signal, not a
// blast radius.
//
// Per-snapshot timing target ≤200ms (snapshot capture only — the
// 30s navigation settle is excluded). Exceedance is a soft warning
// surfaced via attachment, never a hard fail.
//
// Skip behaviours:
//   - Zero baselines: skip with the "capture some first" message
//     (the directory is gitignored beyond .gitkeep + README, so a
//     fresh checkout legitimately has none).
//   - Not signed in (no claude.ai webContents at the claudeAi
//     readiness level): skip — most baselines target post-login
//     surfaces and would fail spuriously on /login.
//
// Row-gated to the same set as the QE-driven specs since the host
// must be capable of reaching claude.ai under launchClaude.

const SNAPSHOT_DIR = resolve(
	dirname(fileURLToPath(import.meta.url)),
	'..',
	'..',
	'..',
	'..',
	'docs',
	'testing',
	'ui-snapshots',
);

// 200ms is the per-snapshot capture target from the plan. Surface
// (not enforce) when a single capture exceeds this.
const CAPTURE_BUDGET_MS = 200;

// 80% from the plan — pass if at least this fraction of snapshots
// have zero diffs. Computed as floor(N * 0.8) so 5/5 passes, 4/5
// passes, 3/5 fails, etc.
const CLEAN_FRACTION_REQUIRED = 0.8;

// Navigation settle: after setting location.href, we poll for the
// URL to land + readyState to reach 'complete' before snapshotting.
// Coupled to the renderer route load + auth-gate redirect time;
// 30s is the same upper bound used by waitForReady('claudeAi').
const NAV_SETTLE_TIMEOUT_MS = 30_000;
const NAV_SETTLE_INTERVAL_MS = 500;

interface SnapshotFile {
	name: string;
	path: string;
	baseline: Snapshot;
}

interface PerSnapshotResult {
	name: string;
	url: string | null;
	clean: boolean;
	captureMs: number;
	summary: { removed: number; changed: number; added: number };
	skipped?: string;
	error?: string;
}

function loadBaselines(): SnapshotFile[] {
	if (!existsSync(SNAPSHOT_DIR)) return [];
	const files = readdirSync(SNAPSHOT_DIR).filter((f) => f.endsWith('.json'));
	const out: SnapshotFile[] = [];
	for (const file of files) {
		const path = resolve(SNAPSHOT_DIR, file);
		const raw = readFileSync(path, 'utf8');
		try {
			out.push({
				name: file.replace(/\.json$/, ''),
				path,
				baseline: JSON.parse(raw) as Snapshot,
			});
		} catch (err) {
			// Surface the bad file as a skipped result rather than
			// aborting the whole run — one corrupt baseline shouldn't
			// hide drift in the rest.
			out.push({
				name: file.replace(/\.json$/, ''),
				path,
				baseline: {
					capturedAt: '',
					claudeAiUrl: '',
					appVersion: null,
					pageState: { url: '', title: '', readyState: '' },
					dfPills: [],
					compactPills: [],
					ariaLabeledButtons: [],
					openMenu: null,
					modals: [],
				},
			});
			// Stash the parse error on the file object via a side
			// channel: the spec body checks for an empty capturedAt
			// on the baseline as the "load failed" signal.
			(out[out.length - 1] as { _loadError?: string })._loadError =
				err instanceof Error ? err.message : String(err);
		}
	}
	return out;
}

// Drive the active claude.ai webContents to the target URL. We set
// location.href in the renderer rather than calling webContents.loadURL
// from main: setting from the renderer keeps the React app's history
// stack intact (it's the same pathway a user-initiated navigation
// takes), avoiding the "blank window then re-mount" flicker loadURL
// triggers. Then poll for the URL to land and readyState=='complete'.
async function navigateRendererTo(
	inspector: InspectorClient,
	targetUrl: string,
): Promise<void> {
	await inspector.evalInRenderer<null>(
		'claude.ai',
		`(() => { window.location.href = ${JSON.stringify(targetUrl)}; return null; })()`,
	);

	const start = Date.now();
	while (Date.now() - start < NAV_SETTLE_TIMEOUT_MS) {
		try {
			const state = await inspector.evalInRenderer<{
				url: string;
				readyState: string;
			}>(
				'claude.ai',
				`(() => ({ url: location.href, readyState: document.readyState }))()`,
			);
			if (
				state.readyState === 'complete' &&
				sameOrigin(state.url, targetUrl)
			) {
				// One extra tick to let claude.ai's React render finish
				// — readyState='complete' fires before the SPA mounts.
				await sleep(500);
				return;
			}
		} catch {
			// During navigation the webContents URL changes and the
			// 'claude.ai' filter may transiently miss; just retry.
		}
		await sleep(NAV_SETTLE_INTERVAL_MS);
	}
	throw new Error(
		`renderer did not settle on ${targetUrl} within ${NAV_SETTLE_TIMEOUT_MS}ms`,
	);
}

// Compare URLs by origin + pathname. claude.ai tacks on tracking
// params, modal state, etc. to the URL after route resolution, so an
// exact match is too strict; the route is what we care about.
function sameOrigin(a: string, b: string): boolean {
	try {
		const ua = new URL(a);
		const ub = new URL(b);
		return ua.origin === ub.origin && ua.pathname === ub.pathname;
	} catch {
		return a === b;
	}
}

test.setTimeout(180_000);

test('H05 — claude.ai UI drift detection', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'claude.ai UI drift detection',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const baselines = loadBaselines();
	await testInfo.attach('baselines-found', {
		body: JSON.stringify(
			{
				dir: SNAPSHOT_DIR,
				count: baselines.length,
				names: baselines.map((b) => b.name),
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	if (baselines.length === 0) {
		testInfo.skip(
			true,
			'no baselines under docs/testing/ui-snapshots/ — capture some ' +
				'with `npm run explore:snapshot <name>` first',
		);
		return;
	}

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});

	const results: PerSnapshotResult[] = [];

	try {
		// claudeAi level: a claude.ai webContents exists. We don't
		// require userLoaded here because some baselines might
		// legitimately be of /login surfaces; per-snapshot navigation
		// will land us on whatever the baseline captured.
		const { inspector, claudeAiUrl } = await app.waitForReady('claudeAi');
		if (!claudeAiUrl) {
			testInfo.skip(
				true,
				'claude.ai webContents never loaded — likely not signed in. ' +
					'Set CLAUDE_TEST_USE_HOST_CONFIG=1 to share host config.',
			);
			return;
		}

		await testInfo.attach('initial-claude-ai-url', {
			body: claudeAiUrl,
			contentType: 'text/plain',
		});

		for (const file of baselines) {
			const loadError = (file as { _loadError?: string })._loadError;
			if (loadError) {
				results.push({
					name: file.name,
					url: null,
					clean: false,
					captureMs: 0,
					summary: { removed: 0, changed: 0, added: 0 },
					error: `failed to parse baseline: ${loadError}`,
				});
				await testInfo.attach(`drift-${file.name}.json`, {
					body: JSON.stringify({ error: loadError }, null, 2),
					contentType: 'application/json',
				});
				continue;
			}

			const targetUrl = file.baseline.claudeAiUrl;

			// Navigate (best-effort). If a baseline has no URL,
			// snapshot the current renderer state in place — it
			// matches the explore CLI's bare `snapshot <name>`
			// pathway, which captures wherever the app is sitting.
			if (targetUrl) {
				try {
					await navigateRendererTo(inspector, targetUrl);
				} catch (err) {
					results.push({
						name: file.name,
						url: targetUrl,
						clean: false,
						captureMs: 0,
						summary: { removed: 0, changed: 0, added: 0 },
						error: `navigation failed: ${err instanceof Error ? err.message : String(err)}`,
					});
					continue;
				}
			}

			const captureStart = Date.now();
			let fresh: Snapshot;
			try {
				fresh = await capture(inspector);
			} catch (err) {
				results.push({
					name: file.name,
					url: targetUrl || null,
					clean: false,
					captureMs: Date.now() - captureStart,
					summary: { removed: 0, changed: 0, added: 0 },
					error: `capture failed: ${err instanceof Error ? err.message : String(err)}`,
				});
				continue;
			}
			const captureMs = Date.now() - captureStart;

			const result = diff(file.baseline, fresh);
			const clean = result.entries.length === 0;

			results.push({
				name: file.name,
				url: targetUrl || null,
				clean,
				captureMs,
				summary: result.summary,
			});

			// Always attach the diff payload — clean diffs are the
			// "no entries" case and confirm the snapshot was actually
			// compared (vs. silently skipped). Naming per-snapshot so
			// the report shows them side-by-side.
			await testInfo.attach(`drift-${file.name}.json`, {
				body: JSON.stringify(result, null, 2),
				contentType: 'application/json',
			});
		}

		inspector.close();
	} finally {
		await app.close();
	}

	const cleanCount = results.filter((r) => r.clean).length;
	const totalCount = results.length;
	const cleanFraction = totalCount === 0 ? 0 : cleanCount / totalCount;
	const slowSnapshots = results.filter(
		(r) => r.captureMs > CAPTURE_BUDGET_MS,
	);
	const errored = results.filter((r) => r.error);

	await testInfo.attach('drift-summary', {
		body: JSON.stringify(
			{
				totalCount,
				cleanCount,
				cleanFraction,
				thresholdRequired: CLEAN_FRACTION_REQUIRED,
				results,
				slowSnapshots: slowSnapshots.map((r) => ({
					name: r.name,
					captureMs: r.captureMs,
					budgetMs: CAPTURE_BUDGET_MS,
				})),
				erroredSnapshots: errored.map((r) => ({
					name: r.name,
					error: r.error,
				})),
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	if (slowSnapshots.length > 0) {
		// Soft warning only — surface as an attachment, don't fail.
		// Capture latency is bounded by the renderer's main-thread
		// availability, which is noisy. The plan's 200ms is a
		// "looking-good" target, not a contract.
		await testInfo.attach('slow-capture-warning', {
			body: JSON.stringify(
				{
					note:
						`${slowSnapshots.length} snapshot(s) exceeded the ` +
						`${CAPTURE_BUDGET_MS}ms capture target. Soft warning — ` +
						'not a fail. Investigate if this trends upward.',
					snapshots: slowSnapshots.map((r) => ({
						name: r.name,
						captureMs: r.captureMs,
					})),
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
	}

	expect(
		cleanFraction,
		`at least ${Math.round(CLEAN_FRACTION_REQUIRED * 100)}% of snapshots ` +
			`must have zero diffs (got ${cleanCount}/${totalCount} clean — see ` +
			'drift-*.json attachments for per-snapshot diffs)',
	).toBeGreaterThanOrEqual(CLEAN_FRACTION_REQUIRED);
});
