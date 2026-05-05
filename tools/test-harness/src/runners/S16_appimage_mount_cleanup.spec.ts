import { test, expect } from '@playwright/test';
import { spawn, execFile } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { open, mkdtemp, rm } from 'node:fs/promises';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { retryUntil, sleep } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

const exec = promisify(execFile);

// S16 — AppImage mount cleans up on app exit.
//
// Per docs/testing/cases/distribution.md S16: launching the AppImage
// produces a `/tmp/.mount_claude*` FUSE mount; quitting cleanly should
// remove it. CLAUDE.md "Common Gotchas" documents
// `pkill -9 -f "mount_claude"` as the manual recovery for stale mounts
// after force-quit. The case-doc anchor notes mount lifecycle is owned
// by upstream `appimagetool`'s runtime, not this repo — we assert
// upstream behaviour as a regression detector.
//
// IMPORTANT — `lib/electron.ts:launchClaude()` bypasses the AppImage
// runtime: it spawns the bundled Electron binary directly with
// `app.asar` as an argument (see electron.ts:312-328 + DEFAULT_INSTALL_
// PATHS at :157-166), so no FUSE mount ever appears. Using launchClaude
// here would make the test trivially pass on any host. To exercise the
// real `appimagetool` runtime + FUSE mount path, we spawn the AppImage
// directly via `child_process.spawn`, the same shape as S01.
//
// Readiness signal: rather than waiting for an X11 window (the AppImage
// re-execs itself + spawns Electron children, so `_NET_WM_PID` matching
// against our spawn pid is unreliable), we poll for the `.mount_claude`
// entry to appear in `mount(8)` output — the FUSE mount is the runtime's
// first user-visible side-effect and happens within ~100ms on a healthy
// host. That same signal is what we ultimately assert on, so it
// double-duties as readiness + the post-launch baseline-delta.

const MOUNT_TOKEN = '.mount_claude';

interface AppImageProbeResult {
	path: string | null;
	reason: string;
}

// Mirrors S01's probe: AppImages are ELF executables with the
// `AI\x02` (type 2) or `AI\x01` (type 1) magic at offset 8.
async function probeAppImagePath(): Promise<AppImageProbeResult> {
	const explicit = process.env.CLAUDE_DESKTOP_LAUNCHER;
	const candidates: string[] = [];
	if (explicit) candidates.push(explicit);

	const projectRoot = '/home/aaddrick/source/claude-desktop-debian';
	const testBuildDir = `${projectRoot}/test-build`;
	if (existsSync(testBuildDir)) {
		try {
			const fs = await import('node:fs/promises');
			const entries = await fs.readdir(testBuildDir);
			for (const entry of entries) {
				if (entry.endsWith('.AppImage')) {
					candidates.push(`${testBuildDir}/${entry}`);
				}
			}
		} catch {
			// best-effort
		}
	}

	for (const candidate of candidates) {
		if (!existsSync(candidate)) continue;
		try {
			const st = statSync(candidate);
			if (!st.isFile()) continue;
			if (candidate.endsWith('.AppImage')) {
				return { path: candidate, reason: 'matched .AppImage suffix' };
			}
			const fh = await open(candidate, 'r');
			try {
				const buf = Buffer.alloc(12);
				await fh.read(buf, 0, 12, 0);
				const elf = buf.subarray(0, 4).toString('hex') === '7f454c46';
				const aiMagic = buf.subarray(8, 11);
				const isAppImage =
					elf &&
					aiMagic[0] === 0x41 &&
					aiMagic[1] === 0x49 &&
					(aiMagic[2] === 0x01 || aiMagic[2] === 0x02);
				if (isAppImage) {
					return {
						path: candidate,
						reason: 'matched AppImage magic bytes',
					};
				}
			} finally {
				await fh.close();
			}
		} catch {
			// fall through
		}
	}

	return {
		path: null,
		reason:
			'no AppImage found via CLAUDE_DESKTOP_LAUNCHER or ' +
			`${testBuildDir}/*.AppImage`,
	};
}

interface MountSnapshot {
	count: number;
	lines: string[];
}

async function snapshotClaudeMounts(): Promise<MountSnapshot> {
	const { stdout } = await exec('mount', [], { timeout: 5_000 });
	const lines = stdout
		.split('\n')
		.filter((line) => line.includes(MOUNT_TOKEN));
	return { count: lines.length, lines };
}

test.setTimeout(60_000);

