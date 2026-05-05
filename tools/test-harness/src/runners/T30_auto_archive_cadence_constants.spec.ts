import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T30 — Auto-archive on PR merge (Tier 1 asar fingerprint slice).
//
// Per docs/testing/cases/code-tab-workflow.md T30: when
// `ccAutoArchiveOnPrClose` is on, the AutoArchiveEngine sweep runs
// every 5 minutes (300_000 ms) with a 30 s startup delay, and a
// 1-hour (3_600_000 ms) recheck cooldown for sessions whose PR state
// isn't yet terminal. Confirming the FULL contract requires a real
// login + a real PR + a 5-minute wait (Tier 3+, manual). What this
// runner pins is the Tier 1 surface: the engine is wired, the gate
// key the sweep checks is bundled, and the cadence constants live
// next to it in the same module body.
//
// Three colocated checks — anchored as a single regex match against
// `.vite/build/index.js` so all three pieces have to drift together
// for the test to keep passing past a real upstream rewrite:
//
//   (1) `AutoArchiveEngine` — engine class wiring. The literal name
//       is preserved by the bundler in two places: the dynamic import
//       (`{AutoArchiveEngine:c}=await Promise.resolve().then(...)`)
//       and the ESM-export registry
//       (`Object.defineProperty({__proto__:null,AutoArchiveEngine:z3n},...)`).
//       The class itself is minified to `z3n` in the runtime form,
//       but the export name survives as a string. Three occurrences
//       inside the class body (`R.error("[AutoArchiveEngine] ...")`,
//       `R.info(...)`) further confirm the same engine module.
//
//   (2) `ccAutoArchiveOnPrClose` — the settings gate. `sweep()`
//       short-circuits on `Qi("ccAutoArchiveOnPrClose")` (case-doc
//       anchor :533537); the key also appears as the default-`!1`
//       entry in the settings record (:55269). If the gate key is
//       renamed without migrating settings storage, the sweep is
//       silently unreachable.
//
//   (3) Cadence constants — `300*1e3` immediately followed by
//       `3600*1e3` (the runtime form of `$3n = 300_000` and
//       `W3n = 3_600_000` the case-doc cites in beautified form).
//       Both literals appear ~20× / ~8× respectively across the
//       bundle, so we only count the colocated pair as evidence —
//       a single literal could be any unrelated 5-min / 1-hour
//       timer.
//
// **Proximity window.** The four pieces appear in the runtime bundle
// in a single 1.8 KB window in the order:
//
//     `300*1e3,W3n=3600*1e3,Fst=10;class z3n{...
//      Qi("ccAutoArchiveOnPrClose")...
//      [AutoArchiveEngine] Sweep failed...
//      [AutoArchiveEngine] Archiving...
//      [AutoArchiveEngine] checkAndArchive failed...
//      AutoArchiveEngine:z3n}`
//
// We anchor the regex on `300*1e3` → `3600*1e3` (≤200 char gap;
// confirmed 12 chars in the current bundle, leaving slack for a
// minifier that inserts a few intermediate declarations) → tail
// `AutoArchiveEngine` (≤3000 char gap; confirmed ~1800 chars in
// the current bundle, leaving room for the class body to grow
// before the export registry without retiring the test). A
// post-match `.includes("ccAutoArchiveOnPrClose")` check on the
// captured window pins the gate key inside the same span.
//
// The window was sized by inspecting the installed asar: at write
// time exactly one global match exists in the bundle, and the
// captured span is ~1.8 KB. A 3 KB tail tolerates ~70% body growth
// before the test starts producing false negatives — tight enough
// to catch class extraction (engine moved to a different module,
// constants stay behind) but loose enough to survive normal
// minifier-driven reflow.
//
// Layer: pure file probe (asar read). No app launch. Fast (<1 s).

const CADENCE_FINGERPRINT_RE =
	/300\*1e3[\s\S]{0,200}3600\*1e3[\s\S]{0,3000}AutoArchiveEngine/;

test('T30 — auto-archive engine + gate key + cadence constants colocated in bundle (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Sidebar',
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
		test.skip(
			true,
			`T30 needs an installed claude-desktop app.asar — ${msg}`,
		);
		return;
	}

	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// (A) Cadence + class fingerprint as a single colocated match.
	const fingerprintMatch = indexJs.match(CADENCE_FINGERPRINT_RE);
	const fingerprintFound = fingerprintMatch !== null;
	const fingerprintSnippet =
		fingerprintMatch !== null
			? fingerprintMatch[0].slice(0, 200)
			: null;
	const fingerprintLength =
		fingerprintMatch !== null ? fingerprintMatch[0].length : 0;

	// (B) Inside that window, the settings-gate key MUST appear —
	//     otherwise the cadence-constant cluster could match an
	//     unrelated 5-min / 1-hour timer + an unrelated
	//     `AutoArchiveEngine` reference.
	const gateKeyInWindow =
		fingerprintMatch !== null &&
		fingerprintMatch[0].includes('ccAutoArchiveOnPrClose');

	// (C) Standalone occurrence counts — surfaced separately so a
	//     future regression that drops only the proximity match (e.g.
	//     class extracted to its own module) is distinguishable from
	//     one that drops a constituent piece entirely (e.g. gate-key
	//     rename, engine deleted).
	const autoArchiveEngineCount = (
		indexJs.match(/AutoArchiveEngine/g) ?? []
	).length;
	const ccAutoArchiveOnPrCloseCount = (
		indexJs.match(/ccAutoArchiveOnPrClose/g) ?? []
	).length;
	const fiveMinuteCount = (indexJs.match(/300\*1e3/g) ?? []).length;
	const oneHourCount = (indexJs.match(/3600\*1e3/g) ?? []).length;

	await testInfo.attach('t30-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				fingerprintRegex: CADENCE_FINGERPRINT_RE.source,
				fingerprintFound,
				fingerprintLength,
				fingerprintSnippet,
				gateKeyInWindow,
				occurrences: {
					AutoArchiveEngine: autoArchiveEngineCount,
					ccAutoArchiveOnPrClose: ccAutoArchiveOnPrCloseCount,
					'300*1e3': fiveMinuteCount,
					'3600*1e3': oneHourCount,
				},
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		fingerprintFound,
		'app.asar contains the cadence-constant + AutoArchiveEngine ' +
			'colocation (`300*1e3 ... 3600*1e3 ... AutoArchiveEngine` ' +
			'within ≤3.2 KB) per code-tab-workflow.md T30 anchors ' +
			':533517 (cadence) and :533520 (AutoArchiveEngine.start)',
	).toBe(true);

	expect(
		gateKeyInWindow,
		'the colocated cadence-fingerprint window contains the ' +
			'`ccAutoArchiveOnPrClose` settings gate key (T30 anchor ' +
			':533537 — `sweep()` gates on `Qi("ccAutoArchiveOnPrClose")`)',
	).toBe(true);

	expect(
		autoArchiveEngineCount,
		'app.asar contains the `AutoArchiveEngine` engine class name ' +
			'(sanity check — surfaced separately so a future drop in ' +
			'this count is distinguishable from a colocation-only ' +
			'regression)',
	).toBeGreaterThan(0);

	expect(
		ccAutoArchiveOnPrCloseCount,
		'app.asar contains the `ccAutoArchiveOnPrClose` settings key ' +
			'(sanity check — implied by gateKeyInWindow but surfaced ' +
			'separately so a future rename is distinguishable from a ' +
			'colocation-only regression)',
	).toBeGreaterThan(0);
});
