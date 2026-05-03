// Mock-then-call helpers for side-effecting Electron module APIs.
//
// Tests that exercise an Electron egress whose real invocation would
// touch the host system (open a file manager, launch an editor, show a
// dialog) install a recorder mock first, then invoke the API via
// `inspector.evalInMain` and assert against the recorded calls. The
// pattern strengthens "didn't throw" probes into "the egress was
// reached + the args flowed through verbatim", with no host side
// effect.
//
// Each helper:
//   - is idempotent within an Electron lifecycle (guarded by a
//     globalThis flag so re-installation in retry loops is a no-op),
//   - records `{ ts, ...args }` into a globalThis call list,
//   - returns a value matching the real API's documented contract
//     (void / Promise<boolean> / canned dialog result).
//
// The companion `get*Calls()` reader returns `[]` if the mock was
// never installed (rather than throwing) so pre-install reads in
// retry loops are cheap.
//
// Extracted from `lib/claudeai.ts` once the third helper landed
// (T17 dialog → T25 showItemInFolder → T24 openExternal). These
// helpers are not claude.ai-domain — they're generic Electron module
// patches — so the extraction keeps `claudeai.ts` focused on the AX-
// tree page-objects and gives future mock-then-call tests an obvious
// home to add to.
//
// Caller pattern: see `runners/T17_folder_picker.spec.ts`,
// `runners/T25_show_item_in_folder_no_throw.spec.ts`,
// `runners/T24_open_in_editor_no_throw.spec.ts`.

import type { InspectorClient } from './inspector.js';

// ----- dialog.showOpenDialog -----------------------------------------

// Replace dialog.showOpenDialog with a mock that records every call
// and returns a canned result. Idempotent — re-installing within the
// same Electron lifecycle is a no-op (guarded by
// globalThis.__claudeAiDialogMockInstalled). Mirrors the shape of
// QuickEntry.installInterceptor (quickentry.ts:86) so callers across
// libs feel consistent.
//
// The first BrowserWindow positional arg is optional in Electron's
// API, so the mock handles both `showOpenDialog(opts)` and
// `showOpenDialog(window, opts)` shapes.
export async function installOpenDialogMock(
	inspector: InspectorClient,
	cannedResult: { canceled: boolean; filePaths: string[] } = {
		canceled: false,
		filePaths: ['/tmp/claude-test-folder'],
	},
): Promise<void> {
	const canned = JSON.stringify(cannedResult);
	await inspector.evalInMain<null>(`
		if (globalThis.__claudeAiDialogMockInstalled) return null;
		const { dialog } = process.mainModule.require('electron');
		globalThis.__claudeAiDialogCalls = [];
		const original = dialog.showOpenDialog.bind(dialog);
		dialog.showOpenDialog = async function(...args) {
			const browserWindowArg = args[0]
				&& typeof args[0] === 'object'
				&& args[0].constructor
				&& args[0].constructor.name === 'BrowserWindow';
			const opts = browserWindowArg ? args[1] : args[0];
			globalThis.__claudeAiDialogCalls.push({
				ts: Date.now(),
				nargs: args.length,
				title: opts && opts.title,
				properties: opts && opts.properties,
			});
			return ${canned};
		};
		void original;
		globalThis.__claudeAiDialogMockInstalled = true;
		return null;
	`);
}

export interface OpenDialogCall {
	ts: number;
	nargs: number;
	title?: string;
	properties?: string[];
}

// Read the recorded call list. Returns [] if the mock was never
// installed (rather than throwing) — pre-install reads in retry
// loops stay cheap.
export async function getOpenDialogCalls(
	inspector: InspectorClient,
): Promise<OpenDialogCall[]> {
	return await inspector.evalInMain<OpenDialogCall[]>(
		`return globalThis.__claudeAiDialogCalls || []`,
	);
}

// ----- shell.showItemInFolder ----------------------------------------

