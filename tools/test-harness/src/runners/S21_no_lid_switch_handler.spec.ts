import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// S21 — Lid-close still suspends per OS policy (absence probe).
//
// S20 covers the positive side: "Keep computer awake" calls
// powerSaveBlocker.start('prevent-app-suspension'), which Electron
// maps to a logind inhibit lock with what='idle:sleep'. S21 is the
// negative complement — the app must NOT install any
// `handle-lid-switch` override, otherwise lid-close stops invoking
// logind's `HandleLidSwitch=suspend` policy.
//
// Per the case-doc Code anchors:
//   "no `handle-lid-switch` / `HandleLidSwitch` token anywhere in
//    `index.js` (verified via grep -nE 'lid|HandleLidSwitch|handle-lid'
//    index.js)"
//
// We assert the lowercase D-Bus form (`handle-lid-switch`) and the
// systemd-config form (`HandleLidSwitch`) are both absent. If either
// surfaces in a future bundle that's a regression worth flagging:
// Electron exposes both as inhibit-what tokens (D-Bus side) and
// logind property names (config side), and any mention in the bundle
// implies the app started reasoning about lid behavior on its own.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent
// (applies to all laptop hosts; desktops still pass trivially since
// the bundle is identical across rows).

test('S21 — App does not handle lid-switch (file probe / absence)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Suspend inhibitor scope',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// Two absence checks — the D-Bus inhibit-what form (lowercase,
	// hyphenated) and the systemd-logind config-property form. The
	// case-doc grep covers both.
	const lowerForm = 'handle-lid-switch';
	const upperForm = 'HandleLidSwitch';
	const lowerPresent = indexJs.includes(lowerForm);
	const upperPresent = indexJs.includes(upperForm);

	await testInfo.attach('lid-switch-probe', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				checks: [
					{ needle: lowerForm, present: lowerPresent },
					{ needle: upperForm, present: upperPresent },
				],
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		lowerPresent,
		'no `handle-lid-switch` string in bundle (lid-close defers to OS)',
	).toBe(false);
	expect(
		upperPresent,
		'no `HandleLidSwitch` string in bundle (lid-close defers to OS)',
	).toBe(false);
});
