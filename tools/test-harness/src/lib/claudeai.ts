// claude.ai renderer-UI domain wrapper — single point of coupling to
// upstream's accessibility tree for tests that drive the renderer.
//
// Why centralize: claude.ai's UI ships from a different release train
// than the Electron shell, so any cross-spec drift would be an N-file
// fix. Confining the discovery here means the rest of the harness can
// speak in domain verbs (`activate('Code')`, `openEnvPill()`, …) and
// we only retune one file when upstream drifts.
//
// Discovery substrate is Chromium's accessibility tree
// (`Accessibility.getFullAXTree` over CDP), shared with the v7 walker.
// Reading from AX rather than the DOM means the page-objects survive
// tailwind class regeneration and React-tree restructuring as long as
// the platform-computed role + accessible name + ancestor landmarks
// stay stable. See docs/learnings/test-harness-ax-tree-walker.md for
// the gotchas (AX-enable async lag, post-click stability gating, list
// virtualization).
//
// Discrimination shapes used:
//   - Top-level tabs: `role: 'button'` whose accessibleName matches
//     the literal tab label ('Chat' | 'Cowork' | 'Code'). The
//     `df-pill` tailwind anchor and `aria-label` selector are gone —
//     the AX-computed name is the durable contract.
//   - Compact pills (the env pill on Code, the "Select folder…" pill
//     after Local is chosen): `role: 'button'` with
//     `hasPopup === 'menu'`, scoped away from the cowork sidebar by
//     filtering out per-row `^More options for ` triggers. The visible
//     label is the button's accessibleName.
//   - Menu items: any of `menuitem` / `menuitemradio` /
//     `menuitemcheckbox` (collected as MENU_ITEM_ROLES below).

import type { InspectorClient } from './inspector.js';
import {
	snapshotAx,
	waitForAxNode,
	waitForAxNodes,
	waitForAxTreeStable,
} from './ax.js';
import { retryUntil, sleep } from './retry.js';

// All three CDP-exposed menu-item variants. Caller code wants to treat
// them uniformly — radios and checkboxes are still "items in an open
// menu the user can pick".
const MENU_ITEM_ROLES = new Set<string>([
	'menuitem',
	'menuitemradio',
	'menuitemcheckbox',
]);

// AccessibleName patterns that indicate a per-row trigger button on
// the cowork sidebar (~70+ of them on a busy account). They share the
// same `hasPopup: 'menu'` signal as the compact pills we actually
// want, so excluding them by name is the load-bearing discriminator.
const ROW_MORE_OPTIONS_RE = /^More options for /;

// `snapshotAx` and the stability gate are now in `lib/ax.ts` —
// extracted there in session 13 once T26 had to redefine the same
// helper inline (two consumers = threshold-driven extraction). Page-
// objects below import via the lib aliases; consumers outside this
// file should reach for `lib/ax.ts` directly rather than re-importing
// through `lib/claudeai.ts`.

// One of the three top-level pills. Click is fire-and-forget — the
// router rerenders the tab body inline (no URL change on Code), so
// callers must poll for whatever signal indicates *their* next step is
// ready (e.g. CodeTab.activate polls for the env pill).
//
// AX-tree match: `role: 'button'` with the literal tab name as the
// accessible name. The visible label and aria-label happen to coincide
// today, and the AX-computed name follows the same cascade — pinning
// to the name keeps the page-object durable across the tailwind
// regenerations that motivated the migration.
//
// Pre-click polling budget. Up to session 13, this was a one-shot
// snapshot — if the tab button hadn't rendered yet when activateTab
// was called, the function returned `{ clicked: false }` immediately.
// Session 13's `waitForAxNode` substrate makes "wait for the button to
// appear" a one-line shape-only change. Default 5000ms matches the
// `lib/ax.ts` defaults; callers that previously relied on the no-retry
// shape pass `timeout: 0` (e.g. via `waitForAxNode`'s timeoutMs) to
// keep the old behaviour, though no caller currently does so. T16
// passes 15s through `CodeTab.activate({ timeout })` — that budget is
// still spent on the post-click pill poll; the pre-click click budget
// is independent.
export async function activateTab(
	inspector: InspectorClient,
	name: 'Chat' | 'Cowork' | 'Code',
	opts: { timeout?: number } = {},
): Promise<{ clicked: boolean }> {
	const target = await waitForAxNode(
		inspector,
		(el) =>
			el.computedRole === 'button' && el.accessibleName === name,
		{ timeoutMs: opts.timeout ?? 5_000 },
	);
	if (!target || target.backendDOMNodeId === null) {
		return { clicked: false };
	}
	await inspector.clickByBackendNodeId('claude.ai', target.backendDOMNodeId);
	return { clicked: true };
}

