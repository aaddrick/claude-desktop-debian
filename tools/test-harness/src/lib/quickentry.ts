// Quick Entry domain wrapper — single point of coupling to upstream's
// main-process structure for QE-* tests.
//
// Why centralize: upstream symbol names (Ko for popup, ut for main, h1
// for the visibility check) drift between releases per CLAUDE.md's
// "Working with Minified JavaScript" notes. If this lookup logic lives
// in 12 separate spec files, every release becomes a 12-file fix. If
// it lives here, it's one fix.
//
// Discovery strategy: don't rely on minified symbol names. Use shape:
//   - Popup webContents = the new entry that appears after the shortcut
//     fires (snapshot/diff pattern).
//   - Popup BrowserWindow = the only one constructed with
//     transparent: true && alwaysOnTop: true.
//   - Main BrowserWindow = the one whose webContents URL contains
//     "claude.ai".
//
// Shortcut injection: ydotool through /dev/uinput. Works on X11,
// XWayland, and native Wayland with portal-grabbed shortcuts (KDE-W,
// Ubu-W, KDE-X). Does NOT work where the OS-level grab itself is broken
// (#404 GNOME-W) — that's the test, not a tool gap. Tests that need
// the popup to be open *without* exercising the OS shortcut grab call
// `installInterceptor()` first to stash a popup-constructor ref via
// BrowserWindow construction-time capture, then... we still need a
// trigger. For the closeout sweep the assumption is ydotool is present
// and the OS grab works on the row under test. S11/S12 explicitly test
// the grab path; everything else assumes it.

import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import type { InspectorClient } from './inspector.js';
import { retryUntil, sleep } from './retry.js';

const exec = promisify(execFile);

export interface WebContentsInfo {
	id: number;
	url: string;
}

export interface BrowserWindowState {
	visible: boolean;
	minimized: boolean;
	fullScreen: boolean;
	focused: boolean;
	bounds: { x: number; y: number; width: number; height: number };
}

// Linux key codes for the upstream default Ctrl+Alt+Space accelerator.
// Override via constructor option for tests that exercise a remapped
// shortcut.
const DEFAULT_KEY_SEQUENCE = [
	'29:1', // LEFTCTRL down
	'56:1', // LEFTALT  down
	'57:1', // SPACE    down
	'57:0', // SPACE    up
	'56:0', // LEFTALT  up
	'29:0', // LEFTCTRL up
];

export class QuickEntry {
	constructor(
		private readonly inspector: InspectorClient,
		private readonly keySeq: string[] = DEFAULT_KEY_SEQUENCE,
	) {}

	// Capture BrowserWindow refs by hooking prototype methods, not the
	// constructor.
	//
	// Why prototype-level: scripts/frame-fix-wrapper.js returns the
	// electron module wrapped in a Proxy whose `get` trap returns a
	// closure-captured PatchedBrowserWindow. A constructor-level wrap
	// (`electron.BrowserWindow = Wrapped`) writes to the underlying
	// module but the Proxy keeps returning PatchedBrowserWindow on
	// reads, so the wrap is bypassed entirely. Hooking
	// `BrowserWindow.prototype.loadFile` instead captures every
	// instance regardless of which subclass it was constructed
	// through — Patched, frame-fix-wrapped, or plain.
	//
	// The popup is identified by its loadFile target:
	// `.vite/renderer/quick_window/quick-window.html`
	// (build-reference index.js:515443).
	async installInterceptor(): Promise<void> {
		await this.inspector.evalInMain<null>(`
			if (globalThis.__qeInterceptorInstalled) return null;
			const electron = process.mainModule.require('electron');
			const proto = electron.BrowserWindow.prototype;
			globalThis.__qeWindows = [];
			const origLoadFile = proto.loadFile;
			proto.loadFile = function(filePath, ...rest) {
				try {
					const url = String(filePath || '');
					globalThis.__qeWindows.push({
						ref: this,
						loadedFile: url,
					});
				} catch (e) { /* recording must never throw */ }
				return origLoadFile.call(this, filePath, ...rest);
			};
			const origLoadURL = proto.loadURL;
			proto.loadURL = function(url, ...rest) {
				try {
					globalThis.__qeWindows.push({
						ref: this,
						loadedFile: String(url || ''),
					});
				} catch (e) {}
				return origLoadURL.call(this, url, ...rest);
			};
			globalThis.__qeInterceptorInstalled = true;
			return null;
		`);
	}

