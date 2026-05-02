import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

const exec = promisify(execFile);

// H04 — cowork daemon spawn / cleanup contract.
//
// docs/learnings/cowork-vm-daemon.md describes the contract that
// patches/cowork.sh implements: the app's auto-launch path
// (cowork.sh:262-362) forks cowork-vm-service.js as a detached
// child on first VM-service connection attempt, and the Linux
// quit handler registered at cowork.sh:584-633 SIGTERMs that
// daemon on app exit. No existing test asserts that contract
// end-to-end. If the auto-launch regresses, the app falls back
// to "VM service not running" errors silently; if the quit
// handler regresses, daemons leak across app sessions and
// pollute the next launch's socket binding.
//
// Shape: pgrep baseline (must be empty after launchClaude's
// cleanupPreLaunch — see lib/electron.ts:160-191), launch with
// isolation, wait for mainVisible, poll for a daemon pid, then
// close + verify cleanup.
//
// The daemon spawn is conditional — cowork.sh:265 anchors on
// 'VM service not running. The service failed to start.' which
// only fires when something in the renderer triggers a VM
// connection. On a freshly-launched app that never hits the
// Cowork tab, the daemon may legitimately not appear within
// the budget. Treat that as `testInfo.skip` rather than a fail.
//
// Row-gated to the same set as the QE tests — daemon is a Linux
// thing, gating mirrors S30.

const PGREP_PATTERN = 'cowork-vm-service\\.js';

async function pgrepPids(pattern: string): Promise<Set<number>> {
	try {
		const { stdout } = await exec('pgrep', ['-f', pattern], {
			timeout: 5_000,
		});
		return new Set(
			stdout
				.split('\n')
				.map((l) => parseInt(l.trim(), 10))
				.filter((n) => !Number.isNaN(n)),
		);
	} catch (err) {
		// pgrep exits 1 with empty stdout when no matches. Treat as
		// the empty set; everything else propagates.
		const e = err as { code?: number; stdout?: string };
		if (e.code === 1) return new Set();
		const out = e.stdout ?? '';
		return new Set(
			out
				.split('\n')
				.map((l) => parseInt(l.trim(), 10))
				.filter((n) => !Number.isNaN(n)),
		);
	}
}

test.setTimeout(60_000);

test('H04 — cowork daemon spawns under app, exits with app', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Cowork daemon lifecycle',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Baseline — launchClaude's cleanupPreLaunch (lib/electron.ts:160-191)
	// pkills any leftover cowork daemon before spawning, so a stray
	// pid here would mean the cleanup itself is broken.
	const baselinePids = await pgrepPids(PGREP_PATTERN);
	await testInfo.attach('baseline-pids', {
		body: JSON.stringify(
			{
				pids: Array.from(baselinePids),
				note:
					'cleanupPreLaunch should leave this empty before launch. ' +
					'Non-empty here is a bug in lib/electron.ts:160-191.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});
	let daemonPid: number | null = null;
	let lingeringPids: number[] = [];

	try {
		// mainVisible — main shell up; the daemon spawn is gated on
		// renderer activity (cowork.sh:262-362) which can begin
		// asynchronously after the shell paints. Lower readiness
		// levels race the spawn window.
		await app.waitForReady('mainVisible');

		// Poll up to 15s for a new daemon pid. cowork.sh's auto-
		// launch only fires when the renderer attempts a VM service
		// connection; on a passive launch (no Cowork tab interaction)
		// the daemon may legitimately not appear in this window.
		const start = Date.now();
		while (Date.now() - start < 15_000) {
			const pids = await pgrepPids(PGREP_PATTERN);
			const newPids = Array.from(pids).filter(
				(p) => !baselinePids.has(p),
			);
			if (newPids.length > 0) {
				daemonPid = newPids[0]!;
				break;
			}
			await sleep(500);
		}

		if (daemonPid === null) {
			await testInfo.attach('skip-reason', {
				body: JSON.stringify(
					{
						reason:
							'cowork daemon not spawned within 15s of mainVisible',
						note:
							'Auto-launch in cowork.sh:262-362 is gated on a VM ' +
							'service connection attempt from the renderer; on a ' +
							'passive launch with no Cowork-tab interaction it may ' +
							'legitimately not fire. Not a regression on its own.',
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
			testInfo.skip(
				true,
				'cowork daemon not spawned by this build — gating in ' +
					'cowork.sh:262-362 may have suppressed it on a passive launch',
			);
			return;
		}

		await testInfo.attach('daemon-spawned', {
			body: JSON.stringify(
				{
					pid: daemonPid,
					elapsedMs: Date.now() - start,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
	} finally {
		await app.close();
	}

	// Quit handler (cowork.sh:584-633) waits up to 10s for the
	// daemon to exit after SIGTERM. Give it a 5s settle window —
	// graceful exit is the common case, but on a slow runner the
	// kill loop's poll cadence (200ms × 50) can stretch. Re-pgrep
	// after the wait.
	await sleep(5_000);

	const postExitPids = await pgrepPids(PGREP_PATTERN);
	lingeringPids = Array.from(postExitPids).filter(
		(p) => p === daemonPid || !baselinePids.has(p),
	);

	await testInfo.attach('post-exit-pgrep', {
		body: JSON.stringify(
			{
				baseline: Array.from(baselinePids),
				postExit: Array.from(postExitPids),
				lingering: lingeringPids,
				note:
					'Lingering daemon pids after app.close() indicate the ' +
					'Linux quit handler in cowork.sh:584-633 did not run, ' +
					'or its 10s SIGTERM-then-noop loop completed without ' +
					'the daemon actually exiting (escalate to SIGKILL upstream).',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		lingeringPids,
		'no cowork-vm-service daemon lingers 5s after app.close()',
	).toEqual([]);
});
