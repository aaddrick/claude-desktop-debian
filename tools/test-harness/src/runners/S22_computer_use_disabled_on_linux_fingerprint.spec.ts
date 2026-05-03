import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// S22 — Computer-use toggle is absent or visibly disabled on Linux.
//
// This spec is the **Tier 1 file-level fingerprint** for S22. The
// full surface check — actually walking Settings → Desktop app →
// General and asserting the toggle either doesn't render or renders
// disabled with a "not supported on Linux" hint — is Tier 3 (AX-tree
// form) and lives elsewhere. Here we only verify the upstream
// platform-gate string still exists in the bundle: if it disappears
// or starts including "linux", the gate has changed shape and any
// downstream UI assertion is built on sand.
//
// Per the case-doc Code anchor (platform-integration.md S22):
//   `qDA = new Set(["darwin", "win32"])` excludes Linux from the
//   computer-use platform set; `TF()` (the master enable check)
//   short-circuits to false when `qDA.has(process.platform)` is
//   false.
//
// The minified identifier (`qDA` here) rotates between releases —
// we DON'T pin it. Instead we match the stable shape:
//   /new Set\(\[\s*"darwin"\s*,\s*"win32"\s*\]\)/
// which tolerates both the no-space minified form
// (`new Set(["darwin","win32"])`) and the with-space beautified form
// (`new Set(["darwin", "win32"])`) the same way our patch-script
// regexes have to.
//
// We also assert the literal `"linux"` is NOT in the same Set
// expression — a positive-shape match ensures Linux stays excluded
// even if upstream re-orders the platform list.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

const PLATFORM_SET_RE =
	/new Set\(\[\s*"darwin"\s*,\s*"win32"\s*\]\)/;

test('S22 — Computer-use platform gate excludes linux (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Computer use / platform gate',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	const match = indexJs.match(PLATFORM_SET_RE);
	const found = match !== null;

	// If the 2-element gate was widened to include "linux", that's a
	// real behavior change — flag it. We sniff for a 2-element
	// `new Set([...])` that pairs "linux" with darwin or win32, which
	// would mean upstream swapped one of the existing platforms for
	// linux at the gate level.
	//
	// Note: a 3-element Set `["darwin","win32","linux"]` exists
	// elsewhere in the bundle for an unrelated feature (telemetry /
	// platform-allowlist scope), so we don't flag that shape here —
	// the computer-use gate is specifically the 2-element one per
	// the case-doc anchor.
	const linuxPairedRe =
		/new Set\(\[\s*"(?:linux"\s*,\s*"(?:darwin|win32)|(?:darwin|win32)"\s*,\s*"linux)"\s*\]\)/;
	const linuxPaired = linuxPairedRe.test(indexJs);

	await testInfo.attach('platform-gate-probe', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				regex: PLATFORM_SET_RE.source,
				found,
				matchSnippet: match ? match[0] : null,
				linuxPaired,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		found,
		'app.asar contains a `new Set(["darwin","win32"])` platform ' +
			'gate (computer-use excludes Linux)',
	).toBe(true);
	expect(
		linuxPaired,
		'no 2-element `new Set([..., "linux", ...])` platform gate ' +
			'exists (would mean upstream re-enabled computer-use ' +
			'on Linux)',
	).toBe(false);
});
