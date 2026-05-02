import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { lstatSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { launchClaude } from '../lib/electron.js';
import { skipUnlessRow } from '../lib/row.js';
import { QuickEntry } from '../lib/quickentry.js';
import { sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { listRegisteredItems } from '../lib/sni.js';
import { getConnectionPid } from '../lib/dbus.js';


const exec = promisify(execFile);

// S30 — Quick Entry shortcut becomes a no-op after full app exit.
// Backs QE-5 in docs/testing/quick-entry-closeout.md.
//
// Electron unregisters the global shortcut on app exit; the
// shortcut becomes a system-level no-op. The failure mode this
// test guards against is "ghost respawn" — where some part of the
// system (autostart, lingering daemon) starts a new instance in
// response to the keypress.
//
// After app.close() the inspector is gone; verification is
// pgrep-based: assert no claude-desktop process exists before AND
// after the keypress, and that no app.asar process appears in a
// 3s window after injection.
//
// Beyond the ghost-respawn delta, this test also asserts a clean
// shutdown: no leftover cowork-vm-service pid, no SNI item still
// registered against launchedPid, and (under isolation) no
// SingletonLock symlink left behind in the per-test config dir.
// These come BEFORE the post-exit shortcut press so the order is
// "did exit clean → did the keypress respawn anything" — both
// failure shapes are observable from the same fixture.

test.setTimeout(45_000);

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
		// pgrep exits 1 when no matches, with empty stdout. Treat
		// that as the empty set; everything else propagates.
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

test('S30 — Quick Entry shortcut becomes a no-op after full app exit', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Global shortcut unregistration',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';
	const app = await launchClaude({
		isolation: useHostConfig ? null : undefined,
	});
	const launchedPid = app.pid;

	// Need an inspector handle just long enough to confirm a working
	// shortcut registration. We use it to verify the popup CAN open
	// before exit, so the post-exit no-op result is meaningful.
	try {
		// mainVisible covers main-shell readiness — triggering the
		// shortcut before show() races the popup-show flow (loadFile
		// + ready-to-show + show()) and the popup never becomes
		// visible.
		const { inspector } = await app.waitForReady('mainVisible');
		const qe = new QuickEntry(inspector);
		await qe.installInterceptor();
		// Confirm shortcut is wired by invoking it and waiting for
		// the popup to appear. openAndWaitReady retries through the
		// upstream lHn() race (build-reference index.js:515604) where
		// the first shortcut after main-visible is sometimes too
		// early for the user object to have populated.
		await qe.openAndWaitReady();
		inspector.close();
	} catch (err) {
		await testInfo.attach('preflight-error', {
			body: err instanceof Error ? err.stack ?? err.message : String(err),
			contentType: 'text/plain',
		});
		await app.close();
		throw new Error(
			'Preflight failed: shortcut did not produce a popup. Cannot ' +
				'verify post-exit no-op without a working pre-exit baseline.',
		);
	}

	// Full exit. close() sends SIGTERM then SIGKILL after 5s. Note:
	// renderer / zygote child processes may linger briefly after the
	// main process exits — they're harmless leftovers, not "ghost
	// respawns." The spec's regression target is "no NEW process
	// from the shortcut," so we baseline whatever's left before
	// injecting and assert the delta.
	await app.close();

	// Give the kernel a moment to reap.
	await sleep(500);

	const baselinePids = await pgrepPids('app\\.asar');
	await testInfo.attach('baseline-pids-after-close', {
		body: JSON.stringify(
			{
				launchedPid,
				pidsRemaining: Array.from(baselinePids),
				note:
					'leftover renderer/zygote processes are harmless; the ' +
					'regression target is "no NEW pid spawned by the ' +
					'shortcut press", asserted as a delta below.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	// Closeout leak checks. These probe "did the app exit clean"
	// rather than "did the post-exit shortcut respawn anything" —
	// distinct failure shapes, observed from the same fixture.
	// Run BEFORE the shortcut injection so a respawn can't taint
	// any of these signals.

	// (a) No leftover cowork-vm-service pids. Pre-launch cleanup
	// pkills these (cleanupPreLaunch in lib/electron.ts); a clean
	// shutdown should have already torn them down.
	const coworkPids = await pgrepPids('cowork-vm-service\\.js');
	const coworkPidsRemaining = Array.from(coworkPids);

	// (b) SNI item is deregistered. The connection should be gone
	// post-exit, so getConnectionPid against the formerly-owned
	// service may throw with NameHasNoOwner — treat that as "not
	// present", which is the desired state.
	let sniItemPresent = false;
	try {
		const items = await listRegisteredItems();
		for (const item of items) {
			try {
				const pid = await getConnectionPid(item.service);
				if (pid === launchedPid) {
					sniItemPresent = true;
					break;
				}
			} catch {
				// owner gone — that's "not present" for this item
			}
		}
	} catch {
		// watcher itself may not be running on this row; absence
		// of a watcher means nothing's registered, which is fine.
	}

	// (c) SingletonLock symlink is removed (isolation only).
	// Under CLAUDE_TEST_USE_HOST_CONFIG the host owns its lock;
	// don't probe it. Use lstatSync because SingletonLock is a
	// symlink whose target may be stale — existsSync would follow
	// the link and miss broken-but-present cases.
	let singletonLockPresent = false;
	if (app.isolation) {
		const lockPath = join(app.isolation.configDir, 'SingletonLock');
		try {
			lstatSync(lockPath);
			singletonLockPresent = true;
		} catch {
			// ENOENT — clean
		}
	}

	await testInfo.attach('closeout-leak-check', {
		body: JSON.stringify(
			{
				coworkPidsRemaining,
				sniItemPresent,
				singletonLockPresent,
				launchedPid,
				isolationConfigDir: app.isolation?.configDir ?? null,
				useHostConfig,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		coworkPidsRemaining,
		'no cowork-vm-service pids remain after app.close()',
	).toEqual([]);
	expect(
		sniItemPresent,
		'no SNI item still registered against launchedPid after app.close()',
	).toBe(false);
	expect(
		singletonLockPresent,
		'no SingletonLock symlink remains under isolation configDir after app.close()',
	).toBe(false);

	// Inject the shortcut. ydotool is at the kernel level, so the
	// keys go out regardless of who's listening. We can't use
	// QuickEntry.openViaShortcut here — that's a class method that
	// exists for tests with a live inspector — so we shell out
	// directly. Same key sequence (Ctrl+Alt+Space).
	try {
		await exec(
			'ydotool',
			['key', '29:1', '56:1', '57:1', '57:0', '56:0', '29:0'],
			{
				env: {
					...process.env,
					YDOTOOL_SOCKET:
						process.env.YDOTOOL_SOCKET ?? '/tmp/.ydotool_socket',
				} as Record<string, string>,
				timeout: 5_000,
			},
		);
	} catch (err) {
		await testInfo.attach('ydotool-error', {
			body: err instanceof Error ? err.message : String(err),
			contentType: 'text/plain',
		});
		throw err;
	}

	// Wait through the window during which a respawn could occur.
	await sleep(3_000);

	const postShortcutPids = await pgrepPids('app\\.asar');
	const newPids = Array.from(postShortcutPids).filter(
		(p) => !baselinePids.has(p),
	);

	await testInfo.attach('post-shortcut-pgrep', {
		body: JSON.stringify(
			{
				baseline: Array.from(baselinePids),
				postShortcut: Array.from(postShortcutPids),
				newPids,
				note: 'A non-empty newPids set indicates a ghost respawn — ' +
					'autostart, service-supervisor, or the OS shortcut ' +
					'binding launching a fresh instance.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		newPids,
		'no NEW claude-desktop pid appears 3s after post-exit shortcut press',
	).toEqual([]);
});
