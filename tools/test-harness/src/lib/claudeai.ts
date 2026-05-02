// claude.ai renderer-UI domain wrapper — single point of coupling to
// upstream's React DOM shape for tests that drive the renderer.
//
// Why centralize: claude.ai's UI ships from a different release train
// than the Electron shell, and the tailwind class signatures regenerate
// on rebuild. If every spec embeds its own `button[aria-haspopup=menu]`
// + `span.truncate.max-w-[Npx]` walk, every UI tweak is an N-file fix.
// Confining the discovery here means the rest of the harness can speak
// in domain verbs (`activate('Code')`, `openEnvPill()`, …) and we only
// retune one file when upstream drifts.
//
// Discovery is by *shape*, not by minified class names:
//   - Top-level tabs are `button.df-pill` with `aria-label` set to the
//     visible label. Live probe (2026-05-02): exactly 3 — Chat, Cowork,
//     Code. Anchor on aria-label, not class.
//   - Compact pills (the env pill on Code, the "Select folder…" pill
//     after Local is chosen) share a single React component: a
//     `button[aria-haspopup="menu"]` containing a `span.truncate` with
//     a tailwind `max-w-[Npx]` class. Live probe found 2 (env=200px,
//     Select-folder=160px). The width differs but the structure
//     matches; we anchor on the structure and read the inner truncate
//     text to identify which pill.
//   - Other `button[aria-haspopup="menu"]` instances on the page are
//     sidebar conversation row "more" buttons (~80 of them). The
//     `span.truncate.max-w-[…]` fingerprint filters those out — they
//     don't carry the truncate child.
//
// Eval-string regex escaping: bodies passed to `evalInRenderer` traverse
// two encodings (TS string → JS string → regex). A word boundary needs
// `\\b` in this source. Bracket literals in class names (`max-w-[`)
// need `\\[`. Test patterns by reading them off the wire if changing.

import type { InspectorClient } from './inspector.js';
import { retryUntil } from './retry.js';

// One of the three top-level df-pills. Click is fire-and-forget — the
// router rerenders the tab body inline (no URL change on Code), so
// callers must poll for whatever signal indicates *their* next step is
// ready (e.g. CodeTab.activate polls for the env pill).
//
// Anchor on aria-label rather than text content because the visible
// text and aria-label happen to match today, but the aria attribute is
// the more durable contract.
export async function activateTab(
	inspector: InspectorClient,
	name: 'Chat' | 'Cowork' | 'Code',
): Promise<{ clicked: boolean }> {
	const selector = `button[aria-label=${JSON.stringify(name)}][class*="df-pill"]`;
	return await inspector.evalInRenderer<{ clicked: boolean }>(
		'claude.ai',
		`(() => {
			const btn = document.querySelector(${JSON.stringify(selector)});
			if (!btn) return { clicked: false };
			btn.click();
			return { clicked: true };
		})()`,
	);
}

// Replace dialog.showOpenDialog with a mock that records every call and
// returns a canned result. Idempotent — re-installing within the same
// Electron lifecycle is a no-op (guarded by
// globalThis.__claudeAiDialogMockInstalled). Mirrors the shape of
// QuickEntry.installInterceptor (quickentry.ts:86) so callers across
// libs feel consistent.
//
// The first BrowserWindow positional arg is optional in Electron's API,
// so the mock handles both `showOpenDialog(opts)` and
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
// installed (rather than throwing) — that way pre-install reads in
// retry loops are cheap.
export async function getOpenDialogCalls(
	inspector: InspectorClient,
): Promise<OpenDialogCall[]> {
	return await inspector.evalInMain<OpenDialogCall[]>(
		`return globalThis.__claudeAiDialogCalls || []`,
	);
}

// A "compact pill" — the React component used by both the env pill and
// the "Select folder…" pill. See the discovery comment at the top of
// the file for why we shape-match instead of class-match.
export interface CompactPill {
	text: string;
	maxW: string; // e.g., "max-w-[200px]"
	expanded: boolean;
}

export async function findCompactPills(
	inspector: InspectorClient,
): Promise<CompactPill[]> {
	return await inspector.evalInRenderer<CompactPill[]>(
		'claude.ai',
		`(() => {
			const buttons = Array.from(
				document.querySelectorAll('button[aria-haspopup="menu"]')
			);
			return buttons.flatMap(btn => {
				const span = btn.querySelector('span.truncate');
				if (!span) return [];
				const m = span.className.match(/max-w-\\[[^\\]]+\\]/);
				if (!m) return [];
				return [{
					text: (span.textContent || '').trim(),
					maxW: m[0],
					expanded: btn.getAttribute('aria-expanded') === 'true',
				}];
			});
		})()`,
	);
}

