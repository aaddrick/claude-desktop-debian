import { test, expect } from '@playwright/test';
import { asarContains, readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T32 — Slash command menu (Tier 1 asar fingerprint slice).
//
// Per docs/testing/cases/code-tab-workflow.md T32: typing `/` in a
// Code-tab session prompt opens the slash menu listing built-in
// commands, custom skills under `~/.claude/skills/`, project skills,
// and skills from installed plugins. Confirming the FULL contract is
// Tier 3 — it requires login + an OPEN Code-tab session + a renderer
// surface that lives in claude.ai's remote bundle (the slash-menu UI
// itself), plus an AX-tree query against the popup. What this runner
// pins is the Tier 1 surface: the IPC pipeline that the renderer
// uses to fetch the supported-commands list at all.
//
// Two load-bearing fingerprints anchored as plain string matches in
// `.vite/build/index.js`:
//
//   (1) `LocalSessions_$_getSupportedCommands` — the IPC channel
//       suffix the renderer invokes to discover the slash-command
//       set (case-doc anchor index.js:459463 —
//       `getSupportedCommands({sessionId})` aggregates per-session
//       `slashCommands` + cowork command registry + built-ins).
//       Without this channel name in the bundle, there is no IPC
//       surface for the renderer to fetch the list at all and the
//       menu is empty / broken silently.
//
//   (2) `slashCommands` — the schema field name used in the
//       supported-commands response shape (case-doc anchor
//       index.js:332711 — `slashCommands: Di.array(Di.string())
//       .optional()` on the session record). Without this field in
//       the response schema, the renderer can't parse the list it
//       just fetched.
//
// The two together are the load-bearing signals that the
// slash-command pipeline is wired end-to-end through main: an IPC
// channel exists for the renderer to fetch supported commands, and
// the schema field that carries the result set is present in the
// same bundle.
//
// Note on framing: the IPC channel itself is wrapped at runtime as
// `$eipc_message$_<UUID>_$_claude.web_$_LocalSessions_$_<name>`
// (precedent: T38 / T31 / T33). Here we are checking the
// `LocalSessions_$_getSupportedCommands` SUFFIX as a static string in
// the bundled source — we are NOT introspecting
// `ipcMain._invokeHandlers` at runtime (that's the Tier 2 pattern in
// T38 and T31). The static check survives without launching the app
// and without the renderer having to be in any particular state.
//
// Layer: pure file probe (asar read). No app launch. Fast (<1 s).
// Row-independent.

interface FingerprintEntry {
	fingerprint: string;
	file: string;
	// Why this string is load-bearing for T32 — surfaced in the
	// attached diagnostic so a future failure ties straight to the
	// case-doc anchor that introduced it.
	source: string;
}

const FINGERPRINTS: FingerprintEntry[] = [
	{
		fingerprint: 'LocalSessions_$_getSupportedCommands',
		file: '.vite/build/index.js',
		source:
			'index.js:459463 — `getSupportedCommands({sessionId})` IPC ' +
			'channel suffix. Renderer invokes this to fetch the ' +
			'aggregated slash-command set (per-session slashCommands + ' +
			'cowork command registry + built-ins).',
	},
	{
		fingerprint: 'slashCommands',
		file: '.vite/build/index.js',
		source:
			'index.js:332711 — `slashCommands: Di.array(Di.string())' +
			'.optional()` schema field on the session record. Carries ' +
			'the result set the renderer parses out of the ' +
			'getSupportedCommands response.',
	},
];

test('T32 — slash-command menu IPC + schema fingerprint (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — Slash command menu',
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
			`T32 needs an installed claude-desktop app.asar — ${msg}`,
		);
		return;
	}

	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Read once for the occurrence-count diagnostic, then use
	// asarContains() (which re-reads internally) for the assertion
	// path so the load-bearing call shape matches the S28 / H03
	// precedent.
	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	const occurrences: Record<string, number> = {};
	for (const entry of FINGERPRINTS) {
		// Plain substring count — these are literal strings, no regex
		// metachars, so split-length is the cleanest way to count
		// without a global-regex escape dance.
		occurrences[entry.fingerprint] =
			indexJs.split(entry.fingerprint).length - 1;
	}

	const ipcPresent = asarContains(
		'.vite/build/index.js',
		'LocalSessions_$_getSupportedCommands',
		asarPath,
	);
	const schemaPresent = asarContains(
		'.vite/build/index.js',
		'slashCommands',
		asarPath,
	);

	await testInfo.attach('t32-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				fingerprints: FINGERPRINTS.map((f) => ({
					fingerprint: f.fingerprint,
					source: f.source,
					found:
						f.fingerprint === 'LocalSessions_$_getSupportedCommands'
							? ipcPresent
							: schemaPresent,
					occurrences: occurrences[f.fingerprint],
				})),
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	// (1) The IPC channel suffix the renderer invokes to fetch the
	//     slash-command set. Without this, no IPC surface exists for
	//     the renderer to populate the menu.
	expect(
		ipcPresent,
		'app.asar contains the `LocalSessions_$_getSupportedCommands` ' +
			'IPC channel suffix (case-doc T32 anchor index.js:459463) — ' +
			'the renderer invokes this to fetch the aggregated slash- ' +
			'command set (per-session slashCommands + cowork registry + ' +
			'built-ins)',
	).toBe(true);

	// (2) The schema field that carries the result set in the
	//     supported-commands response shape. Without this, the
	//     renderer can't parse the list it just fetched.
	expect(
		schemaPresent,
		'app.asar contains the `slashCommands` schema field name ' +
			'(case-doc T32 anchor index.js:332711) — schema field on ' +
			'the session record carrying the slash-command result set ' +
			'in the getSupportedCommands response',
	).toBe(true);
});