// A "compact pill" — the React component used by both the env pill and
// the "Select folder…" pill. AX shape: `role: 'button'` with
// `hasPopup === 'menu'`, scoped away from cowork sidebar row triggers
// (`/^More options for /`). The tailwind `max-w-[Npx]` field used to
// be carried as a diagnostic in v6; that signal isn't in the AX tree
// (and it was tailwind-specific, exactly the kind of thing the
// migration was meant to drop), so it's gone — callers only used it
// in error messages.
export interface CompactPill {
	text: string;
}

export async function findCompactPills(
	inspector: InspectorClient,
): Promise<CompactPill[]> {
	const elements = await snapshotAx(inspector);
	return elements
		.filter(
			(el) =>
				el.computedRole === 'button' &&
				el.hasPopup === 'menu' &&
				el.accessibleName !== null &&
				el.accessibleName.length > 0 &&
				!ROW_MORE_OPTIONS_RE.test(el.accessibleName),
		)
		.map((el) => ({ text: el.accessibleName as string }));
}

// Open a compact pill whose accessibleName matches `labelPattern`.
// Discrimination: `role: 'button'` AND `hasPopup === 'menu'` AND the
// AX-computed name passes the regex. The hasPopup gate is what stops
// us trial-clicking action buttons that happen to share text with a
// pill — the pill always carries an aria-haspopup contract (it opens
// a popover) while a same-named action button does not.
//
// Polls the AX tree post-click for the menu to render (any role in
// MENU_ITEM_ROLES). Returns the rendered menu item names so the caller
// can validate without a second snapshot round-trip.
export async function openPill(
	inspector: InspectorClient,
	labelPattern: RegExp,
	opts: { timeout?: number } = {},
): Promise<{ opened: boolean; items: string[] }> {
	const timeout = opts.timeout ?? 5000;
	const elements = await snapshotAx(inspector);
	const target = elements.find(
		(el) =>
			el.computedRole === 'button' &&
			el.hasPopup === 'menu' &&
			el.accessibleName !== null &&
			labelPattern.test(el.accessibleName),
	);
	if (!target || target.backendDOMNodeId === null) {
		return { opened: false, items: [] };
	}
	await inspector.clickByBackendNodeId('claude.ai', target.backendDOMNodeId);
	// Menu render is async and the AX tree lags DOM by hundreds of ms
	// (see docs/learnings/test-harness-ax-tree-walker.md §1). Gate
	// once on stability post-click, then poll fast — re-gating on every
	// iteration would burn 800ms+ each cycle waiting for "no change"
	// when what we want is "menuitems appear".
	await waitForAxTreeStable(inspector, { minNodes: 1, timeoutMs: 5_000 });
	const deadline = Date.now() + timeout;
	while (Date.now() < deadline) {
		const post = await snapshotAx(inspector, { fast: true });
		const items = post.filter((el) => MENU_ITEM_ROLES.has(el.computedRole));
		if (items.length > 0) {
			return {
				opened: true,
				items: items.map((el) => (el.accessibleName ?? '').slice(0, 80)),
			};
		}
		await sleep(100);
	}
	return { opened: false, items: [] };
}

