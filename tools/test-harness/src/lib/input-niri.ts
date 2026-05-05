// Focus-shifter primitive for "Quick Entry shortcut fires from any
// focus" (S14) on Niri sessions — the Wayland-native sibling of
// lib/input.ts. The runner needs to (a) spawn a sacrificial window
// with a known title, (b) shove keyboard focus to it, then (c) press
// the global shortcut and observe whether the QE popup appears
// regardless of focus.
//
// Niri only — by design.
//   - There is no portable focus-injection on native Wayland. Each
//     compositor exposes a different IPC: niri msg here, swaymsg for
//     Sway, hyprctl for Hyprland, riverctl for River. The libei-based
//     "input emulation" portal is the long-term cross-compositor
//     answer but isn't widely deployed (KDE/GNOME are getting it,
//     niri/sway/hypr are not yet). We pay one file per compositor
//     until a second consumer surfaces the dispatcher need; a
//     hypothetical lib/input-wayland.ts would just switch on
//     XDG_CURRENT_DESKTOP and delegate. With only S14 consuming this,
//     a dispatcher would be ceremony.
//   - lib/input.ts (X11) and this file are independent: they don't
//     share a focus-id type — niri window IDs are u64 numerics, X11
//     WIDs are hex strings. Callers handle one or the other based on
//     session detection; nothing crosses the boundary.
//
// Why niri msg --json over plain text: the niri wiki explicitly
// contracts the JSON output as stable while the plain-text form is
// described as unstable / human-readable-only. A test harness that
// regex-greps human-readable IPC output is one niri release away
// from a quiet break.
//
// Why we verify post-focus via niri msg focused-window: niri msg
// action focus-window exits 0 even when the focus didn't actually
// land (the action queues into the compositor and a competing input
// event or a closing window can race it). The only honest answer is
// to read focused-window back out and compare IDs. This mirrors
// lib/input.ts's xprop-readback paragraph but for niri's IPC. ~3s
// budget covers slow compositor paths; anything beyond is a refusal
// not a slow ack — surface as an error so S14 sees it.
//
// Why foot for the marker terminal: it's the niri-default in many
// distros (Fedora niri spin, several Arch derivatives), accepts
// --title <T> verbatim with no de-escaping surprises, and ships in
// most niri setups so a single binary covers the common case. We
// deliberately don't fall back to alacritty / kitty — the X11
// primitive uses xterm-only and the simplicity is worth more than
// the marginal robustness; an environment without foot can install
// it the same way an X11 environment without xterm installs xterm.
//
// Why detached:false on the marker spawn: keep the foot child in the
// parent's process group so the OS cleans it up if the test crashes.
// (Session 5 recon sketched detached:true; lib/input.ts uses
// detached:false and is the safer pattern — a leaked terminal past a
// crashed test run is worse than a marker that dies cleanly with its
// parent.)
//
// No fixed sleeps. The verification poll uses retryUntil so a fast
// compositor finishes in ~50ms while a slow one gets the full budget.

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { retryUntil } from './retry.js';

const exec = promisify(execFile);

// Caller catches this and calls test.skip() — it's an environment
// gap (not a Niri session, or niri msg not on PATH), not a
// regression. Subclassing Error gives consumers a clean
// `instanceof` check without parsing message strings.
export class NiriIpcUnavailable extends Error {
	constructor(message?: string) {
		super(
			message ??
				'niri msg IPC unavailable: either this is not a Niri ' +
					'session (XDG_CURRENT_DESKTOP !== "niri") or the ' +
					'`niri` binary is missing from PATH. Install the ' +
					'`niri-ipc` / `niri` package, or skip on this row.',
		);
		this.name = 'NiriIpcUnavailable';
	}
}

// Mirrors lib/input.ts's XdotoolUnavailable — the install command is
// the actually-useful part of the error. Consumers should usually
// skip rather than fail; the absence of foot is an environment
// configuration issue, not a Claude Desktop regression.
export class FootUnavailable extends Error {
	constructor(message?: string) {
		super(
			message ??
				'foot binary not found on PATH. Install with ' +
					'`dnf install foot` / `apt install foot`.',
		);
		this.name = 'FootUnavailable';
	}
}

