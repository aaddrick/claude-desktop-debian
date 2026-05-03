import { test, expect } from '@playwright/test';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T22 — PR monitoring read-only Tier 1 fingerprint.
//
// Backs T22 in docs/testing/cases/code-tab-workflow.md ("PR monitoring
// via `gh`"). The Tier 3 form opens a real PR via Claude Code,
// requires an authenticated `gh` CLI, and writes to the user's GitHub
// account; that surface stays manual until we have a sacrificial test
// account + ephemeral repo.
//
// **Session 3 reclassification.** This started as a Tier 2 reframe
// using `ipcMain._invokeHandlers` introspection (T38 pattern from
// session 2) for `LocalSessions_$_getPrChecks`. KDE-W run revealed
// that registry holds only 3 chat-tab MCP-bridge handlers
// (`list-mcp-servers`, `connect-to-mcp-server`,
// `request-open-mcp-settings`); the `LocalSessions_*` and
// `CustomPlugins_*` channels use a separate **eipc** custom protocol
// that doesn't go through Electron's standard `ipcMain.handle()` —
// the `$eipc_message$_<UUID>_$_claude.web_$_<name>` framing in
// `index.js:68816` etc. is a custom message-port layer, not stdlib
// IPC. T38 inherited the same flaw and is being reclassified
// alongside this runner. See plan-doc session 3 status section.
//
// The Tier 1 fingerprint slice asserts the two load-bearing pieces
// of the surface that *don't* need login or the eipc registry:
//
//   1. The `LocalSessions_$_getPrChecks` eipc channel name appears
//      as a string in the bundled `index.js` (case-doc anchor
//      `:464281` — `GitHubPrManager`, `getPrChecks` at `:464964`
//      fans out to `gh pr view`). If the channel is renamed or
//      dropped, the renderer's invoke would fail and the CI status
//      bar regresses silently. The string-presence check is the
//      Tier 1 form of "is the wiring in the bundle"; the runtime
//      "is the handler installed" needs the eipc-registry surface
//      reverse-engineered first (deferred to a future session).
//
//   2. The `"gh CLI not found in PATH"` throw site is present in
//      the bundled `index.js` (case-doc anchor `:464368`). This is
//      the string that backs the missing-`gh` user-facing prompt
//      on Linux/Windows — `installGh()` (anchor `:464480`) is
//      macOS-only `brew install gh`; Linux/Windows fall through to
//      an error pointing at https://cli.github.com.
//
// Pure file probe, no app launch — Tier 1 in plan-doc terms.
//
// Applies to all rows. No skipUnlessRow gate.

test.setTimeout(15_000);

test('T22 — PR monitoring asar fingerprints', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — CI status bar',
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
		test.skip(true, `asar not resolvable: ${msg}`);
		return;
	}
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const checks = [
		{
			needle: 'gh CLI not found in PATH',
			caseDocAnchor: 'index.js:464368',
			rationale:
				'missing-`gh` user-facing prompt throw site — backs the ' +
				'Linux/Windows fallthrough since `installGh()` is macOS-only',
		},
		{
			needle: 'LocalSessions_$_getPrChecks',
			caseDocAnchor: 'index.js:464281 (GitHubPrManager) / :464964',
			rationale:
				'eipc channel name for the renderer→main fan-out to ' +
				'`gh pr view`; without it the CI status bar regresses ' +
				'silently',
		},
	];

	const results = checks.map((c) => ({
		...c,
		found: asarContains('.vite/build/index.js', c.needle, asarPath),
	}));

	await testInfo.attach('asar-fingerprints', {
		body: JSON.stringify(
			{ asarPath, file: '.vite/build/index.js', checks: results },
			null,
			2,
		),
		contentType: 'application/json',
	});

	for (const r of results) {
		expect(
			r.found,
			`[T22] '${r.needle}' present in bundled index.js ` +
				`(case-doc anchor ${r.caseDocAnchor}; ${r.rationale})`,
		).toBe(true);
	}
});
