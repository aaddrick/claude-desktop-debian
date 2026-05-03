import { test, expect } from '@playwright/test';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { asarContains, resolveAsarPath } from '../lib/asar.js';

// T38 — `LocalSessions_$_openInEditor` eipc channel-name fingerprint.
//
// Backs T38 in docs/testing/cases/code-tab-handoff.md ("Continue in
// IDE" — click chooser → IDE opens at the working directory). The
// full click-chain (login + IDE installed + chooser interaction) is
// Tier 3.
//
// **Session 3 reclassification (eipc-registry finding).** This
// originally shipped (session 2) as a `ipcMain._invokeHandlers`
// introspection probe — the assumption being that
// `LocalSessions.openInEditor` registered through Electron's
// standard `ipcMain.handle()`. KDE-W run during session 3 revealed
// the registry holds only three chat-tab MCP-bridge handlers
// (`list-mcp-servers`, `connect-to-mcp-server`,
// `request-open-mcp-settings`); the `LocalSessions_*` and
// `CustomPlugins_*` channels use a custom **eipc** message-port
// protocol distinct from stdlib IPC. The
// `$eipc_message$_<UUID>_$_claude.web_$_<name>` framing at
// `index.js:68816` is part of that custom layer. The original
// Tier 2 probe was a stub that never resolved a real handler —
// reclassified to Tier 1 fingerprint here. T22/T31/T33 (session 3
// shipments) inherited the same flaw and were reclassified the
// same way. Future session can land a proper Tier 2 once the
// eipc-registry surface is reverse-engineered.
//
// Tier 1 fingerprint: assert the channel-name string
// `LocalSessions_$_openInEditor` is present in bundled `index.js`.
// Without this string, the renderer's invoke would fail by name
// resolution and "Continue in IDE" regresses silently — the same
// signal-strength as the static-fingerprint side of T22 / T31 /
// T33 / T11 / T14a.
//
// Note on T24 (sibling test in code-tab-handoff.md): T24 ships as a
// **mock-then-call** form against the actual `shell.openExternal`
// egress (the line ultimately reached by the IPC handler at
// `:464011`). Since `shell.openExternal` is a regular Electron
// module — not the eipc layer — it IS replaceable from main and
// callable via inspector eval; T24's assertion is therefore strictly
// stronger than T38's static fingerprint. T38 retains its own
// runner because the IPC channel-name registration is a separate
// drift signal from the egress.
//
// Pure file probe, no app launch — Tier 1 in plan-doc terms.
//
// Applies to all rows. No skipUnlessRow gate.

test.setTimeout(15_000);

test('T38 — LocalSessions.openInEditor eipc channel fingerprint', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — open in IDE',
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

	const needle = 'LocalSessions_$_openInEditor';
	const found = asarContains('.vite/build/index.js', needle, asarPath);

	await testInfo.attach('asar-fingerprint', {
		body: JSON.stringify(
			{
				asarPath,
				file: '.vite/build/index.js',
				needle,
				found,
				caseDocAnchor: 'index.js:68816 (channel framing) / :464011 (egress)',
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		found,
		`[T38] eipc channel name '${needle}' present in bundled ` +
			'index.js (case-doc anchor :68816 channel framing / :464011 ' +
			'shell.openExternal egress)',
	).toBe(true);
});
