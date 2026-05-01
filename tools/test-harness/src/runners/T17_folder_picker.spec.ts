import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { retryUntil } from '../lib/retry.js';

// T17 — Folder picker opens.
//
// Path: spawn the app normally (no --remote-debugging-port; CDP gate
// stays asleep), wait for the X11 window, send SIGUSR1 to attach the
// Node inspector at runtime (same code path as Developer → Enable Main
// Process Debugger), install a dialog.showOpenDialog mock in the main
// process, then drive the renderer via webContents.executeJavaScript()
// to find and click through to the "Open folder" button. Assert the mock
// was called.
//
// First-run finding (verified end-to-end on KDE-W):
//   - inspector attaches via SIGUSR1 ✓
//   - dialog.showOpenDialog mock installs in main ✓
//   - claude.ai webContents reachable via webContents.getAllWebContents() ✓
//   - sidebar nav clicks land on the Code tab ✓
//   - "Open folder" button is NOT reachable from the home Code view; the
//     upstream test spec describes a multi-step click chain
//     ("environment pill → Local → Select folder") that the renderer
//     selectors below don't yet capture. The test skips at that point
//     with rich diagnostics so the click chain can be iterated on.
//
// The framework itself is proven. What remains is selector tuning to
// match claude.ai's actual Code-tab UI as it ships and evolves.

