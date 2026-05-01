import { spawn, execFile, type ChildProcess } from 'node:child_process';
import { existsSync, readlinkSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { sleep, retryUntil } from './retry.js';
import { findX11WindowByPid } from './wm.js';

const exec = promisify(execFile);

export interface LaunchOptions {
	extraEnv?: Record<string, string>;
	args?: string[];
}

export interface ClaudeApp {
	process: ChildProcess;
	pid: number;
	close(): Promise<void>;
	waitForX11Window(timeoutMs?: number): Promise<string>;
}

// IMPORTANT — this Electron build ships an authenticated-CDP gate (in
// `index.pre.js`):
//
//   uF(process.argv) && !qL() && process.exit(1);
//
// `uF` matches `--remote-debugging-port` / `--remote-debugging-pipe` in argv;
// `qL` validates a token in CLAUDE_CDP_AUTH against a hardcoded ed25519 public
// key (signed payload is `${timestamp_ms}.${base64(userDataDir)}`, 5-minute
// TTL). Without a valid signature the app exits with code 1 immediately after
// frame-fix-wrapper completes.
//
// Consequence: this harness cannot drive Electron via CDP at all today —
// Playwright's `_electron.launch()` and `chromium.connectOverCDP()` both
// inject `--remote-debugging-port=0` and trigger the gate. Renderer-level
// testing is blocked until we either (a) obtain a signing token from
// upstream, (b) carry an app-asar.sh patch that neutralizes the gate, or
// (c) drive the renderer via accessibility (dogtail / AT-SPI).
//
// What works today: spawn Electron without any debug-port flags and probe
// the running app externally (xprop for window state, dbus-next for tray
// and portal calls). T01 verifies "an X11 window appeared with our pid";
// T03/T04 are external probes already. T17 stays skipped pending the v2
// portal mock under dbus-run-session.

const LAUNCHER_INJECTED_FLAGS = [
	'--disable-features=CustomTitlebar',
	'--ozone-platform=x11',
	'--no-sandbox',
];

const LAUNCHER_INJECTED_ENV: Record<string, string> = {
	ELECTRON_FORCE_IS_PACKAGED: 'true',
	ELECTRON_USE_SYSTEM_TITLE_BAR: '1',
};

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
export async function cleanupPreLaunch(): Promise<void> {
	try {
		await exec('pkill', ['-f', 'cowork-vm-service\\.js']);
	} catch {
		// pkill returns non-zero when no matches; that's fine.
	}

	const lockPath = join(homedir(), '.config/Claude/SingletonLock');
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
	await cleanupPreLaunch();
	const { electron: electronBin, asar } = resolveInstall();
	const appDir = dirname(dirname(dirname(dirname(electronBin))));

	const proc = spawn(
		electronBin,
		[...LAUNCHER_INJECTED_FLAGS, asar, ...(opts.args ?? [])],
		{
			cwd: appDir,
			env: {
				...process.env,
				...LAUNCHER_INJECTED_ENV,
				...opts.extraEnv,
				CI: '1',
			} as Record<string, string>,
			stdio: 'ignore',
			detached: false,
		},
	);

	if (!proc.pid) {
		throw new Error('Failed to spawn Electron — no pid');
	}

	return {
		process: proc,
		pid: proc.pid,
		async close() {
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
		},
		async waitForX11Window(timeoutMs = 15_000) {
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
		},
	};
}
