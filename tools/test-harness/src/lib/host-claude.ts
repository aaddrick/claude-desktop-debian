// Detect-and-kill any running Claude Desktop process owned by the
// current user. Used before seeding a hermetic isolation from the
// host config, because Cookies (SQLite) and Local Storage / IndexedDB
// (LevelDB) all hold writer locks while the host app is running — a
// naive cp would either copy a torn page or fail outright on the
// LevelDB LOCK file.
//
// SIGTERM first, wait up to 5s for graceful exit, SIGKILL survivors.
// Loud stderr output: the user needs to know we're force-quitting
// their app so they can blame us, not Claude Desktop, when their
// unsaved chat draft disappears.

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { sleep } from './retry.js';

const exec = promisify(execFile);

// Patterns that match host installs (deb, rpm, AppImage, dev tree).
// argv-based via `pgrep -f`: matches the installed binary path or
// the mounted AppImage path. The harness's own launches always set
// XDG_CONFIG_HOME to a tmpdir, so they wouldn't be confused with
// the host even if the patterns overlapped — but kill runs BEFORE
// our launch, so at this moment there's nothing of ours to confuse.
const HOST_PROCESS_PATTERNS = [
	'/usr/lib/claude-desktop/',
	'/opt/Claude/',
	'\\.mount_[Cc]laude',
	'/usr/bin/claude-desktop',
];

// Per-pid graceful-exit budget. Electron flushes LevelDB + checkpoints
// the SQLite WAL on SIGTERM; 5s covers a typical shutdown with margin.
const SIGTERM_GRACE_MS = 5_000;
const POLL_INTERVAL_MS = 200;

interface HostProcess {
	pid: number;
	argv: string;
}

async function findHostProcesses(): Promise<HostProcess[]> {
	const pattern = HOST_PROCESS_PATTERNS.join('|');
	try {
		const { stdout } = await exec('pgrep', ['-af', pattern]);
		return stdout
			.split('\n')
			.filter(Boolean)
			.map((line) => {
				const space = line.indexOf(' ');
				const pid = Number(space === -1 ? line : line.slice(0, space));
				const argv = space === -1 ? '' : line.slice(space + 1);
				return { pid, argv };
			})
			.filter((p) => Number.isFinite(p.pid) && p.pid !== process.pid);
	} catch {
		// pgrep returns 1 when nothing matches — happy path.
		return [];
	}
}

function isAlive(pid: number): boolean {
	try {
		// Signal 0: existence check, no signal delivered.
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

export async function killHostClaude(): Promise<void> {
	const procs = await findHostProcesses();
	if (procs.length === 0) return;

	process.stderr.write(
		`host-claude: ${procs.length} running Claude process(es) found; ` +
			'sending SIGTERM (auth-state seed needs writer-lock release):\n',
	);
	for (const { pid, argv } of procs) {
		process.stderr.write(`  pid=${pid} ${argv.slice(0, 120)}\n`);
		try {
			process.kill(pid, 'SIGTERM');
		} catch {
			// Race: already exited between pgrep and now.
		}
	}

	const deadline = Date.now() + SIGTERM_GRACE_MS;
	while (Date.now() < deadline) {
		if (!procs.some((p) => isAlive(p.pid))) return;
		await sleep(POLL_INTERVAL_MS);
	}

	const survivors = procs.filter((p) => isAlive(p.pid));
	if (survivors.length === 0) return;

	process.stderr.write(
		`host-claude: ${survivors.length} survived SIGTERM; sending SIGKILL:\n`,
	);
	for (const { pid } of survivors) {
		process.stderr.write(`  pid=${pid}\n`);
		try {
			process.kill(pid, 'SIGKILL');
		} catch {
			// Race: already exited.
		}
	}
	// Final beat so /proc entries clear before the seed copy starts.
	await sleep(POLL_INTERVAL_MS);
}
