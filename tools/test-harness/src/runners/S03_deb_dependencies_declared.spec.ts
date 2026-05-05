import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { captureSessionEnv } from '../lib/diagnostics.js';

const exec = promisify(execFile);

// S03 — DEB control file declares runtime dependencies.
//
// Per docs/testing/cases/distribution.md S03:
//   Expected: All transitive runtime deps are declared in the package
//   and pulled by APT. First launch succeeds without manual `apt
//   install` of any extra package.
//
// Code anchor: scripts/packaging/deb.sh:185-197 — the DEBIAN/control
// file emits Package/Version/Section/Priority/Architecture/Maintainer/
// Description fields and **no `Depends:` line**, with the inline
// comment at :181-183 ("No external dependencies are required at
// runtime"). The case-doc treats this as a regression: Critical
// surface, expected contract is "deps declared", current state is
// "deps absent". So this runner is a regression detector — marked
// `test.fail()` while the case-doc gap is open. The expected
// failure reports green; the day `scripts/packaging/deb.sh:185-197`
// emits a `Depends:` line the assertion passes, which flips the
// `.fail()` to red and prompts a case-doc update + `.fail()` removal.
//
// Layer: pure spawn probe. `dpkg-query -W -f='${Depends}'
// claude-desktop` reads the field straight out of dpkg's status db,
// so we don't need to know where the .deb lives in apt's cache or
// how the package was originally fetched.
//
// Skip behaviour: if dpkg-query exits non-zero (no dpkg installed,
// or claude-desktop not in dpkg's db), the package isn't deb-managed
// on this host and S03 has nothing to assert against.
//
// Subtlety on mixed-tooling hosts: a Fedora/RPM box that also has
// `dpkg` installed for cross-distro dev can wind up with a stale
// `claude-desktop` entry in dpkg's status db (matching the field
// shape from a previous deb install). dpkg-query exits 0 in that
// case and we still run the assertion — the field shape we read is
// authoritative for what a current deb install would look like, so
// it's a valid signal even if the binary on PATH is the rpm one.

test.fail('S03 — DEB control file declares runtime dependencies', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Critical',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / DEB packaging',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Read the Depends field from dpkg's status db. If dpkg-query
	// itself isn't installed (ENOENT) or the package isn't in the db
	// (exit 1), skip — S03 only applies to deb-managed installs.
	let dependsField: string;
	let pkgVersion = '';
	try {
		const { stdout } = await exec(
			'dpkg-query',
			['-W', '-f=${Depends}', 'claude-desktop'],
			{ timeout: 5_000 },
		);
		dependsField = stdout.trim();
	} catch (err) {
		const e = err as { stderr?: string; code?: number | string };
		await testInfo.attach('dpkg-query-error', {
			body: JSON.stringify(
				{
					code: e.code ?? null,
					stderr: (e.stderr ?? '').trim(),
				},
				null,
				2,
			),
			contentType: 'application/json',
		});
		test.skip(
			true,
			'S03 only applies to deb-installed claude-desktop ' +
				'(dpkg-query missing or package not in dpkg db)',
		);
		return;
	}

	// Capture the full Depends payload, version, and resolved binary
	// path as evidence regardless of pass/fail. Per Decision 7 these
	// are always-on attachments.
	try {
		const { stdout } = await exec(
			'dpkg-query',
			['-W', '-f=${Version}', 'claude-desktop'],
			{ timeout: 5_000 },
		);
		pkgVersion = stdout.trim();
	} catch {
		// Version probe is best-effort — Depends-field result above
		// already proves the package is in the db.
	}

	let installPath = '';
	try {
		const { stdout } = await exec('which', ['claude-desktop'], {
			timeout: 5_000,
		});
		installPath = stdout.trim();
	} catch {
		// `which` fails when the launcher isn't on PATH (e.g. dpkg
		// has a stale record but the binary's been removed). Capture
		// the empty string and let the Depends assertion run.
	}

	await testInfo.attach('depends-field', {
		body: dependsField,
		contentType: 'text/plain',
	});
	await testInfo.attach('package-version', {
		body: pkgVersion,
		contentType: 'text/plain',
	});
	await testInfo.attach('install-path', {
		body: installPath,
		contentType: 'text/plain',
	});
	await testInfo.attach('evidence', {
		body: JSON.stringify(
			{
				dependsField,
				dependsLength: dependsField.length,
				packageVersion: pkgVersion,
				installPath,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	// Core S03 assertion. Upstream contract: a Critical-severity
	// runtime install pulls all transitive deps via APT, which
	// requires the control file to declare them. Empty Depends ==
	// regression against scripts/packaging/deb.sh:185-197.
	expect(
		dependsField,
		'DEBIAN/control Depends: field is non-empty per upstream ' +
			'contract (case-doc S03 — currently fails until ' +
			'scripts/packaging/deb.sh:185-197 emits a Depends line)',
	).not.toBe('');
});
