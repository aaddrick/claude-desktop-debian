// Focus-shifter primitive for "Quick Entry shortcut fires from any focus"
// (S11, S14). The runner needs to (a) spawn a sacrificial window with
// a known title, (b) shove keyboard focus to it, then (c) press the
// global shortcut and observe whether the QE popup appears regardless
// of focus.
//
// X11 only — by design.
//   - There is no portable focus-injection on native Wayland. Each
//     compositor exposes its own IPC (swaymsg, kitten, hyprctl,
//     niri msg) and the libei-based "input emulation" portal isn't
//     universally honored. Rather than bake a per-compositor matrix
//     into the harness, runners on native Wayland rows must skip
//     this test entirely. WaylandFocusUnavailable is the signal.
//   - Wayland-with-XWayland (KDE-W default, Ubu-W default, GNOME-W
//     when XDG_SESSION_TYPE=x11 is forced) is *not* an X11 session
//     for our purposes — the WAYLAND-SIDE windows xdotool can't see
//     are exactly the windows S11/S14 care about. The single source
//     of truth is XDG_SESSION_TYPE === 'x11'. Anything else: skip.
//
// Why xdotool over xprop+wmctrl-equivalent: xdotool ships
// `search --name <regex> windowfocus` as one atomic call. Doing it
// with raw xprop means walking _NET_CLIENT_LIST, fetching _NET_WM_NAME
// per WID, picking a match, then sending an _NET_ACTIVE_WINDOW
// ClientMessage — which xprop can't generate, only read. wmctrl can,
// but adds a second binary dependency for no win.
//
// Why we verify post-focus via xprop: xdotool exits 0 even when
// focus didn't actually shift. Some compositors (mutter under
// XWayland-forced mode notably) accept the WM_TAKE_FOCUS / SetInputFocus
// pair and then quietly refuse the activation. The only honest
// answer is to read _NET_ACTIVE_WINDOW back out and compare WIDs.
// xdotool prints decimal WIDs; xprop prints `0x...` hex. We
// normalize to lowercase 0x-prefixed hex with leading zeros stripped.
//
// No fixed sleeps. The verification poll uses retryUntil so a fast
// compositor finishes in ~50ms while a slow one gets the full budget.

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { retryUntil } from './retry.js';

const exec = promisify(execFile);

// Caller catches this and calls test.skip() — it's an environment gap,
// not a regression. Subclassing Error gives consumers a clean
// `instanceof` check without parsing message strings.
export class WaylandFocusUnavailable extends Error {
	constructor(message?: string) {
		super(
			message ??
				'focusOtherWindow: native Wayland session — no portable ' +
					'focus-injection path. Skip on this row.',
		);
		this.name = 'WaylandFocusUnavailable';
	}
}

// Mirrors quickentry.ts's ensureYdotool message style — the install
// command is the actually-useful part of the error. Consumers should
// usually skip rather than fail; the absence of xdotool is an
// environment configuration issue, not a Claude Desktop regression.
export class XdotoolUnavailable extends Error {
	constructor(message?: string) {
		super(
			message ??
				'xdotool binary not found on PATH. Install with ' +
					'`dnf install xdotool` / `apt install xdotool`.',
		);
		this.name = 'XdotoolUnavailable';
	}
}

// Single source of truth for the X11/Wayland branch. Every other
// function in this file calls this — do not duplicate the env check.
//
// XDG_SESSION_TYPE is set by logind. Possible values per spec are
// `x11`, `wayland`, `tty`, `mir`, `unspecified`. We only trust the
// literal string `x11` — anything else, including missing, returns
// false. That means an unset env var on a real X11 box returns false
// here; that's the correct conservative default since we can't
// verify the assumption.
export function isX11Session(): boolean {
	return process.env.XDG_SESSION_TYPE === 'x11';
}

