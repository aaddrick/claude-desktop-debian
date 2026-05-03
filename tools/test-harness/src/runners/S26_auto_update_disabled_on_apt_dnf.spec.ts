import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

const exec = promisify(execFile);

// S26 — Auto-update is disabled when installed via apt/dnf.
//
// Per docs/testing/cases/distribution.md S26:
//   Expected: when installed via the project's APT or DNF repo, the
//   in-app auto-update path is suppressed. The app does not download
//   replacement binaries (which would race the package manager).
//   Updates flow through `apt upgrade` / `dnf upgrade` only. AppImage
//   installs may continue to self-update or punt to the user.
//
// The case-doc explicitly flags this as **Missing in build 1.5354.0**:
// no project-side suppression of the upstream auto-update path exists.
// The launcher exports `ELECTRON_FORCE_IS_PACKAGED=true`
// (scripts/launcher-common.sh:249), upstream's Linux gate (`lii()` at
// build-reference/.../index.js:508761-508774) returns true, and the
// code path proceeds to `hA.autoUpdater.setFeedURL(...)` +
// `.checkForUpdates()` unconditionally. The only reason it doesn't
// hit the network today is Electron's Linux `autoUpdater` being
// unimplemented — a happy accident, not a contract. Tracked at
// https://github.com/aaddrick/claude-desktop-debian/issues/567 with
// two candidate fixes (frame-fix-wrapper hook vs. gating
// ELECTRON_FORCE_IS_PACKAGED on package format).
//
// **Regression-detector shape.** This runner pins the current state
// of the bundle so the failing assertion flips to passing the moment
// the project ships a suppression patch (PR #567 or successor):
//
//   1. Sanity assertion (passes today): `setFeedURL` is present in
//      the bundled main-process JS. This proves the upstream
//      auto-update code path we'd need to suppress is actually in
//      the bundle — without it, the rest of the test would be
//      vacuously true.
//
//   2. Suppression assertion (fails today): a project-injected
//      suppression marker is present in the bundle. No such marker
//      exists yet. The expected fingerprint shape (per the
//      issue-#567 thread) is one of:
//        - `cdd-disable-auto-update` — an injected comment / sentinel
//          string we'd add alongside a no-op patch.
//        - `frame-fix-wrapper`-side autoUpdater interception — would
//          live in scripts/frame-fix-wrapper.js (not the asar JS
//          itself), but the wrapper module is already covered by H02
//          for general presence.
//        - A `disableAutoUpdates: !0`-shaped override in the bundle
//          coming from a new patch in scripts/patches/*.sh.
//      We probe for any of these and require at least one to land.
//      When a suppression patch ships, update MARKERS below with the
//      actual fingerprint so this assertion stays a working drift
//      detector instead of becoming a stale TODO.
//
// **Skip behaviour.** Case-doc scopes this to "all DEB/RPM rows" —
// AppImage installs are explicitly carved out ("AppImage installs
// may continue to self-update or punt to the user"). We detect deb
// or rpm install via `dpkg-query -W claude-desktop` and `rpm -q
// claude-desktop`; if neither succeeds, we skip. On hosts where
// both succeed (mixed-tooling dev box), we run — the assertion
// shape is purely about what's in the bundle, not about which
// package manager owns the on-disk binary.
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

// Candidate suppression-marker fingerprints. None present today;
// any one of these going green flips the assertion to passing. When
// PR #567 (or its successor) lands, prune this list down to the
// actual marker so the test is a clean drift detector going forward.
//
// We deliberately don't match `disableAutoUpdates` alone — that
// string is ALREADY in the bundle as the enterprise-policy MDM key
// (index.js:140737, :140830 etc), so its presence proves nothing.
// The markers below are shapes that only appear if the project
// injected them.
const SUPPRESSION_MARKERS: { needle: string; rationale: string }[] = [
	{
		needle: 'cdd-disable-auto-update',
		rationale:
			'sentinel comment a future scripts/patches/*.sh would ' +
			'inject alongside a no-op autoUpdater patch',
	},
	{
		needle: 'cdd-no-auto-update',
		rationale:
			'alternative sentinel shape consistent with ' +
			'cdd-cowork-* / cdd-tray-* naming used elsewhere',
	},
	{
		needle: 'autoUpdater is disabled by claude-desktop-debian',
		rationale:
			'human-readable log line a frame-fix-wrapper.js-side ' +
			'autoUpdater no-op hook would emit on first call',
	},
];

test('S26 — Auto-update is disabled when installed via apt/dnf', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Critical',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / auto-update suppression',
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
	// re-grounded against the new shape before re-asserting on the
	// suppression direction.
	const setFeedURLCount = (
		indexJs.match(/setFeedURL/g) ?? []
	).length;

	// Probe each candidate suppression marker.
	const markerResults = SUPPRESSION_MARKERS.map((m) => ({
		needle: m.needle,
		rationale: m.rationale,
		found: indexJs.includes(m.needle),
	}));
	const anyMarkerFound = markerResults.some((r) => r.found);

	await testInfo.attach('bundle-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				setFeedURLOccurrences: setFeedURLCount,
				suppressionMarkers: markerResults,
				anyMarkerFound,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		setFeedURLCount,
		'app.asar contains the upstream `setFeedURL` autoUpdater code ' +
			'path (sanity check — the thing S26 expects suppressed). ' +
			'If this drops to 0 the test is vacuous; re-ground against ' +
			'the new bundle shape.',
	).toBeGreaterThan(0);

	// Core S26 assertion. Today: fails by design — no project-side
	// suppression has shipped (#567 open). Flips to passing once a
	// suppression patch lands and one of SUPPRESSION_MARKERS matches.
	expect(
		anyMarkerFound,
		'app.asar contains a project-injected auto-update suppression ' +
			'marker (deb/rpm installs must not race the package ' +
			'manager). Currently absent per case-doc S26 / issue #567 ' +
			'— upstream autoUpdater is unhooked on Linux, suppression ' +
			'is "accidental" and depends on Electron leaving Linux ' +
			'autoUpdater unimplemented.',
	).toBe(true);
});
