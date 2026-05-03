import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
	runDoctor,
	captureSessionEnv,
} from '../lib/diagnostics.js';

const exec = promisify(execFile);

// T13 — Doctor reports correct package format.
//
// Per docs/testing/cases/launch.md T13 (mirror surface: S05 in
// distribution.md): on RPM-based distros, `claude-desktop --doctor`
// must NOT print `not found via dpkg (AppImage?)` for a copy that
// rpm owns. The doctor script's install-method probe is dpkg-only
// (scripts/doctor.sh — the `command -v dpkg-query` block around the
// `Installed version:` PASS / `not found via dpkg (AppImage?)` WARN
// emit; case-doc anchors that as :290-299 but the actual lines are
// :353-360 in the version of doctor.sh checked at runner-write time
// — see case-doc anchor drift note in the report). There is no
// corresponding `rpm -qf` / `rpm -q claude-desktop` branch, so a
// dnf-installed copy on a host that also has `dpkg-query` available
// will false-flag.
//
// Applies to all rows in principle, but the assertion only has
// signal when we can (a) reach `claude-desktop` on PATH and (b)
// detect an actual install method. AppImage rows and rows where the
// launcher isn't reachable get cleanly skipped — the case-doc says
// no skipUnlessRow(), but install-method-undetectable is its own
// skip condition.
//
// Layer: spawn probe + stdout grep. We shell out to `which`, then
// `rpm -qf` and `dpkg -S` against the resolved path — whichever
// returns 0 is the install method. If both fail the binary is not
// package-managed (treat as AppImage / hand-built; skip). If both
// succeed (mixed Debian + RPM tooling host), we still treat it as
// rpm-owned for the assertion shape: the warning we're guarding
// against is "false-flag as AppImage", which can only fire when
// dpkg returns empty.

const FALSE_FLAG_FRAGMENT =
	'not found via dpkg (AppImage?)';

interface ProbeResult {
	cmd: string;
	exitCode: number | null;
	stdout: string;
	stderr: string;
}

async function probe(
	bin: string,
	args: string[],
): Promise<ProbeResult> {
	const cmd = `${bin} ${args.join(' ')}`;
	try {
		const { stdout, stderr } = await exec(bin, args, {
			timeout: 5_000,
		});
		return {
			cmd,
			exitCode: 0,
			stdout: stdout.trim(),
			stderr: stderr.trim(),
		};
	} catch (err) {
		const e = err as {
			stdout?: string;
			stderr?: string;
			code?: number;
		};
		return {
			cmd,
			exitCode: typeof e.code === 'number' ? e.code : null,
			stdout: (e.stdout ?? '').trim(),
			stderr: (e.stderr ?? '').trim(),
		};
	}
}

function formatProbe(p: ProbeResult): string {
	const tail = [
		p.stdout && `stdout: ${p.stdout}`,
		p.stderr && `stderr: ${p.stderr}`,
	]
		.filter(Boolean)
		.join('\n');
	return `$ ${p.cmd} (exit ${p.exitCode ?? '?'})\n${tail}`.trim();
}

type InstallMethod = 'rpm' | 'deb' | 'unknown';

test('T13 — Doctor identifies package format correctly', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Should',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'CLI / --doctor',
	});

	// Applies to all rows per case-doc — no skipUnlessRow().

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const launcher =
		process.env.CLAUDE_DESKTOP_LAUNCHER ?? 'claude-desktop';
	const whichProbe = await probe('which', [launcher]);
	await testInfo.attach('which-claude-desktop', {
		body: formatProbe(whichProbe),
		contentType: 'text/plain',
	});

	const installPath = whichProbe.stdout.split('\n')[0]?.trim() ?? '';
	if (whichProbe.exitCode !== 0 || !installPath) {
		// No claude-desktop on PATH (and CLAUDE_DESKTOP_LAUNCHER
		// either unset or pointing somewhere `which` can't resolve).
		// Without a real binary path we can't probe rpm/dpkg, so skip
		// — runDoctor() would still spawn, but the assertion
		// has no signal.
		test.skip(
			true,
			`claude-desktop not reachable on PATH ` +
				`(launcher='${launcher}'); install-method probe ` +
				`needs a resolvable binary`,
		);
		return;
	}

	const rpmProbe = await probe('rpm', ['-qf', installPath]);
	const dpkgProbe = await probe('dpkg', ['-S', installPath]);
	await testInfo.attach('rpm-qf', {
		body: formatProbe(rpmProbe),
		contentType: 'text/plain',
	});
	await testInfo.attach('dpkg-S', {
		body: formatProbe(dpkgProbe),
		contentType: 'text/plain',
	});

	let method: InstallMethod;
	if (rpmProbe.exitCode === 0) {
		// rpm-owned. If dpkg-S also returned 0 (mixed-tooling host
		// like a Fedora box with dpkg installed for cross-distro
		// dev), we still assert the rpm shape — the false-flag
		// warning can only fire when dpkg-query comes up empty for
		// `claude-desktop`. If both tools claim ownership the
		// assertion still passes against `not found via dpkg`,
		// which is what the case-doc cares about.
		method = 'rpm';
	} else if (dpkgProbe.exitCode === 0) {
		method = 'deb';
	} else {
		method = 'unknown';
	}
	await testInfo.attach('detected-install-method', {
		body: method,
		contentType: 'text/plain',
	});

	if (method === 'unknown') {
		// Neither rpm nor dpkg owns the binary — AppImage extract,
		// hand-built install, or symlink to a mounted AppImage.
		// Doctor's dpkg-only probe has nothing to assert against
		// here; the "package format" question doesn't apply.
		test.skip(
			true,
			`install method undetectable: rpm -qf and dpkg -S both ` +
				`returned non-zero against ${installPath} ` +
				`(AppImage / hand-built / non-package-managed)`,
		);
		return;
	}

	const result = await runDoctor(launcher);
	await testInfo.attach('doctor-output', {
		body: result.output,
		contentType: 'text/plain',
	});
	await testInfo.attach('doctor-exit-code', {
		body: String(result.exitCode),
		contentType: 'text/plain',
	});

	if (method === 'rpm') {
		// Core T13 / S05 assertion. On a Fedora row this currently
		// fails — there's no rpm branch in scripts/doctor.sh, so
		// either the dpkg-only block is skipped (no install-method
		// line printed at all) or — on hosts with dpkg-query
		// installed but no dpkg record for claude-desktop — the
		// false-flag warning fires. The latter is what we guard
		// against: the warning's literal text must not appear.
		expect(
			result.output,
			`doctor must not false-flag rpm install as AppImage ` +
				`(stdout contained '${FALSE_FLAG_FRAGMENT}')`,
		).not.toContain(FALSE_FLAG_FRAGMENT);
	} else {
		// method === 'deb'. The dpkg-query branch should have
		// produced an `Installed version:` PASS, not the AppImage
		// false-flag. Assert the PASS path; if doctor instead
		// printed the WARN despite dpkg owning the binary that's
		// the deb-side regression of the same bug.
		expect(
			result.output,
			`doctor must not warn 'not found via dpkg' for a ` +
				`dpkg-installed copy at ${installPath}`,
		).not.toContain(FALSE_FLAG_FRAGMENT);
	}
});
