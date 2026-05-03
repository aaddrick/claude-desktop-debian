// Renderer-state capture for the explore CLI.
//
// Why a separate module: the snapshot shape is the contract diff.ts
// reads against. Keeping the capture here (rather than inline in the
// dispatcher) means a future format bump only touches two files and
// the schema lives next to its sole producer.
//
// All discovery is by structural shape — never by minified Tailwind
// class names. We anchor on:
//   - df-pills: button.df-pill[aria-label] (3 expected: Chat/Cowork/Code)
//   - compact pills: button[aria-haspopup="menu"] containing
//     span.truncate.max-w-[Npx] (env pill, Select-folder pill, …)
//   - aria-labeled buttons: any <button[aria-label]> for general drift
//     visibility (sidebar "more" buttons, header actions, modals).
//   - open menu: the role=menu currently in the DOM, plus its items.
//   - modals: role=dialog elements with aria-label/aria-labelledby.
//
// All renderer evals run in a single round-trip to keep snapshots
// deterministic — async work between probes can shift the DOM.

import type { InspectorClient } from '../src/lib/inspector.js';

export interface DfPill {
	ariaLabel: string | null;
	text: string;
	visible: boolean;
}

export interface CompactPillSnap {
	ariaLabel: string | null;
	text: string;
	maxW: string;
	expanded: boolean;
}

export interface AriaButton {
	ariaLabel: string;
	text: string;
	expanded: boolean | null;
	hasPopup: string | null;
	visible: boolean;
}

export interface MenuItem {
	role: string;
	text: string;
	ariaChecked: string | null;
	disabled: boolean;
}

export interface OpenMenu {
	ariaLabelledBy: string | null;
	ariaLabel: string | null;
	items: MenuItem[];
}

export interface ModalSnap {
	ariaLabel: string | null;
	ariaLabelledBy: string | null;
	headingText: string | null;
	buttonLabels: string[];
}

export interface PageState {
	url: string;
	title: string;
	readyState: string;
}

export interface Snapshot {
	capturedAt: string;
	claudeAiUrl: string;
	appVersion: string | null;
	pageState: PageState;
	dfPills: DfPill[];
	compactPills: CompactPillSnap[];
	ariaLabeledButtons: AriaButton[];
	openMenu: OpenMenu | null;
	modals: ModalSnap[];
}

// Capture the renderer DOM into the canonical snapshot shape.
// `claudeAiUrl` is recorded separately from pageState.url because the
// pageState reflects the moment of capture and is useful for diff
// triage; the top-level url anchors which webContents we hit.
export async function capture(client: InspectorClient): Promise<Snapshot> {
	const target = await pickClaudeAiWebContents(client);
	const appVersion = await readAppVersion(client);
	const dom = await client.evalInRenderer<{
		pageState: PageState;
		dfPills: DfPill[];
		compactPills: CompactPillSnap[];
		ariaLabeledButtons: AriaButton[];
		openMenu: OpenMenu | null;
		modals: ModalSnap[];
	}>('claude.ai', RENDERER_CAPTURE_BODY);
	return {
		capturedAt: new Date().toISOString(),
		claudeAiUrl: target,
		appVersion,
		pageState: dom.pageState,
		dfPills: dom.dfPills,
		compactPills: dom.compactPills,
		ariaLabeledButtons: dom.ariaLabeledButtons,
		openMenu: dom.openMenu,
		modals: dom.modals,
	};
}

// Just the pills slice — used by `explore pills`. Reuses the same eval
// body to avoid drift between subcommands.
export async function capturePills(
	client: InspectorClient,
): Promise<{
	dfPills: DfPill[];
	compactPills: CompactPillSnap[];
	pageState: PageState;
}> {
	const dom = await client.evalInRenderer<{
		pageState: PageState;
		dfPills: DfPill[];
		compactPills: CompactPillSnap[];
		ariaLabeledButtons: AriaButton[];
		openMenu: OpenMenu | null;
		modals: ModalSnap[];
	}>('claude.ai', RENDERER_CAPTURE_BODY);
	return {
		dfPills: dom.dfPills,
		compactPills: dom.compactPills,
		pageState: dom.pageState,
	};
}

// Just the open menu — used by `explore menu`.
export async function captureOpenMenu(
	client: InspectorClient,
): Promise<OpenMenu | null> {
	const dom = await client.evalInRenderer<{ openMenu: OpenMenu | null }>(
		'claude.ai',
		`(() => { ${OPEN_MENU_FN} return { openMenu: openMenu() }; })()`,
	);
	return dom.openMenu;
}

