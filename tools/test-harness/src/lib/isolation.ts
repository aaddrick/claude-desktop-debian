// Per-test config isolation.
//
// Decision 1 in docs/testing/automation.md calls for hermetic
// XDG_CONFIG_HOME / CLAUDE_CONFIG_DIR per test (S19 is the underlying
// primitive). Without it, persisted state leaks between tests:
// SingletonLock from one run blocks the next; S35's saved
// quickWindowPosition contaminates S29's closed-to-tray sanity; etc.
//
// Shape: each call to `createIsolation()` builds a fresh config root
// under $TMPDIR/claude-test-<random>/ and returns the env vars to merge
// into the spawned app, plus a teardown that removes the dir. Pass the
// same handle to multiple `launchClaude({ isolation })` calls when a
// test needs to launch the same app twice with shared state (e.g. S35
// position-memory across restart).
//
// `seedFromHost: true` extends this for tests that need the host's
// signed-in auth state (U01). The host directory itself stays
// untouched after the kill+copy: the test runs hermetically against
// a copy of just the auth-relevant files, and the tmpdir is rm -rf'd
// on cleanup so secrets never persist past the test process.

import { cp, mkdir, mkdtemp, rm, stat } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

import { killHostClaude } from './host-claude.js';

export interface Isolation {
	configHome: string;
	configDir: string;
	cacheHome: string;
	dataHome: string;
	env: Record<string, string>;
	cleanup(): Promise<void>;
}

export interface CreateIsolationOptions {
	// When true: kill any running host Claude (LevelDB / SQLite hold
	// writer locks while it runs), then copy the auth-relevant subset
	// of $XDG_CONFIG_HOME/Claude into the new configDir. The host
	// config never gets mutated by the test; secrets never leave the
	// per-launch tmpdir.
	seedFromHost?: boolean;
}

// Allowlist of relative paths under ~/.config/Claude/ that carry auth
// or first-launch UI state. Everything else is deliberately
// regenerated fresh in the tmpdir:
//   - Cache/, Code Cache/, GPUCache/, Dawn*Cache/  — cheap to rebuild
//   - blob_storage/, Crashpad/, logs/             — irrelevant to auth
//   - SingletonLock, SingletonCookie, SingletonSocket — block startup
//   - .org.chromium.Chromium.*                    — host-specific lock turds
//   - claude-code-sessions/, claude-code-vm/, local-agent-mode-sessions/
//     — large, account-specific, not needed for renderer auth
//
// Cookies + Local State are the auth-cookie pair (the latter holds
// the os_crypt key wrapper on platforms that need it). IndexedDB +
// Local Storage hold the renderer-side auth context that claude.ai's
// route guards check before redirecting to /login — cookies alone
// leave you bouncing back to login.
const SEED_PATHS = [
	'Cookies',
	'Cookies-journal',
	'Local State',
	'Local Storage',
	'IndexedDB',
	'Session Storage',
	'WebStorage',
	'SharedStorage',
	'Network Persistent State',
	'config.json',
	'claude_desktop_config.json',
	'developer_settings.json',
];

async function exists(path: string): Promise<boolean> {
	try {
		await stat(path);
		return true;
	} catch {
		return false;
	}
}

async function seedAuthFromHost(targetConfigDir: string): Promise<void> {
	const hostConfigHome =
		process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config');
	const hostClaudeDir = join(hostConfigHome, 'Claude');

	if (!(await exists(hostClaudeDir))) {
		throw new Error(
			`seedFromHost: host config dir not found at ${hostClaudeDir}. ` +
				'Sign into Claude Desktop on this machine first, then re-run.',
		);
	}

	await mkdir(targetConfigDir, { recursive: true });

	let copied = 0;
	for (const rel of SEED_PATHS) {
		const src = join(hostClaudeDir, rel);
		if (!(await exists(src))) continue;
		const dst = join(targetConfigDir, rel);
		await cp(src, dst, {
			recursive: true,
			preserveTimestamps: true,
			errorOnExist: false,
		});
		copied++;
	}

	if (copied === 0) {
		throw new Error(
			`seedFromHost: ${hostClaudeDir} exists but contains none of the ` +
				'expected auth files. Open Claude Desktop, sign in, fully close, ' +
				'and re-run.',
		);
	}
}

export async function createIsolation(
	opts: CreateIsolationOptions = {},
): Promise<Isolation> {
	const root = await mkdtemp(join(tmpdir(), 'claude-test-'));
	const configHome = join(root, 'config');
	const configDir = join(configHome, 'Claude');
	const cacheHome = join(root, 'cache');
	const dataHome = join(root, 'data');

	if (opts.seedFromHost) {
		// Order matters: kill before copy. While the host app runs,
		// LevelDB holds a LOCK file in IndexedDB/Local Storage that
		// makes the directory unreadable to a second process, and
		// SQLite Cookies has WAL pages that may not be checkpointed.
		await killHostClaude();
		await seedAuthFromHost(configDir);
	}

	const env: Record<string, string> = {
		XDG_CONFIG_HOME: configHome,
		XDG_CACHE_HOME: cacheHome,
		XDG_DATA_HOME: dataHome,
		// CLAUDE_CONFIG_DIR is honored by launcher-common.sh and by
		// the app itself for picking the persisted-settings location.
		CLAUDE_CONFIG_DIR: configDir,
	};

	return {
		configHome,
		configDir,
		cacheHome,
		dataHome,
		env,
		async cleanup() {
			await rm(root, { recursive: true, force: true });
		},
	};
}
