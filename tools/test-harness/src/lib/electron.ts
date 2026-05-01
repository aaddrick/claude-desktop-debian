import { spawn, execFile, type ChildProcess } from 'node:child_process';
import { existsSync, readlinkSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { sleep, retryUntil } from './retry.js';
import { findX11WindowByPid } from './wm.js';
import { InspectorClient } from './inspector.js';

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
	attachInspector(timeoutMs?: number): Promise<InspectorClient>;
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
		async attachInspector(timeoutMs = 15_000) {
			// Send SIGUSR1 to open the Node inspector at runtime — same code
			// path as Developer → Enable Main Process Debugger menu item.
			// Then poll http://127.0.0.1:9229/json/list until it answers.
			process.kill(proc.pid!, 'SIGUSR1');
			const start = Date.now();
			let lastErr: unknown = null;
			while (Date.now() - start < timeoutMs) {
				try {
					return await InspectorClient.connect(9229);
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
		},
	};
}
