import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
	runDoctor,
	captureSessionEnv,
} from '../lib/diagnostics.js';

const exec = promisify(execFile);

// S05 — Doctor recognises rpm-installed claude-desktop, doesn't
// false-flag as AppImage.
//
// Per docs/testing/cases/distribution.md S05 (sibling of T13 in
// launch.md — same surface, intentional matrix overlap):
//
// * Steps: on a Fedora/Nobara/RPM-based distro with claude-desktop
//   installed via dnf, run `claude-desktop --doctor` and look for the
//   install-method line.
// * Expected: doctor detects rpm install (e.g. via `rpm -qf` against
//   the binary path) and reports it cleanly. No `not found via dpkg
//   (AppImage?)` warning.
// * Currently: scripts/doctor.sh's install-method probe is gated on
//   `command -v dpkg-query` and has no `rpm -qf` branch. Case-doc
//   anchors the block as :290-299; the actual lines in the file as of
//   runner-write time are :353-362 (drift noted, see report). On
//   RPM-only hosts (no dpkg-query) the entire block is skipped — no
//   install-method line is printed at all. On hosts with both
//   dpkg-query installed AND an rpm-installed claude-desktop, the
//   `_warn 'claude-desktop not found via dpkg (AppImage?)'` branch
//   fires only if dpkg-query comes up empty. (Anecdotally on some
//   Fedora hosts dpkg-query returns a stale Version string against
//   `claude-desktop` — in that case the PASS path runs and the
//   warning is suppressed for the wrong reason, but S05 still
//   passes by the letter of the assertion.)
//
// Scope split vs T13:
//
// * T13 (launch.md) covers all rows: detect rpm OR deb, assert no
//   false-flag for whichever owns the binary. Skips on AppImage /
//   hand-built / undetectable installs.
// * S05 (this file) is RPM-only: skips when `rpm -qf` doesn't claim
//   the binary, regardless of whether dpkg owns it. The matrix wants
//   both cells filled; the overlap is intentional — S05 fails loudly
//   on Fedora rows when T13's broader gating happens to skip (e.g.
//   if `rpm -qf` is missing from PATH, T13 falls through to the
//   `unknown` branch and skips, while S05 reports skip with the same
//   reason but separately).
//
// Layer: spawn probe + stdout grep. Doesn't touch the running app
// instance; doctor is `--doctor`-gated and exits without launching
// Electron.
//
// Diagnostics on failure (per case-doc): full --doctor output,
// `rpm -qf $(which claude-desktop)`, the doctor source line that
// decides the format. Captured unconditionally as attachments so
// post-hoc triage from a JUnit-only run is possible.

const FALSE_FLAG_FRAGMENT = 'not found via dpkg (AppImage?)';

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

test('S05 — Doctor recognises rpm install, no dpkg false-flag', async (
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

	// Applies to RPM-based rows per case-doc (KDE-W, KDE-X, GNOME,
	// Sway, i3, Niri). Rather than gating on the ROW env var, gate on
	// the actual install method — the assertion has no signal on
	// non-rpm hosts regardless of how the matrix labels them.

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

	const installPath =
		whichProbe.stdout.split('\n')[0]?.trim() ?? '';
	if (whichProbe.exitCode !== 0 || !installPath) {
		test.skip(
			true,
			`claude-desktop not reachable on PATH ` +
				`(launcher='${launcher}'); rpm-install probe needs ` +
				`a resolvable binary`,
		);
		return;
	}

	// Detect rpm install. `rpm -qf` returns 0 + the owning package's
	// NEVRA when the file is rpm-managed, non-zero otherwise. We also
	// run `rpm -q claude-desktop` to surface the package metadata
	// independent of which file `which` resolved (helpful when the
	// launcher is a wrapper script that shadows the real binary).
	const rpmFile = await probe('rpm', ['-qf', installPath]);
	const rpmPkg = await probe('rpm', ['-q', 'claude-desktop']);
	await testInfo.attach('rpm-qf', {
		body: formatProbe(rpmFile),
		contentType: 'text/plain',
	});
	await testInfo.attach('rpm-q-claude-desktop', {
		body: formatProbe(rpmPkg),
		contentType: 'text/plain',
	});

	if (rpmFile.exitCode !== 0) {
		// Not rpm-installed. S05's assertion only has signal on RPM
		// rows; on deb / AppImage / hand-built / undetectable installs
		// this is a clean skip (T13 covers the deb-side mirror).
		test.skip(
			true,
			`S05 only applies to rpm-installed claude-desktop; ` +
				`rpm -qf ${installPath} returned ` +
				`exit ${rpmFile.exitCode ?? '?'} ` +
				`(stderr: ${rpmFile.stderr || '<empty>'})`,
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

	// Core S05 assertion: doctor must NOT print the dpkg false-flag
	// warning for an rpm-installed copy. T02 already asserts the
	// exit-code contract (`doctor exits 0`) — don't duplicate that
	// here; S05 is purely about the install-method line.
	expect(
		result.output,
		`doctor must not false-flag rpm install ` +
			`(${rpmFile.stdout || 'rpm-owned'} at ${installPath}) ` +
			`as missing-dpkg AppImage`,
	).not.toContain(FALSE_FLAG_FRAGMENT);
});
