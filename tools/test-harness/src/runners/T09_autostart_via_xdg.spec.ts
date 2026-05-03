import { test, expect } from '@playwright/test';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { launchClaude } from '../lib/electron.js';
import { retryUntil } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// T09 — Autostart via XDG.
//
// frame-fix-wrapper.js installs a setLoginItemSettings shim on Linux
// (Electron's openAtLogin is a no-op there — electron/electron#15198).
// The shim resolves $XDG_CONFIG_HOME/autostart/claude-desktop.desktop
// (falling back to ~/.config when the env var is unset/empty) and
// writes a spec-compliant [Desktop Entry] block on `openAtLogin: true`,
// unlinking it on `openAtLogin: false`.
//
// Default isolation gives a per-test XDG_CONFIG_HOME, so the autostart
// file lands inside the sandbox — no host-level cleanup needed.
//
// Code anchors:
//   scripts/frame-fix-wrapper.js:566 — autostartPath construction
//   scripts/frame-fix-wrapper.js:601 — buildAutostartContent()
//   scripts/frame-fix-wrapper.js:627 — setLoginItemSettings shim

// Cold-start + waitForReady('mainVisible') alone has a 90s budget,
// so the default 60s test timeout is too tight. Two inspector evals
// add a few hundred ms each; 120s gives margin without masking real
// hangs.
test.setTimeout(120_000);

test('T09 — Autostart via XDG writes/removes desktop entry', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Autostart / login item',
	});

	// All Linux rows — no skipUnlessRow.

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	const app = await launchClaude();
	try {
		await testInfo.attach('isolation-env', {
			body: JSON.stringify(app.isolation?.env ?? null, null, 2),
			contentType: 'application/json',
		});
		const xdgConfigHome = app.isolation?.env.XDG_CONFIG_HOME;
		expect(
			xdgConfigHome,
			'isolation provides XDG_CONFIG_HOME',
		).toBeTruthy();
		const autostartPath = join(
			xdgConfigHome!,
			'autostart',
			'claude-desktop.desktop',
		);
		await testInfo.attach('autostart-path', {
			body: autostartPath,
			contentType: 'text/plain',
		});

		// Don't gate on 'mainVisible' — that requires a claude.ai
		// webContents to exist, which depends on network reachability
		// and isn't relevant to the autostart shim (installed at
		// frame-fix-wrapper module-load time, well before the renderer
		// loads claude.ai). All we need is the inspector attached.
		await app.waitForX11Window();
		const inspector = await app.attachInspector();

		// Sanity: file should not exist before the toggle. The shim only
		// writes on explicit setLoginItemSettings calls.
		const initiallyPresent = existsSync(autostartPath);
		await testInfo.attach('initial-existence', {
			body: String(initiallyPresent),
			contentType: 'text/plain',
		});
		expect(
			initiallyPresent,
			'autostart file absent before any toggle',
		).toBe(false);

		// Capture the wrapper's view of XDG_CONFIG_HOME and shim binding.
		// On failure this answers two questions immediately: did the env
		// var propagate into the spawned process, and is the wrapper's
		// setLoginItemSettings substitution still in place. If wrapperEnv
		// .xdg is null but isolation-env had it set, the env didn't reach
		// Electron — diagnose at launchClaude. If isFn is true but the
		// file never lands, the wrapper substitution is being undone (or
		// the path-construction comment in this file is out of date).
		const wrapperEnv = await inspector.evalInMain<{
			xdg: string | null;
			home: string;
			isFn: boolean;
			xdgKeys: string[];
		}>(`
			const os = process.mainModule.require('os');
			const { app } = process.mainModule.require('electron');
			return {
				xdg: process.env.XDG_CONFIG_HOME ?? null,
				home: os.homedir(),
				isFn: typeof app.setLoginItemSettings === 'function',
				xdgKeys: Object.keys(process.env).filter(k => k.startsWith('XDG_')),
			};
		`);
		await testInfo.attach('wrapper-env', {
			body: JSON.stringify(wrapperEnv, null, 2),
			contentType: 'application/json',
		});

		// Toggle on.
		await inspector.evalInMain<null>(`
			const { app } = process.mainModule.require('electron');
			app.setLoginItemSettings({ openAtLogin: true });
			return null;
		`);

		// Filesystem write is synchronous in the shim, but the eval
		// resolves before the Node fs.writeFileSync syscall settles
		// against any FUSE-backed tmpdir. retryUntil returns null on
		// timeout, so use a truthy sentinel to distinguish "found" from
		// "timed out".
		const enabled = await retryUntil(
			async () => (existsSync(autostartPath) ? 'present' : null),
			{ timeout: 3_000, interval: 100 },
		);
		await testInfo.attach('post-enable-existence', {
			body: String(existsSync(autostartPath)),
			contentType: 'text/plain',
		});
		expect(
			enabled,
			'autostart file written after openAtLogin: true',
		).toBe('present');

		const desktopEntry = readFileSync(autostartPath, 'utf8');
		await testInfo.attach('desktop-entry', {
			body: desktopEntry,
			contentType: 'text/plain',
		});
		expect(
			desktopEntry,
			'desktop entry has [Desktop Entry] header',
		).toMatch(/^\[Desktop Entry\]/m);
		expect(desktopEntry, 'desktop entry has Type= line').toMatch(
			/^Type=Application/m,
		);
		expect(desktopEntry, 'desktop entry has Exec= line').toMatch(/^Exec=.+/m);
		expect(desktopEntry, 'desktop entry has Name= line').toMatch(/^Name=.+/m);

		// Toggle off.
		await inspector.evalInMain<null>(`
			const { app } = process.mainModule.require('electron');
			app.setLoginItemSettings({ openAtLogin: false });
			return null;
		`);

		const disabled = await retryUntil(
			async () => (!existsSync(autostartPath) ? 'gone' : null),
			{ timeout: 3_000, interval: 100 },
		);
		await testInfo.attach('post-disable-existence', {
			body: String(existsSync(autostartPath)),
			contentType: 'text/plain',
		});
		expect(
			disabled,
			'autostart file removed after openAtLogin: false',
		).toBe('gone');
	} finally {
		await app.close();
	}
});
