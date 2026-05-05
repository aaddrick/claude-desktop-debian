import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const exec = promisify(execFile);

const LAUNCHER_LOG = join(
	homedir(),
	'.cache/claude-desktop-debian/launcher.log',
);

export async function readLauncherLog(): Promise<string | null> {
	try {
		return await readFile(LAUNCHER_LOG, 'utf8');
	} catch {
		return null;
	}
}

export interface DoctorResult {
	output: string;
	exitCode: number | null;
}

export async function runDoctor(launcher?: string): Promise<DoctorResult> {
	const bin = launcher ?? process.env.CLAUDE_DESKTOP_LAUNCHER ?? 'claude-desktop';
	try {
		const { stdout, stderr } = await exec(bin, ['--doctor'], { timeout: 15_000 });
		return {
			output: `${stdout}\n${stderr}`.trim(),
			exitCode: 0,
		};
	} catch (err) {
		// --doctor may exit non-zero if checks fail; still return the output
		// and the actual exit code so T02/T13/S05 can assert against it.
		const e = err as { stdout?: string; stderr?: string; code?: number };
		const combined = `${e.stdout ?? ''}\n${e.stderr ?? ''}`.trim();
		return {
			output: combined,
			exitCode: typeof e.code === 'number' ? e.code : null,
		};
	}
}

export function captureSessionEnv(): Record<string, string> {
	const keys = [
		'XDG_SESSION_TYPE',
		'XDG_CURRENT_DESKTOP',
		'WAYLAND_DISPLAY',
		'DISPLAY',
		'GDK_BACKEND',
		'QT_QPA_PLATFORM',
		'OZONE_PLATFORM',
		'ELECTRON_OZONE_PLATFORM_HINT',
		'CLAUDE_DESKTOP_LAUNCHER',
	];
	const out: Record<string, string> = {};
	for (const k of keys) {
		const v = process.env[k];
		if (v !== undefined) out[k] = v;
	}
	return out;
}
