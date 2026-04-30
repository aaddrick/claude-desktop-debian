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

export async function runDoctor(launcher?: string): Promise<string | null> {
	const bin = launcher ?? process.env.CLAUDE_DESKTOP_LAUNCHER ?? 'claude-desktop';
	try {
		const { stdout, stderr } = await exec(bin, ['--doctor'], { timeout: 15_000 });
		return `${stdout}\n${stderr}`.trim();
	} catch (err) {
		// --doctor may exit non-zero if checks fail; still return the output
		const e = err as { stdout?: string; stderr?: string };
		const combined = `${e.stdout ?? ''}\n${e.stderr ?? ''}`.trim();
		return combined || null;
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
