import { test, expect } from '@playwright/test';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T14a — Single-instance lock + second-instance listener wired
// (file probe).
//
// T14 in docs/testing/cases/launch.md covers multi-instance
// behavior: a second invocation of `claude-desktop` should focus
// the existing window rather than spawning a fresh process. The
// case-doc anchors point at two upstream sites in the bundled
// main process:
//
//   build-reference/app-extracted/.vite/build/index.js:525162-525173
//     hA.app.requestSingleInstanceLock()
//       ? hA.app.on("second-instance", (A, t, i) => {
//           ...
//           ut.isVisible() || ut.show(),
//           ut.isMinimized() && ut.restore(),
//           ut.focus());
//         })
//       : hA.app.quit();
//
//   build-reference/app-extracted/.vite/build/index.js:525204-525207
//     hA.app.on("ready", async () => {
//       ...
//       if (!Zr && !hA.app.requestSingleInstanceLock()) {
//         R.info("Not main instance, returning early from app ready");
//         return;
//       }
//
// T14 is split across two specs:
//
//   - T14a (this file, Tier 1) — file-level fingerprint. Verifies
//     `requestSingleInstanceLock` and the `'second-instance'`
//     listener event name exist in the bundled JS. Cheap (<1s),
//     row-independent, no app launch. Catches an upstream rename or
//     a future patch accidentally stripping the gate.
//
//   - T14b (Tier 2, lands separately) — runtime second-launch
//     behavior assertion: spawn the app, spawn it again, verify no
//     new pid appears and the existing window gets focus. Needs a
//     real launch + window-state probe + pgrep delta, which is why
//     it's deferred to a later tier.
//
// Pure file probe. Tag matches T14's case-doc severity: Critical.

test('T14a — Single-instance lock + second-instance listener wired (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'App lifecycle / single instance',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Both fingerprints live in `.vite/build/index.js`. Probe with
	// `asarContains` against the same archive twice — @electron/asar
	// reads are cheap enough that a per-call read keeps the assertion
	// shape simple without needing to cache.
	const lockCallPresent = asarContains(
		'.vite/build/index.js',
		'requestSingleInstanceLock',
		asarPath,
	);
	const secondInstanceListenerPresent = asarContains(
		'.vite/build/index.js',
		'second-instance',
		asarPath,
	);

	await testInfo.attach('fingerprints', {
		body: JSON.stringify(
			{
				lockCallPresent,
				secondInstanceListenerPresent,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		lockCallPresent,
		'app.asar contains requestSingleInstanceLock() — single-instance gate wired',
	).toBe(true);
	expect(
		secondInstanceListenerPresent,
		"app.asar contains 'second-instance' listener event name",
	).toBe(true);
});
