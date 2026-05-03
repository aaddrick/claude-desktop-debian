import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { skipUnlessRow } from '../lib/row.js';

// S08 — Tray rebuild-race fast-path injected (file probe).
//
// Backs the static side of S08 in
// docs/testing/cases/tray-and-window-chrome.md. T03 already covers the
// runtime SNI-count assertion (post-`nativeTheme.themeSource` toggle:
// exactly one StatusNotifierItem stays registered). This spec is the
// complementary build-time fingerprint — verifies that
// `patch_tray_inplace_update` in scripts/patches/tray.sh actually
// landed in the bundled `index.js`, so a silent regex miss in the
// patch script (idempotency guard short-circuits, anchor regex drifts
// against minifier churn, etc.) is observable without having to wait
// for a runtime tray-duplication failure on KDE.
//
// Fingerprint: literal `.setImage(` substring in
// `.vite/build/index.js`.
//
// Why this is load-bearing and stable:
//
//   - Pristine upstream (`build-reference/app-extracted/.vite/build/
//     index.js`) contains zero `.setImage(` occurrences. The tray
//     constructs exclusively via `new <EL>.Tray(<EL>.nativeImage
//     .createFromPath(...))` and never re-images in place. (Verified
//     by `grep -cE '\.setImage\s*\(' index.js` → 0.)
//   - The injected fast-path emitted by `patch_tray_inplace_update`
//     (scripts/patches/tray.sh:212-217) calls
//     `<TRAY_VAR>.setImage(<EL_VAR>.nativeImage.createFromPath(
//     <PATH_VAR>))` — that is the entire point of the fast-path
//     (skip destroy + recreate, update the existing Tray's image in
//     place so the SNI registration stays put on KDE Plasma).
//   - The Electron API name `setImage` is not a minified local —
//     it's a method on `Tray.prototype` and stays literal across
//     upstream version bumps regardless of the bundler's variable
//     renaming. So the fingerprint is robust to the same minifier
//     churn that forces tray.sh to extract `tray_var` / `electron_var`
//     / `path_var` dynamically.
//   - Idempotency marker in tray.sh:174-180 keys on the same literal
//     post-rename `setImage(<EL>.nativeImage.createFromPath(<PATH>))`
//     sequence; presence of `.setImage(` therefore tracks 1:1 with
//     the patch's own self-detection.
//
// Why not the other candidates considered:
//
//   - `_trayStartTime`: already covered by H03 for the prior tray.sh
//     sub-patch (`patch_tray_menu_handler`). H03's note explicitly
//     calls out that the in-place update sub-patch needs its own
//     fingerprint, which is what S08 supplies here.
//   - `process.platform!=="darwin"`: appears 50+ times in the
//     minified bundle (every Electron-on-Linux / -on-Windows
//     branch). Not distinctive.
//   - `setContextMenu` count >= 2: works (upstream has exactly one
//     occurrence; patched bundle has two — fast-path + slow-path),
//     but is brittle to any future upstream code that calls
//     `setContextMenu` for an unrelated reason. `.setImage(`
//     presence-only is stricter and simpler.
//
// Pure file probe — no app launch. Fast (<1s). Row-gated to KDE
// (case-doc Applies-to: KDE-W, KDE-X) since the underlying SNI
// rebuild race only manifests on KDE Plasma's `systemtray` widget;
// other DEs handle UnregisterItem/Register sequencing without the
// duplicate-icon visual artifact, so the fast-path is a should-have
// there but the assertion isn't load-bearing for the row.

test('S08 — Tray rebuild-race fast-path injected (file probe)', async ({}, testInfo) => {
	skipUnlessRow(testInfo, ['KDE-W', 'KDE-X']);

	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Tray icon / KDE rebuild race',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// `.setImage(` is the patch-injected literal. Match-count is
	// surfaced for diagnostics: 0 = patch missed, 1+ = patch landed.
	// (We don't pin to exactly 1 — if upstream ever ships a
	// legitimate second `.setImage(` site, the patch's fast-path is
	// still present and S08 should still pass.)
	const setImageCount = (indexJs.match(/\.setImage\s*\(/g) ?? []).length;
	const fastPathPresent = setImageCount > 0;

	// Bonus diagnostic signal: the slow-path destroy+recreate block
	// is preserved by the patch (it stays in place for initial-
	// creation and tray-disable cases — see tray.sh:182-188 and
	// docs/learnings/tray-rebuild-race.md "The fix"). So a healthy
	// patched bundle has >= 1 `setContextMenu` call (slow path) and
	// >= 1 `.setImage(` call (fast path). Pristine upstream has
	// exactly 1 `setContextMenu` and 0 `.setImage(`.
	const setContextMenuCount = (
		indexJs.match(/\.setContextMenu\s*\(/g) ?? []
	).length;

	await testInfo.attach('fingerprint-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				fingerprint: '.setImage(',
				setImageCount,
				setContextMenuCount,
				fastPathPresent,
				source:
					'patches/tray.sh:212-217 (patch_tray_inplace_update) ' +
					'injects `<TRAY>.setImage(<EL>.nativeImage.' +
					'createFromPath(<PATH>))` before the destroy+recreate ' +
					'block. Upstream never calls .setImage on the tray, ' +
					'so non-zero count == patch landed.',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		fastPathPresent,
		'app.asar contains the in-place `.setImage(` call injected by ' +
			'patch_tray_inplace_update (scripts/patches/tray.sh)',
	).toBe(true);
});