// Open a compact pill whose label matches `labelPattern`. Polls for the
// menu to render (any role=menuitem*) before resolving. Returns the
// rendered menu items so the caller can do its own validation.
//
// Discovery is anchored on the inner `span.truncate` text — that's
// what the user sees and what the probe captured. The label pattern's
// source is embedded into the renderer eval body verbatim; bring your
// own anchors (`^Local\\b`).
export async function openPill(
	inspector: InspectorClient,
	labelPattern: RegExp,
	opts: { timeout?: number } = {},
): Promise<{ opened: boolean; items: string[] }> {
	const timeout = opts.timeout ?? 5000;
	const reSrc = JSON.stringify(labelPattern.source);
	const reFlags = JSON.stringify(labelPattern.flags);
	return await inspector.evalInRenderer<{ opened: boolean; items: string[] }>(
		'claude.ai',
		`(async () => {
			const wait = (ms) => new Promise(r => setTimeout(r, ms));
			const re = new RegExp(${reSrc}, ${reFlags});
			const buttons = Array.from(
				document.querySelectorAll('button[aria-haspopup="menu"]')
			);
			const target = buttons.find(btn => {
				const span = btn.querySelector('span.truncate');
				if (!span) return false;
				if (!/max-w-\\[/.test(span.className)) return false;
				return re.test((span.textContent || '').trim());
			});
			if (!target) return { opened: false, items: [] };
			target.click();
			const deadline = Date.now() + ${timeout};
			while (Date.now() < deadline) {
				const items = Array.from(document.querySelectorAll(
					'[role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]'
				));
				if (items.length > 0) {
					return {
						opened: true,
						items: items.map(it => (it.textContent || '').trim().slice(0, 80)),
					};
				}
				await wait(50);
			}
			return { opened: false, items: [] };
		})()`,
	);
}

// Click any menuitem (any role=menuitem* variant) whose textContent
// matches `textPattern`. The caller is responsible for opening a menu
// first. Polls briefly because menu render is async (popover transition).
//
// Returns the matched item's text and the full item list at the time of
// the match — the second is useful for diagnostics when `clicked` is null.
export async function clickMenuItem(
	inspector: InspectorClient,
	textPattern: RegExp,
	opts: { timeout?: number } = {},
): Promise<{ clicked: string | null; items: string[] }> {
	const timeout = opts.timeout ?? 1500;
	const reSrc = JSON.stringify(textPattern.source);
	const reFlags = JSON.stringify(textPattern.flags);
	return await inspector.evalInRenderer<{ clicked: string | null; items: string[] }>(
		'claude.ai',
		`(async () => {
			const wait = (ms) => new Promise(r => setTimeout(r, ms));
			const re = new RegExp(${reSrc}, ${reFlags});
			const deadline = Date.now() + ${timeout};
			while (Date.now() < deadline) {
				const items = Array.from(document.querySelectorAll(
					'[role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]'
				));
				const match = items.find(el =>
					re.test((el.textContent || '').trim())
				);
				if (match) {
					const text = (match.textContent || '').trim().slice(0, 80);
					match.click();
					return {
						clicked: text,
						items: items.map(it => (it.textContent || '').trim().slice(0, 80)),
					};
				}
				await wait(50);
			}
			const items = Array.from(document.querySelectorAll(
				'[role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]'
			));
			return {
				clicked: null,
				items: items.map(it => (it.textContent || '').trim().slice(0, 80)),
			};
		})()`,
	);
}

// Dispatch an Escape keydown to the document. Used by openEnvPill's
// trial-click loop to dismiss the menu when the wrong pill was hit.
// We dispatch on document because the popover trigger may not have
// retained focus.
export async function pressEscape(inspector: InspectorClient): Promise<void> {
	await inspector.evalInRenderer<null>(
		'claude.ai',
		`(() => {
			document.dispatchEvent(new KeyboardEvent('keydown', {
				key: 'Escape', code: 'Escape', keyCode: 27, which: 27,
				bubbles: true, cancelable: true,
			}));
			return null;
		})()`,
	);
}

// Code tab domain operations. Instance-shaped (carries the inspector)
// to match QuickEntry / MainWindow in quickentry.ts.
//
// Only valid after the renderer has loaded a logged-in claude.ai page;
// callers should `app.waitForReady('userLoaded')` first. activate()
// itself doesn't repeat that check — it would just fail to find the
// df-pill on /login, which surfaces as a clear error.
export class CodeTab {
	constructor(private readonly inspector: InspectorClient) {}

	// Click the Code df-pill, then poll up to `timeout` for at least one
	// compact pill to render. The env pill rendering is the cheapest
	// signal that the Code-tab body has mounted and is interactive —
	// the URL doesn't change (route stays `/new` etc.), so we can't
	// anchor on navigation. Throws on miss with the candidate count for
	// triage.
	async activate(opts: { timeout?: number } = {}): Promise<void> {
		const timeout = opts.timeout ?? 5000;
		const result = await activateTab(this.inspector, 'Code');
		if (!result.clicked) {
			throw new Error(
				'CodeTab.activate: Code df-pill (button[aria-label="Code"][class*="df-pill"]) not found',
			);
		}
		const ready = await retryUntil(
			async () => {
				const pills = await findCompactPills(this.inspector);
				return pills.length > 0 ? pills : null;
			},
			{ timeout, interval: 200 },
		);
		if (!ready) {
			throw new Error(
				`CodeTab.activate: no compact pill rendered within ${timeout}ms ` +
					`after clicking Code — tab body may not have mounted`,
			);
		}
	}

