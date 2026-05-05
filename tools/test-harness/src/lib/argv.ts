// Read a process's argv from /proc/<pid>/cmdline.
//
// /proc/<pid>/cmdline is a single string of NUL-separated args (no
// trailing NUL on most kernels; trim defensively). Used by QE-6 / S12
// to verify the launcher appended the right Electron flags, and by
// future flag-presence tests (Decision 6 Wayland-default Smoke, S07
// CLAUDE_USE_WAYLAND, etc.).
//
// readPidArgv returns null if the process is gone — callers usually
// want to retry until the pid stabilizes.

import { readFile } from 'node:fs/promises';

export async function readPidArgv(pid: number): Promise<string[] | null> {
	try {
		const raw = await readFile(`/proc/${pid}/cmdline`, 'utf8');
		// Strip trailing NUL if present, then split. Empty argv is
		// theoretically possible (kernel threads); preserve it.
		const trimmed = raw.endsWith('\0') ? raw.slice(0, -1) : raw;
		return trimmed.length === 0 ? [] : trimmed.split('\0');
	} catch {
		return null;
	}
}

export function argvHasFlag(argv: string[], flag: string): boolean {
	// Matches `--enable-features=GlobalShortcutsPortal` (full equality)
	// and `--enable-features` (bare flag, value in next argv slot).
	// Substring match handles `--enable-features=Foo,Bar` correctly when
	// flag is `--enable-features=Foo`.
	for (const arg of argv) {
		if (arg === flag) return true;
		if (arg.startsWith(`${flag}=`)) return true;
		// Comma-separated --enable-features value: match any subkey.
		if (flag.includes('=')) {
			const [key, val] = flag.split('=', 2);
			if (arg.startsWith(`${key}=`)) {
				const values = arg.slice(key!.length + 1).split(',');
				if (values.includes(val!)) return true;
			}
		}
	}
	return false;
}