	// The popup is the BrowserWindow whose loadFile target ends with
	// `quick-window.html`. Stable path — upstream uses it verbatim
	// (build-reference index.js:515443).
	private popupSelector(): string {
		return `(w => {
			if (!w || !w.ref || w.ref.isDestroyed()) return false;
			const f = String(w.loadedFile || '');
			return f.indexOf('quick-window.html') !== -1
				|| f.indexOf('quick_window/') !== -1;
		})`;
	}

	async listWebContents(): Promise<WebContentsInfo[]> {
		return await this.inspector.evalInMain<WebContentsInfo[]>(`
			const { webContents } = process.mainModule.require('electron');
			return webContents.getAllWebContents().map(w => ({
				id: w.id, url: w.getURL(),
			}));
		`);
	}

	// Find the popup by elimination: not the main shell (file:// chrome)
	// and not the embedded claude.ai BrowserView.
	async getPopupWebContents(): Promise<WebContentsInfo | null> {
		const all = await this.listWebContents();
		const popup = all.find((w) => isPopupUrl(w.url));
		return popup ?? null;
	}

	// Send the configured accelerator via ydotool. Errors out (caller
	// can catch + skip) if ydotool isn't on PATH.
	//
	// YDOTOOL_SOCKET is honored from the parent env; defaults to
	// /tmp/.ydotool_socket (the path the shipped systemd unit uses
	// after the override drop-in). Without YDOTOOL_SOCKET, the client
	// probes /run/user/$UID/.ydotool_socket — a location the daemon
	// doesn't bind to, so the call fails confusingly.
	async openViaShortcut(): Promise<void> {
		await ensureYdotool();
		await exec('ydotool', ['key', ...this.keySeq], {
			env: {
				...process.env,
				YDOTOOL_SOCKET:
					process.env.YDOTOOL_SOCKET ?? '/tmp/.ydotool_socket',
			} as Record<string, string>,
		});
	}

	// openViaShortcut + waitForPopupReady, with retry for the
	// upstream-only-shows-when-logged-in race (build-reference
	// index.js:515604: `function lHn() { return !user.isLoggedOut; }`).
	// On a fresh launch, the renderer URL flips past /login before
	// the main-process user object is populated; the first shortcut
	// constructs the popup but skips show(). A second shortcut after
	// a brief settle hits the populated-user path. Total budget is
	// `attempts * (perAttemptMs + retryDelayMs)`.
	async openAndWaitReady(opts: {
		attempts?: number;
		perAttemptMs?: number;
		retryDelayMs?: number;
	} = {}): Promise<void> {
		const attempts = opts.attempts ?? 3;
		const perAttemptMs = opts.perAttemptMs ?? 8_000;
		const retryDelayMs = opts.retryDelayMs ?? 1_500;
		let lastErr: unknown = null;
		for (let i = 0; i < attempts; i++) {
			await this.openViaShortcut();
			try {
				await this.waitForPopupReady(perAttemptMs);
				return;
			} catch (err) {
				lastErr = err;
				if (i < attempts - 1) await sleep(retryDelayMs);
			}
		}
		throw new Error(
			`openAndWaitReady: popup never became ready after ${attempts} ` +
				`shortcut presses. Last error: ` +
				(lastErr instanceof Error ? lastErr.message : String(lastErr)),
		);
	}

	// Wait for the popup webContents to appear after openViaShortcut().
	async waitForPopup(timeoutMs = 5000): Promise<WebContentsInfo> {
		const wc = await retryUntil(
			async () => this.getPopupWebContents(),
			{ timeout: timeoutMs, interval: 100 },
		);
		if (!wc) {
			throw new Error(
				`Quick Entry popup webContents did not appear within ${timeoutMs}ms`,
			);
		}
		return wc;
	}

	// Wait for the popup to become hidden (the upstream "submit
	// accepted" signal). Upstream reuses the popup BrowserWindow
	// across invocations — Ko stays alive, only the visibility
	// toggles — so checking webContents existence would never
	// resolve. Read isVisible() on the captured BrowserWindow ref
	// instead.
	async waitForPopupClosed(timeoutMs = 5000): Promise<void> {
		const closed = await retryUntil(
			async () => {
				const state = await this.getPopupState();
				if (!state) return true; // destroyed → closed
				return state.visible ? null : true;
			},
			{ timeout: timeoutMs, interval: 100 },
		);
		if (!closed) {
			throw new Error(
				`Quick Entry popup did not become hidden within ${timeoutMs}ms`,
			);
		}
	}

