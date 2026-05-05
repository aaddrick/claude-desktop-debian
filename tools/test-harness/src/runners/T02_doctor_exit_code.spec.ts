import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
	runDoctor,
	captureSessionEnv,
} from '../lib/diagnostics.js';

const exec = promisify(execFile);

// T02 — Doctor health check.
//
// Run `claude-desktop --doctor` and assert exit code === 0. Per the
// case-doc (docs/testing/cases/launch.md T02): all checks should
// PASS / WARN with no FAIL, and the launcher exits 0. This is a
// short-lived spawn probe — `runDoctor()` shells out under a
// 15s timeout and returns `{ output, exitCode }` without touching
// the host's main app instance (doctor is a `--doctor`-gated branch
// that prints and exits, not a full Electron launch).
//
// Applies to all rows. No `skipUnlessRow()` — the doctor script
// (scripts/doctor.sh) runs identically on every distribution we
// ship (deb/rpm/AppImage); a row-specific FAIL there is a real T02
// failure, not a "doesn't apply" skip.
//
// Diagnostics on failure (per case-doc): full --doctor output, the
// install path (`which claude-desktop`), and package metadata
// (`dpkg -S` / `rpm -qf` against the binary). The output and session
// env are attached unconditionally; the locate / package-metadata
// probes only run when the assertion is about to fail, since they're
// noisy and only useful for triage.

async function captureWhich(bin: string): Promise<string> {
	try {
		const { stdout } = await exec('which', [bin], { timeout: 5_000 });
		return stdout.trim();
	} catch (err) {
		const e = err as { stdout?: string; stderr?: string; code?: number };
		return (
			`which exited ${e.code ?? '?'}\n` +
			`stdout: ${e.stdout ?? ''}\n` +
			`stderr: ${e.stderr ?? ''}`
		).trim();
	}
}

async function capturePackageMetadata(path: string): Promise<string> {
	if (!path) return 'no install path resolved';
	const lines: string[] = [];
	for (const cmd of [
		['dpkg', ['-S', path]],
		['rpm', ['-qf', path]],
	] as [string, string[]][]) {
		try {
			const { stdout, stderr } = await exec(cmd[0], cmd[1], {
				timeout: 5_000,
			});
			lines.push(
				`$ ${cmd[0]} ${cmd[1].join(' ')}\n` +
					`${stdout.trim()}${stderr.trim() ? `\n${stderr.trim()}` : ''}`,
			);
		} catch (err) {
			const e = err as {
				stdout?: string;
				stderr?: string;
				code?: number;
			};
			lines.push(
				`$ ${cmd[0]} ${cmd[1].join(' ')} (exit ${e.code ?? '?'})\n` +
					`${(e.stdout ?? '').trim()}\n` +
					`${(e.stderr ?? '').trim()}`.trim(),
			);
		}
	}
	return lines.join('\n\n');
}

test('T02 — Doctor exit code is 0', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'CLI / --doctor',
	});

	// Applies to all rows — no skipUnlessRow.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const result = await runDoctor();

	await testInfo.attach('doctor-output', {
		body: result.output,
		contentType: 'text/plain',
	});
	await testInfo.attach('doctor-exit-code', {
		body: String(result.exitCode),
		contentType: 'text/plain',
	});

	if (result.exitCode !== 0) {
		const launcher =
			process.env.CLAUDE_DESKTOP_LAUNCHER ?? 'claude-desktop';
		const whichOut = await captureWhich(launcher);
		await testInfo.attach('which-claude-desktop', {
			body: whichOut,
			contentType: 'text/plain',
		});

		// First line of `which` output is the resolved path; pass that
		// to dpkg/rpm so package-metadata reflects what doctor actually
		// inspected.
		const installPath = whichOut.split('\n')[0]?.trim() ?? '';
		const pkgMeta = await capturePackageMetadata(installPath);
		await testInfo.attach('package-metadata', {
			body: pkgMeta,
			contentType: 'text/plain',
		});
	}

	expect(result.exitCode, 'doctor exits with code 0').toBe(0);
});
