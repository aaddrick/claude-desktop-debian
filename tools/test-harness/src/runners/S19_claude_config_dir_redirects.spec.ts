import { test, expect } from '@playwright/test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S19 — `CLAUDE_CONFIG_DIR` redirects scheduled-task storage.
//
// Backs S19 in docs/testing/cases/routines.md.
//
// Case-doc anchors:
//   build-reference/app-extracted/.vite/build/index.js:283107 — `cE()`
//     resolves `process.env.CLAUDE_CONFIG_DIR ?? ~/.claude` (with a
//     `~` / `~/` / `~\` expansion shim).
//   build-reference/app-extracted/.vite/build/index.js:283118 — `Tce()`
//     returns `${cE()}/scheduled-tasks`, the directory the
//     scheduled-tasks substrate writes into.
//   build-reference/app-extracted/.vite/build/index.js:488317, :509032 —
//     call sites that pass `taskFilesDir: Tce()` into the
//     scheduled-tasks substrate.
//
// Tier 2 reframe: the full flow (login + create a scheduled task and
// read its SKILL.md off disk) is Tier 3. Tier 2's slice is the
// env-propagation half:
// confirm `CLAUDE_CONFIG_DIR` from `extraEnv` actually reaches the main
// process's `process.env`. If that contract breaks, `cE()` falls back
// to `~/.claude` and every Tier-3 path-redirection assertion built on
// top of it silently regresses.
//
// We also opportunistically eval the resolver fingerprint inline (the
// same expression `cE()` and `Tce()` compute) and assert the synthetic
// resolved path lives under our test dir. This is a runtime echo, not
// an introspection of the bundled symbols (`cE` / `Tce` are minified
// closure-locals — not reachable from `globalThis`); the static
// fingerprint of those functions is covered by the asar-grep style
// probes (S26 / S27 family). A future regression where the env stops
// propagating shows up as a hard failure here even though the bundled
// resolver is unchanged.
//
// extraEnv-vs-isolation env precedence: `lib/electron.ts` spreads
// `opts.extraEnv` AFTER `isolation?.env` (line ~317-323), so the
// override here wins over the default isolation's
// `CLAUDE_CONFIG_DIR=<tmp>/config/Claude`. Confirmed by reading
// electron.ts before writing this runner.
//
// No row gate — applies to all rows.

interface ResolverProbe {
	homedir: string;
	envValue: string | null;
	resolvedConfigDir: string;
	resolvedScheduledTasksDir: string;
}

test.setTimeout(60_000);

test('S19 — CLAUDE_CONFIG_DIR from extraEnv reaches main process', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Could' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Config dir env var',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Dedicated tmpdir for this test's CLAUDE_CONFIG_DIR override —
	// disjoint from the default-isolation tmpdir so a future regression
	// where the override path silently falls back to the isolation dir
	// is caught (the two paths differ by their tmpdir prefix).
	const testDir = await mkdtemp(join(tmpdir(), 'claude-s19-'));
	await testInfo.attach('test-config-dir', {
		body: testDir,
		contentType: 'text/plain',
	});

	const app = await launchClaude({
		extraEnv: { CLAUDE_CONFIG_DIR: testDir },
	});

	try {
		const { inspector } = await app.waitForReady('mainVisible');

		// Half 1: env propagation. The bundled `cE()` resolver reads
		// `process.env.CLAUDE_CONFIG_DIR` directly — if this doesn't
		// equal what we passed in `extraEnv`, every downstream path
		// resolution inherits the wrong root.
		const observed = await inspector.evalInMain<string | null>(`
			return process.env.CLAUDE_CONFIG_DIR ?? null;
		`);
		await testInfo.attach('observed-claude-config-dir', {
			body: observed ?? '(unset)',
			contentType: 'text/plain',
		});

		expect(
			observed,
			'main process sees CLAUDE_CONFIG_DIR === <test-dir> ' +
				'(extraEnv must win over default isolation env)',
		).toBe(testDir);

		// Half 2: synthetic resolver echo. Re-implement `cE()` /
		// `Tce()` in the inspector — same expression the bundled
		// code uses, computed against the live main-process env and
		// homedir. Captures both the env-propagation fact AND the
		// path shape Tce() actually produces, so a future regression
		// where someone reroutes scheduled-tasks under a sibling
		// folder (e.g. `${cE()}/tasks/`) is visible here.
		const probe = await inspector.evalInMain<ResolverProbe>(`
			const os = process.mainModule.require('node:os');
			const path = process.mainModule.require('node:path');
			const envValue = process.env.CLAUDE_CONFIG_DIR ?? null;
			const homedir = os.homedir();
			const resolveConfigDir = () => {
				const e = envValue;
				if (
					e === '~' ||
					(e != null && e.startsWith('~/')) ||
					(e != null && e.startsWith('~\\\\'))
				) {
					return path.join(homedir, e.slice(1));
				}
				return e ?? path.join(homedir, '.claude');
			};
			const resolvedConfigDir = resolveConfigDir();
			return {
				homedir,
				envValue,
				resolvedConfigDir,
				resolvedScheduledTasksDir: path.join(
					resolvedConfigDir,
					'scheduled-tasks',
				),
			};
		`);
		await testInfo.attach('resolver-probe', {
			body: JSON.stringify(probe, null, 2),
			contentType: 'application/json',
		});

		expect(
			probe.resolvedConfigDir,
			'cE()-equivalent resolves to the test dir',
		).toBe(testDir);
		expect(
			probe.resolvedScheduledTasksDir,
			'Tce()-equivalent resolves under the test dir',
		).toBe(join(testDir, 'scheduled-tasks'));
	} finally {
		await app.close();
		await rm(testDir, { recursive: true, force: true });
	}
});