test('S16 — AppImage mount cleans up on app exit', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / AppImage mount',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const probe = await probeAppImagePath();
	await testInfo.attach('appimage-probe', {
		body: JSON.stringify(probe, null, 2),
		contentType: 'application/json',
	});

	if (!probe.path) {
		test.skip(true, `S16 only applies to AppImage installs: ${probe.reason}`);
		return;
	}

	const appimagePath = probe.path;

	// Baseline: any pre-existing claude mounts on this host. Should be
	// zero on a clean host, but if a previous run leaked a mount we
	// want to delta against it rather than fail spuriously here.
	const baseline = await snapshotClaudeMounts();
	await testInfo.attach('baseline-mounts', {
		body: JSON.stringify(baseline, null, 2),
		contentType: 'application/json',
	});

	// Per-test sandbox so the briefly-launched Electron child doesn't
	// pollute the host's ~/.config/Claude. Same shape as S01 — we
	// can't use launchClaude()'s isolation because it bypasses the
	// AppImage runtime altogether.
	const sandboxRoot = await mkdtemp(join(tmpdir(), 'claude-s16-'));
	const sandboxConfig = join(sandboxRoot, 'config');
	const sandboxHome = join(sandboxRoot, 'home');

	let postLaunch: MountSnapshot | null = null;
	let postClose: MountSnapshot | null = null;
	let newMountLines: string[] = [];
	let proc: ReturnType<typeof spawn> | null = null;
	let cleanShutdown = false;

	try {
		proc = spawn(appimagePath, [], {
			cwd: sandboxRoot,
			env: {
				...process.env,
				HOME: sandboxHome,
				XDG_CONFIG_HOME: sandboxConfig,
				XDG_DATA_HOME: join(sandboxRoot, 'data'),
				XDG_CACHE_HOME: join(sandboxRoot, 'cache'),
			},
			stdio: ['ignore', 'ignore', 'ignore'],
			detached: false,
		});

		if (!proc.pid) {
			throw new Error('Failed to spawn AppImage — no pid');
		}

		// Wait for the FUSE mount to appear. retryUntil polls every
		// 200ms; on a healthy host the mount lands in <500ms. 15s is
		// generous slack for slow VMs / heavily-loaded hosts.
		const mountAppeared = await retryUntil(
			async () => {
				const snap = await snapshotClaudeMounts();
				const fresh = snap.lines.filter(
					(line) => !baseline.lines.includes(line),
				);
				return fresh.length > 0 ? snap : null;
			},
			{ timeout: 15_000, interval: 200 },
		);

		if (!mountAppeared) {
			// Capture diagnostics before bailing — same shape we'd
			// attach on the assertion failure path.
			postLaunch = await snapshotClaudeMounts();
			await testInfo.attach('post-launch-mounts', {
				body: JSON.stringify(postLaunch, null, 2),
				contentType: 'application/json',
			});
			throw new Error(
				`AppImage runtime did not produce a ${MOUNT_TOKEN} mount ` +
					`within 15s of spawn. Either the runtime failed (check ` +
					`for libfuse2 — see S01) or upstream changed the mount ` +
					`token.`,
			);
		}

		postLaunch = mountAppeared;
		newMountLines = postLaunch.lines.filter(
			(line) => !baseline.lines.includes(line),
		);
		await testInfo.attach('post-launch-mounts', {
			body: JSON.stringify(
				{
					...postLaunch,
					newSinceBaseline: newMountLines,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		// Case-doc step 2: "Quit the app cleanly". `app.close()`-style
		// SIGTERM to the AppImage process. Per CLAUDE.md "Common
		// Gotchas", killing only the main proc may leave Electron
		// children alive holding the mount — so we follow the SIGTERM
		// with a `pkill -f mount_claude` SIGKILL backstop if the mount
		// hasn't unwound after the settle window.
		proc.kill('SIGTERM');
		await Promise.race([
			new Promise<void>((resolve) => {
				proc!.once('exit', () => resolve());
			}),
			sleep(8_000),
		]);
		cleanShutdown = proc.exitCode !== null || proc.signalCode !== null;
	} finally {
		// Whatever happened above, force-clear any leftover claude
		// processes so the next test starts clean. This mirrors the
		// `pkill -9 -f "mount_claude"` recovery from CLAUDE.md.
		if (proc && proc.exitCode === null && proc.signalCode === null) {
			try {
				proc.kill('SIGKILL');
			} catch {
				// already dead
			}
		}
		try {
			await exec('pkill', ['-9', '-f', 'mount_claude'], {
				timeout: 5_000,
			});
		} catch {
			// pkill exits 1 when nothing matches — that's the success
			// case for cleanup (the SIGTERM path already worked).
		}
		await rm(sandboxRoot, { recursive: true, force: true }).catch(() => {});
	}

	// Post-close: poll for the mount to disappear. Upstream's runtime
	// unmounts on its own when all children exit; the case-doc gives
	// it ~10s. retryUntil with 200ms polls keeps the typical-case
	// settle to ~500ms while leaving headroom for slow hosts.
	const cleanedUp = await retryUntil(
		async () => {
			const snap = await snapshotClaudeMounts();
			const lingering = snap.lines.filter(
				(line) => !baseline.lines.includes(line),
			);
			return lingering.length === 0 ? snap : null;
		},
		{ timeout: 10_000, interval: 200 },
	);

	postClose = cleanedUp ?? (await snapshotClaudeMounts());
	const lingeringMounts = postClose.lines.filter(
		(line) => !baseline.lines.includes(line),
	);

	await testInfo.attach('post-close-mounts', {
		body: JSON.stringify(
			{
				...postClose,
				lingeringSinceBaseline: lingeringMounts,
				cleanShutdown,
				note:
					'Lingering mounts after SIGTERM + 10s settle indicate the ' +
					'AppImage runtime did not unmount on child exit. CLAUDE.md ' +
					'documents `pkill -9 -f "mount_claude"` as the manual ' +
					'recovery; this test asserts that the recovery path is ' +
					'NOT needed for a clean SIGTERM shutdown.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		newMountLines.length,
		`AppImage spawn should produce at least one new ${MOUNT_TOKEN} mount ` +
			`(baseline ${baseline.count}, post-launch ${postLaunch?.count ?? 0})`,
	).toBeGreaterThan(0);

	expect(
		lingeringMounts,
		`No ${MOUNT_TOKEN} mount should linger after app exit + 10s settle. ` +
			`Stale mounts indicate the upstream appimagetool runtime's ` +
			`unmount-on-exit handler did not fire (or an Electron child is ` +
			`still alive holding the mount — see CLAUDE.md "Killing the app" ` +
			`gotcha).`,
	).toEqual([]);
});
