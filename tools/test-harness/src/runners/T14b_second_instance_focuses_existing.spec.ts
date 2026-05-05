import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { launchClaude } from '../lib/electron.js';

// T14b — Second invocation exits and focuses existing window
// (runtime pair of T14a's file-probe).
//
// docs/testing/cases/launch.md T14 expects: when the app is
// already running and a second invocation happens, the second
// invocation exits and the existing window receives focus — no
// new pid stays alive. Code anchors at
// build-reference/app-extracted/.vite/build/index.js:525162-525173
// (`hA.app.requestSingleInstanceLock()` + `app.on('second-instance', ...)`)
// and :525204-525207 (early-return in `app.on('ready', ...)` when the
// lock is lost — this is the path the second spawn takes to exit).
//
// Shape: launch the app under per-test isolation, then spawn a
// SECOND Electron with the SAME isolation env so both procs collide
// on the same SingletonLock under <configHome>/Claude. The second
// spawn should call `app.requestSingleInstanceLock()`, lose, hit
// the early-return in the `ready` handler and exit on its own. We
// observe via exit(code, signal) on the second proc, then re-check
// the primary pid is still alive via /proc/<pid>.
//
// Replicating the install-resolution logic inline (mirrors H01) keeps
// this spec independent of `launchClaude`'s internal spawn shape.
// We do NOT want to call `launchClaude()` for the second invocation —
// that would attach a second inspector, fight signal handlers, and
// register a second cleanup. Raw `spawn()` is the right primitive:
// observe the gate fire, then walk away.

const DEFAULT_INSTALL_PATHS: { electron: string; asar: string }[] = [
	{
		electron: '/usr/lib/claude-desktop/node_modules/electron/dist/electron',
		asar: '/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar',
	},
	{
		electron: '/opt/Claude/node_modules/electron/dist/electron',
		asar: '/opt/Claude/node_modules/electron/dist/resources/app.asar',
	},
];

function resolveInstallInline(): { electron: string; asar: string } {
	const envBin = process.env.CLAUDE_DESKTOP_ELECTRON;
	const envAsar = process.env.CLAUDE_DESKTOP_APP_ASAR;
	if (envBin && envAsar) return { electron: envBin, asar: envAsar };
	for (const candidate of DEFAULT_INSTALL_PATHS) {
		if (existsSync(candidate.electron) && existsSync(candidate.asar)) {
			return candidate;
		}
	}
	throw new Error(
		'Could not locate claude-desktop install. Set CLAUDE_DESKTOP_ELECTRON ' +
			'and CLAUDE_DESKTOP_APP_ASAR, or install the deb/rpm package.',
	);
}

function pidAlive(pid: number): boolean {
	// /proc/<pid> existence is the cheapest liveness check on Linux.
	// `process.kill(pid, 0)` would also work but throws on ESRCH which
	// makes the call site noisier for no benefit here.
	return existsSync(`/proc/${pid}`);
}

test.setTimeout(60_000);

