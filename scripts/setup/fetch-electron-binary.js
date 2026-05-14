#!/usr/bin/env node
// Fetches the Electron prebuilt binary into node_modules/electron/dist/.
//
// electron@42.0.0 (2026-05-06) removed the postinstall script that
// historically populated dist/ during `npm install`. This helper restores
// that behavior using @electron/get + extract-zip, so the rest of the
// build pipeline (which depends on the dist/ layout) keeps working.
//
// Run from the directory containing node_modules/electron. Reads the
// installed electron version from its package.json and downloads the
// matching binary for the host platform/arch.
//
// See: https://github.com/aaddrick/claude-desktop-debian/issues/584

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

async function main() {
	const cwd = process.cwd();
	const electronModuleDir = path.join(cwd, 'node_modules', 'electron');
	const distDir = path.join(electronModuleDir, 'dist');

	if (!fs.existsSync(electronModuleDir)) {
		throw new Error(
			`Electron module not found at ${electronModuleDir}; ` +
			"run 'npm install electron' first.",
		);
	}

	const pkgPath = path.join(electronModuleDir, 'package.json');
	const { version } = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
	if (!version) {
		throw new Error(`Could not read version from ${pkgPath}`);
	}

	const platform = 'linux';
	// node's process.arch values map cleanly to electron release archs,
	// except 'arm' which electron publishes as 'armv7l'.
	const arch = process.arch === 'arm' ? 'armv7l' : process.arch;

	const supportedArchs = ['x64', 'arm64', 'armv7l', 'ia32'];
	if (!supportedArchs.includes(arch)) {
		throw new Error(
			`Unsupported architecture: ${arch}. ` +
			`Electron publishes Linux binaries for ${supportedArchs.join(', ')}.`,
		);
	}

	// Resolve @electron/get and extract-zip from the work-dir's
	// node_modules. The script lives at scripts/setup/ so a plain
	// require() walks up from there and never sees work_dir/.
	const workDirRequire = createRequire(path.join(cwd, 'package.json'));
	const { downloadArtifact } = workDirRequire('@electron/get');
	const extractZip = workDirRequire('extract-zip');

	console.log(`Fetching electron@${version} for ${platform}-${arch}...`);
	const zipPath = await downloadArtifact({
		version,
		platform,
		arch,
		artifactName: 'electron',
	});

	console.log(`Extracting ${zipPath} into ${distDir}`);
	fs.mkdirSync(distDir, { recursive: true });
	await extractZip(zipPath, { dir: distDir });

	const electronBin = path.join(distDir, 'electron');
	if (fs.existsSync(electronBin)) {
		fs.chmodSync(electronBin, 0o755);
	}

	console.log('Electron binary fetched and extracted successfully.');
}

main().catch((err) => {
	console.error(err && err.stack ? err.stack : err);
	process.exit(1);
});
