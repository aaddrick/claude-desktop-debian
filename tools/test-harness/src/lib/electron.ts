import { spawn, execFile, type ChildProcess } from 'node:child_process';
import { existsSync, readlinkSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { sleep, retryUntil } from './retry.js';
import { findX11WindowByPid } from './wm.js';
import { InspectorClient } from './inspector.js';
import { createIsolation, type Isolation } from './isolation.js';
import { MainWindow, waitForUserLoaded } from './quickentry.js';

const exec = promisify(execFile);

export interface LaunchOptions {
	extraEnv?: Record<string, string>;
	args?: string[];
	// Pass an existing Isolation to share config across multiple
	// launches in one test (e.g. S35 position-memory across restart).
	// Pass `null` to opt out of isolation entirely (legacy: shares
	// ~/.config/Claude with the host). Default: a fresh isolation per
	// launch, cleaned up on close().
	isolation?: Isolation | null;
}

// Tiered readiness levels for waitForReady(). Higher levels include
// every check from lower levels. Pick the lowest level a test
// actually needs:
//   - 'window'      X11 window mapped (no inspector, no renderer state)
//   - 'mainVisible' main shell BrowserWindow.isVisible() === true
//   - 'claudeAi'    any claude.ai webContents reachable (may be /login)
//   - 'userLoaded'  claude.ai URL past /login (lHn() precondition; the
//                   tightest gate before exercising QE submit paths)
export type ReadyLevel = 'window' | 'mainVisible' | 'claudeAi' | 'userLoaded';

export interface WaitForReadyOptions {
	// Overall budget across all levels. Each step consumes from the
	// remaining budget. Default 90_000ms covers the userLoaded path
	// (~5-10s startup + main visible + 30s claude.ai load + login
	// nav) with margin. Override down for cheaper levels.
	timeout?: number;
}

export interface WindowReady {
	wid: string;
}

export interface MainVisibleReady extends WindowReady {
	inspector: InspectorClient;
}

export interface ClaudeAiReady extends MainVisibleReady {
	// First claude.ai webContents URL observed. Absent if claude.ai
	// never loaded within the budget — caller can treat as a skip
	// (host likely not signed in).
	claudeAiUrl?: string;
}

export interface UserLoadedReady extends ClaudeAiReady {
	// claude.ai URL past /login. Absent if the renderer never
	// navigated past the login page within the budget.
	postLoginUrl?: string;
}

// Maps each level to the precise return shape its callers see.
// Conditional type rather than overloads because the implementation
// is a single closure with a union return — overloads would require
// either an unsafe cast or function-declaration overloads, both
// noisier than this.
export type ReadyResultFor<L extends ReadyLevel> =
	L extends 'window' ? WindowReady :
	L extends 'mainVisible' ? MainVisibleReady :
	L extends 'claudeAi' ? ClaudeAiReady :
	L extends 'userLoaded' ? UserLoadedReady :
	never;

export interface ClaudeApp {
	process: ChildProcess;
	pid: number;
	isolation: Isolation | null;
	// Populated on close(). When the spawned Electron exits with
	// non-zero `code` and was NOT killed by us (`signal === null`),
	// this carries the data so a runner can `testInfo.attach()` the
	// crash info without us coupling electron.ts to Playwright APIs
	// or breaking the existing `await app.close()` sites that ignore
	// the return value. Stays null while the proc is still running.
	lastExitInfo: { code: number | null; signal: NodeJS.Signals | null } | null;
	close(): Promise<void>;
	waitForX11Window(timeoutMs?: number): Promise<string>;
	attachInspector(timeoutMs?: number): Promise<InspectorClient>;
	// Tiered "is the app ready for the kind of work this test does"
	// helper. See ReadyLevel for what each level checks. Throws on
	// timeout for 'window' / 'mainVisible' (hard-fail levels). For
	// 'claudeAi' / 'userLoaded', returns with the corresponding field
	// (claudeAiUrl, postLoginUrl) absent on timeout so callers can
	// `testInfo.skip()` rather than fail when the host isn't signed in.
	waitForReady<L extends ReadyLevel>(
		level: L,
		opts?: WaitForReadyOptions,
	): Promise<ReadyResultFor<L>>;
}

// CDP auth gate: index.pre.js has
//   uF(process.argv) && !qL() && process.exit(1);
// where uF matches --remote-debugging-port / --remote-debugging-pipe on argv
// and qL validates a token in CLAUDE_CDP_AUTH against a hardcoded ed25519
// public key (signed payload `${timestamp_ms}.${base64(userDataDir)}`,
// 5-minute TTL). Both Playwright's _electron.launch() and
// chromium.connectOverCDP() inject --remote-debugging-port=0 and trip the
// gate. Signing key is upstream's; we can't forge tokens.
//
// Workaround: the gate doesn't check --inspect or runtime SIGUSR1 (the
// "Developer → Enable Main Process Debugger" menu's code path). So we
// spawn without any debug-port flags (gate stays asleep), wait for the
// X11 window to appear, then send SIGUSR1 to attach the Node inspector at
// runtime. From there lib/inspector.ts gives us main-process JS eval,
// which reaches the renderer via webContents.executeJavaScript() and
// supports main-process mocks (e.g. dialog.showOpenDialog for T17).

// Default backend: X11 via XWayland. Mirrors launcher-common.sh's
// build_electron_args() X11 branch (the launcher itself isn't invoked
// because we spawn Electron directly to keep CLAUDE_CDP_AUTH out of
// the picture — see the SIGUSR1 attach comment above).
const LAUNCHER_INJECTED_FLAGS_X11 = [
	'--disable-features=CustomTitlebar',
	'--ozone-platform=x11',
	'--no-sandbox',
];

// Native-Wayland backend, opted into by CLAUDE_HARNESS_USE_WAYLAND=1.
// Mirrors launcher-common.sh's Wayland branch (lines 132-135). Tests
// that need to drive the app under native Wayland (#226 follow-ups,
// future S07 sweep) flip the harness-level switch and every runner
// inherits this without per-spec changes.
const LAUNCHER_INJECTED_FLAGS_WAYLAND = [
	'--disable-features=CustomTitlebar',
	'--enable-features=UseOzonePlatform,WaylandWindowDecorations',
	'--ozone-platform=wayland',
	'--enable-wayland-ime',
	'--wayland-text-input-version=3',
	'--no-sandbox',
];

const LAUNCHER_INJECTED_ENV: Record<string, string> = {
	ELECTRON_FORCE_IS_PACKAGED: 'true',
	ELECTRON_USE_SYSTEM_TITLE_BAR: '1',
};

// Top-level opt-in: when CLAUDE_HARNESS_USE_WAYLAND=1, every
// launchClaude() call swaps the X11 flag set for the Wayland one and
// also exports CLAUDE_USE_WAYLAND=1 into the spawn env (so any in-app
// path that reads the launcher var stays consistent). Caller-supplied
// extraEnv still wins — a single test can override per-launch.
function harnessUseWayland(): boolean {
	return process.env.CLAUDE_HARNESS_USE_WAYLAND === '1';
}

const DEFAULT_INSTALL_PATHS = [
	{
		electron: '/usr/lib/claude-desktop/node_modules/electron/dist/electron',
		asar: '/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar',
	},
	{
		electron: '/opt/Claude/node_modules/electron/dist/electron',
		asar: '/opt/Claude/node_modules/electron/dist/resources/app.asar',
	},
];

interface AppPaths {
	electron: string;
	asar: string;
}

// Per-launch state needed by the SIGINT/SIGTERM cleanup. Tracks the
// child proc + isolation root so a Ctrl-C through Playwright doesn't
// leak Electron processes or the per-launch tmpdir. Stored separately
// from ClaudeApp so the signal handler doesn't reach into closure
// internals — `proc` and `root` are everything cleanup needs.
interface ActiveLaunch {
	proc: ChildProcess;
	// Isolation root to remove on signal. null when caller opted out
	// (`isolation: null`) or supplied a shared handle (`ownsIsolation`
	// false — that handle's lifetime is the test's, not ours).
	root: string | null;
}

const activeLaunches = new Set<ActiveLaunch>();
let signalHandlersInstalled = false;

// Install once across every launch in the test process. Handler is
// synchronous: SIGKILL each spawned proc, rmSync each owned isolation
// root, then re-emit the signal so Playwright's own teardown still
// runs (and the process actually exits — without re-emit, Node would
// notice the handler swallowed the signal and stay alive).
//
// Only owns processes/dirs from this module, not anything Playwright
// itself spawned, so the cleanup is safe to run in parallel with
// Playwright's teardown.
function ensureSignalHandlers(): void {
	if (signalHandlersInstalled) return;
	signalHandlersInstalled = true;
	const cleanup = (signal: NodeJS.Signals) => {
		for (const launch of activeLaunches) {
			try {
				launch.proc.kill('SIGKILL');
			} catch {
				// proc may already be dead
			}
			if (launch.root) {
				try {
					rmSync(launch.root, { recursive: true, force: true });
				} catch {
					// best-effort — tmpdir cleanup is not load-bearing
				}
			}
		}
		activeLaunches.clear();
		// Re-emit so default disposition runs. Removing our handler
		// first prevents an infinite loop.
		process.removeListener('SIGINT', sigintHandler);
		process.removeListener('SIGTERM', sigtermHandler);
		process.kill(process.pid, signal);
	};
	const sigintHandler = () => cleanup('SIGINT');
	const sigtermHandler = () => cleanup('SIGTERM');
	process.on('SIGINT', sigintHandler);
	process.on('SIGTERM', sigtermHandler);
}

function resolveInstall(): AppPaths {
	const envBin = process.env.CLAUDE_DESKTOP_ELECTRON;
	const envAsar = process.env.CLAUDE_DESKTOP_APP_ASAR;
	if (envBin && envAsar) return { electron: envBin, asar: envAsar };
	for (const candidate of DEFAULT_INSTALL_PATHS) {
		if (existsSync(candidate.electron) && existsSync(candidate.asar)) {
			return candidate;
		}
	}
	throw new Error(
		'Could not locate claude-desktop install. Set CLAUDE_DESKTOP_ELECTRON ' +
			'and CLAUDE_DESKTOP_APP_ASAR, or install the deb/rpm package.',
	);
}

// Mirrors the pre-launch cleanup in launcher-common.sh (cleanup_orphaned_
// cowork_daemon + cleanup_stale_lock + cleanup_stale_cowork_socket).
//
// When `configDir` is provided (isolated test mode), the SingletonLock
// path is relative to that dir rather than ~/.config/Claude — the host
// config is left untouched.
export async function cleanupPreLaunch(configDir?: string): Promise<void> {
	try {
		await exec('pkill', ['-f', 'cowork-vm-service\\.js']);
	} catch {
		// pkill returns non-zero when no matches; that's fine.
	}

	const lockPath = configDir
		? join(configDir, 'SingletonLock')
		: join(homedir(), '.config/Claude/SingletonLock');
	try {
		const target = readlinkSync(lockPath);
		const pidMatch = target.match(/-(\d+)$/);
		if (pidMatch && !existsSync(`/proc/${pidMatch[1]}`)) {
			rmSync(lockPath, { force: true });
		}
	} catch {
		// Lock doesn't exist or isn't a symlink — both fine.
	}

	const sockPath = join(
		process.env.XDG_RUNTIME_DIR ?? '/tmp',
		'cowork-vm-service.sock',
	);
	if (existsSync(sockPath)) {
		try {
			rmSync(sockPath, { force: true });
		} catch {
			// Stale socket may already be gone.
		}
	}
}

export async function launchClaude(opts: LaunchOptions = {}): Promise<ClaudeApp> {
	// Isolation default: create a fresh per-launch sandbox unless the
	// caller passed `null` (legacy ~/.config/Claude) or supplied a
	// pre-existing handle (shared across multiple launches in one test).
	let isolation: Isolation | null;
	let ownsIsolation = false;
	if (opts.isolation === null) {
		isolation = null;
	} else if (opts.isolation) {
		isolation = opts.isolation;
	} else {
		isolation = await createIsolation();
		ownsIsolation = true;
	}

	await cleanupPreLaunch(isolation?.configDir);
	const { electron: electronBin, asar } = resolveInstall();
	const appDir = dirname(dirname(dirname(dirname(electronBin))));

	const useWayland = harnessUseWayland();
	const launcherFlags = useWayland
		? LAUNCHER_INJECTED_FLAGS_WAYLAND
		: LAUNCHER_INJECTED_FLAGS_X11;
	// CLAUDE_USE_WAYLAND only when the harness-level gate is on.
	// Spread BEFORE opts.extraEnv so a single test can override.
	const waylandEnv: Record<string, string> = useWayland
		? { CLAUDE_USE_WAYLAND: '1', GDK_BACKEND: 'wayland' }
		: {};

	const proc = spawn(
		electronBin,
		[...launcherFlags, asar, ...(opts.args ?? [])],
		{
			cwd: appDir,
			env: {
				...process.env,
				...LAUNCHER_INJECTED_ENV,
				...(isolation?.env ?? {}),
				...waylandEnv,
				...opts.extraEnv,
				CI: '1',
			} as Record<string, string>,
			stdio: 'ignore',
			detached: false,
		},
	);

	if (!proc.pid) {
		if (ownsIsolation && isolation) await isolation.cleanup();
		throw new Error('Failed to spawn Electron — no pid');
	}

	// Register signal handlers + add this launch to the active set so a
	// Ctrl-C through Playwright SIGKILLs the Electron child and (if we
	// own the tmpdir) rmSync's the isolation root. Owned-isolation
	// signal cleanup uses dirname(configHome) — Isolation doesn't
	// expose `root`, but createIsolation builds configHome as
	// `<root>/config`, so the parent dir is the tmpdir to remove.
	ensureSignalHandlers();
	const isolationRoot =
		ownsIsolation && isolation ? dirname(isolation.configHome) : null;
	const launchEntry: ActiveLaunch = { proc, root: isolationRoot };
	activeLaunches.add(launchEntry);

	// Single-slot inspector tracking. Only one inspector ever attaches
	// per launch (SIGUSR1 opens port 9229; reusing the port across
	// re-attaches isn't supported). Stored so close() can release the
	// WebSocket even if the runner forgets — previously every runner
	// did `inspector.close(); finally app.close();` and the WS leaked
	// when an `expect()` between those threw.
	let trackedInspector: InspectorClient | null = null;

	const waitForX11Window = async (timeoutMs = 15_000): Promise<string> => {
		const wid = await retryUntil(
			async () => findX11WindowByPid(proc.pid!),
			{ timeout: timeoutMs, interval: 250 },
		);
		if (!wid) {
			throw new Error(
				`X11 window for pid ${proc.pid} did not appear within ${timeoutMs}ms`,
			);
		}
		return wid;
	};

	const attachInspector = async (timeoutMs = 15_000): Promise<InspectorClient> => {
		// Send SIGUSR1 to open the Node inspector at runtime — same code
		// path as Developer → Enable Main Process Debugger menu item.
		// Then poll http://127.0.0.1:9229/json/list until it answers.
		process.kill(proc.pid!, 'SIGUSR1');
		const start = Date.now();
		let lastErr: unknown = null;
		while (Date.now() - start < timeoutMs) {
			try {
				const client = await InspectorClient.connect(9229);
				trackedInspector = client;
				return client;
			} catch (err) {
				lastErr = err;
				await sleep(250);
			}
		}
		throw new Error(
			`Inspector did not become ready on port 9229 within ${timeoutMs}ms: ${
				lastErr instanceof Error ? lastErr.message : String(lastErr)
			}`,
		);
	};

	const waitForReady = async (
		level: ReadyLevel,
		opts: WaitForReadyOptions = {},
	): Promise<WindowReady | MainVisibleReady | ClaudeAiReady | UserLoadedReady> => {
		const overall = opts.timeout ?? 90_000;
		const start = Date.now();
		// Each step uses the remaining overall budget rather than
		// a fixed per-step timeout. If startup is slow, downstream
		// steps still get whatever's left; if startup is fast, the
		// later steps inherit the unused margin.
		const remaining = () => Math.max(0, overall - (Date.now() - start));

		const wid = await waitForX11Window(remaining());
		if (level === 'window') return { wid };

		const inspector = await attachInspector(remaining());

		// 'mainVisible' — the main shell BrowserWindow has been
		// shown. MainWindow.getState() resolves the window via
		// claude.ai webContents, so this poll implicitly also
		// requires that webContents to exist; the explicit
		// 'claudeAi' step below is for the URL-list signal that
		// some tests want even when window visibility is incidental.
		const mainWin = new MainWindow(inspector);
		const visibleState = await retryUntil(
			async () => {
				const s = await mainWin.getState();
				return s && s.visible ? s : null;
			},
			{ timeout: remaining(), interval: 250 },
		);
		if (!visibleState) {
			throw new Error(
				`waitForReady('${level}'): main window did not become ` +
					`visible within ${overall}ms`,
			);
		}
		if (level === 'mainVisible') return { wid, inspector };

		// 'claudeAi' — a claude.ai-domain webContents exists in
		// the registry. May still be on /login. Soft-fails on
		// timeout: returns without claudeAiUrl so the caller
		// can skip (host likely not signed in).
		const claudeAiUrl = await retryUntil(
			async () => {
				const all = await inspector.evalInMain<{ url: string }[]>(`
					const { webContents } = process.mainModule.require('electron');
					return webContents.getAllWebContents().map(w => ({ url: w.getURL() }));
				`);
				return all.find((w) => w.url.includes('claude.ai'))?.url ?? null;
			},
			{ timeout: remaining(), interval: 500 },
		);
		if (!claudeAiUrl) {
			return { wid, inspector };
		}
		if (level === 'claudeAi') return { wid, inspector, claudeAiUrl };

		// 'userLoaded' — URL past /login. Necessary precondition
		// for upstream's lHn() (`!user.isLoggedOut`) returning
		// true, which gates Ko.show() in the shortcut handler.
		// NOT sufficient on its own — main-process user state
		// loads on a separate timeline from the renderer URL,
		// so QE submit paths still need openAndWaitReady's
		// retry loop on top of this.
		const postLoginUrl =
			(await waitForUserLoaded(inspector, remaining())) ?? undefined;
		return { wid, inspector, claudeAiUrl, postLoginUrl };
	};

	const app: ClaudeApp = {
		process: proc,
		pid: proc.pid,
		isolation,
		lastExitInfo: null,
		async close() {
			// Drop the inspector first — InspectorClient.close() is now
			// idempotent (see lib/inspector.ts) so the runner-side
			// `inspector.close()` calls keep working even when this
			// fires too. Wrapped in try/catch because a thrown ws.close
			// shouldn't block the proc/iso cleanup below.
			if (trackedInspector) {
				try {
					trackedInspector.close();
				} catch {
					// already closed
				}
				trackedInspector = null;
			}

			if (proc.exitCode === null && proc.signalCode === null) {
				proc.kill('SIGTERM');
				await Promise.race([
					new Promise<void>((resolve) => proc.once('exit', () => resolve())),
					sleep(5000),
				]);
				if (proc.exitCode === null && proc.signalCode === null) {
					proc.kill('SIGKILL');
				}
			}

			// Capture exit info BEFORE iso cleanup. Runners can attach
			// app.lastExitInfo to testInfo when non-null + signal === null
			// (we didn't kill it, so a non-zero code means a real crash).
			app.lastExitInfo = {
				code: proc.exitCode,
				signal: proc.signalCode,
			};

			activeLaunches.delete(launchEntry);
			if (ownsIsolation && isolation) {
				await isolation.cleanup();
			}
		},
		waitForX11Window,
		attachInspector,
		// TS can't verify a closure with a union return matches the
		// generic conditional signature, even though the runtime
		// branches do produce the right shape per level. The cast
		// preserves the public contract.
		waitForReady: waitForReady as ClaudeApp['waitForReady'],
	};
	return app;
}
