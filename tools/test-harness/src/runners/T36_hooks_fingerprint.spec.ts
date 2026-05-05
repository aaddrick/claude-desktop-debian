import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T36 — Hooks runtime is wired (file-probe form).
//
// The full T36 case (`SessionStart` hook in `~/.claude/settings.json`
// writes a marker file; `PreToolUse` / `PostToolUse` hook output
// shows up in Verbose transcript) is Tier 3: it needs login plus a
// Code-tab session OPEN against a project. The harness can stage the
// `~/.claude/settings.json` fixture (under `seedFromHost: true`) but
// has no way to drive a Code-tab session start — that's a logged-in
// renderer interaction the AX-tree walker hasn't been taught yet.
// Until that runner exists, this spec is the cheap "the hooks
// runtime is wired in the bundle" signal.
//
// Five colocated string fingerprints, anchored against the case-doc
// `:489098` / `:455717` / `:455819` / `:465680` / `:465754` / `:493411`
// lines. Three single-occurrence Verbose-transcript runtime emits
// carry the load-bearing signal; two registry tokens give context:
//
//   1. `hook_started` — single-occurrence runtime emit at
//      `:493411`. Highest-signal anchor: this is the
//      Verbose-transcript path the case-doc's "Hook output is
//      visible in Verbose transcript mode" claim hangs on. If
//      upstream renames the channel, that claim regresses silently.
//   2. `hook_progress` — sister single-occurrence emit at
//      `:493411`. Same Verbose-transcript path, mid-run progress.
//   3. `hook_response` — sister single-occurrence emit at
//      `:493411`. Same path, terminal hook response.
//   4. `PreToolUse` — built-in hook event registry token (17×
//      across the bundle), case-doc anchor `:455717`. The runtime
//      extends this set; if the registry name changes, settings
//      written against the documented event name stop firing.
//   5. `UserPromptSubmit` — less-common registry token (4×),
//      case-doc anchor `:455819`. Stronger fingerprint than
//      `PostToolUse` (9×) for uniqueness; same load-bearing role.
//
// Three single-occurrence channels colocated with the registry
// tokens is the same shape as T37 (single-occurrence log line +
// filename literal + env-var token): the rare strings pin the exact
// code path, the common strings pin the surrounding wiring.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent
// (the hooks-runtime wiring is in the bundle regardless of desktop
// environment).

interface FingerprintEntry {
	fingerprint: string;
	file: string;
	// Why this string is load-bearing for T36 — surfaced in the
	// attached manifest so a future failure ties straight to the
	// case-doc anchor that introduced it.
	source: string;
}

const FINGERPRINTS: FingerprintEntry[] = [
	{
		fingerprint: 'hook_started',
		file: '.vite/build/index.js',
		source:
			'index.js:493411 — single-occurrence Verbose-transcript ' +
			'runtime emit (hook fire start). Highest-signal anchor: ' +
			'backs the case-doc "Hook output is visible in Verbose ' +
			'transcript mode" claim. Rename here regresses silently.',
	},
	{
		fingerprint: 'hook_progress',
		file: '.vite/build/index.js',
		source:
			'index.js:493411 — sister single-occurrence runtime emit ' +
			'(mid-run hook progress on the Verbose-transcript path).',
	},
	{
		fingerprint: 'hook_response',
		file: '.vite/build/index.js',
		source:
			'index.js:493411 — sister single-occurrence runtime emit ' +
			'(terminal hook response on the Verbose-transcript path).',
	},
	{
		fingerprint: 'PreToolUse',
		file: '.vite/build/index.js',
		source:
			'index.js:455717 — built-in hook event registry token the ' +
			'runtime extends. Pins "the documented event names users ' +
			'wire in `~/.claude/settings.json` still exist in the ' +
			'bundle".',
	},
	{
		fingerprint: 'UserPromptSubmit',
		file: '.vite/build/index.js',
		source:
			'index.js:455819 — less-common hook event registry token ' +
			'(4× in the bundle vs `PostToolUse`\'s 9×). Stronger ' +
			'fingerprint uniqueness; same registry-token role.',
	},
];

test('T36 — hooks runtime code path is wired (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Hooks runtime',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	let asarPath: string;
	try {
		asarPath = resolveAsarPath();
	} catch (err) {
		test.skip(
			true,
			'resolveAsarPath() failed: ' +
				(err instanceof Error ? err.message : String(err)),
		);
		return;
	}

	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Read each unique file once, then check fingerprints against
	// the cached contents. Mirrors T37's manifest shape so future
	// additions slot in without restructuring.
	const fileCache = new Map<string, string>();
	const results: {
		fingerprint: string;
		file: string;
		source: string;
		found: boolean;
		occurrences: number;
	}[] = [];

	for (const entry of FINGERPRINTS) {
		let contents = fileCache.get(entry.file);
		if (contents === undefined) {
			try {
				contents = readAsarFile(entry.file, asarPath);
				fileCache.set(entry.file, contents);
			} catch (err) {
				results.push({
					fingerprint: entry.fingerprint,
					file: entry.file,
					source:
						entry.source +
						' [READ ERROR: ' +
						(err instanceof Error ? err.message : String(err)) +
						']',
					found: false,
					occurrences: 0,
				});
				continue;
			}
		}
		// Per-string occurrence count for drift detection — a future
		// regression that drops the count from N→N-1 (without
		// dropping it to zero) is still load-bearing signal worth
		// surfacing in the attachment.
		let occurrences = 0;
		let idx = contents.indexOf(entry.fingerprint);
		while (idx !== -1) {
			occurrences += 1;
			idx = contents.indexOf(entry.fingerprint, idx + 1);
		}
		results.push({
			fingerprint: entry.fingerprint,
			file: entry.file,
			source: entry.source,
			found: occurrences > 0,
			occurrences,
		});
	}

	await testInfo.attach('hooks-runtime-fingerprints', {
		body: JSON.stringify(results, null, 2),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found);
	expect(
		missing,
		'every hooks-runtime fingerprint is present in the bundled ' +
			'app.asar (per extensibility.md T36 code anchors :493411 / ' +
			':455717 / :455819)',
	).toEqual([]);
});
