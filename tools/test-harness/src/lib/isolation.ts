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

import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export interface Isolation {
	configHome: string;
	configDir: string;
	cacheHome: string;
	dataHome: string;
	env: Record<string, string>;
	cleanup(): Promise<void>;
}

export async function createIsolation(): Promise<Isolation> {
	const root = await mkdtemp(join(tmpdir(), 'claude-test-'));
	const configHome = join(root, 'config');
	const configDir = join(configHome, 'Claude');
	const cacheHome = join(root, 'cache');
	const dataHome = join(root, 'data');

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