// Single source of truth for the Niri / not-Niri branch. Pure env
// check, no process spawn — matches the simplicity of isX11Session()
// in lib/input.ts. A `niri msg version` probe would be more
// authoritative (catches the case where someone manually overrides
// XDG_CURRENT_DESKTOP) but adds a fork-per-call cost that's
// disproportionate to how rare the override is in practice.
//
// The literal string 'niri' is the value niri itself sets in
// XDG_CURRENT_DESKTOP per its own documentation; we trust that and
// nothing else (no case-folding, no startswith).
export function isNiriSession(): boolean {
	return process.env.XDG_CURRENT_DESKTOP === 'niri';
}

// Niri's --json output for several IPC calls is wrapped in a
// Result-style envelope: `{"Ok": <payload>}`. Newer/older niri
// versions sometimes return the bare payload. Defensively unwrap one
// layer of `.Ok` if present, then return the payload as-is. Returns
// null if the input is null/undefined.
function unwrapOk(value: unknown): unknown {
	if (value === null || value === undefined) return null;
	if (typeof value === 'object' && value !== null && 'Ok' in value) {
		return (value as { Ok: unknown }).Ok;
	}
	return value;
}

// Shape of a niri window row, restricted to the fields we use. The
// real schema has more (workspace_id, is_floating, etc.) — we don't
// commit to those.
interface NiriWindow {
	id: number;
	title: string | null;
	app_id: string | null;
	is_focused?: boolean;
}

// Read the currently-focused niri window via `niri msg --json
// focused-window`.
//
// Returns null on:
//   - Non-Niri session (gated out by isNiriSession()).
//   - niri binary missing / spawn ENOENT — analogous to lib/input.ts
//     returning null on xprop spawn failure rather than throwing.
//     focusOtherWindow's poll fails through to its own timeout.
//   - JSON parse failure or unexpected shape (defensive — should
//     not happen against a healthy niri but the cost of a null
//     return is one re-poll).
//   - No focused window (e.g. all workspaces empty).
export async function getFocusedWindowId(): Promise<number | null> {
	if (!isNiriSession()) return null;
	let stdout: string;
	try {
		({ stdout } = await exec('niri', [
			'msg',
			'--json',
			'focused-window',
		]));
	} catch {
		return null;
	}
	const trimmed = stdout.trim();
	if (!trimmed) return null;
	let parsed: unknown;
	try {
		parsed = JSON.parse(trimmed);
	} catch {
		return null;
	}
	// Two known wrappings: `{Ok: {FocusedWindow: <window>}}` (older)
	// and the bare window object (newer). Try unwrapping in order.
	const okUnwrapped = unwrapOk(parsed);
	let candidate: unknown = okUnwrapped;
	if (
		typeof okUnwrapped === 'object' &&
		okUnwrapped !== null &&
		'FocusedWindow' in okUnwrapped
	) {
		candidate = (okUnwrapped as { FocusedWindow: unknown }).FocusedWindow;
	}
	if (
		typeof candidate !== 'object' ||
		candidate === null ||
		!('id' in candidate)
	) {
		return null;
	}
	const id = (candidate as { id: unknown }).id;
	if (typeof id !== 'number' || !Number.isFinite(id)) return null;
	return id;
}

// Resolve a window title to its niri ID via `niri msg --json
// windows`. The list is `Vec<Window>`; we filter on title match AND
// app_id !== 'Claude' so we never accidentally pick the test target
// itself. Returns null on zero matches; returns the first match's
// ID on multi-match (mirrors xdotool's first-match behavior in
// lib/input.ts).
async function resolveWindowIdByTitle(
	title: string,
): Promise<number | null> {
	const { stdout } = await exec('niri', ['msg', '--json', 'windows']);
	const trimmed = stdout.trim();
	if (!trimmed) return null;
	let parsed: unknown;
	try {
		parsed = JSON.parse(trimmed);
	} catch {
		return null;
	}
	// Same Ok-wrapping defense as getFocusedWindowId.
	const unwrapped = unwrapOk(parsed);
	if (!Array.isArray(unwrapped)) return null;
	for (const row of unwrapped as NiriWindow[]) {
		if (
			row &&
			typeof row === 'object' &&
			typeof row.id === 'number' &&
			row.title === title &&
			row.app_id !== 'Claude'
		) {
			return row.id;
		}
	}
	return null;
}

