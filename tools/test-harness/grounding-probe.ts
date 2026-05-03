// Grounding probe — dumps Claude Desktop runtime state that backs the
// load-bearing claims in docs/testing/cases/. Output is keyed by
// test-ID so the next grounding sweep can diff captures across
// upstream versions.
//
// Two modes:
//   - attach (default): connect to an already-running app on port 9229
//     (manual `--inspect=9229` run, or a launchClaude() instance that
//     called attachInspector()).
//   - --launch: spin up a fresh isolated instance via launchClaude(),
//     capture, tear down. Self-contained — usable in CI.
//
// Mostly read-only; --include-synthetic enables short-lived state
// changes (powerSaveBlocker start+stop) to close API-only gaps.
//
// Usage:
//   cd tools/test-harness
//   npx tsx grounding-probe.ts                                          # attach :9229
//   npx tsx grounding-probe.ts --launch                                 # self-contained
//   npx tsx grounding-probe.ts --launch --include-synthetic
//   npx tsx grounding-probe.ts --out ../../docs/testing/cases-grounding-runtime.json
//   npx tsx grounding-probe.ts --port 9229 --out path/to/file.json
//
// Extending: add a section in capture() with a `client.evalInMain`
// dump targeting whatever runtime state your new test cares about,
// then map the result into `tests[<id>]`.

import { writeFileSync } from 'node:fs';
import { InspectorClient } from './src/lib/inspector.js';
import { launchClaude } from './src/lib/electron.js';

// Accelerators we expect to be registered on Linux. T06 = Quick Entry
// default. S31/S32 — fullscreen + cmd-K dispatch. Extend per case docs.
const KNOWN_ACCELERATORS = [
	'Alt+Space',
	'Ctrl+Alt+Space',
	'CommandOrControl+Shift+L',
];

interface GroundingCapture {
	capturedAt: string;
	appVersion: string;
	appPath: string;
	isPackaged: boolean;
	platform: string;
	// Cross-test corpus — useful as a denormalized source the per-test
	// entries reference by index/key. Keep these flat so jq queries
	// don't need to walk a nested tree.
	ipcInvokeChannels: string[];
	ipcOnChannels: string[];
	webContents: Array<{ id: number; url: string; type: string }>;
	// Per-test bag — extend as new probes land. Each entry is the
	// runtime state the test's load-bearing claim depends on, in a
	// shape that's easy to diff across captures.
	tests: Record<string, unknown>;
	// Probe-level diagnostics — what we tried and couldn't capture.
	// Surfaced so the grounding sweep can flag uncovered surfaces.
	gaps: string[];
}

interface CaptureOptions {
	includeSynthetic: boolean;
}

