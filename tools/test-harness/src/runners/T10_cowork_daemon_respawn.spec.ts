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
// Trigger model: post-1.5354.0 the cowork client opens a
// persistent pipe at boot (zI/E$i happy path) and uses it for
// every subsequent RPC. After SIGKILL the persistent socket goes
// dead but no client code is in steady-state RPC traffic, so
// nothing fires the retry loop on its own. T10 has to drive
// traffic itself: invoking ClaudeVM.getRunningStatus() through
// the renderer wrapper forces the client to call zI() / kUe(),
// which sees the dead socket, hits the cooldown gate, and
// re-forks the daemon.
//
// Verification primitive: globalThis.__coworkDaemonPid is set
// by the patched fork code after each successful spawn (Patch 6
// in scripts/patches/cowork.sh). Polling that global is faster
// and race-free vs. pgrep, but pgrep is also captured on
// failure for cross-check.
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
		// userLoaded — main shell up AND the renderer has navigated
		// to a post-login URL. The boot-time daemon spawn happens
		// well before this (cowork.sh:262-362 gates on early renderer
		// activity), but Phase 3's `window['claude.web'].ClaudeVM`
		// invocation requires the renderer to be on a post-login URL
		// where the eipc wrapper is exposed. Pre-login pages don't
		// expose `claude.web`, so RPC attempts get "Cannot find
		// context with specified id" errors. Waiting for userLoaded
		// once at the top guarantees the wrapper is reachable.
		const { inspector } = await app.waitForReady('userLoaded');

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

		// Phase 3: drive the retry loop and poll for a NEW pid. The
		// cooldown in cowork.sh:329-332 is 10s, so the new pid can't
		// arrive earlier than 10s past the original `_lastSpawn`. The
		// 30s budget gives 10s of cooldown headroom plus 20s for the
		// renderer context to recover from any post-kill navigation
		// (the dead VM service can trigger a re-render that throws
		// "Cannot find context with specified id" on RPCs in flight),
		// plus the fork + bind + exec round-trip for the new daemon.
		//
		// Each poll iteration: (1) fire ClaudeVM.getRunningStatus()
		// via the renderer wrapper — best-effort, expect throws on
		// post-kill navigations and on the first attempts before the
		// cooldown gate opens — and (2) read globalThis.__coworkDaemonPid
		// (set by the patched fork code after every successful spawn).
		// pgrep is the cross-check.
		const respawnStart = Date.now();
		let respawnPid: number | null = null;
		let rpcAttempts = 0;
		let rpcFailures = 0;
		let lastRpcError: string | null = null;
		while (Date.now() - respawnStart < 30_000) {
			// Drive a daemon RPC by invoking the eipc handler from
			// MAIN directly. The renderer-wrapper path
			// (window['claude.web'].ClaudeVM.getRunningStatus) is
			// unreliable here because the dead VM service triggers
			// a renderer re-render that throws "Cannot find context
			// with specified id" on most calls. Calling the handler
			// from main bypasses the renderer entirely; the handler
			// internally goes through zI()/VsA()/kUe(), the latter
			// of which sees ECONNREFUSED/ENOENT and hits the
			// cooldown-gated fork. We forge a senderFrame.url to
			// satisfy any origin-gated handlers (claude.web scope).
			rpcAttempts++;
			try {
				await inspector.evalInMain(`
					const { webContents } = process.mainModule.require('electron');
					const wc = webContents.getAllWebContents().find(w => {
						try { return w.getURL().includes('claude.ai'); }
						catch { return false; }
					});
					if (!wc) return null;
					const handlers = wc.ipc && wc.ipc._invokeHandlers;
					if (!handlers || typeof handlers.keys !== 'function') return null;
					const channel = Array.from(handlers.keys())
						.find(k => k.endsWith('_$_ClaudeVM_$_getRunningStatus'));
					if (!channel) return null;
					const handler = handlers.get(channel);
					if (typeof handler !== 'function') return null;
					const fakeEvent = {
						senderFrame: { url: 'https://claude.ai/' },
						sender: wc,
					};
					try { await handler(fakeEvent); } catch (e) { /* expected */ }
					return null;
				`);
			} catch (err) {
				rpcFailures++;
				lastRpcError = err instanceof Error ? err.message : String(err);
			}

			// Primary signal: the global pid changed.
			let currentGlobalPid: number | null = null;
			try {
				currentGlobalPid = await inspector.evalInMain<number | null>(
					`return globalThis.__coworkDaemonPid ?? null;`,
				);
			} catch {
				// inspector momentarily unavailable — keep polling
			}
			if (
				currentGlobalPid !== null &&
				currentGlobalPid !== daemonPid &&
				!baselinePids.has(currentGlobalPid)
			) {
				respawnPid = currentGlobalPid;
				break;
			}

			// Cross-check via pgrep (covers the corner where the global
			// is set but pgrep hasn't observed the new pid yet, or the
			// global never gets updated for some reason).
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
			let finalGlobalPid: number | null = null;
			try {
				finalGlobalPid = await inspector.evalInMain<number | null>(
					`return globalThis.__coworkDaemonPid ?? null;`,
				);
			} catch {
				// best-effort
			}
			await testInfo.attach('respawn-failure', {
				body: JSON.stringify(
					{
						killedPid: daemonPid,
						pgrepFinal: Array.from(finalPids),
						globalDaemonPidFinal: finalGlobalPid,
						rpcAttempts,
						rpcFailures,
						lastRpcError,
						elapsedMs: respawnElapsedMs,
						note:
							'No new cowork-vm-service pid observed within 30s ' +
							'of SIGKILL despite firing ClaudeVM.getRunningStatus ' +
							'each iteration. Cooldown in cowork.sh:329-332 is 10s. ' +
							'Possible regressions: cooldown reverted to a one-shot ' +
							'boolean (issue #408), the retry loop no longer enters ' +
							'the auto-launch branch on ECONNREFUSED/ENOENT, the ' +
							'patched fork no longer assigns __coworkDaemonPid, or ' +
							'ClaudeVM eipc no longer routes through the daemon ' +
							'RPC (the trigger surface).',
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
						rpcAttempts,
						rpcFailures,
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
			'cowork-vm-service respawns within 30s of SIGKILL',
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
