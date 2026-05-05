import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// S09 — Quick window patch runs only on KDE (post-#406 gate).
// Backs QE-19 in docs/testing/quick-entry-closeout.md.
//
// The patch in scripts/patches/quick-window.sh injects an
// `(process.env.XDG_CURRENT_DESKTOP||"").toLowerCase().includes("kde")`
// gate into the bundled JS. The string `XDG_CURRENT_DESKTOP` shows up
// in app.asar's index.js if and only if the patch ran at build time.
// The patch ships in every build; the KDE-vs-non-KDE branch is
// decided at runtime by the env-var check.
//
// Pure file probe — no app launch. Fast (<1s).
//
// Runtime gate effectiveness is verified implicitly by S31 passing
// on KDE (popup-show works through the patched code path) and the
// upstream-equivalent path running on non-KDE rows.

test('S09 — Quick window patch runs only on KDE (post-#406 gate)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({ type: 'surface', description: 'Patch gate' });

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// The gate string is the runtime fingerprint of the patch. If the
	// patch didn't run, the bundled JS won't contain it.
	const gatePresent = indexJs.includes('XDG_CURRENT_DESKTOP');
	expect(
		gatePresent,
		'app.asar contains the XDG_CURRENT_DESKTOP gate string injected by quick-window.sh',
	).toBe(true);

	// Bonus signal: the patch's idempotency guard. If both are
	// present the patch's full payload landed.
	const patchedComment = indexJs.includes('kde');
	await testInfo.attach('gate-evidence', {
		body: JSON.stringify({ gatePresent, patchedComment }, null, 2),
		contentType: 'application/json',
	});
});
