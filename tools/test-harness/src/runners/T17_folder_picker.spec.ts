import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';

const MOCK_FOLDER = '/tmp/claude-desktop-test-folder';

// V1 SHALLOW TEST — Electron-level dialog intercept.
//
// The unit being tested here is "Claude's renderer requested a folder and
// handled the response" — which Electron's `dialog.showOpenDialog` API
// captures regardless of whether the underlying impl is portal- or
// GTK-based. Real portal-level mocking (registering a backend at
// org.freedesktop.portal.FileChooser via dbus-next) is the v2 path; it
// requires displacing the running portal service or running under
// dbus-run-session, both of which are intrusive enough to defer until
// signal warrants it.
//
// See docs/testing/automation.md "Native dialogs" section. If you find
// the renderer doesn't call dialog.showOpenDialog (i.e. it goes directly
// to a portal request), this test will skip and you'll know to upgrade
// to v2.

test('T17 — Folder picker opens', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Code tab / folder picker',
	});

	const app = await launchClaude();

	try {
		const window = await app.firstWindow({ timeout: 10_000 });
		await window.waitForLoadState('domcontentloaded', { timeout: 15_000 });

		// Install the dialog intercept in the main process before the renderer
		// triggers it. Captured into a global so we can assert from the test.
		await app.evaluate(async ({ dialog }, fakeFolder: string) => {
			(globalThis as unknown as { __dialogCalls: unknown[] }).__dialogCalls = [];
			const original = dialog.showOpenDialog.bind(dialog);
			dialog.showOpenDialog = (async (...args: unknown[]) => {
				(globalThis as unknown as { __dialogCalls: unknown[] }).__dialogCalls.push(args);
				return { canceled: false, filePaths: [fakeFolder] };
			}) as typeof dialog.showOpenDialog;
			void original;
		}, MOCK_FOLDER);

		// Try to navigate to the Code tab. Selectors are best-effort; the
		// upstream UI structure may differ. Adjust on first run.
		const codeTab = window.getByRole('tab', { name: /code/i });
		const codeLink = window.getByRole('link', { name: /code/i });

		const tabVisible = await codeTab.isVisible({ timeout: 5_000 }).catch(() => false);
		const linkVisible = await codeLink.isVisible({ timeout: 1_000 }).catch(() => false);

		if (!tabVisible && !linkVisible) {
			testInfo.skip(
				true,
				'Code tab not reachable — likely not signed in. Sign-in fixture is a separate concern.',
			);
			return;
		}

		if (tabVisible) {
			await codeTab.click();
		} else {
			await codeLink.click();
		}

		// Click whatever opens the folder picker. Multiple plausible labels.
		const openFolderButton = window.getByRole('button', {
			name: /open folder|open project|add (folder|project)/i,
		});
		await openFolderButton.click({ timeout: 10_000 });

		const calls = await app.evaluate(() => {
			return (globalThis as unknown as { __dialogCalls?: unknown[] }).__dialogCalls ?? [];
		});

		await testInfo.attach('dialog-calls', {
			body: JSON.stringify(calls, null, 2),
			contentType: 'application/json',
		});

		expect(
			calls.length,
			'dialog.showOpenDialog was invoked at least once',
		).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
