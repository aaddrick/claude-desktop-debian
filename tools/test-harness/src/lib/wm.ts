import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const exec = promisify(execFile);

export interface FrameExtents {
	left: number;
	right: number;
	top: number;
	bottom: number;
}

export async function findX11WindowByPid(pid: number): Promise<string | null> {
	try {
		const { stdout } = await exec('xdotool', ['search', '--pid', String(pid)]);
		const ids = stdout.trim().split('\n').filter(Boolean);
		// xdotool returns multiple windows for an Electron app (renderer, etc).
		// Prefer the one that has _NET_WM_NAME set (the visible top-level).
		for (const id of ids) {
			const title = await getWindowProperty(id, '_NET_WM_NAME');
			if (title) return id;
		}
		return ids[0] ?? null;
	} catch {
		return null;
	}
}

export async function getFrameExtents(windowId: string): Promise<FrameExtents | null> {
	const raw = await getWindowProperty(windowId, '_NET_FRAME_EXTENTS');
	if (!raw) return null;
	const nums = raw.split(',').map((s) => parseInt(s.trim(), 10));
	if (nums.length !== 4 || nums.some(Number.isNaN)) return null;
	return { left: nums[0]!, right: nums[1]!, top: nums[2]!, bottom: nums[3]! };
}

export async function getWindowTitle(windowId: string): Promise<string | null> {
	const raw = await getWindowProperty(windowId, '_NET_WM_NAME');
	if (!raw) return null;
	const m = raw.match(/^"(.*)"$/s);
	return m ? m[1]! : raw;
}

async function getWindowProperty(windowId: string, prop: string): Promise<string | null> {
	try {
		const { stdout } = await exec('xprop', ['-id', windowId, prop]);
		const m = stdout.match(/=\s*(.+)$/m);
		return m ? m[1]!.trim() : null;
	} catch {
		return null;
	}
}
