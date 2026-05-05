import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const exec = promisify(execFile);

// S04 — RPM install via DNF pulls all required runtime deps.
//
// Mirror of S03 for the RPM/DNF branch. Case-doc:
// docs/testing/cases/distribution.md#s04--rpm-install-via-dnf-pulls-all-required-runtime-deps
//
// Severity: Critical. Surface: DNF repository / dependency
// declarations. Applies to KDE-W, KDE-X, GNOME, Sway, i3, Niri (any
// RPM-based distro).
//
// Case-doc anchors `scripts/packaging/rpm.sh:188` (`AutoReqProv: no`
// disables RPM's auto-dep generation; the spec declares no
// `Requires:`) and `:194-198` (strip + build-id disabled because
// Electron binaries don't tolerate them — bundled approach).
//
// **Regression-detector shape.** The assertion direction is "Requires
// has at least one declared runtime dep" — i.e. at least one line in
// `rpm -qR claude-desktop` that isn't an `rpmlib(...)` capability and
// isn't a `%post`/`%postun` interpreter path (`/bin/sh` etc). Today
// that filter empties out, so the spec is marked `test.fail()` while
// the case-doc gap is open: the expected failure reports green. When
// upstream `rpm.sh` flips `AutoReqProv: on` (or declares an explicit
// `Requires:` block) the assertion passes, which flips the `.fail()`
// to red and prompts a case-doc update + `.fail()` removal.
//
// `rpm -qR` always emits `rpmlib(CompressedFileNames)`,
// `rpmlib(FileDigests)`, `rpmlib(PayloadFilesHavePrefix)`, and
// `rpmlib(PayloadIsZstd)` regardless of spec content — those are
// satisfied by the rpm runtime itself, not by declared deps. Bare
// interpreter paths like `/bin/sh` come from scriptlet detection on
// the spec's `%post` / `%postun`, not from declared library deps.
// Both get filtered out so the assertion is strictly "did anyone
// declare a runtime dep, by hand or via AutoReqProv".
//
// Skip cleanly when:
//   - `rpm` isn't on PATH (Debian/Ubuntu host, AppImage-only host).
//   - `rpm -q claude-desktop` says the package isn't rpm-installed
//     (deb host with rpm tooling for cross-distro dev, AppImage extract).
//
// Layer: spawn probe + stdout parse. No app launch. Row-independent
// in shape, but only meaningful on RPM-based rows.

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
			typeof e.code === 'number'
				? e.code
				: typeof e.code === 'string'
					? null
					: null;
		return {
			cmd,
			exitCode: code,
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

// `rpm -qR` lines we don't count as "declared runtime deps":
//   - `rpmlib(...)` capabilities — auto-emitted by rpm regardless of
//     the spec, satisfied by the rpm runtime itself.
//   - Bare interpreter paths (`/bin/sh`, `/bin/bash`, `/usr/bin/env`)
//     — picked up from the spec's scriptlets (`%post` / `%postun`),
//     not from declared library deps.
function isAutoEmittedRequire(line: string): boolean {
	const trimmed = line.trim();
	if (!trimmed) return true;
	if (trimmed.startsWith('rpmlib(')) return true;
	// Strip a trailing version constraint ("/bin/sh >= 1.0") before
	// matching so the shape is just the capability/path.
	const head = trimmed.split(/\s+/)[0] ?? '';
	if (
		head === '/bin/sh' ||
		head === '/bin/bash' ||
		head === '/usr/bin/env' ||
		head === '/usr/bin/sh' ||
		head === '/usr/bin/bash'
	) {
		return true;
	}
	return false;
}

test.fail('S04 — RPM package declares runtime requirements', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({
		type: 'severity',
		description: 'Critical',
	});
	testInfo.annotations.push({
		type: 'surface',
		description: 'DNF repository / dependency declarations',
	});

	// Skip cleanly on hosts without rpm tooling.
	const rpmWhich = await probe('which', ['rpm']);
	await testInfo.attach('which-rpm', {
		body: formatProbe(rpmWhich),
		contentType: 'text/plain',
	});
	if (rpmWhich.exitCode !== 0 || !rpmWhich.stdout) {
		test.skip(
			true,
			'S04 only applies to rpm-installed claude-desktop ' +
				'(rpm not on PATH)',
		);
		return;
	}

	// Resolve installed package version. `rpm -q` returns non-zero if
	// the package isn't installed via rpm (Debian/AppImage host with
	// rpm tooling, etc) — that's the second skip path.
	const rpmQ = await probe('rpm', ['-q', 'claude-desktop']);
	await testInfo.attach('rpm-q', {
		body: formatProbe(rpmQ),
		contentType: 'text/plain',
	});
	if (rpmQ.exitCode !== 0) {
		test.skip(
			true,
			'S04 only applies to rpm-installed claude-desktop ' +
				'(rpm -q claude-desktop returned non-zero)',
		);
		return;
	}

	// Capture install path for the diagnostics bundle. Failure here
	// isn't a skip — `which` not finding `claude-desktop` on a host
	// where `rpm -q claude-desktop` succeeds is unusual but harmless
	// for the assertion shape.
	const whichClaude = await probe('which', ['claude-desktop']);
	await testInfo.attach('which-claude-desktop', {
		body: formatProbe(whichClaude),
		contentType: 'text/plain',
	});

	const rpmRequires = await probe('rpm', ['-qR', 'claude-desktop']);
	await testInfo.attach('rpm-qR', {
		body: formatProbe(rpmRequires),
		contentType: 'text/plain',
	});
	expect(
		rpmRequires.exitCode,
		`rpm -qR claude-desktop must succeed on an rpm-installed host`,
	).toBe(0);

	const allLines = rpmRequires.stdout
		.split('\n')
		.map((l) => l.trim())
		.filter((l) => l.length > 0);
	const declaredRequires = allLines.filter(
		(l) => !isAutoEmittedRequire(l),
	);

	await testInfo.attach('requires-classified', {
		body: JSON.stringify(
			{
				all: allLines,
				declared: declaredRequires,
				declaredCount: declaredRequires.length,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	// Core S04 assertion. Per case-doc "Expected": "All transitive
	// runtime deps are declared in the RPM and pulled by DNF." A
	// non-empty `declaredRequires` is the minimum signal — it doesn't
	// prove the *full* set is declared, but it proves the spec moved
	// off `AutoReqProv: no` with no manual `Requires:` (the current
	// state per scripts/packaging/rpm.sh:188).
	//
	// Marked `test.fail()` at the test definition: today this fails
	// by design (regression-detector state), and the expected failure
	// reports green. When scripts/packaging/rpm.sh starts declaring
	// runtime deps (manual Requires lines, AutoReqProv flip, or both)
	// the assertion passes, which flips `.fail()` to red — the signal
	// to update the case-doc and remove the annotation.
	expect(
		declaredRequires.length,
		`rpm -qR claude-desktop should report at least one declared ` +
			`runtime requirement (non-rpmlib(...), non-interpreter). ` +
			`Currently empty per scripts/packaging/rpm.sh:188 ` +
			`(\`AutoReqProv: no\`, no \`Requires:\`).`,
	).toBeGreaterThan(0);
});