// Shift Niri focus to the first window whose title matches `title`
// and whose app_id is not 'Claude' (so we never target Claude's own
// window), then verify the shift actually took.
//
// Throws:
//   - NiriIpcUnavailable when not a Niri session, or niri binary
//     missing.
//   - Plain Error when no window matches (caller's bug — forgot to
//     spawn the marker, or used the wrong title).
//   - Plain Error when niri msg returns 0 but focused-window never
//     reflects the focus change within ~3s (compositor refused the
//     activation; this is the diagnostic path S14 wants surfaced,
//     not swallowed).
export async function focusOtherWindow(title: string): Promise<void> {
	if (!isNiriSession()) {
		throw new NiriIpcUnavailable();
	}

	let targetId: number | null;
	try {
		targetId = await resolveWindowIdByTitle(title);
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') throw new NiriIpcUnavailable();
		throw err;
	}
	if (targetId === null) {
		throw new Error(
			`focusOtherWindow: no Niri window matches title ${JSON.stringify(title)} ` +
				'(with app_id != "Claude"). Did the marker window finish ' +
				'mapping? Caller should await spawnMarkerWindow + a short ' +
				'readiness poll before calling focusOtherWindow.',
		);
	}

	try {
		await exec('niri', [
			'msg',
			'action',
			'focus-window',
			'--id',
			String(targetId),
		]);
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') throw new NiriIpcUnavailable();
		throw err;
	}

	const matched = await retryUntil(
		async () => {
			const active = await getFocusedWindowId();
			return active === targetId ? true : null;
		},
		{ timeout: 3_000, interval: 100 },
	);
	if (!matched) {
		throw new Error(
			'focusOtherWindow: niri msg action focus-window returned 0 ' +
				`but focused-window never settled to id=${targetId} ` +
				`for title ${JSON.stringify(title)}. Compositor may have ` +
				'refused the activation request.',
		);
	}
}

// Handle returned from spawnMarkerWindow. Lifecycle is owned by the
// caller — the test that spawned it must kill() in afterEach (or
// equivalent), otherwise the foot terminal leaks past the test run.
export interface MarkerWindow {
	pid: number;
	title: string;
	kill(): Promise<void>;
}

// Spawn a long-lived foot terminal with a known title, suitable as
// a focus target on a Niri session. Backgrounded with detached:false
// so the parent test process owns its lifetime — if the test
// crashes, the OS cleans up the child when the parent dies.
//
// Throws FootUnavailable if foot isn't on PATH (both at spawn-throw
// time AND via the 'error' event, mirroring lib/input.ts's redundant
// ENOENT handling — Node delivers ENOENT through different paths
// across versions).
export async function spawnMarkerWindow(
	title: string,
): Promise<MarkerWindow> {
	const { spawn } = await import('node:child_process');

	let child;
	try {
		// `sleep 600` keeps the foot terminal alive for 10min — longer
		// than any reasonable single test, short enough that a leaked
		// terminal self-cleans within the sweep. foot's --title sets
		// the window title field that niri's windows list reports.
		child = spawn('foot', ['--title', title, '-e', 'sleep', '600'], {
			detached: false,
			stdio: 'ignore',
		});
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') {
			throw new FootUnavailable();
		}
		throw err;
	}

	const earlyError = await new Promise<Error | null>((resolve) => {
		const onError = (err: Error) => {
			child.removeListener('spawn', onSpawn);
			resolve(err);
		};
		const onSpawn = () => {
			child.removeListener('error', onError);
			resolve(null);
		};
		child.once('error', onError);
		child.once('spawn', onSpawn);
	});
	if (earlyError) {
		const e = earlyError as Error & { code?: string | number };
		if (e.code === 'ENOENT') {
			throw new FootUnavailable();
		}
		throw earlyError;
	}

	const pid = child.pid;
	if (typeof pid !== 'number') {
		throw new Error(
			'spawnMarkerWindow: child.pid was undefined after spawn',
		);
	}

	let killed = false;
	const kill = async (): Promise<void> => {
		if (killed) return;
		killed = true;
		if (child.exitCode !== null || child.signalCode !== null) {
			return;
		}
		// SIGTERM with a short grace period before SIGKILL. foot
		// honors SIGTERM cleanly; the SIGKILL fallback is for the
		// pathological "child wedged in a syscall" case.
		const exited = new Promise<void>((resolve) => {
			child.once('exit', () => resolve());
		});
		try {
			child.kill('SIGTERM');
		} catch {
			// Process may have died between the check and the kill.
		}
		const graceMs = 500;
		const timedOut = await Promise.race([
			exited.then(() => false),
			new Promise<boolean>((resolve) =>
				setTimeout(() => resolve(true), graceMs),
			),
		]);
		if (timedOut) {
			try {
				child.kill('SIGKILL');
			} catch {
				// Already dead.
			}
			await exited;
		}
	};

	return { pid, title, kill };
}