	// Read live properties of the popup BrowserWindow. Replaces the
	// previous getPopupConstructionArgs — construction-time options
	// aren't observable through the prototype-method hook, but every
	// upstream-relevant signal has a runtime equivalent. Frame state
	// uses `getContentBounds() vs getBounds()` (frameless windows
	// have equal content + frame bounds). Transparent uses the
	// background color (popup is `#00000000`).
	async getPopupRuntimeProps(): Promise<{
		frameless: boolean;
		transparent: boolean;
		alwaysOnTop: boolean;
		backgroundColor: string;
	} | null> {
		// `skipTaskbar` was previously reported here but BrowserWindow
		// has no isSkipTaskbar() getter; the field hardcoded `false`
		// regardless of how the popup was constructed, which is
		// misleading. Dropped — no current spec consumes it. If a
		// future test needs it, capture via a setSkipTaskbar wrap in
		// installInterceptor() rather than faking a getter.
		return await this.inspector.evalInMain(`
			const wins = globalThis.__qeWindows || [];
			const isPopup = ${this.popupSelector()};
			const popup = wins.find(isPopup);
			if (!popup || !popup.ref || popup.ref.isDestroyed()) return null;
			const w = popup.ref;
			const bounds = w.getBounds();
			const content = w.getContentBounds();
			const bg = (w.getBackgroundColor && w.getBackgroundColor()) || '';
			return {
				frameless: bounds.width === content.width && bounds.height === content.height,
				transparent: bg === '#00000000' || bg === '#0000',
				alwaysOnTop: w.isAlwaysOnTop(),
				backgroundColor: bg,
			};
		`);
	}

	// Read the popup BrowserWindow's runtime visibility / bounds /
	// focus / fullscreen state. Used by waitForPopupReady and
	// waitForPopupClosed; the popup is reused across invocations
	// (Ko stays alive, only visibility toggles), so isVisible() is
	// the right "open vs closed" signal — not webContents existence.
	async getPopupState(): Promise<(BrowserWindowState & { alwaysOnTop: boolean }) | null> {
		return await this.inspector.evalInMain(`
			const wins = globalThis.__qeWindows || [];
			const isPopup = ${this.popupSelector()};
			const popup = wins.find(isPopup);
			if (!popup || !popup.ref || popup.ref.isDestroyed()) return null;
			const w = popup.ref;
			return {
				visible: w.isVisible(),
				minimized: w.isMinimized(),
				fullScreen: w.isFullScreen(),
				focused: w.isFocused(),
				bounds: w.getBounds(),
				alwaysOnTop: w.isAlwaysOnTop(),
			};
		`);
	}

	// Wait for the popup to be fully ready for input — meaning:
	//   (a) BrowserWindow has been show()n (isVisible === true),
	//       which only fires after upstream's `ready-to-show` event,
	//       which is after React's mount + first-pass effects, which
	//       is when document.addEventListener('keydown', ...) gets
	//       attached;
	//   (b) the textarea exists in the DOM.
	// Without (a), first-time-mount typing fires keydown into a
	// document with no listener and the submit silently drops.
	async waitForPopupReady(timeoutMs = 5000): Promise<void> {
		const popup = await this.waitForPopup(timeoutMs);
		let lastState: unknown = null;
		const ready = await retryUntil(
			async () => {
				const state = await this.getPopupState();
				const dom = await this.inspector
					.evalInMain<{
						readyState: string;
						hasTextarea: boolean;
					} | null>(
						`
							const { webContents } = process.mainModule.require('electron');
							const wc = webContents.fromId(${popup.id});
							if (!wc || wc.isDestroyed()) return null;
							return await wc.executeJavaScript(\`(() => ({
								readyState: document.readyState,
								hasTextarea: !!(document.querySelector('textarea')
									|| document.querySelector('[contenteditable="true"]')),
							}))()\`);
						`,
					)
					.catch(() => null);
				lastState = { state, dom };
				if (!state || !state.visible) return null;
				return dom && dom.hasTextarea ? dom : null;
			},
			{ timeout: timeoutMs, interval: 100 },
		);
		if (!ready) {
			throw new Error(
				`Popup did not become visible with a textarea within ${timeoutMs}ms. ` +
					`Last observed: ${JSON.stringify(lastState)}`,
			);
		}
	}