async function pickClaudeAiWebContents(
	client: InspectorClient,
): Promise<string> {
	const list = await client.evalInMain<Array<{ url: string }>>(`
		const { webContents } = process.mainModule.require('electron');
		return webContents.getAllWebContents().map(w => ({ url: w.getURL() }));
	`);
	const target = list.find((w) => w.url.includes('claude.ai'));
	if (!target) {
		throw new Error(
			'snapshot: no claude.ai webContents — open the app to a ' +
				'logged-in state first',
		);
	}
	return target.url;
}

// app.getVersion() is the cleanest source of truth — same value the
// app.asar serves at runtime. Returns null if the call shape ever
// changes upstream rather than failing the whole snapshot.
async function readAppVersion(
	client: InspectorClient,
): Promise<string | null> {
	try {
		return await client.evalInMain<string>(`
			const { app } = process.mainModule.require('electron');
			return app.getVersion();
		`);
	} catch {
		return null;
	}
}

// Single shared renderer-eval body. Definitions are inlined as IIFEs so
// the whole capture is one round-trip. Truncation limits (text 200,
// list 200) are wide enough for current claude.ai but bounded so a
// future infinite-scroll regression doesn't blow up the JSON file.
const OPEN_MENU_FN = `
	function openMenu() {
		const menu = document.querySelector('[role=menu][data-open]')
			|| document.querySelector('[role=menu]');
		if (!menu) return null;
		const items = Array.from(menu.querySelectorAll(
			'[role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]'
		)).slice(0, 200).map(el => ({
			role: el.getAttribute('role') || '',
			text: (el.textContent || '').trim().slice(0, 200),
			ariaChecked: el.getAttribute('aria-checked'),
			disabled: el.hasAttribute('data-disabled')
				|| el.getAttribute('aria-disabled') === 'true',
		}));
		return {
			ariaLabelledBy: menu.getAttribute('aria-labelledby'),
			ariaLabel: menu.getAttribute('aria-label'),
			items,
		};
	}
`;

const RENDERER_CAPTURE_BODY = `
	(() => {
		${OPEN_MENU_FN}
		const buttons = Array.from(document.querySelectorAll('button'));
		const dfPills = buttons
			.filter(b => /\\bdf-pill\\b/.test(b.className))
			.map(b => ({
				ariaLabel: b.getAttribute('aria-label'),
				text: (b.textContent || '').trim().slice(0, 200),
				visible: !!b.getClientRects().length,
			}));
		const compactPills = buttons.flatMap(b => {
			if (b.getAttribute('aria-haspopup') !== 'menu') return [];
			const span = b.querySelector('span.truncate');
			if (!span) return [];
			const m = span.className.match(/max-w-\\[[^\\]]+\\]/);
			if (!m) return [];
			return [{
				ariaLabel: b.getAttribute('aria-label'),
				text: (span.textContent || '').trim().slice(0, 200),
				maxW: m[0],
				expanded: b.getAttribute('aria-expanded') === 'true',
			}];
		});
		const ariaLabeledButtons = buttons
			.filter(b => b.hasAttribute('aria-label'))
			.slice(0, 200)
			.map(b => ({
				ariaLabel: b.getAttribute('aria-label') || '',
				text: (b.textContent || '').trim().slice(0, 200),
				expanded: b.hasAttribute('aria-expanded')
					? b.getAttribute('aria-expanded') === 'true'
					: null,
				hasPopup: b.getAttribute('aria-haspopup'),
				visible: !!b.getClientRects().length,
			}));
		const modals = Array.from(
			document.querySelectorAll('[role=dialog]')
		).slice(0, 20).map(d => {
			const heading = d.querySelector(
				'h1, h2, h3, [role=heading]'
			);
			const btnLabels = Array.from(d.querySelectorAll('button'))
				.slice(0, 50)
				.map(b => {
					const al = b.getAttribute('aria-label');
					if (al) return al;
					return (b.textContent || '').trim().slice(0, 80);
				})
				.filter(s => s.length > 0);
			return {
				ariaLabel: d.getAttribute('aria-label'),
				ariaLabelledBy: d.getAttribute('aria-labelledby'),
				headingText: heading
					? (heading.textContent || '').trim().slice(0, 200)
					: null,
				buttonLabels: btnLabels,
			};
		});
		return {
			pageState: {
				url: location.href,
				title: document.title,
				readyState: document.readyState,
			},
			dfPills,
			compactPills,
			ariaLabeledButtons,
			openMenu: openMenu(),
			modals,
		};
	})()
`;
