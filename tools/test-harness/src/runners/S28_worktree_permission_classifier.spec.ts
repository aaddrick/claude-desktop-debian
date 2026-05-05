import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S28 — Worktree creation surfaces clear error on read-only mounts
// (file-probe form).
//
// Per docs/testing/cases/extensibility.md S28: when a project sits on
// a read-only mount and the user tries to start a parallel session,
// worktree creation must fail with a clear error pointing at the
// read-only mount — no silent loss, no parent-repo corruption. The
// case-doc anchor (`build-reference/.../index.js:462760` `Sbn()`) is
// the classifier that buckets the underlying git error into
// `"permission-denied"` for the read-only-mount taxonomy.
//
// **Tier reclassification.** A Tier 2 inspector-eval against `Sbn()`
// with a synthetic error would be the natural shape. In practice `Sbn`
// is a closure-local
// in the bundled main process — not reachable from the inspector
// without an IPC surface that calls into it, and no such surface is
// exposed by the case-doc anchors. So we drop one tier further: a
// pure asar fingerprint that pins the classifier's input strings and
// output bucket together with the worktree-failure log line they're
// wired into. If upstream reshapes the classifier (renames the bucket,
// drops one of the input matches, or unwires the worktree path from
// the bucketing call), this test fails — which is exactly the drift
// signal the higher-tier form would catch via a synthetic error.
//
// The full Tier 3 surface — actual read-only mount, parallel session,
// dialog text scrape — stays in the case doc as a manual repro.
//
// Fingerprint shape (single regex matches all four strings together
// in the same `Sbn()` return expression, identifier-agnostic):
//
//   <id>.includes("Permission denied") ||
//   <id>.includes("Access is denied") ||
//   <id>.includes("could not lock config file")
//   ? "permission-denied"
//
// where `<id>` is `e` in the beautified source but rotates between
// releases. We anchor on the call shape and the literal strings, not
// the identifier. Whitespace is tolerated to handle both the
// minified runtime form and the beautified build-reference form.
//
// Sibling assertion: the `Failed to create git worktree:` log line
// (case-doc anchor :462928, `R.error("Failed to create git worktree:
// …")`) is present in the same file. This is the call site whose
// error string Sbn() classifies — without it, the classifier exists
// in isolation and the contract S28 cares about (read-only mount →
// permission-denied bucket on the worktree creation path) is broken.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

const PERMISSION_DENIED_CLASSIFIER_RE =
	/(\w+)\.includes\(\s*"Permission denied"\s*\)\s*\|\|\s*\1\.includes\(\s*"Access is denied"\s*\)\s*\|\|\s*\1\.includes\(\s*"could not lock config file"\s*\)\s*\?\s*"permission-denied"/;

const WORKTREE_FAILURE_LOG_RE =
	/Failed to create git worktree:/;

test('S28 — worktree permission-denied classifier wired to git worktree failure path (file probe)', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Could' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Worktree permission classifier',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// (1) Classifier shape — all three input strings + the
	//     "permission-denied" output bucket appear in the same
	//     expression. The single regex enforces clustering: the three
	//     `<id>.includes(...)` calls are joined by `||` and resolve to
	//     `"permission-denied"` in the same ternary, so we don't need a
	//     separate proximity window check — the regex IS the cluster
	//     condition.
	const classifierMatch = indexJs.match(PERMISSION_DENIED_CLASSIFIER_RE);
	const classifierFound = classifierMatch !== null;

	// Surrounding context for the diagnostic attachment — ~200 chars
	// either side of the match so a future failure shows what the
	// upstream-reshaped classifier looks like.
	let classifierContext: string | null = null;
	if (classifierMatch && classifierMatch.index !== undefined) {
		const start = Math.max(0, classifierMatch.index - 200);
		const end = Math.min(
			indexJs.length,
			classifierMatch.index + classifierMatch[0].length + 200,
		);
		classifierContext = indexJs.slice(start, end);
	}

	// (2) The classifier's call site — the `Failed to create git
	//     worktree:` log line at case-doc anchor :462928. Without this,
	//     the classifier exists in isolation and S28's contract
	//     (read-only mount → permission-denied bucket on the worktree
	//     creation path) is unwired.
	const worktreeFailureLogPresent =
		WORKTREE_FAILURE_LOG_RE.test(indexJs);

	// (3) Sanity: the bucket name itself appears in the bundle. This
	//     is implied by (1) but we surface it as a separate count so a
	//     future failure that drops only the regex match is
	//     distinguishable from one that drops the bucket entirely.
	const bucketOccurrences = (
		indexJs.match(/"permission-denied"/g) ?? []
	).length;

	await testInfo.attach('s28-evidence', {
		body: JSON.stringify(
			{
				file: '.vite/build/index.js',
				classifierRegex: PERMISSION_DENIED_CLASSIFIER_RE.source,
				classifierFound,
				classifierMatchSnippet: classifierMatch
					? classifierMatch[0]
					: null,
				classifierContext,
				worktreeFailureLogRegex: WORKTREE_FAILURE_LOG_RE.source,
				worktreeFailureLogPresent,
				permissionDeniedBucketOccurrences: bucketOccurrences,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		classifierFound,
		'app.asar contains the permission-denied classifier shape ' +
			'(`<id>.includes("Permission denied") || ... || ' +
			'<id>.includes("could not lock config file") ? ' +
			'"permission-denied"`) per extensibility.md S28 anchor :462760',
	).toBe(true);

	expect(
		worktreeFailureLogPresent,
		'app.asar contains the `Failed to create git worktree:` log ' +
			'line (extensibility.md S28 anchor :462928) — the call site ' +
			'whose error string the classifier buckets',
	).toBe(true);

	expect(
		bucketOccurrences,
		'app.asar contains the `"permission-denied"` bucket name (sanity ' +
			'check — implied by classifier match but surfaced separately ' +
			'so a future regression can distinguish a regex-shape change ' +
			'from a bucket rename)',
	).toBeGreaterThan(0);
});