	// Type a prompt into the popup's textarea and submit. The popup is
	// a React app with a textarea + send button; React tracks input
	// values via a private setter, so plain `el.value = ...` is ignored.
	// The native-setter dance below is the standard React-friendly path.
	//
	// Waits for the textarea to exist before dispatching — first-time
	// lazy popup creation needs the React mount to complete, otherwise
	// the input event lands before any state listener and upstream
	// drops the submit as empty.
	async typeAndSubmit(text: string): Promise<void> {
		await this.waitForPopupReady();
		const popup = await this.getPopupWebContents();
		if (!popup) throw new Error('popup vanished after waitForPopupReady');
		const popupId = popup.id;
		await this.inspector.evalInMain<null>(`
			const { webContents } = process.mainModule.require('electron');
			const wc = webContents.fromId(${popupId});
			if (!wc) throw new Error('popup webContents ${popupId} gone');
			await wc.executeJavaScript(${JSON.stringify(typeAndSubmitJs(text))});
			return null;
		`);
	}

	// Read the persisted popup position (S35) directly from the
	// on-disk store. electron-store defaults to `config.json` under the
	// app's userData dir; for claude-desktop that's
	// `${configDir}/Claude/config.json` (or `~/.config/Claude/...`
	// when no isolation is in play). Reading the file beats the
	// previous globalThis-walk: that probe matched any object with
	// .get/.set returning a `quickWindowPosition` value, which is
	// fragile against unrelated minified objects coincidentally
	// matching the shape.
	//
	// Optional `configDir` keeps the call backward-compatible — pass
	// `app.isolation?.configDir` from runners under per-test isolation,
	// omit it to fall back to the host's `~/.config/Claude`.
	async getStoredPosition(configDir?: string): Promise<unknown | null> {
		const storePath = configDir
			? join(configDir, 'config.json')
			: join(homedir(), '.config/Claude/config.json');
		try {
			const raw = await readFile(storePath, 'utf8');
			const parsed = JSON.parse(raw) as { quickWindowPosition?: unknown };
			return parsed.quickWindowPosition ?? null;
		} catch {
			// File missing (never saved) or unreadable — both null.
			return null;
		}
	}
}

// Upstream loads the popup via
//   loadFile('.vite/renderer/quick_window/quick-window.html')
// (build-reference index.js:515443). Anchor on that exact path. Fall
// back to a broader 'quick_window/' substring if upstream renames just
// the HTML file.
export function isPopupUrl(url: string): boolean {
	if (!url.startsWith('file://')) return false;
	if (url.includes('claude.ai')) return false;
	if (url.includes('quick_window/quick-window.html')) return true;
	if (url.includes('/quick_window/')) return true;
	return false;
}

// React-friendly value setter. document.activeElement isn't reliable
// because the popup may not have focus on construction; we walk the
// DOM for the only textarea (or contenteditable).
function typeAndSubmitJs(text: string): string {
	const escaped = JSON.stringify(text);
	return `
		(async () => {
			const input = document.querySelector('textarea')
				|| document.querySelector('[contenteditable="true"]');
			if (!input) throw new Error('no textarea/contenteditable in popup DOM');
			input.focus();
			if (input.tagName === 'TEXTAREA') {
				const setter = Object.getOwnPropertyDescriptor(
					HTMLTextAreaElement.prototype, 'value'
				).set;
				setter.call(input, ${escaped});
				input.dispatchEvent(new Event('input', { bubbles: true }));
			} else {
				input.textContent = ${escaped};
				input.dispatchEvent(new InputEvent('input', { bubbles: true, data: ${escaped} }));
			}
			// Submit via Enter keydown — popup binds its own keyhandler
			// (renderer-side per the closeout doc).
			input.dispatchEvent(new KeyboardEvent('keydown', {
				key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
				bubbles: true, cancelable: true,
			}));
			input.dispatchEvent(new KeyboardEvent('keyup', {
				key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
				bubbles: true,
			}));
		})()
	`;
}

