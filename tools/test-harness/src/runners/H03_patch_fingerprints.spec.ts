import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// H03 — active-patch fingerprints (file probe).
//
// Since the v3.0.0 rebase the build ships Anthropic's official
// app.asar byte-identical unless a patch in the `active_patches`
// array of scripts/patches/app-asar.sh is wired in (patch-zero,
// decision D-002 in docs/decisions.md). Each active patch lands a
// distinctive string in the bundled JS; if a patch silently skips
// (anchor regex misses against a re-minified upstream, idempotency
// guard short-circuits the wrong way, orchestrator drops the call),
// that string is absent and the patch's behavior is gone.
//
// The manifest below must track active_patches — currently
// quick-window.sh and org-plugins.sh. Fingerprints are pinned to
// STRINGS THE PATCH INJECTS (not strings the patch matches against),
// so an upstream rename of the matched site doesn't false-positive a
// passing patch. Verified against pristine official 1.18286.0 bytes:
// zero occurrences of each fingerprint.
//
// Also pins the productName guard's runtime contract (the same
// invariant app-asar.sh enforces at build time): productName must
// stay 'Claude' or StartupWMClass breaks in every .desktop file.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

interface PatchEntry {
	patch: string;
	fingerprint: string;
	file: string;
	// One-line note tying the fingerprint back to the right
	// scripts/patches/*.sh site — surfaced in the attached manifest.
	source: string;
}

const MANIFEST: PatchEntry[] = [
	{
		patch: 'quick-window.sh',
		fingerprint: 'XDG_CURRENT_DESKTOP',
		file: '.vite/build/index.js',
		source:
			'patches/quick-window.sh injects KDE-gated blur()/visibility ' +
			'workarounds guarded by (process.env.XDG_CURRENT_DESKTOP||"")' +
			'.toLowerCase().includes("kde"); same fingerprint S09 asserts. ' +
			'Pristine official bundle: zero occurrences.',
	},
	{
		patch: 'org-plugins.sh',
		fingerprint: 'case"linux":return"/etc/claude/org-plugins"',
		file: '.vite/build/index.js',
		source:
			'patches/org-plugins.sh inserts a Linux case into the ' +
			'org-plugins source-dir platform switch (upstream only has ' +
			'darwin/win32 cases; the default returns null and silently ' +
			'disables the marketplace feature on Linux).',
	},
];

test('H03 — active-patch fingerprints present in app.asar', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Active-patch fingerprints (patch-zero)',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Read each unique file once, then check fingerprints against the
	// cached contents.
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

	// Always attach the manifest — passing tests should still surface
	// the verified fingerprints so future drift is visible without
	// re-running with -v.
	await testInfo.attach('patch-manifest', {
		body: JSON.stringify(results, null, 2),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found);
	expect(
		missing,
		'every active-patch fingerprint is present in the bundled app.asar',
	).toEqual([]);

	// productName guard parity — runtime pin of app-asar.sh's
	// build-time WM_CLASS/.desktop contract check.
	const pkgJsonRaw = readAsarFile('package.json', asarPath);
	const parsed = JSON.parse(pkgJsonRaw) as { productName?: unknown };
	expect(
		parsed.productName,
		'package.json productName matches the WM_CLASS/.desktop contract',
	).toBe('Claude');
});
