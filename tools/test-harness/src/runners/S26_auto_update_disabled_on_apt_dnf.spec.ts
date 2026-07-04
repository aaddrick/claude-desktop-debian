import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

const exec = promisify(execFile);

// S26 — Auto-update stays inert on apt/dnf installs.
//
// Per docs/testing/cases/distribution.md S26:
//   Expected: when installed via the project's APT or DNF repo, the
//   in-app auto-update path does not download replacement binaries
//   (which would race the package manager). Updates flow through
//   `apt upgrade` / `dnf upgrade` only. AppImage installs may
//   continue to self-update or punt to the user.
//
// v3.0.0 state (decision D-001 in docs/decisions.md): the official
// Linux build ships its apt-channel autoupdater PENDING — the bundle
// carries the `apt_channel_pending` gate and does not self-update on
// the apt channel. That pending gate is currently the entire
// suppression mechanism; the project injects nothing. The build
// enforces this assumption with the AU-1 tripwire in
// scripts/patches/app-asar.sh (build fails when upstream removes the
// marker). The 2.x plan of a project-injected suppression marker
// (issue #567, frame-fix-wrapper hook / ELECTRON_FORCE_IS_PACKAGED
// gating) died with the rebase — the wrapper and the env export are
// both gone.
//
// **Regression-detector shape**, mirroring AU-1 at install time:
//
//   1. Sanity assertion: `setFeedURL` is present in the bundled
//      main-process JS — the upstream auto-update machinery is
//      still in the bundle, so the gate below is load-bearing,
//      not vacuous.
//
//   2. Gate assertion: `apt_channel_pending` is present. The moment
//      upstream ships the apt-channel autoupdater for real, this
//      fails on freshly-installed builds and forces the D-001
//      decision (defer to upstream vs suppress) before deb/rpm
//      installs start racing the package manager. A build made from
//      a tree where AU-1 already fired can't reach this point, but
//      an install probed against a NEWER official deb (VM rows,
//      manual installs) can — that's the gap this covers.
//
// **Skip behaviour.** Case-doc scopes this to "all DEB/RPM rows" —
// AppImage installs are explicitly carved out. We detect deb or rpm
// install via `dpkg-query -W claude-desktop` and `rpm -q
// claude-desktop`; if neither succeeds, we skip.
//
// Layer: pure file probe (asar read) + spawn probes for install
// detection. No app launch.

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
			code?: number | string;
		};
		const code =
			typeof e.code === 'number' ? e.code : null;
		return {
			cmd,
			exitCode: code,
			stdout: (e.stdout ?? '').trim(),
			stderr: (e.stderr ?? '').trim(),
		};
	}
}

test('S26 — Auto-update stays inert on apt/dnf installs (apt_channel_pending gate)', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Critical',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / auto-update gate',
	});

	// Detect install method. S26 only applies to deb/rpm-installed
	// hosts per case-doc "Applies to: All DEB/RPM rows".
	const dpkgProbe = await probe('dpkg-query', [
		'-W',
		'-f=${Version}',
		'claude-desktop',
	]);
	const rpmProbe = await probe('rpm', ['-q', 'claude-desktop']);

	await testInfo.attach('install-probes', {
		body: JSON.stringify(
			{
				dpkg: {
					cmd: dpkgProbe.cmd,
					exitCode: dpkgProbe.exitCode,
					stdout: dpkgProbe.stdout,
					stderr: dpkgProbe.stderr,
				},
				rpm: {
					cmd: rpmProbe.cmd,
					exitCode: rpmProbe.exitCode,
					stdout: rpmProbe.stdout,
					stderr: rpmProbe.stderr,
				},
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	const debInstalled = dpkgProbe.exitCode === 0 && !!dpkgProbe.stdout;
	const rpmInstalled = rpmProbe.exitCode === 0 && !!rpmProbe.stdout;
	const installMethod = debInstalled
		? 'deb'
		: rpmInstalled
			? 'rpm'
			: 'none';

	await testInfo.attach('install-method', {
		body: installMethod,
		contentType: 'text/plain',
	});

	if (!debInstalled && !rpmInstalled) {
		test.skip(
			true,
			'S26 only applies to deb/rpm-installed claude-desktop ' +
				'(case-doc scopes to APT/DNF rows; AppImage installs ' +
				'are explicitly carved out)',
		);
		return;
	}

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// Sanity assertion: the upstream autoUpdater code path is in the
	// bundle. If `setFeedURL` ever disappears (upstream rewrite,
	// module rename), this whole test is vacuous and should be
	// re-grounded against the new bundle shape before re-asserting
	// on the gate direction.
	const setFeedURLCount = (
		indexJs.match(/setFeedURL/g) ?? []
	).length;

	const pendingGateCount = (
		indexJs.match(/apt_channel_pending/g) ?? []
	).length;

	await testInfo.attach('bundle-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				setFeedURLOccurrences: setFeedURLCount,
				aptChannelPendingOccurrences: pendingGateCount,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		setFeedURLCount,
		'app.asar contains the upstream `setFeedURL` autoUpdater code ' +
			'path (sanity check — the machinery the pending gate holds ' +
			'back). If this drops to 0 the test is vacuous; re-ground ' +
			'against the new bundle shape.',
	).toBeGreaterThan(0);

	// Core S26 assertion (install-time sibling of the AU-1 tripwire).
	// Fails the moment upstream ships the apt-channel autoupdater —
	// at which point deb/rpm installs could race apt/dnf and D-001
	// must be settled before the next release.
	expect(
		pendingGateCount,
		'app.asar carries the upstream `apt_channel_pending` gate ' +
			'(D-001: apt-channel autoupdater still pending). Absence ' +
			'means upstream activated self-update on the apt channel — ' +
			'settle D-001 (defer vs suppress) before shipping deb/rpm ' +
			'builds that race the package manager.',
	).toBeGreaterThan(0);
});
