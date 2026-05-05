// Standalone probe that connects to a running claude-desktop with the
// main process debugger enabled (port 9229) and dumps renderer-DOM
// shapes useful for designing reusable abstractions in lib/claudeai.ts.
//
// Run from tools/test-harness:
//   npx tsx probe.ts
//
// Non-destructive — observes only, doesn't click anything.

import { InspectorClient } from './src/lib/inspector.js';
import { writeFileSync } from 'node:fs';

async function main() {
	const client = await InspectorClient.connect(9229);

	const webContentsList = await client.evalInMain<
		Array<{ id: number; url: string; type: string }>
	>(`
		const { webContents } = process.mainModule.require('electron');
		return webContents.getAllWebContents().map(w => ({
			id: w.id,
			url: w.getURL(),
			type: w.getType ? w.getType() : 'unknown',
		}));
	`);

	const target = webContentsList.find((w) => w.url.includes('claude.ai'));
	if (!target) {
		console.error('No claude.ai webContents — open the app to a logged-in state first.');
		console.error('webContents observed:', webContentsList);
		process.exit(1);
	}

	console.log('=== webContents ===');
	console.log(JSON.stringify(webContentsList, null, 2));
	console.log('Targeting:', target.url, `(id=${target.id})`);

	// All "pill"-shape buttons on the page.
	const pills = await client.evalInRenderer<{
		dfPills: Array<{ ariaLabel: string | null; text: string; visible: boolean; classSig: string }>;
		menuButtons: Array<{
			ariaLabel: string | null;
			text: string;
			expanded: boolean;
			truncateMaxW: string | null;
			classSig: string;
		}>;
		summary: { totalButtons: number; ariaHaspopupMenu: number; dfPills: number };
	}>(
		'claude.ai',
		`
		(() => {
			const buttons = Array.from(document.querySelectorAll('button'));
			const dfPills = buttons
				.filter(b => /\\bdf-pill\\b/.test(b.className))
				.map(b => ({
					ariaLabel: b.getAttribute('aria-label'),
					text: (b.textContent || '').trim().slice(0, 80),
					visible: !!b.getClientRects().length,
					classSig: b.className.slice(0, 120),
				}));
			const menuButtons = buttons
				.filter(b => b.getAttribute('aria-haspopup') === 'menu')
				.map(b => {
					const truncSpan = b.querySelector('span.truncate');
					const maxW = truncSpan
						? (truncSpan.className.match(/max-w-\\[[^\\]]+\\]/) || [null])[0]
						: null;
					return {
						ariaLabel: b.getAttribute('aria-label'),
						text: (b.textContent || '').trim().slice(0, 80),
						expanded: b.getAttribute('aria-expanded') === 'true',
						truncateMaxW: maxW,
						classSig: b.className.slice(0, 120),
					};
				});
			return {
				dfPills,
				menuButtons,
				summary: {
					totalButtons: buttons.length,
					ariaHaspopupMenu: menuButtons.length,
					dfPills: dfPills.length,
				},
			};
		})()
	`,
	);

	console.log('\n=== Pills summary ===');
	console.log(JSON.stringify(pills.summary, null, 2));

	console.log('\n=== df-pill buttons ===');
	console.log(JSON.stringify(pills.dfPills, null, 2));

	console.log('\n=== aria-haspopup=menu buttons (sample) ===');
	console.log(JSON.stringify(pills.menuButtons.slice(0, 10), null, 2));

	// Currently open menu (if any) — items, structure.
	const openMenu = await client.evalInRenderer<{
		menuPresent: boolean;
		ariaLabelledBy: string | null;
		items: Array<{ role: string; text: string; ariaChecked: string | null; disabled: boolean }>;
	} | null>(
		'claude.ai',
		`
		(() => {
			const menu = document.querySelector('[role=menu][data-open]') || document.querySelector('[role=menu]');
			if (!menu) return null;
			const items = Array.from(menu.querySelectorAll('[role=menuitem], [role=menuitemradio], [role=menuitemcheckbox]'))
				.map(el => ({
					role: el.getAttribute('role') || '',
					text: (el.textContent || '').trim().slice(0, 80),
					ariaChecked: el.getAttribute('aria-checked'),
					disabled: el.hasAttribute('data-disabled') || el.getAttribute('aria-disabled') === 'true',
				}));
			return {
				menuPresent: true,
				ariaLabelledBy: menu.getAttribute('aria-labelledby'),
				items,
			};
		})()
	`,
	);

	console.log('\n=== Currently open menu ===');
	console.log(openMenu ? JSON.stringify(openMenu, null, 2) : 'no menu open');

	// URL and basic page state.
	const pageState = await client.evalInRenderer<{
		url: string;
		title: string;
		readyState: string;
		hasComposer: boolean;
		hasSidebar: boolean;
	}>(
		'claude.ai',
		`
		(() => ({
			url: location.href,
			title: document.title,
			readyState: document.readyState,
			hasComposer: !!document.querySelector('[data-testid*=composer], textarea[placeholder*=Reply], textarea[placeholder*=Message]'),
			hasSidebar: !!document.querySelector('nav, [role=navigation]'),
		}))()
	`,
	);

	console.log('\n=== Page state ===');
	console.log(JSON.stringify(pageState, null, 2));

	const out = { webContentsList, pills, openMenu, pageState };
	writeFileSync('/tmp/claude-probe.json', JSON.stringify(out, null, 2));
	console.log('\nFull dump → /tmp/claude-probe.json');

	client.close();
	process.exit(0);
}

main().catch((err) => {
	console.error('probe failed:', err);
	process.exit(1);
});