	// Open the env pill (the compact pill whose menu contains a `^Local`
	// menuitemradio). Trial-click strategy: for each compact pill, try
	// opening it and check for the Local item. If absent, dismiss with
	// Escape and try the next. Necessary because nothing in the DOM
	// distinguishes the env pill from a future second compact pill at
	// rest — only the menu contents disambiguate.
	//
	// Returns the matched pill's label text and the rendered menu
	// items. Throws if no candidate yields a Local-bearing menu.
	async openEnvPill(): Promise<{ pillText: string; items: string[] }> {
		const pills = await findCompactPills(this.inspector);
		if (pills.length === 0) {
			throw new Error(
				'CodeTab.openEnvPill: no compact pills on the page — ' +
					'did you call activate() first?',
			);
		}
		// Iterate by label rather than DOM index so we can use openPill
		// with an exact-text anchor — avoids re-querying ordinals after
		// each Escape (the DOM may shift).
		for (const pill of pills) {
			const labelRe = new RegExp(`^${escapeRegExp(pill.text)}$`);
			const opened = await openPill(this.inspector, labelRe, { timeout: 1500 });
			if (!opened.opened) continue;
			const hasLocal = opened.items.some((t) => /^Local\b/.test(t));
			if (hasLocal) {
				return { pillText: pill.text, items: opened.items };
			}
			await pressEscape(this.inspector);
			// Brief settle so the next openPill doesn't race the popover
			// teardown. 150ms matches the original T17 implementation.
			await sleepMs(150);
		}
		throw new Error(
			`CodeTab.openEnvPill: probed ${pills.length} compact pill(s), ` +
				`none yielded a menu containing /^Local\\b/`,
		);
	}

	// Click the `^Local` menuitemradio inside the (already-open) env-pill
	// menu. textContent reads "Local, environment settings, right arrow"
	// because of the SR-only suffix; we anchor on /^Local\b/.
	async selectLocal(): Promise<void> {
		const result = await clickMenuItem(this.inspector, /^Local\b/);
		if (!result.clicked) {
			throw new Error(
				`CodeTab.selectLocal: no /^Local\\b/ item in the open menu. ` +
					`Items: ${JSON.stringify(result.items)}`,
			);
		}
	}

	// Full chain: open env pill → Local → wait for the "Select folder…"
	// pill to render → open it → click "Open folder…". After this
	// resolves, dialog.showOpenDialog has been invoked (the caller
	// installs the mock first and polls getOpenDialogCalls to confirm).
	//
	// Each step throws on its own miss with enough metadata to tell
	// which selector decayed; the caller can wrap the whole chain in
	// try/catch for partial-state attachment.
	async openFolderPicker(): Promise<void> {
		await this.openEnvPill();
		await this.selectLocal();
		// The Select-folder pill renders after Local is chosen. Same
		// CompactPill shape — anchor on the leading "Select folder"
		// text. 4s budget matches the T17 wait that proved sufficient
		// in practice on KDE-W.
		const selectOpened = await retryUntil(
			async () => {
				const r = await openPill(this.inspector, /^Select folder/, {
					timeout: 1000,
				});
				return r.opened ? r : null;
			},
			{ timeout: 4000, interval: 200 },
		);
		if (!selectOpened) {
			throw new Error(
				'CodeTab.openFolderPicker: "Select folder…" pill did not ' +
					'open within 4s after Local was clicked',
			);
		}
		// The Select-folder menu has a "Recent" group (radios — clicking
		// reuses the past path silently, no dialog) followed by
		// "Open folder…" (menuitem — fires the picker). Click the
		// menuitem variant explicitly; clickMenuItem matches all
		// menuitem* roles, so the leading-text anchor is what
		// disambiguates here.
		const openClicked = await clickMenuItem(this.inspector, /^Open folder/);
		if (!openClicked.clicked) {
			throw new Error(
				`CodeTab.openFolderPicker: no /^Open folder/ menuitem in ` +
					`the Select-folder menu. Items: ${JSON.stringify(openClicked.items)}`,
			);
		}
	}
}

// Local because retry.ts's `sleep` is fine to import elsewhere but the
// 150ms post-Escape settle is internal-only — keeping the helper
// adjacent makes the intent clear at the call site.
function sleepMs(ms: number): Promise<void> {
	return new Promise((r) => setTimeout(r, ms));
}

// Standard "escape regex special chars in a literal string" helper.
// Used to build an exact-match RegExp from a captured pill label.
function escapeRegExp(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