async function capture(
	client: InspectorClient,
	opts: CaptureOptions,
): Promise<GroundingCapture> {
	const gaps: string[] = [];

	// App metadata — every test references at least one of these.
	const appMeta = await client.evalInMain<{
		appVersion: string;
		appPath: string;
		isPackaged: boolean;
		appReady: boolean;
		platform: string;
	}>(`
		const { app } = process.mainModule.require('electron');
		return {
			appVersion: app.getVersion(),
			appPath: app.getAppPath(),
			isPackaged: app.isPackaged,
			appReady: app.isReady(),
			platform: process.platform,
		};
	`);

	// IPC handler registry. Every claude.web_* channel registers via
	// ipcMain.handle() (invoke side) or ipcMain.on() (fire-and-forget).
	// Private API — surfaces shift across Electron versions; tolerate
	// both shapes.
	const ipc = await client.evalInMain<{ invoke: string[]; on: string[] }>(`
		const { ipcMain } = process.mainModule.require('electron');
		const invoke = ipcMain._invokeHandlers
			? Array.from(ipcMain._invokeHandlers.keys())
			: [];
		const on = ipcMain.eventNames ? ipcMain.eventNames().map(String) : [];
		return { invoke, on };
	`);

	// WebContents inventory — proves which BrowserViews / BrowserWindows
	// exist at probe time. Note: BrowserWindow.getAllWindows() returns
	// 0 because frame-fix-wrapper substitutes the class (see
	// inspector.ts header comment) — webContents registry stays intact.
	const webContents = await client.evalInMain<
		Array<{ id: number; url: string; type: string }>
	>(`
		const { webContents } = process.mainModule.require('electron');
		return webContents.getAllWebContents().map(w => ({
			id: w.id,
			url: w.getURL(),
			type: w.getType ? w.getType() : 'unknown',
		}));
	`);

	// Global shortcuts — T06, S31/S32 reference these. isRegistered()
	// is the canonical runtime probe; matches the case-doc claim about
	// what's bound at startup.
	const accelerators = await client.evalInMain<
		Array<{ accelerator: string; registered: boolean }>
	>(`
		const { globalShortcut } = process.mainModule.require('electron');
		const list = ${JSON.stringify(KNOWN_ACCELERATORS)};
		return list.map(a => ({
			accelerator: a,
			registered: globalShortcut.isRegistered(a),
		}));
	`);

	// Autostart resolution — T09. On Linux Electron's openAtLogin is a
	// documented no-op; our wrapper installs an XDG Autostart shim
	// (frame-fix-wrapper.js:376). The empirical check confirms which
	// path is active.
	const loginItems = await client.evalInMain<{
		openAtLogin: boolean;
		wasOpenedAtLogin?: boolean;
		executableWillLaunchAtLogin?: boolean;
	}>(`
		const { app } = process.mainModule.require('electron');
		return app.getLoginItemSettings();
	`);

	// safeStorage — S18 (env-config encryption) + S25 (cowork trusted-
	// device token). Linux backend is libsecret; availability gates
	// whether tokens persist or stall.
	const safeStorage = await client.evalInMain<{
		available: boolean;
		backend: string;
	}>(`
		const { safeStorage } = process.mainModule.require('electron');
		let backend = 'unknown';
		try {
			if (safeStorage.getSelectedStorageBackend) {
				backend = safeStorage.getSelectedStorageBackend();
			}
		} catch (_) { /* older Electron — backend not exposed */ }
		return {
			available: safeStorage.isEncryptionAvailable(),
			backend,
		};
	`);

	// autoUpdater feedURL — S26. The case doc claims the gate is open
	// by construction (lii() returns true on Linux when packaged).
	// Accidental coverage from Electron's Linux autoUpdater being
	// unimplemented saves us from real download attempts. This probe
	// puts that on the record empirically.
	const autoUpdater = await client.evalInMain<{
		feedURL: string | null;
		feedURLError: string | null;
	}>(`
		const { autoUpdater } = process.mainModule.require('electron');
		let feedURL = null, feedURLError = null;
		try {
			feedURL = autoUpdater.getFeedURL ? autoUpdater.getFeedURL() : null;
		} catch (e) {
			feedURLError = String(e && e.message);
		}
		return { feedURL, feedURLError };
	`);

	// Tray — T03. We can't enumerate Tray instances via public API,
	// but we can confirm Notification support is alive (T23 prerequisite).
	const notifications = await client.evalInMain<{ supported: boolean }>(`
		const { Notification } = process.mainModule.require('electron');
		return { supported: Notification.isSupported() };
	`);

	// Powermonitor / suspend inhibit — S20. powerSaveBlocker has no
	// public enumeration API. Synthetic probe (gated behind
	// --include-synthetic) starts a blocker, reads isStarted, stops
	// immediately. Brief inhibit (~ms) is harmless; what we get back
	// is empirical proof the API path is alive on this host. Doesn't
	// verify the case-doc claim that `keepAwakeEnabled` setting toggles
	// trigger this — that requires correlating settings IO with the
	// `PhA` Set at index.js:241897, which depends on minified-name
	// stability and is left to the next sweep.
	let powerSaveBlocker: {
		apiAvailable: boolean;
		startWorks: boolean;
		idType: string;
		probeError: string | null;
	} | null = null;
	if (opts.includeSynthetic) {
		powerSaveBlocker = await client.evalInMain(`
			const { powerSaveBlocker } = process.mainModule.require('electron');
			let id = null, started = false, probeError = null;
			try {
				id = powerSaveBlocker.start('prevent-app-suspension');
				started = powerSaveBlocker.isStarted(id);
			} catch (e) {
				probeError = String(e && e.message);
			} finally {
				if (id !== null) {
					try { powerSaveBlocker.stop(id); } catch (_) {}
				}
			}
			return {
				apiAvailable: true,
				startWorks: started,
				idType: typeof id,
				probeError,
			};
		`);
	} else {
		gaps.push(
			'S20: powerSaveBlocker not probed (skip-synthetic). ' +
				'Re-run with --include-synthetic to confirm API path.',
		);
	}

	// T22 PR toolbar / T31 side chat / T32 slash menu / T39 /desktop —
	// these are renderer-side surfaces. Reachable via
	// `client.evalInRenderer('claude.ai', ...)` once the relevant view
	// is open. Captured-at-idle inventory misses them, so this probe
	// would need to either drive the UI to open them (destructive) or
	// be invoked while the user has the surface open. Flagged.
	gaps.push(
		'T22/T31/T32: contextual renderer surfaces (PR toolbar, side chat, ' +
			'slash menu) require the surface to be open at probe time. ' +
			'Re-run grounding-probe with the relevant view active to capture.',
	);
	gaps.push(
		'T39 /desktop: lives in the upstream `claude` CLI binary, not the ' +
			'Electron asar — not reachable from this probe.',
	);

	return {
		capturedAt: new Date().toISOString(),
		appVersion: appMeta.appVersion,
		appPath: appMeta.appPath,
		isPackaged: appMeta.isPackaged,
		platform: appMeta.platform,
		ipcInvokeChannels: ipc.invoke,
		ipcOnChannels: ipc.on,
		webContents,
		tests: {
			T01: { appReady: appMeta.appReady, webContentsCount: webContents.length },
			T06: { accelerators },
			T09: loginItems,
			T23: notifications,
			S18: safeStorage,
			S20: powerSaveBlocker,
			S22: {
				platform: appMeta.platform,
				expectedDisabledOnLinux: appMeta.platform === 'linux',
			},
			S25: safeStorage,
			S26: {
				...autoUpdater,
				isPackaged: appMeta.isPackaged,
				platform: appMeta.platform,
				note: 'Gate is structurally open; saved by Electron autoUpdater being unimplemented on Linux.',
			},
		},
		gaps,
	};
}

