import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T18 — Drag-and-drop files into prompt (Tier 1 / asar fingerprint).
//
// Backs T18 in docs/testing/cases/code-tab-foundations.md
// ("Drag-and-drop files into prompt"). The case-doc's load-bearing
// assertion is that the renderer resolves dropped File objects to
// absolute paths via the preload-bridged
// `claudeAppSettings.filePickers.getPathForFile`, which wraps
// Electron's `webUtils.getPathForFile`. That wiring lives entirely
// in the bundled `mainView.js` preload — case-doc anchors:
//
//   - mainView.js:9267 — `filePickers.getPathForFile` wraps
//     `webUtils.getPathForFile`
//   - mainView.js:9552 — exposed to the renderer as
//     `window.claudeAppSettings`
//
// **Why Tier 1, not Tier 2/3.** A Tier 2/3 OS-level drag-drop test
// would need to put file URIs on the desktop's drag selection so
// Chromium's drop handler fires the path-resolution bridge. Both
// backends are dead-ends with the primitives we have:
//
//   - X11: `xdotool` can simulate mouse motion + button press but
//     cannot put file URIs on the X11 XDND selection. A simulated
//     drag against a marker window arrives at Chromium as a mouse
//     drag with no file payload — the bridge is never exercised.
//     A real OS-level XDND test needs a custom XDND source app
//     (heavy primitive build); deferred.
//   - Wayland: same shape — per-compositor IPC plus libei input
//     injection. Same primitive gap.
//
// Since the load-bearing surface is the bridge wiring (preload
// expose + the `webUtils.getPathForFile` call), pinning the bundle
// strings catches every regression that would matter to the
// case-doc claim, without faking OS drag-drop. Same pattern as
// T35/T36 from session 4: when Tier 2 readback isn't reachable,
// ship the Tier 1 fingerprint against the actual load-bearing
// strings.
//
// **What this catches.** Any rename / removal of the four needles
// in the shipped `mainView.js` preload — i.e. a regression in the
// path-resolution bridge wiring (the property key
// `filePickers.getPathForFile`, the underlying
// `webUtils.getPathForFile` call, or the `claudeAppSettings`
// expose namespace).
//
// **What this does NOT catch.** The OS-level drop handler itself
// — i.e. whether Chromium's drag-drop event actually reaches the
// renderer with file payload on the host's compositor / window
// system. That's a Tier 2/3 concern and stays manual until a
// drag-source primitive lands.
//
// **Bundle vs case-doc anchor form.** The case-doc anchors point
// at the beautified `build-reference/.../mainView.js` line numbers
// (:9267 / :9552); the shipped minified bundle preserves the
// property name and the `webUtils.getPathForFile(` call shape, so
// the case-doc strings are also the bundle needles. No translation
// needed (unlike T35's `~/.claude.json` → `.claude.json`).
//
// Observed counts in the installed asar at write time:
// `getPathForFile` = 2 (property key + the actual call),
// `webUtils` = 1, `filePickers` = 1, `claudeAppSettings` = 1.
// Per-needle occurrence counts are recorded in the attached JSON
// for drift detection (mirrors T36's pattern).
//
// Pure file probe — no app launch. Applies to all rows; no
// skipUnlessRow gate.

interface FingerprintEntry {
	needle: string;
	caseDocAnchor: string;
	rationale: string;
}

const FINGERPRINTS: FingerprintEntry[] = [
	{
		needle: 'getPathForFile',
		caseDocAnchor: 'mainView.js:9267',
		rationale:
			'the renderer-bridged method name. Both occurrences in the ' +
			'bundle (property key + the underlying ' +
			'`webUtils.getPathForFile(` call) live on this single line ' +
			'in the beautified reference. Renaming this is the most ' +
			'load-bearing single regression for the path-resolution ' +
			'bridge.',
	},
	{
		needle: 'webUtils',
		caseDocAnchor: 'mainView.js:9267',
		rationale:
			'the Electron module the bridge wraps. If the preload ever ' +
			'switches away from `webUtils.getPathForFile` (e.g. back to ' +
			'the deprecated `File.path`), this needle disappears even ' +
			'when `getPathForFile` survives elsewhere.',
	},
	{
		needle: 'filePickers',
		caseDocAnchor: 'mainView.js:9267',
		rationale:
			'the property under `claudeAppSettings` the renderer reads. ' +
			'Pins the namespace nesting — if the bridge moves out from ' +
			'under `filePickers`, the renderer call site breaks even ' +
			'when the underlying `webUtils.getPathForFile` wrap is ' +
			'still wired.',
	},
	{
		needle: 'claudeAppSettings',
		caseDocAnchor: 'mainView.js:9552',
		rationale:
			'the `contextBridge.exposeInMainWorld` namespace the ' +
			'renderer accesses as `window.claudeAppSettings`. Without ' +
			'this expose, the renderer never reaches the bridge at all.',
	},
];

const SOURCE_FILE = '.vite/build/mainView.js';

test.setTimeout(15_000);

test('T18 — drag-drop path-resolution bridge asar fingerprints', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab → Prompt area',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	let asarPath: string;
	try {
		asarPath = resolveAsarPath();
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		test.skip(true, `asar not resolvable: ${msg}`);
		return;
	}

	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	let contents: string;
	try {
		contents = readAsarFile(SOURCE_FILE, asarPath);
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		throw new Error(
			`[T18] failed to read ${SOURCE_FILE} from ${asarPath}: ${msg}`,
		);
	}

	// Per-needle occurrence count for drift detection — a future
	// regression that drops the count from N→N-1 (without dropping
	// it to zero) is still load-bearing signal worth surfacing in
	// the attachment. Mirrors T36's pattern.
	const results = FINGERPRINTS.map((entry) => {
		let occurrences = 0;
		let idx = contents.indexOf(entry.needle);
		while (idx !== -1) {
			occurrences += 1;
			idx = contents.indexOf(entry.needle, idx + 1);
		}
		return {
			name: entry.needle,
			anchorRef: entry.caseDocAnchor,
			rationale: entry.rationale,
			count: occurrences,
			found: occurrences > 0,
		};
	});

	await testInfo.attach('drag-drop-bridge-fingerprints', {
		body: JSON.stringify(
			{ asarPath, sourceFile: SOURCE_FILE, needles: results },
			null,
			2,
		),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found).map((r) => r.name);
	expect(
		missing,
		'every drag-drop path-resolution bridge needle is present in ' +
			'the bundled `mainView.js` preload (per ' +
			'code-tab-foundations.md T18 code anchors :9267 / :9552). ' +
			'Missing needle(s) indicate the preload-bridged ' +
			'`claudeAppSettings.filePickers.getPathForFile` wiring has ' +
			'been refactored — re-anchor against the new bundle form.',
	).toEqual([]);
});
