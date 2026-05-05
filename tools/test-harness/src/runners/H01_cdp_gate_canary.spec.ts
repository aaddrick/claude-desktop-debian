import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { createIsolation } from '../lib/isolation.js';

// H-prefix runners are HARNESS self-tests — they validate the test
// harness's preconditions and the build pipeline's invariants, distinct
// from T-tests (upstream test cases) and S-tests (doc-spec entries).
// They tend to be cheap (file probes, exit-code assertions) and exist
// to catch silent drift in the things our other tests assume.
//
// H01 — CDP auth gate canary.
//
// The whole L1 strategy (lib/electron.ts:96-110) hinges on the fact
// that the shipped Electron exits the app whenever
// `--remote-debugging-port` / `--remote-debugging-pipe` is on argv
// without a valid CLAUDE_CDP_AUTH token. If upstream removes that
// gate, every L1 test silently weakens — Playwright's
// `_electron.launch()` (which always injects --remote-debugging-port=0)
// would start working again, but our SIGUSR1-attach pathway would
// keep "passing" without exercising the contract it was built for.
//
// This canary spawns the bundled Electron directly with
// --remote-debugging-port=0 and NO auth token, then asserts the
// process exits with code 1 (the gate's `process.exit(1)` per
// lib/electron.ts:96-97) and was not killed by signal. Timeout
// without exit means the gate is gone.
//
// Spawn-only — no app stays running, no inspector attach, no
// X11 window probe. Pure exit-code observation under isolation
// so the host config never sees the failed launch.
//
// Row-independent: the gate's Linux behavior is the same on every
// row we ship to. Don't `skipUnlessRow`.

// DEFAULT_INSTALL_PATHS mirror lib/electron.ts:123-132 — kept inline
// rather than importing resolveInstall() so this canary can run even
// if a future change to electron.ts breaks the import surface (the
// canary should be the LEAST coupled spec to any moving part).
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

test.setTimeout(30_000);

test('H01 — CDP auth gate fires on --remote-debugging-port without token', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({ type: 'surface', description: 'CDP auth gate' });

	const { electron: electronBin, asar } = resolveInstallInline();
	const appDir = dirname(dirname(dirname(dirname(electronBin))));

	// Fresh isolation — the gate trips before any persisted state is
	// touched, but if anything sneaks past `process.exit(1)` we'd
	// rather it write to /tmp than ~/.config/Claude.
	const isolation = await createIsolation();
	const start = Date.now();

	// Raw spawn — no LAUNCHER_INJECTED_FLAGS, no isolation env beyond
	// what we set explicitly. The OPPOSITE of launchClaude(): we WANT
	// the debug-port flag on argv so the gate fires.
	const argv = [
		'--remote-debugging-port=0',
		asar,
	];

	// Build env: scrub CLAUDE_CDP_AUTH so a developer who set it
	// locally doesn't accidentally pass the gate. Keep the rest of
	// the parent env so Electron's normal load path (DISPLAY,
	// XDG_RUNTIME_DIR, etc.) still works up to the gate check.
	const env: Record<string, string> = {};
	for (const [k, v] of Object.entries(process.env)) {
		if (v !== undefined) env[k] = v;
	}
	delete env.CLAUDE_CDP_AUTH;
	for (const [k, v] of Object.entries(isolation.env)) {
		env[k] = v;
	}

	const proc = spawn(electronBin, argv, {
		cwd: appDir,
		env,
		stdio: 'ignore',
		detached: false,
	});

	let exitCode: number | null = null;
	let signalCode: NodeJS.Signals | null = null;
	let timedOut = false;

	try {
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
				}, 10_000);
			}),
		]);
	} finally {
		// If the gate didn't fire we have a live Electron — kill it
		// hard so the test environment isn't polluted by a running
		// app pointed at the host's display.
		if (proc.exitCode === null && proc.signalCode === null) {
			proc.kill('SIGKILL');
			await new Promise<void>((resolve) => {
				proc.once('exit', () => resolve());
				setTimeout(() => resolve(), 2_000);
			});
		}
		await isolation.cleanup();
	}

	const elapsedMs = Date.now() - start;

	await testInfo.attach('spawn-argv', {
		body: JSON.stringify([electronBin, ...argv], null, 2),
		contentType: 'application/json',
	});
	await testInfo.attach('exit-info', {
		body: JSON.stringify(
			{
				exitCode,
				signalCode,
				timedOut,
				elapsedMs,
				note:
					'Gate fires via process.exit(1) (lib/electron.ts:96-107). ' +
					'exitCode=1, signalCode=null is the canonical signature.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	if (timedOut) {
		throw new Error(
			'CDP gate did not fire — app stayed running with ' +
				'--remote-debugging-port flag and no auth token, gate may ' +
				'have been removed (lib/electron.ts:96-107). The L1 test ' +
				'strategy depends on this gate being present.',
		);
	}

	expect(
		exitCode,
		'gate exits with code 1 (process.exit(1) in index.pre.js)',
	).toBe(1);
	expect(
		signalCode,
		'process exited via gate, not killed by signal',
	).toBe(null);
});
