import { test, expect } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

// S33 — Quick Entry transparent rendering tracked against bundled
// Electron version. Backs QE-18 in docs/testing/quick-entry-closeout.md.
//
// Per @noctuum's bisect on #370, Electron 41.0.4 introduced the
// transparency / opaque-square-frame regression on KDE Wayland. This
// test records the bundled Electron version per row so the matrix
// can correlate S10 outcomes with the version.
//
// Reads from electron/package.json rather than running
// `electron --version`. The bundled Electron binary auto-loads
// resources/app.asar relative to its own path, so `--version` is
// passed through as argv to Claude Desktop instead of being
// intercepted by Electron's flag parser. The package.json is
// canonical and avoids that whole class of issue.

const DEFAULT_ELECTRON_PATHS = [
	'/usr/lib/claude-desktop/node_modules/electron/dist/electron',
	'/opt/Claude/node_modules/electron/dist/electron',
];

function resolveElectronBin(): string {
	const env = process.env.CLAUDE_DESKTOP_ELECTRON;
	if (env) return env;
	for (const candidate of DEFAULT_ELECTRON_PATHS) {
		if (existsSync(candidate)) return candidate;
	}
	throw new Error(
		'Could not locate the bundled Electron binary. Set ' +
			'CLAUDE_DESKTOP_ELECTRON or install the deb/rpm package.',
	);
}

// electron/package.json sits two dirs up from `dist/electron`.
function resolveElectronPkg(electronBin: string): string {
	return join(dirname(electronBin), '..', 'package.json');
}

test('S33 — Quick Entry transparent rendering tracked against bundled Electron version', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Bundled Electron version',
	});

	const electronBin = resolveElectronBin();
	const pkgPath = resolveElectronPkg(electronBin);
	await testInfo.attach('electron-bin', {
		body: electronBin,
		contentType: 'text/plain',
	});
	await testInfo.attach('electron-package-json-path', {
		body: pkgPath,
		contentType: 'text/plain',
	});

	expect(
		existsSync(pkgPath),
		`electron/package.json exists at ${pkgPath}`,
	).toBe(true);

	const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as {
		version?: string;
		name?: string;
	};

	expect(pkg.name, 'package.json is for the electron module').toMatch(
		/^electron/,
	);

	const version = pkg.version ?? '';
	await testInfo.attach('electron-version', {
		body: version,
		contentType: 'text/plain',
	});

	expect(version, 'package.json version is a non-empty semver').toMatch(
		/^\d+\.\d+\.\d+/,
	);

	// Surface the #370 hypothesis check for matrix-regen.
	const [major, minor, patch] = version
		.split('.')
		.map((n) => parseInt(n, 10));
	const bisectThreshold =
		major !== undefined &&
		minor !== undefined &&
		patch !== undefined &&
		(major > 41 ||
			(major === 41 && minor > 0) ||
			(major === 41 && minor === 0 && patch >= 4));
	await testInfo.attach('bisect-context', {
		body: JSON.stringify(
			{
				version,
				atOrAboveBisectThreshold: bisectThreshold,
				bisectNote:
					'electron/electron#50213; #370 expected to reproduce on >= 41.0.4 ' +
					'until upstream ships a CSD-rendering fix',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});
});