// Click any menuitem (any of MENU_ITEM_ROLES) whose accessibleName
// matches `textPattern`. Caller opens the menu first. Polls the AX
// snapshot — menu render is async and the AX tree lags DOM by
// hundreds of ms.
//
// Returns the matched item's text and the full item list at the time
// of the match — the second is useful for diagnostics when `clicked`
// is null.
export async function clickMenuItem(
	inspector: InspectorClient,
	textPattern: RegExp,
	opts: { timeout?: number } = {},
): Promise<{ clicked: string | null; items: string[] }> {
	const timeout = opts.timeout ?? 1500;
	// Caller has just opened a menu — gate once on stability so the
	// first iteration sees the populated tree, then poll fast for the
	// match. Same shape as openPill's post-click handling.
	await waitForAxTreeStable(inspector, { minNodes: 1, timeoutMs: 5_000 });
	const deadline = Date.now() + timeout;
	let lastItemNames: string[] = [];
	while (Date.now() < deadline) {
		const elements = await snapshotAx(inspector, { fast: true });
		const items = elements.filter((el) =>
			MENU_ITEM_ROLES.has(el.computedRole),
		);
		lastItemNames = items.map((el) => (el.accessibleName ?? '').slice(0, 80));
		const match = items.find(
			(el) =>
				el.accessibleName !== null && textPattern.test(el.accessibleName),
		);
		if (match && match.backendDOMNodeId !== null) {
			const text = (match.accessibleName ?? '').slice(0, 80);
			await inspector.clickByBackendNodeId(
				'claude.ai',
				match.backendDOMNodeId,
			);
			return { clicked: text, items: lastItemNames };
		}
		await sleep(100);
	}
	return { clicked: null, items: lastItemNames };
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
// Code button on /login, which surfaces as a clear error.
export class CodeTab {
	constructor(private readonly inspector: InspectorClient) {}

	// Click the Code tab, then poll up to `timeout` for at least one
	// compact pill to render. The env pill rendering is the cheapest
	// signal that the Code-tab body has mounted and is interactive —
	// the URL doesn't change (route stays `/new` etc.), so we can't
	// anchor on navigation. Throws on miss with the candidate count for
	// triage.
	//
	// Session 14 migration: the pre-click `activateTab` call now polls
	// up to `opts.timeout` for the Code button itself to appear (was a
	// one-shot snapshot prior — the T16 failure mode). Same budget
	// covers both phases; in practice the click resolves in well under
	// a second when the Code button is present, so the post-click pill
	// poll inherits the bulk of the budget.
	async activate(opts: { timeout?: number } = {}): Promise<void> {
		const timeout = opts.timeout ?? 5000;
		const result = await activateTab(this.inspector, 'Code', { timeout });
		if (!result.clicked) {
			throw new Error(
				'CodeTab.activate: no AX-tree button with accessibleName="Code" found',
			);
		}
		// Post-click: poll the AX tree for at least one compact pill.
		// `waitForAxNodes` carries the snapshot+filter+sleep loop
		// formerly hand-rolled here, with the same per-iteration cadence
		// (200ms) and overall budget. Predicate matches `findCompactPills`
		// — `role: 'button'` + `hasPopup: 'menu'` + non-empty
		// accessibleName + not a per-row "More options for X" trigger.
		const ready = await waitForAxNodes(
			this.inspector,
			(el) =>
				el.computedRole === 'button' &&
				el.hasPopup === 'menu' &&
				el.accessibleName !== null &&
				el.accessibleName.length > 0 &&
				!ROW_MORE_OPTIONS_RE.test(el.accessibleName),
			{ timeoutMs: timeout, intervalMs: 200 },
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
			await sleep(150);
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

// Standard "escape regex special chars in a literal string" helper.
// Used to build an exact-match RegExp from a captured pill label.
function escapeRegExp(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
