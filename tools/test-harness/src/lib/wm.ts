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
	// Walk _NET_CLIENT_LIST and match on _NET_WM_PID. Pure xprop, no
	// xdotool dependency — Electron's main window will surface here once
	// the WM has accepted it.
	const ids = await listClientWindows();
	let firstMatch: string | null = null;
	for (const id of ids) {
		const wmPid = await getWindowPid(id);
		if (wmPid !== pid) continue;
		const title = await getWindowProperty(id, '_NET_WM_NAME');
		if (title) return id;
		if (!firstMatch) firstMatch = id;
	}
	return firstMatch;
}

async function listClientWindows(): Promise<string[]> {
	try {
		const { stdout } = await exec('xprop', ['-root', '_NET_CLIENT_LIST']);
		// _NET_CLIENT_LIST(WINDOW): window id # 0x1234, 0x5678, ...
		const m = stdout.match(/#\s*(.+)$/m);
		if (!m) return [];
		return m[1]!.split(',').map((s) => s.trim()).filter(Boolean);
	} catch {
		return [];
	}
}

async function getWindowPid(windowId: string): Promise<number | null> {
	const raw = await getWindowProperty(windowId, '_NET_WM_PID');
	if (!raw) return null;
	const n = parseInt(raw, 10);
	return Number.isNaN(n) ? null : n;
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
