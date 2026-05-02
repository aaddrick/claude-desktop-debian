import { test, expect } from '@playwright/test';
import { listAsar, readAsarFile, resolveAsarPath } from '../lib/asar.js';

// H02 — frame-fix-wrapper presence (file probe).
//
// The wrapper at scripts/frame-fix-wrapper.js is the linchpin of every
// Linux frame fix (close-to-tray, autostart shim, KWin child-bounds
// jiggle, AZERTY Ctrl+Q). It's injected by patch_app_asar in
// scripts/patches/app-asar.sh:18-49: the script copies the wrapper
// into the asar root, writes a frame-fix-entry.js shim that requires
// it, then rewrites package.json's `main` to point at the shim.
//
// If any of those steps silently breaks (missing source file, asar
// pack failure, package.json rewrite skipped), the app reverts to
// upstream's frameless-window behavior on every Linux row and our
// test harness's hook patterns (CLAUDE.md "Hooking Electron")
// stop matching what's loaded. S09 only covers the quick-window
// patch; nothing else asserts the wrapper landed at all.
//
// Three checks, ordered cheapest-first:
//   1. Both files exist in the asar manifest.
//   2. frame-fix-wrapper.js contains `Proxy(` (the Proxy pattern is
//      the entire reason the wrapper works — see CLAUDE.md and
//      lib/quickentry.ts:75-81).
//   3. frame-fix-entry.js requires the wrapper.
//   4. package.json's `main` references frame-fix-entry (substring,
//      not exact, since patches don't always preserve `.js`).
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

test('H02 — frame-fix-wrapper.js + frame-fix-entry.js injected into app.asar', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Frame fix wrapper injection',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// 1. Manifest probe. listAsar returns full paths inside the
	//    archive (e.g. '/frame-fix-wrapper.js' or 'frame-fix-wrapper.js'
	//    depending on @electron/asar's normalization). Use endsWith
	//    so either form matches.
	const manifest = listAsar(asarPath);
	const frameFixFiles = manifest.filter(
		(p) =>
			p.endsWith('frame-fix-wrapper.js') ||
			p.endsWith('frame-fix-entry.js'),
	);
	const wrapperPresent = frameFixFiles.some((p) =>
		p.endsWith('frame-fix-wrapper.js'),
	);
	const entryPresent = frameFixFiles.some((p) =>
		p.endsWith('frame-fix-entry.js'),
	);

	await testInfo.attach('frame-fix-files', {
		body: JSON.stringify(
			{
				found: frameFixFiles,
				wrapperPresent,
				entryPresent,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		wrapperPresent,
		'frame-fix-wrapper.js is present in app.asar manifest',
	).toBe(true);
	expect(
		entryPresent,
		'frame-fix-entry.js is present in app.asar manifest',
	).toBe(true);

	// 2. Wrapper contents — the Proxy pattern is the load-bearing
	//    structure (see scripts/frame-fix-wrapper.js:491-506 and
	//    CLAUDE.md "Frame Fix Wrapper" section). A wrapper without
	//    a Proxy is a stub that doesn't intercept anything.
	const wrapper = readAsarFile('frame-fix-wrapper.js', asarPath);
	const proxyPresent = wrapper.includes('Proxy(');
	expect(
		proxyPresent,
		'frame-fix-wrapper.js uses the Proxy() pattern (CLAUDE.md "Frame Fix Wrapper")',
	).toBe(true);

	// 3. Entry shim — it must require the wrapper, otherwise it's
	//    not actually loading any of the patches.
	const entry = readAsarFile('frame-fix-entry.js', asarPath);
	const entryRequiresWrapper =
		entry.includes("require('./frame-fix-wrapper") ||
		entry.includes('require("./frame-fix-wrapper');
	expect(
		entryRequiresWrapper,
		'frame-fix-entry.js requires ./frame-fix-wrapper',
	).toBe(true);

	// 4. package.json `main` — patch_app_asar in app-asar.sh:40-49
	//    rewrites pkg.main to 'frame-fix-entry.js'. Substring match
	//    on 'frame-fix-entry' tolerates patches that re-extension
	//    or rename the shim.
	const pkgJsonRaw = readAsarFile('package.json', asarPath);
	let mainEntry = '';
	try {
		const parsed = JSON.parse(pkgJsonRaw) as { main?: unknown };
		if (typeof parsed.main === 'string') mainEntry = parsed.main;
	} catch (err) {
		throw new Error(
			'package.json in app.asar is not valid JSON: ' +
				(err instanceof Error ? err.message : String(err)),
		);
	}

	await testInfo.attach('package-main', {
		body: JSON.stringify({ main: mainEntry }, null, 2),
		contentType: 'application/json',
	});

	expect(
		mainEntry.includes('frame-fix-entry'),
		'package.json `main` references frame-fix-entry (app-asar.sh:40-49)',
	).toBe(true);

	await testInfo.attach('evidence', {
		body: JSON.stringify(
			{
				wrapperPresent,
				entryPresent,
				proxyPresent,
				entryRequiresWrapper,
				mainEntry,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});
});