interface ParsedArgs {
	port: number;
	out: string;
	launch: boolean;
	includeSynthetic: boolean;
}

function parseArgs(argv: string[]): ParsedArgs {
	const flags = new Set<string>();
	const args = new Map<string, string>();
	for (let i = 2; i < argv.length; i++) {
		const tok = argv[i];
		if (!tok || !tok.startsWith('--')) continue;
		const key = tok.replace(/^--/, '');
		const next = argv[i + 1];
		if (next && !next.startsWith('--')) {
			args.set(key, next);
			i++;
		} else {
			flags.add(key);
		}
	}
	return {
		port: Number(args.get('port') ?? 9229),
		out: args.get('out') ?? '/tmp/grounding-probe.json',
		launch: flags.has('launch'),
		includeSynthetic: flags.has('include-synthetic'),
	};
}

async function main() {
	const parsed = parseArgs(process.argv);
	const { out, launch, includeSynthetic } = parsed;

	let client: InspectorClient;
	let cleanup: () => Promise<void>;

	if (launch) {
		// Self-contained: fresh isolation per run, tear down on exit.
		// 'mainVisible' is the lowest level that gives us the inspector
		// without waiting on claude.ai network load. Sufficient for
		// every probe in capture() — none touch renderer DOM.
		const app = await launchClaude();
		const ready = await app.waitForReady('mainVisible');
		client = ready.inspector;
		cleanup = async () => {
			client.close();
			await app.close();
		};
	} else {
		client = await InspectorClient.connect(parsed.port);
		cleanup = async () => {
			client.close();
		};
	}

	try {
		const result = await capture(client, { includeSynthetic });
		writeFileSync(out, JSON.stringify(result, null, 2));
		console.log(
			`grounding-probe: wrote ${out} ` +
				`(${result.ipcInvokeChannels.length} invoke channels, ` +
				`${result.webContents.length} webContents, ` +
				`${result.gaps.length} gaps` +
				`${launch ? ', --launch' : ''}` +
				`${includeSynthetic ? ', synthetic' : ''})`,
		);
	} finally {
		await cleanup();
	}
}

main().catch((err) => {
	console.error('grounding-probe failed:', err);
	process.exit(1);
});
