import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// H03 — build pipeline patch fingerprints (file probe).
//
// scripts/patches/*.sh layers a stack of regex-based mutations onto
// the bundled JS at build time. Each patch lands a distinctive
// string somewhere in the asar; if a patch silently skips (anchor
// regex misses, idempotency guard short-circuits the wrong way,
// build orchestrator drops the call), that string is absent and
// the patch's behavior is gone.
//
// S09 already covers quick-window.sh. This test consolidates the
// rest into one manifest so future drift is observable in a single
// JSON dump. Fingerprints are pinned to STRINGS THE PATCH INJECTS
// (not strings the patch matches against), so an upstream rename
// of the matched site doesn't false-positive a passing patch.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

interface PatchEntry {
	patch: string;
	fingerprint: string;
	file: string;
	// One-line note explaining where the fingerprint comes from
	// in the patch script — surfaced in the attached manifest so
	// future maintainers can tie a failure back to the right
	// scripts/patches/*.sh:LINE.
	source: string;
}

const MANIFEST: PatchEntry[] = [
	{
		patch: 'quick-window.sh',
		fingerprint: 'XDG_CURRENT_DESKTOP',
		file: '.vite/build/index.js',
		source:
			'patches/quick-window.sh injects an XDG_CURRENT_DESKTOP env-var ' +
			'gate; same fingerprint S09 asserts.',
	},
	{
		patch: 'app-asar.sh (frame-fix injection)',
		fingerprint: 'frame-fix-entry',
		file: 'package.json',
		source:
			'patches/app-asar.sh:40-49 rewrites package.json main to ' +
			"'frame-fix-entry.js'.",
	},
	{
		patch: 'tray.sh (startup-delay nativeTheme guard)',
		fingerprint: '_trayStartTime',
		file: '.vite/build/index.js',
		source:
			'patches/tray.sh:67-69 injects `let _trayStartTime=Date.now();` ' +
			"into the nativeTheme `on('updated')` handler. Variable name " +
			'is unique to our patch — upstream never declares it.',
	},
	{
		patch: 'cowork.sh (Linux daemon quit handler)',
		fingerprint: 'cowork-linux-daemon-shutdown',
		file: '.vite/build/index.js',
		source:
			'patches/cowork.sh:602-605 registers a Linux-only quit handler ' +
			"with name:'cowork-linux-daemon-shutdown'. Distinctive string " +
			'unique to the patch.',
	},
	{
		patch: 'claude-code.sh (Linux platform branch)',
		fingerprint: 'linux-arm64',
		file: '.vite/build/index.js',
		source:
			'patches/claude-code.sh:20-24 injects `linux-arm64` / `linux-x64` ' +
			'platform-bundle branches into getHostPlatform. Upstream throws ' +
			'on Linux; the string is absent without the patch.',
	},
];

// TODOs intentionally left where a stable fingerprint isn't easy:
//   - tray.sh has multiple sub-patches (icon selection, in-place
//     update, menu-bar default). _trayStartTime above covers the
//     menu-handler patch reliably; the in-place update patch
//     anchors on a generated name like `${TRAY_VAR}.setImage(...)`
//     where TRAY_VAR is minifier-renamed every release, so no
//     fingerprint there is stable enough to assert without a
//     second extraction step. Acceptable: the menu-handler
//     fingerprint is upstream of the in-place patch in the same
//     subsystem, so a missing _trayStartTime implies a much
//     bigger build problem anyway.

test('H03 — build pipeline patch fingerprints present in app.asar', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Build pipeline patch fingerprints',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Read each unique file once, then check fingerprints against
	// the cached contents. Saves repeated asar extraction for
	// patches that share a target file.
	const fileCache = new Map<string, string>();
	const results: {
		patch: string;
		fingerprint: string;
		file: string;
		source: string;
		found: boolean;
	}[] = [];

	for (const entry of MANIFEST) {
		let contents = fileCache.get(entry.file);
		if (contents === undefined) {
			try {
				contents = readAsarFile(entry.file, asarPath);
				fileCache.set(entry.file, contents);
			} catch (err) {
				// File missing — record as a "not found" result so
				// the manifest dump shows the failure shape rather
				// than aborting on the first hiccup.
				results.push({
					patch: entry.patch,
					fingerprint: entry.fingerprint,
					file: entry.file,
					source:
						entry.source +
						' [READ ERROR: ' +
						(err instanceof Error ? err.message : String(err)) +
						']',
					found: false,
				});
				continue;
			}
		}
		results.push({
			patch: entry.patch,
			fingerprint: entry.fingerprint,
			file: entry.file,
			source: entry.source,
			found: contents.includes(entry.fingerprint),
		});
	}

	// Always attach the manifest — passing tests should still
	// surface the verified fingerprints so future drift is visible
	// without re-running with -v.
	await testInfo.attach('patch-manifest', {
		body: JSON.stringify(results, null, 2),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found);
	expect(
		missing,
		'every expected patch fingerprint is present in the bundled app.asar',
	).toEqual([]);
});
