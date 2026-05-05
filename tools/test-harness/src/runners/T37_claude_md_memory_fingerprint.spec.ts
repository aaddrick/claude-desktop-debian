import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T37 — `CLAUDE.md` memory loads (file-probe form).
//
// The full T37 case (project `CLAUDE.md` + `~/.claude/CLAUDE.md`
// loaded into the Code-tab session's system prompt; edits picked up
// on the next session start) is Tier 3: it needs login, a Code-tab
// session against a working dir with `CLAUDE.md`, and a way to read
// the resolved system prompt — none of which the harness has today.
// Until that runner exists, this spec is the cheap "memory-loading
// wiring is in the bundle" signal.
//
// Three colocated string fingerprints, anchored against the
// case-doc `:259691` / `:455188` / `:283107` lines:
//
//   1. `[GlobalMemory] Copied CLAUDE.md` — single-occurrence log
//      line at `:455188`. Highest-signal anchor: it's specific
//      enough that any rename/refactor of the global-memory copy
//      path (`zhA(accountId, orgId)` → per-session
//      `.claude/CLAUDE.md`) trips the assertion.
//   2. `CLAUDE.md` — filename literal. Appears in both the
//      working-dir scanner (`:259691`) and the memory copier
//      (`:455188`); broader sentinel that catches a regression
//      gutting either path even if the log line at (1) was
//      renamed.
//   3. `CLAUDE_CONFIG_DIR` — env var `cE()` resolves at
//      `:283107`; the dir whose `CLAUDE.md` the agent SDK loads
//      via `settingSources: ["user", ...]` (T36 anchor `:489098`).
//
// An inspector-eval form (place a fixture `~/.claude/CLAUDE.md`,
// launch, read parsed memory state) was considered and deferred:
// the parsed memory likely lives in a closure-local minified
// helper not reachable from `globalThis`. Session 2 hit this exact
// failure mode on S28 — `Sbn()` is a closure-local with no IPC
// surface, so S28 was reclassified Tier 2 → Tier 1. Without a
// verified inspector-eval target for the memory state, the
// fixture-readback form is speculative; it can ship as T37b once a
// future session proves a reachable surface (a known main-process
// global, or an IPC handler that returns the parsed memory).
//
// Pure file probe — no app launch. Fast (<1s). Row-independent
// (memory-loading wiring is in the bundle regardless of desktop
// environment).

interface FingerprintEntry {
	fingerprint: string;
	file: string;
	// Why this string is load-bearing for T37 — surfaced in the
	// attached manifest so a future failure ties straight to the
	// case-doc anchor that introduced it.
	source: string;
}

const FINGERPRINTS: FingerprintEntry[] = [
	{
		fingerprint: '[GlobalMemory] Copied CLAUDE.md',
		file: '.vite/build/index.js',
		source:
			'index.js:455188 — single-occurrence log line emitted ' +
			'when global account memory `zhA(accountId, orgId)` is ' +
			'copied to the per-session `.claude/CLAUDE.md`. ' +
			'Highest-signal anchor for the memory-copy code path.',
	},
	{
		fingerprint: 'CLAUDE.md',
		file: '.vite/build/index.js',
		source:
			'index.js:259691 (working-dir scan reads `CLAUDE.md` and ' +
			'`.claude/CLAUDE.md`) and :455188 (memory copier). ' +
			'Filename literal — broader sentinel covering both the ' +
			'project-dir read path and the global-memory copy path.',
	},
	{
		fingerprint: 'CLAUDE_CONFIG_DIR',
		file: '.vite/build/index.js',
		source:
			'index.js:283107 — env var `cE()` resolves (falls back ' +
			'to `~/.claude`); the dir whose `CLAUDE.md` the agent ' +
			'SDK loads via `settingSources: ["user", ...]` (T36 ' +
			'anchor :489098).',
	},
];

test('T37 — CLAUDE.md memory-loading code path is wired (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Memory / Code tab session prompt',
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
	// the cached contents. Mirrors T11's manifest shape so future
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

	await testInfo.attach('claude-md-memory-fingerprints', {
		body: JSON.stringify(results, null, 2),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found);
	expect(
		missing,
		'every CLAUDE.md memory-loading fingerprint is present in the ' +
			'bundled app.asar (per extensibility.md T37 code anchors ' +
			':259691 / :455188 / :283107)',
	).toEqual([]);
});
