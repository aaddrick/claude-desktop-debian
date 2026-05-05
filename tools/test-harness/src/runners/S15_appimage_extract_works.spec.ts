import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { mkdtemp, open, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// S15 — AppImage `--appimage-extract` fallback works as documented.
//
// Per docs/testing/cases/distribution.md S15: on FUSE-less hosts the
// AppImage runtime ships an extract fallback. Running the AppImage
// with `--appimage-extract` should drop a `squashfs-root/` next to
// CWD with a working `AppRun` inside, runnable without FUSE. The
// case-doc anchors point at scripts/packaging/appimage.sh:282/:312
// (built with stock `appimagetool`, which always supports
// `--appimage-extract`) and the AppRun script at
// scripts/packaging/appimage.sh:70-118; CI exercises the same path
// (tests/test-artifact-appimage.sh:36-44).
//
// Assertion shape:
//   1. Locate an AppImage. Skip cleanly if not running from one.
//   2. mkdtemp a work dir, spawn `<AppImage> --appimage-extract` with
//      that dir as CWD. Assert exit 0.
//   3. Assert `squashfs-root/AppRun` exists.
//   4. Spawn `squashfs-root/AppRun --version` with a 5s timeout. The
//      case-doc accepts "exit 0 or doesn't immediately fail" — we
//      treat anything that didn't crash with a FUSE/dlopen error
//      within the window as a pass; clean exit 0 is the strongest
//      signal.
//   5. rm the extracted tree in `finally`.
//
// AppImage detection mirrors S01's inline probe (probe
// CLAUDE_DESKTOP_LAUNCHER, fall back to <repo>/test-build/*.AppImage,
// verify ELF magic + AppImage type marker). Inline rather than
// extracted to a shared lib — only two callers today, and the
// canary-style runners benefit from being decoupled from moving
// helper surfaces.

interface AppImageProbeResult {
	path: string | null;
	reason: string;
}

// AppImages are ELF executables containing a squashfs image with a
// magic header at offset 8: `AI\x02` for type 2 (the format our build
// emits) or `AI\x01` for type 1.
async function probeAppImagePath(): Promise<AppImageProbeResult> {
	const explicit = process.env.CLAUDE_DESKTOP_LAUNCHER;
	const candidates: string[] = [];
	if (explicit) candidates.push(explicit);

	const projectRoot = '/home/aaddrick/source/claude-desktop-debian';
	const testBuildDir = `${projectRoot}/test-build`;
	if (existsSync(testBuildDir)) {
		try {
			const entries = await readdir(testBuildDir);
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
			// fall through to next candidate
		}
	}

	return {
		path: null,
		reason:
			'no AppImage found via CLAUDE_DESKTOP_LAUNCHER or ' +
			`${testBuildDir}/*.AppImage`,
	};
}

interface SpawnResult {
	exitCode: number | null;
	signalCode: NodeJS.Signals | null;
	stdout: string;
	stderr: string;
	timedOut: boolean;
	elapsedMs: number;
}

async function runWithTimeout(
	cmd: string,
	args: string[],
	cwd: string,
	timeoutMs: number,
): Promise<SpawnResult> {
	const start = Date.now();
	const proc = spawn(cmd, args, {
		cwd,
		env: process.env,
		stdio: ['ignore', 'pipe', 'pipe'],
		detached: false,
	});

	const stdoutChunks: Buffer[] = [];
	const stderrChunks: Buffer[] = [];
	proc.stdout?.on('data', (c: Buffer) => stdoutChunks.push(c));
	proc.stderr?.on('data', (c: Buffer) => stderrChunks.push(c));

	let exitCode: number | null = null;
	let signalCode: NodeJS.Signals | null = null;
	let timedOut = false;

	await Promise.race([
		new Promise<void>((resolve) => {
			proc.once('exit', (code, signal) => {
				exitCode = code;
				signalCode = signal;
				resolve();
			});
		}),
		new Promise<void>((resolve) => {
			setTimeout(() => {
				timedOut = true;
				resolve();
			}, timeoutMs);
		}),
	]);

	if (proc.exitCode === null && proc.signalCode === null) {
		proc.kill('SIGTERM');
		await Promise.race([
			new Promise<void>((resolve) =>
				proc.once('exit', (code, signal) => {
					exitCode = code;
					signalCode = signal;
					resolve();
				}),
			),
			new Promise<void>((resolve) => setTimeout(resolve, 2_000)),
		]);
		if (proc.exitCode === null && proc.signalCode === null) {
			proc.kill('SIGKILL');
			await new Promise<void>((resolve) => {
				proc.once('exit', (code, signal) => {
					exitCode = code;
					signalCode = signal;
					resolve();
				});
				setTimeout(() => resolve(), 1_000);
			});
		}
	}

	return {
		exitCode,
		signalCode,
		stdout: Buffer.concat(stdoutChunks).toString('utf8'),
		stderr: Buffer.concat(stderrChunks).toString('utf8'),
		timedOut,
		elapsedMs: Date.now() - start,
	};
}

function tail(s: string, n: number): string {
	if (s.length <= n) return s;
	return s.slice(-n);
}

test.setTimeout(60_000);

test('S15 — AppImage --appimage-extract fallback works', async ({}, testInfo) => {
	// Case-doc S15 lists Severity: Could. Surface label is the harness
	// taxonomy ("Distribution / AppImage extract") rather than the
	// case-doc's free-text "AppImage runtime / FUSE-less fallback".
	testInfo.annotations.push({ type: 'severity', description: 'Could' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / AppImage extract',
	});

	const probe = await probeAppImagePath();
	await testInfo.attach('appimage-probe', {
		body: JSON.stringify(probe, null, 2),
		contentType: 'application/json',
	});

	if (!probe.path) {
		test.skip(true, `S15 only applies to AppImage installs: ${probe.reason}`);
		return;
	}

	const appImagePath = probe.path;
	await testInfo.attach('appimage-path', {
		body: appImagePath,
		contentType: 'text/plain',
	});

	// mkdtemp so the extract tree lands in $TMPDIR, not the harness
	// CWD. `--appimage-extract` writes `squashfs-root/` relative to
	// CWD, so we just spawn with cwd = the temp dir.
	const extractDir = await mkdtemp(join(tmpdir(), 'claude-s15-'));
	const squashRoot = join(extractDir, 'squashfs-root');
	const appRun = join(squashRoot, 'AppRun');

	await testInfo.attach('extract-dir', {
		body: extractDir,
		contentType: 'text/plain',
	});

	try {
		// Step 1: extraction. 30s budget — extracting ~200MB of
		// squashfs to disk is well under that on any modern host.
		const extract = await runWithTimeout(
			appImagePath,
			['--appimage-extract'],
			extractDir,
			30_000,
		);

		await testInfo.attach('extract-exit', {
			body: JSON.stringify(
				{
					exitCode: extract.exitCode,
					signalCode: extract.signalCode,
					timedOut: extract.timedOut,
					elapsedMs: extract.elapsedMs,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
		await testInfo.attach('extract-stderr-tail-4k', {
			body: tail(extract.stderr, 4096) || '(empty)',
			contentType: 'text/plain',
		});
		await testInfo.attach('extract-stdout-tail-4k', {
			body: tail(extract.stdout, 4096) || '(empty)',
			contentType: 'text/plain',
		});

		expect(
			extract.exitCode,
			`AppImage --appimage-extract should exit 0 ` +
				`(stderr tail: ${tail(extract.stderr, 256)})`,
		).toBe(0);
		expect(
			extract.signalCode,
			'extraction process should not be killed by signal',
		).toBe(null);

		// Step 2: assert squashfs-root/AppRun exists.
		const appRunExists = existsSync(appRun);
		await testInfo.attach('apprun-exists', {
			body: JSON.stringify(
				{
					path: appRun,
					exists: appRunExists,
					squashfsRootExists: existsSync(squashRoot),
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
		expect(
			appRunExists,
			`squashfs-root/AppRun should exist after extract at ${appRun}`,
		).toBe(true);

		// Step 3: spawn `AppRun --version` with a 5s timeout. AppRun
		// is a wrapper script (scripts/packaging/appimage.sh:70-118)
		// that hands off to the real Electron entry — `--version`
		// is the cheapest probe that exercises the full launch path
		// without bringing up a window. The case-doc accepts "exit 0
		// or doesn't immediately fail"; a clean exit 0 is best, but
		// we also flag obvious FUSE / dlopen errors as failures.
		const apprun = await runWithTimeout(
			appRun,
			['--version'],
			squashRoot,
			5_000,
		);

		await testInfo.attach('apprun-exit', {
			body: JSON.stringify(
				{
					exitCode: apprun.exitCode,
					signalCode: apprun.signalCode,
					timedOut: apprun.timedOut,
					elapsedMs: apprun.elapsedMs,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
		await testInfo.attach('apprun-stderr-tail-4k', {
			body: tail(apprun.stderr, 4096) || '(empty)',
			contentType: 'text/plain',
		});
		await testInfo.attach('apprun-stdout-tail-4k', {
			body: tail(apprun.stdout, 4096) || '(empty)',
			contentType: 'text/plain',
		});

		// Hard fail on the cardinal "didn't run at all" patterns: a
		// FUSE / dlopen complaint here would mean the extract path
		// ALSO depends on FUSE (which would defeat its purpose).
		const stderrLower = apprun.stderr.toLowerCase();
		const fuseFailure =
			stderrLower.includes('libfuse.so.2') ||
			(stderrLower.includes('dlopen') && stderrLower.includes('fuse'));
		expect(
			fuseFailure,
			`AppRun --version stderr should not show a FUSE/dlopen ` +
				`failure (the extract fallback exists precisely to avoid ` +
				`FUSE). stderr tail: ${tail(apprun.stderr, 256)}`,
		).toBe(false);

		// Soft acceptance: exit 0 is canonical, but Electron's
		// `--version` printer can occasionally exit non-zero on Linux
		// when accessory subsystems (sandbox, dbus) are missing while
		// still printing the version. Accept exit 0 OR (timed-out
		// while still alive AND stdout shows a version string).
		const versionLooksOk =
			/\d+\.\d+\.\d+/.test(apprun.stdout) ||
			/\d+\.\d+\.\d+/.test(apprun.stderr);
		const acceptableNonZero = apprun.timedOut && versionLooksOk;
		expect(
			apprun.exitCode === 0 || acceptableNonZero,
			`AppRun --version should exit 0 or print a version before ` +
				`timeout. exit=${apprun.exitCode} signal=${apprun.signalCode} ` +
				`timedOut=${apprun.timedOut} ` +
				`stdoutHasVersion=${versionLooksOk}`,
		).toBe(true);
	} finally {
		await rm(extractDir, { recursive: true, force: true }).catch(() => {});
	}
});