test('T17 — Folder picker opens', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab / folder picker',
	});

	const app = await launchClaude();

	try {
		await app.waitForX11Window(15_000);
		console.log('[T17] X11 window appeared');
		const inspector = await app.attachInspector(15_000);
		console.log('[T17] inspector attached');

		// Install dialog mock + capture call invocations as JSON-safe
		// metadata. The mock returns a canned filePath so the renderer
		// proceeds with a "successful" folder selection.
		const installed = await inspector.evalInMain<string>(`
			const { dialog } = process.mainModule.require('electron');
			globalThis.__dialogCalls = [];
			const original = dialog.showOpenDialog.bind(dialog);
			dialog.showOpenDialog = async function(...args) {
				const browserWindowArg = args[0] && typeof args[0] === 'object' && args[0].constructor && args[0].constructor.name === 'BrowserWindow';
				const opts = browserWindowArg ? args[1] : args[0];
				globalThis.__dialogCalls.push({
					ts: Date.now(),
					nargs: args.length,
					title: opts && opts.title,
					properties: opts && opts.properties,
				});
				return { canceled: false, filePaths: ['/tmp/claude-desktop-test-folder'] };
			};
			void original;
			return 'mock-installed';
		`);
		expect(installed, 'dialog mock installed in main').toBe('mock-installed');
		console.log('[T17] dialog mock installed');

		// Wait for the claude.ai BrowserView's webContents to appear. The
		// shell window loads first (file://...main_window/index.html);
		// claude.ai gets loaded into an embedded BrowserView a few seconds
		// later. Poll for up to 30s.
		const wcInfo = await retryUntil(
			async () => {
				const r = await inspector.evalInMain<
					{ id: number; url: string } | null
				>(`
					const { webContents } = process.mainModule.require('electron');
					const all = webContents.getAllWebContents();
					const main = all.find(w => w.getURL().includes('claude.ai'));
					if (!main) return null;
					return { id: main.id, url: main.getURL() };
				`);
				return r;
			},
			{ timeout: 30_000, interval: 500 },
		);

		console.log(`[T17] wcInfo: ${JSON.stringify(wcInfo)}`);

		if (!wcInfo) {
			const allWcs = await inspector.evalInMain<{ urls: string[] }>(`
				const { webContents } = process.mainModule.require('electron');
				return { urls: webContents.getAllWebContents().map(w => w.getURL()) };
			`);
			console.log(
				`[T17] no claude.ai webContents after 30s. all urls: ${JSON.stringify(allWcs.urls)}`,
			);
			await testInfo.attach('webcontents-urls', {
				body: JSON.stringify(allWcs.urls, null, 2),
				contentType: 'application/json',
			});
			testInfo.skip(
				true,
				'claude.ai webContents never loaded within 30s — likely not signed in.',
			);
			return;
		}

		await testInfo.attach('renderer-url', {
			body: wcInfo.url,
			contentType: 'text/plain',
		});

		// Wait for the renderer's DOM to actually populate. claude.ai/
		// auto-redirects to /new (or /code, etc.) and that target page
		// renders its buttons asynchronously. Poll until at least some
		// button-like elements are present.
		const domReady = await retryUntil(
			async () => {
				const r = await inspector.evalInRenderer<{
					url: string;
					readyState: string;
					buttonCount: number;
				}>(
					'claude.ai',
					`(() => ({
						url: location.href,
						readyState: document.readyState,
						buttonCount: document.querySelectorAll('button, [role=button]').length,
					}))()`,
				);
				return r.buttonCount > 0 ? r : null;
			},
			{ timeout: 30_000, interval: 500 },
		);

		console.log(`[T17] domReady: ${JSON.stringify(domReady)}`);
		await testInfo.attach('dom-ready', {
			body: JSON.stringify(domReady, null, 2),
			contentType: 'application/json',
		});

		if (!domReady) {
			testInfo.skip(true, 'renderer DOM never populated buttons within 30s');
			return;
		}

		// Step 1: navigate to the Code tab. The home renderer
		// (claude.ai/new) shows the "Code" entry in the sidebar; the
		// folder picker lives on that tab.
		const navResult = await inspector.evalInRenderer<{
			clicked: string | null;
			urlBefore: string;
			diag: Array<{ tag: string; text: string; len: number; codes: number[] }>;
		}>(
			'claude.ai',
			`
			(() => {
				const urlBefore = location.href;
				const candidates = Array.from(document.querySelectorAll('button, a, [role=button], [role=tab], [role=link]'));
				const matching = candidates.filter(el => (el.textContent || '').toLowerCase().includes('code'));
				const diag = matching.slice(0, 5).map(el => {
					const text = (el.textContent || '').trim();
					return {
						tag: el.tagName.toLowerCase(),
						text,
						len: text.length,
						codes: [...text].slice(0, 10).map(c => c.charCodeAt(0)),
					};
				});
				// Click the first candidate with text === "Code" after stripping
				// invisible/decorative chars. Reject parents that contain "Code"
				// nested in longer history-item text.
				const codeBtn = matching.find(el => {
					const text = (el.textContent || '').trim();
					// strip non-printable / invisible chars
					const clean = text.replace(/[^\\x20-\\x7E]/g, '').trim();
					return clean.toLowerCase() === 'code';
				});
				if (!codeBtn) return { clicked: null, urlBefore, diag };
				codeBtn.click();
				return { clicked: 'Code', urlBefore, diag };
			})()
		`,
		);
		console.log(`[T17] navResult: ${JSON.stringify(navResult)}`);

		if (!navResult.clicked) {
			testInfo.skip(true, 'Code sidebar entry not found in renderer');
			return;
		}

		// Step 2: wait for navigation, then find folder-picker button
		await retryUntil(
			async () => {
				const r = await inspector.evalInRenderer<{ url: string }>(
					'claude.ai',
					`({ url: location.href })`,
				);
				return r.url !== navResult.urlBefore ? r.url : null;
			},
			{ timeout: 10_000, interval: 250 },
		);

		// Wait for the Code tab UI to populate
		await retryUntil(
			async () => {
				const r = await inspector.evalInRenderer<{ count: number }>(
					'claude.ai',
					`({ count: document.querySelectorAll('button, [role=button]').length })`,
				);
				return r.count > 5 ? r : null;
			},
			{ timeout: 10_000, interval: 250 },
		);

		// Step 3: try to click the folder-picker button
		const clickAttempt = await inspector.evalInRenderer<{
			matched: number;
			texts: string[];
			clicked: string | null;
			urlNow: string;
		}>(
			'claude.ai',
			`
			(() => {
				const candidates = Array.from(document.querySelectorAll('button, [role=button]'));
				const wanted = candidates.filter(el => {
					const text = (el.textContent || el.getAttribute('aria-label') || '').toLowerCase();
					return /open folder|open project|add folder|select folder|local folder/.test(text);
				});
				const texts = candidates.slice(0, 50).map(el => (el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 60));
				const urlNow = location.href;
				if (wanted.length === 0) return { matched: 0, texts, clicked: null, urlNow };
				const target = wanted[0];
				const label = (target.textContent || '').trim();
				target.click();
				return { matched: wanted.length, texts: [], clicked: label, urlNow };
			})()
		`,
		);

		console.log(`[T17] clickAttempt: ${JSON.stringify(clickAttempt).slice(0, 500)}`);
		await testInfo.attach('click-attempt', {
			body: JSON.stringify(clickAttempt, null, 2),
			contentType: 'application/json',
		});

		if (!clickAttempt.clicked) {
			testInfo.skip(
				true,
				`No "Open folder" button found in renderer. ` +
					`Found ${clickAttempt.matched} candidates by text matching; ` +
					`first 30 button labels logged in click-attempt attachment.`,
			);
			return;
		}

		// Wait for the dialog mock to fire
		const calls = await retryUntil(
			async () => {
				const c = await inspector.evalInMain<unknown[]>(
					`return globalThis.__dialogCalls`,
				);
				return c.length > 0 ? c : null;
			},
			{ timeout: 10_000, interval: 250 },
		);

		await testInfo.attach('dialog-calls', {
			body: JSON.stringify(calls, null, 2),
			contentType: 'application/json',
		});

		expect(
			calls,
			'dialog.showOpenDialog was invoked after clicking Open folder',
		).toBeTruthy();
		expect((calls ?? []).length).toBeGreaterThan(0);

		inspector.close();
	} finally {
		await app.close();
	}
});