// Replace electron.shell.showItemInFolder with a mock that records
// every call without performing the underlying DBus FileManager1 /
// xdg-open dispatch. Same idempotency-flag pattern as
// installOpenDialogMock.
//
// Why mock vs. invoke real: `showItemInFolder` is fire-and-forget on
// Linux (returns void, no success signal). Invoking it for real opens
// the host's actual file manager — fine in a click-chain test, but
// disruptive when the assertion is just "the JS-level call is
// reachable + accepts a path arg + the IPC layer terminates here".
// The mock keeps the same assertion shape with no host side effect.
export async function installShowItemInFolderMock(
	inspector: InspectorClient,
): Promise<void> {
	await inspector.evalInMain<null>(`
		if (globalThis.__claudeAiShowItemMockInstalled) return null;
		const { shell } = process.mainModule.require('electron');
		globalThis.__claudeAiShowItemCalls = [];
		const original = shell.showItemInFolder.bind(shell);
		shell.showItemInFolder = function(fullPath) {
			globalThis.__claudeAiShowItemCalls.push({
				ts: Date.now(),
				path: typeof fullPath === 'string' ? fullPath : String(fullPath),
			});
			// Return undefined like the real method — callers don't
			// inspect the return value.
		};
		void original;
		globalThis.__claudeAiShowItemMockInstalled = true;
		return null;
	`);
}

export interface ShowItemInFolderCall {
	ts: number;
	path: string;
}

export async function getShowItemInFolderCalls(
	inspector: InspectorClient,
): Promise<ShowItemInFolderCall[]> {
	return await inspector.evalInMain<ShowItemInFolderCall[]>(
		`return globalThis.__claudeAiShowItemCalls || []`,
	);
}

// ----- shell.openExternal --------------------------------------------

// Replace electron.shell.openExternal with a mock that records every
// call without performing the underlying xdg-open / scheme-handler
// dispatch. Same idempotency-flag pattern as installOpenDialogMock /
// installShowItemInFolderMock.
//
// Why mock vs. invoke real: `shell.openExternal` is the single egress
// for all URL-scheme handoffs (browser, OAuth callback, editor URL
// schemes like `vscode://file/<path>`). Invoking it for real on a
// host with the matching scheme handler installed launches the target
// app (e.g. a full VS Code window) — fine in a click-chain test,
// disruptive when the assertion is just "the JS-level call is
// reachable + the URL flowed through verbatim". The mock keeps the
// same assertion shape with no host side effect.
//
// Unlike `showItemInFolder`, `openExternal` returns `Promise<boolean>`
// (true on success, false otherwise — see Electron docs), so the mock
// must return a resolved Promise with the canned boolean rather than
// undefined, otherwise callers that `await` the result would observe
// `undefined` instead of the documented contract.
export async function installOpenExternalMock(
	inspector: InspectorClient,
	cannedResult: boolean = true,
): Promise<void> {
	const canned = JSON.stringify(cannedResult);
	await inspector.evalInMain<null>(`
		if (globalThis.__claudeAiOpenExternalMockInstalled) return null;
		const { shell } = process.mainModule.require('electron');
		globalThis.__claudeAiOpenExternalCalls = [];
		const original = shell.openExternal.bind(shell);
		shell.openExternal = async function(url, options) {
			globalThis.__claudeAiOpenExternalCalls.push({
				ts: Date.now(),
				url: typeof url === 'string' ? url : String(url),
				options: options,
			});
			// Return a resolved Promise<boolean> like the real method —
			// callers that await the result expect the documented
			// contract (true on success, false otherwise).
			return ${canned};
		};
		void original;
		globalThis.__claudeAiOpenExternalMockInstalled = true;
		return null;
	`);
}

export interface OpenExternalCall {
	ts: number;
	url: string;
	options?: unknown;
}

export async function getOpenExternalCalls(
	inspector: InspectorClient,
): Promise<OpenExternalCall[]> {
	return await inspector.evalInMain<OpenExternalCall[]>(
		`return globalThis.__claudeAiOpenExternalCalls || []`,
	);
}