// Main-window state manipulation. Used by QE-7/8/9/10/11 to set the
// precondition (minimized, hidden-to-tray, fullscreen, etc.) before
// triggering Quick Entry.
//
// All methods walk webContents to find the claude.ai-hosting
// BrowserWindow via BrowserWindow.fromWebContents(). The
// `BrowserWindow.getAllWindows()` registry is broken by frame-fix-
// wrapper (see lib/inspector.ts gotchas) but `fromWebContents` uses a
// different code path and remains reliable.
export class MainWindow {
	constructor(private readonly inspector: InspectorClient) {}

	async setState(action: 'minimize' | 'hide' | 'show' | 'restore' | 'fullScreen' | 'unFullScreen' | 'focus' | 'close'): Promise<void> {
		await this.inspector.evalInMain<null>(`
			const { webContents, BrowserWindow } = process.mainModule.require('electron');
			const main = webContents.getAllWebContents().find(w => w.getURL().includes('claude.ai'));
			if (!main) throw new Error('no claude.ai webContents — main not yet loaded');
			const win = BrowserWindow.fromWebContents(main);
			if (!win) throw new Error('no BrowserWindow for claude.ai webContents');
			switch (${JSON.stringify(action)}) {
				case 'minimize':    win.minimize(); break;
				case 'hide':        win.hide(); break;
				case 'show':        win.show(); break;
				case 'restore':     win.restore(); break;
				case 'fullScreen':  win.setFullScreen(true); break;
				case 'unFullScreen':win.setFullScreen(false); break;
				case 'focus':       win.focus(); break;
				// 'close' fires the BrowserWindow 'close' event so
				// frame-fix-wrapper.js:178-185 (the close-to-tray
				// interceptor) and the upstream before-quit flow
				// run as they would on a real X-button click. NOT
				// the same as 'hide' — that bypasses the wrapper.
				// T08 asserts on this distinction.
				case 'close':       win.close(); break;
			}
			return null;
		`);
		// Compositor-side state changes are async — small settle.
		await sleep(150);
	}

	async getState(): Promise<BrowserWindowState | null> {
		return await this.inspector.evalInMain(`
			const { webContents, BrowserWindow } = process.mainModule.require('electron');
			const main = webContents.getAllWebContents().find(w => w.getURL().includes('claude.ai'));
			if (!main) return null;
			const win = BrowserWindow.fromWebContents(main);
			if (!win || win.isDestroyed()) return null;
			return {
				visible: win.isVisible(),
				minimized: win.isMinimized(),
				fullScreen: win.isFullScreen(),
				focused: win.isFocused(),
				bounds: win.getBounds(),
			};
		`);
	}
}

