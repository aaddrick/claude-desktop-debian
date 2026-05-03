import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// T11 — Plugin install (Anthropic & Partners), file-level fingerprint.
//
// The full T11 case (Code-tab → + → Plugins → Add plugin → Install →
// landed under Manage plugins → re-install idempotent) is Tier 3:
// the install handshake hits the Anthropic API, which requires a
// signed-in claude.ai. Until that end-to-end runner exists, this
// spec is the cheap "install code path is wired into the bundle"
// signal — if these strings are missing, the upstream rename or
// refactor that removed them would silently break the Tier 3 flow
// the moment it gets written, and a build that ships without the
// install plumbing would pass the rest of the harness with zero
// indication anything is wrong.
//
// Two fingerprints, both pinned to STRING LITERALS the install code
// path itself emits/uses (not strings the path matches against):
//
//   1. `[CustomPlugins] installPlugin: attempting remote API install`
//      — the log line emitted at index.js:507193 when the gate
//      accepts and the remote-API branch fires (see case-doc T11
//      Code anchors and docs/learnings/plugin-install.md "Install
//      Gate"). If this string disappears, either the log was
//      removed or the whole `installPlugin` IPC handler was
//      restructured — both cases drift far enough from current
//      behavior that the click-chain Tier 3 spec needs revisiting.
//
//   2. `installed_plugins.json` — the per-user idempotency record
//      written under `dx()` (index.js:465822). T11's "re-install is
//      idempotent" expectation rides on this file's read/write.
//      Also load-bears for S27 (per-user storage) — its absence
//      from the bundle would mean both T11 and S27's plumbing
//      moved.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent
// (the install code path is in the bundle regardless of desktop
// environment).

interface FingerprintEntry {
	fingerprint: string;
	file: string;
	// Why this string is load-bearing for T11 — surfaced in the
	// attached manifest so a future failure ties straight to the
	// case-doc anchor that introduced it.
	source: string;
}

const FINGERPRINTS: FingerprintEntry[] = [
	{
		fingerprint:
			'[CustomPlugins] installPlugin: attempting remote API install',
		file: '.vite/build/index.js',
		source:
			'index.js:507193 — log line on the remote-API branch of ' +
			"the installPlugin gate (pluginSource === 'remote'). Case-doc " +
			'T11 Code anchors; docs/learnings/plugin-install.md "Install Gate".',
	},
	{
		fingerprint: 'installed_plugins.json',
		file: '.vite/build/index.js',
		source:
			'index.js:465822 — per-user idempotency record under dx() ' +
			"(`~/.claude/plugins/`). T11 step 4 ('re-install idempotent') " +
			'and S27 (per-user storage) both ride on this path.',
	},
];

test('T11 — Plugin install code path is wired (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Plugin install / extensibility',
	});

	// Applies to all rows — fingerprints are in the bundle,
	// row-independent. Login-required end-to-end coverage of T11
	// (gate → API → Manage plugins → idempotent re-install) lives
	// in a Tier 3 follow-up; this is the cheap drift sentinel.

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	// Read each unique file once, then check fingerprints against
	// the cached contents. Mirrors H03's manifest shape so future
	// additions slot in without restructuring.
	const fileCache = new Map<string, string>();
	const results: {
		fingerprint: string;
		file: string;
		source: string;
		found: boolean;
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
				});
				continue;
			}
		}
		results.push({
			fingerprint: entry.fingerprint,
			file: entry.file,
			source: entry.source,
			found: contents.includes(entry.fingerprint),
		});
	}

	await testInfo.attach('plugin-install-fingerprints', {
		body: JSON.stringify(results, null, 2),
		contentType: 'application/json',
	});

	const missing = results.filter((r) => !r.found);
	expect(
		missing,
		'every plugin-install fingerprint is present in the bundled app.asar',
	).toEqual([]);
});
