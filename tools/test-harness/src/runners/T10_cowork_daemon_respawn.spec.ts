import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

const exec = promisify(execFile);

// T10 — cowork daemon respawn after kill.
//
// docs/testing/cases/platform-integration.md T10 covers two
// claims: the daemon spawns when Cowork needs it (asserted by
// H04), AND it respawns within the documented timeout if it
// crashes mid-session. This runner covers the second half.
//
// The respawn path is implemented by Patch 6 in
// scripts/patches/cowork.sh:244-362 (issue #408). The auto-launch
// gate uses a timestamp-based cooldown (`_lastSpawn`, 10s window)
// instead of a one-shot boolean specifically so the retry loop
// in kUe()/the renamed retry function can re-fork the daemon
// after it dies. If the cooldown regresses back to a one-shot
// boolean, or the cooldown window grows past the renderer's
// retry budget, kill-then-respawn silently breaks and the user
// sees "VM service not running" until they restart the app.
//
// Shape: same baseline + spawn detection as H04. Once a daemon
// pid is captured, SIGKILL it and `retryUntil`-poll pgrep for a
// distinct new pid (NOT in baseline AND NOT the killed pid)
// within 20s — 10s cooldown + 10s slack for the renderer's next
// retry tick to land. Fail with a pgrep-state attachment if no
// new pid appears.
//
// Row gate matches H04 — daemon is Linux-only, gating mirrors the
// rest of the cowork lifecycle row set.

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

test.setTimeout(90_000);

test('T10 — cowork daemon respawns after SIGKILL', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Cowork daemon respawn',
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

	try {
		// mainVisible — main shell up; the daemon spawn is gated on
		// renderer activity (cowork.sh:262-362) which can begin
		// asynchronously after the shell paints.
		await app.waitForReady('mainVisible');

		// Phase 1: capture the original daemon pid. Same 15s window
		// as H04 — if the daemon never spawned in the first place,
		// there's nothing to kill, so skip with the same reason.
		const spawnStart = Date.now();
		while (Date.now() - spawnStart < 15_000) {
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
							'legitimately not fire. Without an initial spawn there ' +
							'is no daemon to kill, so the respawn assertion is ' +
							'unreachable. Same skip path as H04.',
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

		const originalSpawnElapsedMs = Date.now() - spawnStart;
		await testInfo.attach('original-spawn', {
			body: JSON.stringify(
				{
					pid: daemonPid,
					elapsedMs: originalSpawnElapsedMs,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		// Phase 2: SIGKILL the daemon. Try direct process.kill first;
		// the daemon is forked by the Electron main process under the
		// same uid as the test runner, so this should not need root.
		// Shell-out fallback covers the unlikely case where direct
		// kill fails (e.g. EPERM on a misconfigured runner).
		const killTs = Date.now();
		let killMethod = 'process.kill';
		try {
			process.kill(daemonPid, 'SIGKILL');
		} catch (err) {
			killMethod = 'execFile-kill-9';
			await exec('kill', ['-9', String(daemonPid)], { timeout: 5_000 });
		}

		await testInfo.attach('kill', {
			body: JSON.stringify(
				{
					killedPid: daemonPid,
					killMethod,
					killedAt: new Date(killTs).toISOString(),
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		// Phase 3: poll up to 20s for a NEW daemon pid. The cooldown
		// in cowork.sh:329-332 is 10s (`Date.now()-_lastSpawn>1e4`),
		// so a respawn cannot fire earlier than 10s after the original
		// spawn timestamp. We add 10s of slack for the renderer's
		// retry tick to land after the cooldown elapses.
		//
		// Predicate: a pid that's not in the original baseline AND
		// not the killed pid. The killed pid is excluded explicitly
		// so a kernel that hasn't yet reaped the zombie can't fool
		// pgrep into reporting "respawned" with the dead pid.
		const respawnStart = Date.now();
		let respawnPid: number | null = null;
		while (Date.now() - respawnStart < 20_000) {
			const pids = await pgrepPids(PGREP_PATTERN);
			const candidates = Array.from(pids).filter(
				(p) => !baselinePids.has(p) && p !== daemonPid,
			);
			if (candidates.length > 0) {
				respawnPid = candidates[0]!;
				break;
			}
			await sleep(500);
		}

		const respawnElapsedMs = Date.now() - respawnStart;

		if (respawnPid === null) {
			const finalPids = await pgrepPids(PGREP_PATTERN);
			await testInfo.attach('respawn-failure', {
				body: JSON.stringify(
					{
						killedPid: daemonPid,
						pgrepFinal: Array.from(finalPids),
						elapsedMs: respawnElapsedMs,
						note:
							'No new cowork-vm-service pid observed within 20s ' +
							'of SIGKILL. Cooldown in cowork.sh:329-332 is 10s; ' +
							'budget includes 10s of slack for the renderer retry ' +
							'tick. Possible regressions: cooldown reverted to a ' +
							'one-shot boolean (issue #408), retry loop no longer ' +
							're-enters the auto-launch branch on ECONNREFUSED, ' +
							'or the renderer stopped retrying VM connections ' +
							'after the daemon dropped its socket.',
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
		} else {
			await testInfo.attach('respawn', {
				body: JSON.stringify(
					{
						originalPid: daemonPid,
						respawnPid,
						elapsedMs: respawnElapsedMs,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
		}

		expect(
			respawnPid,
			'cowork-vm-service respawns within 20s of SIGKILL',
		).not.toBeNull();
		expect(
			respawnPid,
			'respawn pid is distinct from the killed pid',
		).not.toBe(daemonPid);
	} finally {
		await app.close();

		// Best-effort cleanup confirmation. If anything still matches
		// PGREP_PATTERN after close, attach it for diagnosis but don't
		// fail — H04 is the runner that asserts the cleanup contract.
		await sleep(2_000);
		const postExitPids = await pgrepPids(PGREP_PATTERN);
		const lingering = Array.from(postExitPids).filter(
			(p) => !baselinePids.has(p),
		);
		await testInfo.attach('post-exit-pgrep', {
			body: JSON.stringify(
				{
					baseline: Array.from(baselinePids),
					postExit: Array.from(postExitPids),
					lingering,
					note:
						'Informational. H04 owns the cleanup-after-close ' +
						'assertion; this attachment is for cross-referencing ' +
						'when respawn passes but cleanup regresses elsewhere.',
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
	}
});