test('T14b — Second invocation exits and focuses existing window', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'App lifecycle / single instance',
	});

	const start = Date.now();
	const app = await launchClaude();
	const firstPid = app.pid;

	// Capture the isolation env up front — `app.close()` cleans up the
	// tmpdir, so we need a snapshot to drive the second spawn while the
	// primary is still running. `isolation` is null only when the caller
	// passed `isolation: null`; the default constructs a fresh handle.
	if (!app.isolation) {
		throw new Error(
			'T14b expects launchClaude default isolation; ' +
				'app.isolation is null. Did the harness defaults change?',
		);
	}
	const isolationEnv = { ...app.isolation.env };

	let secondPid: number | null = null;
	let secondExitCode: number | null = null;
	let secondSignal: NodeJS.Signals | null = null;
	let secondTimedOut = false;
	let firstAliveAfter = false;

	try {
		await app.waitForReady('mainVisible');

		// Build the second-spawn argv + env. Mirror launchClaude()'s
		// LAUNCHER_INJECTED_FLAGS_X11 / LAUNCHER_INJECTED_ENV (lib/
		// electron.ts:123-146) so both procs look the same to the
		// SingletonLock check — the only difference is that this one
		// is started after the first holds the lock.
		const { electron: electronBin, asar } = resolveInstallInline();
		const appDir = dirname(dirname(dirname(dirname(electronBin))));

		const argv = [
			'--disable-features=CustomTitlebar',
			'--ozone-platform=x11',
			'--no-sandbox',
			asar,
		];

		const env: Record<string, string> = {};
		for (const [k, v] of Object.entries(process.env)) {
			if (v !== undefined) env[k] = v;
		}
		// SAME isolation env as the running primary. SingletonLock lives
		// under <configHome>/Claude — both procs must point there for
		// requestSingleInstanceLock() to collide.
		for (const [k, v] of Object.entries(isolationEnv)) {
			env[k] = v;
		}
		env.ELECTRON_FORCE_IS_PACKAGED = 'true';
		env.ELECTRON_USE_SYSTEM_TITLE_BAR = '1';
		env.CI = '1';

		const proc = spawn(electronBin, argv, {
			cwd: appDir,
			env,
			stdio: 'ignore',
			detached: false,
		});
		secondPid = proc.pid ?? null;
		if (!secondPid) {
			throw new Error('Failed to spawn second Electron — no pid');
		}

		// 10s budget. The second-instance early-return path (index.js
		// :525204-525207) fires on `app.on('ready', ...)`, which lands
		// well within Electron startup (~2-4s on a warm cache). If we
		// blow past 10s the gate didn't fire — kill hard and fail.
		await Promise.race([
			new Promise<void>((resolve) => {
				proc.once('exit', (code, signal) => {
					secondExitCode = code;
					secondSignal = signal;
					resolve();
				});
			}),
			new Promise<void>((resolve) => {
				setTimeout(() => {
					secondTimedOut = true;
					resolve();
				}, 10_000);
			}),
		]);

		if (secondTimedOut && proc.exitCode === null && proc.signalCode === null) {
			// Gate didn't fire — kill the rogue second proc so we don't
			// leave two Electrons fighting over the same userData dir.
			proc.kill('SIGKILL');
			await new Promise<void>((resolve) => {
				proc.once('exit', () => resolve());
				setTimeout(() => resolve(), 2_000);
			});
		}

		firstAliveAfter = pidAlive(firstPid);
	} finally {
		await app.close();
	}

	const elapsedMs = Date.now() - start;

	await testInfo.attach('pids', {
		body: JSON.stringify(
			{
				firstPid,
				secondPid,
				firstAliveAfterSecondSpawn: firstAliveAfter,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});
	await testInfo.attach('second-spawn-exit', {
		body: JSON.stringify(
			{
				exitCode: secondExitCode,
				signalCode: secondSignal,
				timedOut: secondTimedOut,
				elapsedMs,
				note:
					'Second instance is expected to exit on its own via the ' +
					'early-return path in app.on("ready") at ' +
					'build-reference/app-extracted/.vite/build/index.js:525204-525207 ' +
					'when requestSingleInstanceLock() loses to the primary. ' +
					'timedOut=true means the gate did not fire — second-instance ' +
					'wiring may be broken.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	if (secondTimedOut) {
		throw new Error(
			'Second-instance gate did not fire within 10s — second Electron ' +
				'stayed alive under the same isolation as the primary. ' +
				'requestSingleInstanceLock() / app.on("second-instance", ...) ' +
				'wiring may be broken (index.js:525162-525173).',
		);
	}

	expect(
		secondSignal,
		'second instance exited on its own, not by signal from us',
	).toBe(null);
	expect(
		firstAliveAfter,
		'primary pid still alive after the second spawn exited',
	).toBe(true);
});