// Normalize a WID to lowercase 0x-prefixed hex with leading zeros
// stripped after the prefix. Accepts decimal (xdotool stdout) or hex
// (xprop stdout, with or without 0x). Returns null on parse failure.
//
// Examples:
//   '94371842'    → '0x5a00002'
//   '0x05a00002'  → '0x5a00002'
//   '0X5A00002'   → '0x5a00002'
function normalizeWid(raw: string): string | null {
	const s = raw.trim();
	if (!s) return null;
	const isHex = /^0x/i.test(s);
	const n = isHex ? parseInt(s, 16) : parseInt(s, 10);
	if (!Number.isFinite(n) || n <= 0) return null;
	return '0x' + n.toString(16);
}

// Read the currently-focused X11 window via _NET_ACTIVE_WINDOW.
//
// Returns null on:
//   - Native Wayland (xprop may still respond via XWayland but the
//     value is meaningless for native-Wayland clients — they don't
//     appear in the X11 active-window list at all). Returning null
//     here lets focusOtherWindow's poll fail through to its own
//     timeout, but in practice native-Wayland rows are gated out
//     earlier by isX11Session().
//   - xprop missing / spawn failure.
//   - Output that doesn't match the documented format (defensive —
//     this should never happen on a real EWMH-compliant WM but the
//     cost of a null return is one re-poll).
export async function getFocusedWindowId(): Promise<string | null> {
	if (!isX11Session()) return null;
	let stdout: string;
	try {
		({ stdout } = await exec('xprop', [
			'-root',
			'_NET_ACTIVE_WINDOW',
		]));
	} catch {
		return null;
	}
	// Documented format:
	//   _NET_ACTIVE_WINDOW(WINDOW): window id # 0x5a00002
	const m = stdout.match(/window id #\s*(0x[0-9a-fA-F]+)/);
	if (!m || !m[1]) return null;
	return normalizeWid(m[1]);
}

// Resolve a window title to its WID via xdotool. xdotool prints one
// decimal WID per matching line — we take the first (and warn via
// thrown Error if there are zero matches; multi-match is silently
// resolved to the first, mirroring xdotool's own windowfocus
// behavior).
async function resolveWindowIdByTitle(
	title: string,
): Promise<string | null> {
	const { stdout } = await exec('xdotool', ['search', '--name', title]);
	const lines = stdout
		.split('\n')
		.map((l) => l.trim())
		.filter(Boolean);
	if (lines.length === 0) return null;
	const first = lines[0];
	if (!first) return null;
	return normalizeWid(first);
}

// Shift X11 focus to the first window whose title matches `title`,
// then verify the shift actually took.
//
// Throws:
//   - WaylandFocusUnavailable on native Wayland.
//   - XdotoolUnavailable when xdotool isn't on PATH.
//   - Plain Error when no window matches the title (caller's bug —
//     forgot to spawn the marker, or used the wrong title).
//   - Plain Error when xdotool reports success but xprop never
//     reflects the focus change within ~3s (compositor refused the
//     activation; this is the diagnostic path S11/S14 actually want
//     to surface, not swallow).
export async function focusOtherWindow(title: string): Promise<void> {
	if (!isX11Session()) {
		throw new WaylandFocusUnavailable();
	}

	// Resolve target WID first so we know what to verify against.
	// Combining this with `windowfocus` would save a roundtrip but
	// would also make the post-focus comparison impossible.
	let targetWid: string | null;
	try {
		targetWid = await resolveWindowIdByTitle(title);
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') throw new XdotoolUnavailable();
		throw err;
	}
	if (!targetWid) {
		throw new Error(
			`focusOtherWindow: no X11 window matches title ${JSON.stringify(title)}. ` +
				'Did the marker window finish mapping? Caller should ' +
				'await spawnMarkerWindow + a short readiness poll before ' +
				'calling focusOtherWindow.',
		);
	}

	// Send the focus request. xdotool's windowfocus issues a
	// SetInputFocus, which is best-effort; the verify-via-xprop
	// step below is the actual assertion.
	try {
		await exec('xdotool', ['search', '--name', title, 'windowfocus']);
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') throw new XdotoolUnavailable();
		throw err;
	}

	// Poll _NET_ACTIVE_WINDOW until it matches the target. ~3s budget
	// covers slow compositor activation paths (mutter cold-path is
	// the worst observed, ~800ms). Anything beyond 3s is a refusal,
	// not a slow ack — surface as an error so S11/S14 see it.
	const matched = await retryUntil(
		async () => {
			const active = await getFocusedWindowId();
			return active === targetWid ? true : null;
		},
		{ timeout: 3_000, interval: 100 },
	);
	if (!matched) {
		throw new Error(
			`focusOtherWindow: xdotool windowfocus returned 0 but ` +
				`_NET_ACTIVE_WINDOW never settled to ${targetWid} ` +
				`for title ${JSON.stringify(title)}. Compositor may ` +
				'have refused the activation request.',
		);
	}
}

// Handle returned from spawnMarkerWindow. Lifecycle is owned by the
// caller — the test that spawned it must kill() in afterEach (or
// equivalent), otherwise the xterm leaks past the test run.
export interface MarkerWindow {
	pid: number;
	title: string;
	kill(): Promise<void>;
}

// Spawn a long-lived xterm with a known title, suitable as a focus
// target. Backgrounded with detached:false so the parent test process
// owns its lifetime — if the test crashes, the OS cleans up the child
// when the parent dies.
//
// Why xterm: it's the lowest-common-denominator X11 terminal — every
// X11 row has it (or can install it via the standard package). It
// honors -title verbatim (no de-escaping surprises) and -e accepts
// a single command without argv parsing quirks. Alternatives like
// `xclock` / `xeyes` either don't accept arbitrary titles or are
// missing on minimal Fedora installs.
//
// Throws if xterm isn't on PATH. Caller's responsibility to fall
// back or skip; we don't carry an `XtermUnavailable` class because
// the consumer decision tree is identical to "skip on missing
// xdotool" and the message is self-explanatory.
export async function spawnMarkerWindow(
	title: string,
): Promise<MarkerWindow> {
	// Lazy import so the module loads cleanly on Wayland rows that
	// never call this function. (Top-level imports of node:child_process
	// are already paid for by execFile, so this is mostly stylistic.)
	const { spawn } = await import('node:child_process');

	let child;
	try {
		// `sleep 600` keeps the xterm alive for 10min — longer than
		// any reasonable single test, short enough that a leaked
		// xterm self-cleans within the sweep. -hold not used: we
		// want the window to die when sleep dies.
		child = spawn('xterm', ['-title', title, '-e', 'sleep', '600'], {
			detached: false,
			stdio: 'ignore',
		});
	} catch (err) {
		const e = err as { code?: string | number };
		if (e.code === 'ENOENT') {
			throw new Error(
				'xterm binary not found on PATH. Install with ' +
					'`dnf install xterm` / `apt install xterm`. ' +
					'Required by the focus-shift test path; consumers ' +
					'should skip when this throws.',
			);
		}
		throw err;
	}

	// Surface synchronous spawn failures (ENOENT on some Node
	// versions arrives via the 'error' event, not the throw above).
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
			throw new Error(
				'xterm binary not found on PATH. Install with ' +
					'`dnf install xterm` / `apt install xterm`.',
			);
		}
		throw earlyError;
	}

	const pid = child.pid;
	if (typeof pid !== 'number') {
		// Shouldn't happen after a successful 'spawn' event, but
		// the type system doesn't know that.
		throw new Error('spawnMarkerWindow: child.pid was undefined after spawn');
	}

	let killed = false;
	const kill = async (): Promise<void> => {
		if (killed) return;
		killed = true;
		if (child.exitCode !== null || child.signalCode !== null) {
			return; // already exited
		}
		// SIGTERM with a short grace period before SIGKILL. xterm
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