// Wait for the claude.ai user object to be loaded — the precondition
// for upstream's lHn() (`!user.isLoggedOut`) returning true. The
// shortcut handler calls Ko.show() only when lHn() is true; if the
// renderer hasn't finished loading the user yet, the popup gets
// constructed and ready-to-show fires, but show() is silently
// skipped (build-reference index.js:515604). The user object is
// available once the renderer has navigated past the login page —
// e.g. /new, /chat/<uuid>, /code, /projects.
//
// Returns the post-login URL on success. Returns null on timeout —
// caller can decide to skip vs fail.
//
// Anchored at the host root and bounded with a path-terminator class so
// only `/login`, `/auth`, `/sign-in` etc. as the *first* path segment
// match. The previous unanchored `/\/(login|auth|sign[-_]?in)/i` also
// caught substrings like `/oauth/callback` (auth) and any URL containing
// `/login` further down the path.
const LOGIN_URL_RE =
	/^https?:\/\/[^/]+\/(login|auth|sign[-_]?in)(?:[/?#]|$)/i;

export async function waitForUserLoaded(
	inspector: InspectorClient,
	timeoutMs = 30_000,
): Promise<string | null> {
	return await retryUntil(
		async () => {
			const urls = await inspector.evalInMain<string[]>(`
				const { webContents } = process.mainModule.require('electron');
				return webContents.getAllWebContents()
					.filter(w => w.getURL().includes('claude.ai'))
					.map(w => w.getURL());
			`);
			const postLogin = urls.find(
				(u) => !LOGIN_URL_RE.test(u) && u.includes('claude.ai'),
			);
			return postLogin ?? null;
		},
		{ timeout: timeoutMs, interval: 250 },
	);
}

// Wait for a new chat session to load in the claude.ai webContents.
// Returns the URL once a /chat/<uuid> path is reached. This is the
// network-coupled half of the layered submit assertion (S31): a slow
// claude.ai or a network blip can fail this independently of any QE
// regression. Callers should treat its failure as Should-not-Critical.
const CHAT_URL_RE = /\/chat\/[0-9a-f-]{8,}/i;

export async function waitForNewChat(
	inspector: InspectorClient,
	timeoutMs = 15_000,
): Promise<string | null> {
	return await retryUntil(
		async () => {
			const all = await inspector.evalInMain<{ url: string }[]>(`
				const { webContents } = process.mainModule.require('electron');
				return webContents.getAllWebContents()
					.filter(w => w.getURL().includes('claude.ai'))
					.map(w => ({ url: w.getURL() }));
			`);
			const match = all.find((w) => CHAT_URL_RE.test(w.url));
			return match ? match.url : null;
		},
		{ timeout: timeoutMs, interval: 250 },
	);
}

// Local-only assertion half: did the popup-side IPC fire with the
// right payload? Wraps the popup's `requestDismissWithPayload` IPC
// channel by intercepting it on the main side. Call before
// typeAndSubmit; resolves with the captured payload (or null on
// timeout).
export async function captureSubmitIpc(
	inspector: InspectorClient,
	timeoutMs = 5000,
): Promise<{ text: string } | null> {
	await inspector.evalInMain<null>(`
		if (!globalThis.__qeIpcInstalled) {
			const { ipcMain } = process.mainModule.require('electron');
			globalThis.__qeIpcCalls = [];
			// Wrap every existing 'requestDismiss'-shaped channel.
			// Channel names are minified-stable: requestDismiss /
			// requestDismissWithPayload (closeout doc index.js:515409).
			const channels = ['requestDismissWithPayload', 'requestDismiss'];
			for (const ch of channels) {
				const handlers = ipcMain._invokeHandlers || ipcMain._events || {};
				// Best-effort: register a parallel listener that records
				// invocations without disturbing the original handler.
				ipcMain.on(ch, (_event, payload) => {
					globalThis.__qeIpcCalls.push({ channel: ch, payload, ts: Date.now() });
				});
			}
			globalThis.__qeIpcInstalled = true;
		}
		return null;
	`);
	return await retryUntil(
		async () => {
			const calls = await inspector.evalInMain<
				{ channel: string; payload: unknown; ts: number }[]
			>(`return globalThis.__qeIpcCalls || []`);
			const submit = calls.find(
				(c) =>
					c.channel === 'requestDismissWithPayload' &&
					c.payload != null &&
					typeof c.payload === 'object',
			);
			if (!submit) return null;
			const p = submit.payload as Record<string, unknown>;
			const text =
				typeof p.text === 'string'
					? p.text
					: typeof p.prompt === 'string'
						? p.prompt
						: typeof p.value === 'string'
							? p.value
							: '';
			return { text };
		},
		{ timeout: timeoutMs, interval: 100 },
	);
}

async function ensureYdotool(): Promise<void> {
	try {
		// `ydotool` with no args exits 1 and prints the help text — that
		// confirms the binary works without sending input. Avoid
		// `ydotool --help` which is rejected as an unknown command.
		await exec('ydotool', [], {
			env: {
				...process.env,
				YDOTOOL_SOCKET:
					process.env.YDOTOOL_SOCKET ?? '/tmp/.ydotool_socket',
			} as Record<string, string>,
		});
	} catch (err) {
		const e = err as { code?: string | number; stderr?: string };
		// exit 1 with usage help is normal — only fail on ENOENT (no
		// binary) or stderr socket errors.
		const stderr = (e.stderr ?? '').toString();
		if (e.code === 'ENOENT') {
			throw new Error(
				'ydotool binary not found on PATH. Install with ' +
					'`dnf install ydotool` / `apt install ydotool`.',
			);
		}
		if (stderr.includes('failed to connect socket')) {
			throw new Error(
				'ydotoold socket not reachable. Start the daemon ' +
					'(`sudo systemctl start ydotool.service`) and ensure ' +
					'YDOTOOL_SOCKET points at its bind path. Underlying: ' +
					stderr.trim(),
			);
		}
		// Any other non-zero exit (notably exit 1 with usage) is fine.
	}
}
