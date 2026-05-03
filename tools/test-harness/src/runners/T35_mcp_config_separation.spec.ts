import { test, expect } from '@playwright/test';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T35 — MCP server config picked up (Phase 1 / Tier 1 fingerprint).
//
// Backs T35 in docs/testing/cases/extensibility.md ("MCP server config
// picked up"). The full case-doc form requires login + a Code-tab
// session against a project with `.mcp.json`, and a way to enumerate
// the loaded MCP tools through the slash menu — Tier 3 work that the
// harness can't do today. This Phase 1 spec is the cheap "the
// per-tab MCP-config separation is wired in the bundle" signal.
//
// **Why Phase 1 / Tier 1.** Pure file probe, no app launch. It pins
// the wiring in the shipped bundle without verifying live MCP
// startup; if the four needles drift, the case-doc anchors are stale
// and the runtime behaviour described under "Expected" is no longer
// the one shipped.
//
// **Why Phase 2 (fixture-then-readback) is deferred.** The
// parsed-MCP-server-state target is almost certainly a closure-local
// minified symbol with no `globalThis` or IPC handle — the same
// blocker hit on T37b (parsed CLAUDE.md memory state), S19, and S28
// (`Sbn()`). Shipping a stub that asserts against unreachable state
// would assert nothing; better to land Phase 1 now and revisit Phase
// 2 once a future session proves a reachable surface (a known
// main-process global, or an IPC handler that returns the parsed MCP
// server map).
//
// **Why these four needles together pin the separation.** The
// case-doc's load-bearing claim is that the chat-tab and Code-tab
// MCP-config trees do not overlap:
//
//   - Chat tab uses `claude_desktop_config.json` (anchor :130821) in
//     a separate userData dir resolved by `kee()` (:130829).
//   - Code tab loads MCP config from `~/.claude.json` (user-level,
//     anchor :176766) and `<project>/.mcp.json` (project-level,
//     anchor :215418), and explicitly passes the
//     `["user", "project", "local"]` settingSources triple to the
//     agent SDK at session start (anchor :489098).
//
// All four strings present together is the strongest static
// signature for "the two trees are wired separately". If
// `claude_desktop_config.json` started showing up in the
// settingSources path, or if `.mcp.json` / `.claude.json` were
// dropped, the regression would be visible at this layer.
//
// **Case-doc vs bundle discrepancy.** The case-doc step references
// `~/.claude.json` (with tilde — that's the documented user-level
// path); the minified bundle stores it as `.claude.json` (no
// tilde — minified strips the path-prefix style and resolves home
// at use). `~/.claude.json` has 0 occurrences in the bundle.
// Future maintainers: don't waste time chasing the tilde form;
// `.claude.json` (no tilde) is the correct needle.
//
// Pure file probe — no app launch. Applies to all rows; no
// skipUnlessRow gate.

test.setTimeout(15_000);

test('T35 — MCP config separation asar fingerprints', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'MCP / Code tab',
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
			needle: 'claude_desktop_config.json',
			caseDocAnchor: 'index.js:130821 (kee() userData dir at :130829)',
			rationale:
				'chat-tab MCP-config path constant, lives under a ' +
				'separate userData dir from the Code-tab tree — the ' +
				'load-bearing "no overlap" claim depends on this still ' +
				'being the chat-tab path',
		},
		{
			needle: '.claude.json',
			caseDocAnchor: 'index.js:176766',
			rationale:
				'Code-tab user-level MCP config loader (the case-doc ' +
				'writes `~/.claude.json` but minified bundle stores it ' +
				'as `.claude.json` — home is resolved at use)',
		},
		{
			needle: '.mcp.json',
			caseDocAnchor: 'index.js:215418',
			rationale:
				'Code-tab project-level MCP config loader — Code tab ' +
				'reads `<project>/.mcp.json` per scanned dir',
		},
		{
			needle: '"user","project","local"',
			caseDocAnchor: 'index.js:489098',
			rationale:
				'settingSources triple Code-session passes to the agent ' +
				'SDK — strongest signature that Code-tab MCP config ' +
				'flows through the agent-SDK path, not the chat-tab ' +
				'`claude_desktop_config.json` tree',
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
			`[T35] '${r.needle}' present in bundled index.js ` +
				`(case-doc anchor ${r.caseDocAnchor}; ${r.rationale})`,
		).toBe(true);
	}
});
