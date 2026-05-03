import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T38 — `LocalSessions.openInEditor` IPC handler is registered in main.
//
// Backs T38 in docs/testing/cases/code-tab-handoff.md ("Continue in
// IDE" — click chooser → IDE opens at the working directory). Same
// IPC surface as T24 ("Open in external editor"); per the case-doc,
// the "Continue in" chooser UI is rendered server-side by claude.ai
// and absent from the local asar — only the IPC bridge is anchorable.
//
// Tier 2 reframe (per docs/testing/runner-implementation-plan.md
// T38, line ~419): the full click-chain (login + IDE installed +
// chooser interaction) is Tier 3. Tier 2's slice asserts that the
// `LocalSessions.openInEditor(path, editor, sshConfig, line)` IPC
// handler is wired up in the main process — i.e. the renderer can
// reach it. If the handler is unregistered (rename, refactor that
// drops the registration, missing module load), the renderer's
// invoke() would reject with "No handler registered for ..." and
// every Tier-3 path through the chooser silently regresses with no
// other signal in the bundle.
//
// Why introspect, not invoke:
//   - Invoking the handler would call A.openInEditor(...) which
//     terminates at shell.openExternal('vscode://file/...') (case-doc
//     anchor index.js:464011). On a host with VS Code installed,
//     that's a real side effect (editor launches). T25 accepts that
//     trade-off because the file manager popup is a single window;
//     here the side effect is launching a full editor app.
//   - The Tier 2 contract is "wired up", not "doesn't throw on a
//     synthetic path". Invoking would also trip the channel's origin
//     validation (`le(i)` at index.js:68820 rejects non-claude.ai
//     senders), so invoking from main wouldn't even reach the impl.
//
// Channel-name shape (anchor index.js:68816, verified against the
// bundled source):
//   $eipc_message$_<UUID>_$_claude.web_$_LocalSessions_$_openInEditor
// The UUID (`c0eed8c9-c94a-4931-8cc3-3a08694e9863` in the current
// bundle) appears to be build-stable but is not guaranteed across
// releases, so we match on the suffix `LocalSessions_$_openInEditor`
// rather than the full string. Surfacing the prefix as a diagnostic
// helps spot if the IPC framing ever changes.
//
// `ipcMain._invokeHandlers` is a private Electron API (a Map of
// channel → async handler that backs `ipcMain.handle()` /
// `ipcRenderer.invoke()`). It exists in current Electron and is
// already relied on by `lib/quickentry.ts` (captureSubmitIpc). If
// upstream Electron ever drops it, this runner will fail loudly with
// "_invokeHandlers is not a function/property" — see Open questions
// in the runner-implementation-plan.md follow-up doc.
//
// Applies to all rows. No skipUnlessRow gate.

interface HandlerProbe {
	invokeHandlersType: string;
	invokeHandlersSize: number | null;
	localSessionsChannels: string[];
	openInEditorChannel: string | null;
}

test.setTimeout(60_000);

test('T38 — LocalSessions.openInEditor IPC handler is registered', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab — open in IDE',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude();
	try {
		// 'mainVisible' is the cheapest level that gives us an
		// inspector + a known-good main process. The IPC handlers
		// register during main bootstrap (alongside the rest of the
		// LocalSessions surface) and are live before any renderer
		// state matters; we don't need 'claudeAi' or 'userLoaded'.
		const { inspector } = await app.waitForReady('mainVisible');

		const probe = await inspector.evalInMain<HandlerProbe>(`
			const { ipcMain } = process.mainModule.require('electron');
			// Electron's ipcMain.handle() registry is a Map keyed by
			// channel name. The property is undocumented but stable
			// (also used by lib/quickentry.ts captureSubmitIpc).
			const reg = ipcMain._invokeHandlers;
			const invokeHandlersType = reg == null
				? 'null'
				: (reg instanceof Map ? 'Map' : typeof reg);
			let channels = [];
			let size = null;
			if (reg instanceof Map) {
				size = reg.size;
				channels = Array.from(reg.keys());
			} else if (reg && typeof reg === 'object') {
				// Defensive: older/newer Electron builds may use a
				// plain object instead of a Map. Surface both.
				channels = Object.keys(reg);
				size = channels.length;
			}
			const localSessionsChannels = channels.filter((c) =>
				typeof c === 'string' && c.includes('LocalSessions_$_'),
			);
			const openInEditorChannel = channels.find((c) =>
				typeof c === 'string'
					&& c.endsWith('LocalSessions_$_openInEditor'),
			) ?? null;
			return {
				invokeHandlersType,
				invokeHandlersSize: size,
				localSessionsChannels,
				openInEditorChannel,
			};
		`);

		await testInfo.attach('ipc-handler-probe', {
			body: JSON.stringify(probe, null, 2),
			contentType: 'application/json',
		});

		// Hard-fail if the registry shape itself changed — without
		// this, the empty-list match below would be ambiguous between
		// "channel missing" and "we couldn't read the registry at all".
		expect(
			probe.invokeHandlersType,
			'ipcMain._invokeHandlers is a Map (Electron private API ' +
				'still available in this build)',
		).toBe('Map');

		expect(
			probe.openInEditorChannel,
			'LocalSessions.openInEditor IPC handler is registered ' +
				'(channel suffix `LocalSessions_$_openInEditor` present ' +
				'in ipcMain._invokeHandlers; case-doc T38 anchor ' +
				'index.js:68816)',
		).not.toBeNull();
	} finally {
		await app.close();
	}
});
