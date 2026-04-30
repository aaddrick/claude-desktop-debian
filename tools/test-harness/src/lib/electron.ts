import { _electron as electron, type ElectronApplication } from 'playwright';
import { existsSync, readlinkSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const exec = promisify(execFile);

export interface LaunchOptions {
	extraEnv?: Record<string, string>;
	args?: string[];
	timeout?: number;
}

// The shipped launcher script (/usr/bin/claude-desktop) redirects Electron's
// stdout/stderr to ~/.cache/claude-desktop-debian/launcher.log, which means
// Playwright can't read the CDP-port advertisement Electron prints on stderr.
// Tests therefore drive the Electron binary + app.asar directly. The launcher
// is still the right surface for end-user diagnostics (--doctor) and for L2
// tests that exercise launcher behavior, but L1 tests bypass it.
//
// Override resolution by setting:
//   CLAUDE_DESKTOP_ELECTRON  — path to the electron binary
//   CLAUDE_DESKTOP_APP_ASAR  — path to app.asar
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

// Flags the production launcher injects (see /usr/bin/claude-desktop +
// launcher-common.sh build_electron_args). Forcing X11/XWayland is Decision 6;
// disabling CustomTitlebar avoids Chromium's experimental WCO conflicting with
// the hybrid topbar shim. Tests that want to characterize native-Wayland
// behavior should override `args` explicitly.
const LAUNCHER_INJECTED_FLAGS = [
	'--disable-features=CustomTitlebar',
	'--ozone-platform=x11',
];

// Env vars setup_electron_env() exports. ELECTRON_FORCE_IS_PACKAGED makes
// app.isPackaged return true so resource resolution goes through
// process.resourcesPath (correct for our deb/rpm/Nix layouts).
// ELECTRON_USE_SYSTEM_TITLE_BAR=1 matches hybrid/native titlebar modes.
const LAUNCHER_INJECTED_ENV: Record<string, string> = {
	ELECTRON_FORCE_IS_PACKAGED: 'true',
	ELECTRON_USE_SYSTEM_TITLE_BAR: '1',
};

// Mirrors the pre-launch cleanup in launcher-common.sh (cleanup_orphaned_
// cowork_daemon + cleanup_stale_lock + cleanup_stale_cowork_socket). Tests
// bypass the launcher script — we reproduce its cleanup so a previous run's
// orphans don't poison the next one.
export async function cleanupPreLaunch(): Promise<void> {
	// Kill any orphaned cowork-vm-service daemons.
	try {
		await exec('pkill', ['-f', 'cowork-vm-service\\.js']);
	} catch {
		// pkill returns non-zero when no matches; that's fine.
	}

	// Stale SingletonLock from a previous crashed run.
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

	// Stale cowork socket.
	const sockPath = join(
		process.env.XDG_RUNTIME_DIR ?? '/tmp',
		'cowork-vm-service.sock',
	);
	try {
		await exec('test', ['-S', sockPath]);
		rmSync(sockPath, { force: true });
	} catch {
		// Socket doesn't exist — fine.
	}
}

export async function launchClaude(opts: LaunchOptions = {}): Promise<ElectronApplication> {
	await cleanupPreLaunch();
	const { electron: electronBin, asar } = resolveInstall();
	// The shipped launcher cds into the app dir (typically the parent of
	// node_modules/electron) before exec'ing Electron. Mirror that so the
	// app's relative path resolution matches production.
	const appDir = dirname(dirname(dirname(dirname(electronBin))));
	return electron.launch({
		executablePath: electronBin,
		args: [...LAUNCHER_INJECTED_FLAGS, asar, ...(opts.args ?? [])],
		cwd: appDir,
		env: {
			...process.env,
			...LAUNCHER_INJECTED_ENV,
			...opts.extraEnv,
			CI: '1',
		} as Record<string, string>,
		timeout: opts.timeout ?? 30_000,
	});
}
