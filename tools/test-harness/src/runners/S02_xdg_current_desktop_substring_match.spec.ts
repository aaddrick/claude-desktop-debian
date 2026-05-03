import { test, expect } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

// S02 — XDG_CURRENT_DESKTOP detection uses substring match.
//
// Backs S02 in docs/testing/cases/distribution.md.
//
// Ubuntu sets XDG_CURRENT_DESKTOP=ubuntu:GNOME (colon-separated,
// distro-prefixed). A naive `== "GNOME"` (or POSIX `= "GNOME"`)
// equality check misses Ubuntu and silently disables every DE-gated
// branch on those rows. The expected pattern is a substring/glob
// match (case-insensitive) over the colon-separated value:
//
//   launcher-common.sh:38-44  →  desktop="${XDG_CURRENT_DESKTOP,,}"
//                                [[ "$desktop" == *niri* ]]
//   quick-window.sh:34-35     →  (process.env.XDG_CURRENT_DESKTOP||"")
//                                  .toLowerCase().includes("kde")
//   quick-window.sh:117-118   →  same shape, injected into index.js
//
// This is a source-tree regression detector: if a future change
// rewrites either gate to a strict-equality form, the runner trips.
// It does NOT assert the presence of any specific good pattern (the
// case doc anchors describe several different shapes — niri glob,
// KDE includes(), runtime JS gate); it asserts the *absence* of the
// bad ones.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.
//
// Path resolution probes, in order:
//   1. $CLAUDE_DESKTOP_REPO_ROOT/scripts (override)
//   2. ../../scripts relative to cwd (dev worktree, where the harness
//      runs from tools/test-harness/)
//   3. /usr/lib/claude-desktop/scripts (deb/rpm install layout)
// If none resolve, the test skips with a reason.

interface BadHit {
	file: string;
	line: number;
	text: string;
}

function resolveScriptsDir(): string | null {
	const env = process.env.CLAUDE_DESKTOP_REPO_ROOT;
	if (env) {
		const p = join(env, 'scripts');
		if (
			existsSync(join(p, 'launcher-common.sh')) &&
			existsSync(join(p, 'patches', 'quick-window.sh'))
		) {
			return p;
		}
	}
	// Dev worktree probe — tools/test-harness lives two dirs deep,
	// so cwd/../../scripts is the repo's scripts/ when tests are run
	// from tools/test-harness/.
	const devProbe = resolve(process.cwd(), '..', '..', 'scripts');
	if (
		existsSync(join(devProbe, 'launcher-common.sh')) &&
		existsSync(join(devProbe, 'patches', 'quick-window.sh'))
	) {
		return devProbe;
	}
	// Installed path (deb/rpm).
	const installedProbe = '/usr/lib/claude-desktop/scripts';
	if (
		existsSync(join(installedProbe, 'launcher-common.sh')) &&
		existsSync(join(installedProbe, 'patches', 'quick-window.sh'))
	) {
		return installedProbe;
	}
	return null;
}

// Bad patterns: shell + JS strict-equality forms against
// XDG_CURRENT_DESKTOP. Each regex is intentionally narrow so the
// expected substring/glob shapes don't false-positive:
//
//   - Shell `[[ "$XDG_CURRENT_DESKTOP" == "GNOME" ]]` — bash strict
//     equality with a *literal* RHS (no glob `*`). The `*niri*`
//     glob form is fine and must NOT match.
//   - Shell `[ "$XDG_CURRENT_DESKTOP" = "GNOME" ]` — POSIX strict
//     equality.
//   - JS `process.env.XDG_CURRENT_DESKTOP === "GNOME"` (and `==`).
//
// Each regex captures the variable on either side of the operator
// so `"GNOME" == "$XDG_CURRENT_DESKTOP"` is also caught.
//
// `lowered` form (`"${XDG_CURRENT_DESKTOP,,}" == *niri*`) uses a
// glob and is allowed; the bad-RHS regexes require the literal to
// have no `*` wildcards inside the quotes.
const BAD_PATTERNS: { name: string; re: RegExp }[] = [
	{
		// bash [[ ... == "literal" ]] with XDG_CURRENT_DESKTOP on
		// either side. RHS literal contains no `*` (glob-free).
		name: 'bash [[ == ]] strict equality (no glob)',
		re: /\[\[[^\]]*\$\{?XDG_CURRENT_DESKTOP[^\]]*==\s*"[^"*]*"[^\]]*\]\]/,
	},
	{
		name: 'bash [[ == ]] strict equality, var on right (no glob)',
		re: /\[\[[^\]]*==\s*"\$\{?XDG_CURRENT_DESKTOP[^\]]*\]\]/,
	},
	{
		// POSIX [ ... = "literal" ] with XDG_CURRENT_DESKTOP.
		name: 'POSIX [ = ] strict equality',
		re: /\[\s+[^]]*\$\{?XDG_CURRENT_DESKTOP[^\]]*=\s*"[^"]*"[^\]]*\]/,
	},
	{
		// JS strict equality (=== or ==) against a string literal.
		// Either single or double quotes; either side of the operator.
		name: 'JS === / == strict equality',
		re: /process\.env\.XDG_CURRENT_DESKTOP\s*===?\s*['"][^'"]*['"]|['"][^'"]*['"]\s*===?\s*process\.env\.XDG_CURRENT_DESKTOP/,
	},
];

function scanFile(absPath: string): BadHit[] {
	const text = readFileSync(absPath, 'utf8');
	const lines = text.split('\n');
	const hits: BadHit[] = [];
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i] ?? '';
		// Cheap pre-filter: only check lines mentioning the env var.
		if (!line.includes('XDG_CURRENT_DESKTOP')) continue;
		for (const { re } of BAD_PATTERNS) {
			if (re.test(line)) {
				hits.push({
					file: absPath,
					line: i + 1,
					text: line.length > 200 ? line.slice(0, 200) + '…' : line,
				});
				break;
			}
		}
	}
	return hits;
}

test('S02 — XDG_CURRENT_DESKTOP detection uses substring match, not strict ==', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / desktop detection',
	});

	const scriptsDir = resolveScriptsDir();
	if (!scriptsDir) {
		test.skip(
			true,
			'No accessible scripts/ dir (set CLAUDE_DESKTOP_REPO_ROOT or install deb/rpm)',
		);
		return;
	}

	await testInfo.attach('scripts-dir', {
		body: scriptsDir,
		contentType: 'text/plain',
	});

	const targets = [
		join(scriptsDir, 'launcher-common.sh'),
		join(scriptsDir, 'patches', 'quick-window.sh'),
	];

	await testInfo.attach('files-checked', {
		body: JSON.stringify(targets, null, 2),
		contentType: 'application/json',
	});

	const allHits: BadHit[] = [];
	for (const t of targets) {
		allHits.push(...scanFile(t));
	}

	await testInfo.attach('bad-pattern-hits', {
		body: JSON.stringify(allHits, null, 2),
		contentType: 'application/json',
	});

	expect(
		allHits,
		// eslint-disable-next-line max-len
		'No strict-equality checks against XDG_CURRENT_DESKTOP — ubuntu:GNOME would miss them. Use substring/glob match (case-insensitive) instead.',
	).toEqual([]);
});
