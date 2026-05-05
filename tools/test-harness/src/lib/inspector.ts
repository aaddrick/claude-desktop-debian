// Node-inspector client for Electron's main process.
//
// Why this exists: the shipped Electron has an authenticated-CDP gate
// (see lib/electron.ts) that exits the app whenever
// --remote-debugging-port is on argv. The gate doesn't check --inspect /
// SIGUSR1, so we can attach the Node inspector at runtime — same code
// path as the in-app "Developer → Enable Main Process Debugger" menu.
//
// From the inspector we can evaluate arbitrary JS in the main process,
// which gives us:
//   - Electron API access (app, webContents, dialog, BrowserView)
//   - Renderer access via webContents.executeJavaScript()
//   - Main-process mocks (e.g. dialog.showOpenDialog for T17)
//
// Caveat: `BrowserWindow.getAllWindows()` returns 0 because frame-fix-
// wrapper substitutes the BrowserWindow class and the substitution
// breaks the static registry. Use `webContents.getAllWebContents()`
// instead — that registry stays intact.

interface PendingCall {
	resolve: (value: unknown) => void;
	reject: (err: Error) => void;
	timer: ReturnType<typeof setTimeout>;
}

// CDP accessibility-tree node shape (subset). The full AX tree is a flat
// array of these with parent/child links carried by id refs. We surface
// the value-bearing fields the v7 walker + claudeai.ts page-objects
// actually consume; remaining CDP fields (ignoredReasons,
// frameId, …) are accessible via the string-keyed bag.
export interface AxValue {
	type: string;
	value?: unknown;
}
export interface AxProperty {
	name: string;
	value: AxValue;
}
export interface AxNode {
	nodeId: string;
	parentId?: string;
	childIds?: string[];
	backendDOMNodeId?: number;
	role?: { type: string; value: string };
	name?: { type: string; value: string };
	// AX state/relation properties (`haspopup`, `expanded`, `modal`,
	// `checked`, `disabled`, …). claudeai.ts reads `haspopup` to
	// discriminate menu-trigger buttons from action buttons that
	// happen to share an accessible name.
	properties?: AxProperty[];
	ignored?: boolean;
	[k: string]: unknown;
}

export class InspectorClient {
	// why: 30s default for send() timeouts. "Slow but not stuck."
	// Lower defaults break legitimately-slow operations like initial
	// page-load on a cold app or a chunky DOM snapshot; higher defaults
	// turn renderer-side hangs (blocked event loop, modal trapping focus,
	// network-bound script stalled) into invisible silent freezes.
	// Consumers can override per-call (timeoutMs arg) or per-instance
	// (mutate InspectorClient.defaultTimeoutMs before instantiating).
	static defaultTimeoutMs = 30000;

	private ws: WebSocket;
	private nextId = 0;
	private pending = new Map<number, PendingCall>();
	// Idempotency flag for close(). Runners + electron.ts close() may
	// both call this on the same instance (intentionally — see
	// electron.ts launchClaude tracking comment); the flag guarantees
	// a second call is a true no-op rather than a redundant ws.close().
	private closed = false;

	private constructor(ws: WebSocket) {
		this.ws = ws;
		this.ws.addEventListener('message', (ev) => this.handleMessage(ev));
	}

	static async connect(port: number): Promise<InspectorClient> {
		const meta = await fetch(`http://127.0.0.1:${port}/json/list`).then((r) =>
			r.json(),
		) as Array<{ webSocketDebuggerUrl: string }>;
		if (!meta.length) {
			throw new Error(`Inspector at ${port} has no debuggee`);
		}
		const url = meta[0]!.webSocketDebuggerUrl;
		const ws = new WebSocket(url);
		await new Promise<void>((resolve, reject) => {
			ws.addEventListener('open', () => resolve(), { once: true });
			ws.addEventListener(
				'error',
				(e) => reject(new Error(`inspector ws error: ${e.type}`)),
				{ once: true },
			);
		});
		const client = new InspectorClient(ws);
		await client.send('Runtime.enable');
		await client.send('Runtime.runIfWaitingForDebugger');
		return client;
	}

	private handleMessage(ev: MessageEvent): void {
		const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : '{}') as {
			id?: number;
			error?: unknown;
			result?: unknown;
		};
		if (msg.id !== undefined && this.pending.has(msg.id)) {
			const { resolve, reject, timer } = this.pending.get(msg.id)!;
			this.pending.delete(msg.id);
			clearTimeout(timer);
			if (msg.error) {
				reject(new Error(JSON.stringify(msg.error)));
			} else {
				resolve(msg.result);
			}
		}
	}

	// why: every pending call gets a timer. When the renderer event loop
	// is blocked (modal focus trap, network-bound script stalled, DOM
	// snapshot too large) the CDP reply never arrives and the promise
	// would hang forever. We reject with a clear "method=X" error and
	// drop the pending entry (no leak), but we deliberately do NOT
	// close the websocket — a single hung eval shouldn't tear down the
	// connection; the next call may succeed.
	send(
		method: string,
		params: Record<string, unknown> = {},
		timeoutMs?: number,
	): Promise<unknown> {
		const id = ++this.nextId;
		const ms = timeoutMs ?? InspectorClient.defaultTimeoutMs;
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				if (this.pending.delete(id)) {
					reject(
						new Error(
							`inspector.send timed out after ${ms}ms (method=${method})`,
						),
					);
				}
			}, ms);
			this.pending.set(id, { resolve, reject, timer });
			this.ws.send(JSON.stringify({ id, method, params }));
		});
	}

	// Evaluate an async expression in the main process; the expression body
	// must end with `return X` (or set a value). Returns the JSON-parsed
	// value. JSON-stringification inside the IIFE dodges the inspector's
	// Promise-result deep-marshaling quirks (returnByValue produces empty
	// objects for awaited Promise resolutions on this build).
	//
	// Bare `require` is NOT a global in the CDP eval scope — go through
	// `process.mainModule.require('electron'|'node:fs'|…)` instead.
	async evalInMain<T = unknown>(body: string, timeoutMs?: number): Promise<T> {
		const expression =
			'globalThis.__r = (async () => { ' +
			'const __v = await (async () => { ' +
			body +
			' })(); ' +
			'return JSON.stringify(__v === undefined ? null : __v); ' +
			'})(); globalThis.__r;';
		const result = (await this.send(
			'Runtime.evaluate',
			{
				expression,
				awaitPromise: true,
				returnByValue: true,
			},
			timeoutMs,
		)) as { result?: { value?: unknown }; exceptionDetails?: unknown };

		if (result.exceptionDetails) {
			throw new Error(
				`evalInMain threw: ${JSON.stringify(result.exceptionDetails)}`,
			);
		}
		const v = result.result?.value;
		if (typeof v !== 'string') {
			throw new Error(
				`evalInMain expected JSON string, got ${JSON.stringify(result.result)}`,
			);
		}
		return JSON.parse(v) as T;
	}

	// Convenience: evaluate JS in a specific webContents (renderer).
	// `urlFilter` selects which webContents (substring match on getURL()).
	async evalInRenderer<T = unknown>(
		urlFilter: string,
		js: string,
		timeoutMs?: number,
	): Promise<T> {
		const escaped = JSON.stringify(js);
		const result = await this.evalInMain<T>(
			`
			const { webContents } = process.mainModule.require('electron');
			const all = webContents.getAllWebContents();
			const target = all.find(w => w.getURL().includes(${JSON.stringify(urlFilter)}));
			if (!target) {
				throw new Error('no webContents matching: ${urlFilter.replace(/'/g, "\\'")}');
			}
			return await target.executeJavaScript(${escaped});
		`,
			timeoutMs,
		);
		return result;
	}

	// Query the renderer's full accessibility tree via Chrome DevTools
	// Protocol's `Accessibility.getFullAXTree`. Reachable from main
	// process JS (this client connects to Node's debugger, not Chromium's
	// — but webContents.debugger gives us full CDP access from there).
	//
	// `urlFilter` selects which webContents to attach to (substring match
	// on getURL()). Idempotent attach: reusing the same webContents
	// across calls won't double-attach. Caller is responsible for AX
	// cost — full-tree latency on large surfaces may be ≥100ms; use a
	// scoped subtree query for those.
	async getAccessibleTree(
		urlFilter: string,
		timeoutMs?: number,
	): Promise<AxNode[]> {
		const result = await this.evalInMain<{ nodes: AxNode[] }>(
			`
			const { webContents } = process.mainModule.require('electron');
			const all = webContents.getAllWebContents();
			const target = all.find(w => w.getURL().includes(${JSON.stringify(urlFilter)}));
			if (!target) {
				throw new Error('no webContents matching: ${urlFilter.replace(/'/g, "\\'")}');
			}
			if (!target.debugger.isAttached()) {
				target.debugger.attach('1.3');
			}
			try {
				await target.debugger.sendCommand('Accessibility.enable');
			} catch (err) {
				// Already-enabled is benign; surface anything else.
				if (!String(err && err.message).includes('already enabled')) {
					throw err;
				}
			}
			const r = await target.debugger.sendCommand(
				'Accessibility.getFullAXTree',
			);
			return r;
		`,
			timeoutMs,
		);
		return result.nodes;
	}

	// Resolve the AX-tree-supplied backendNodeId to a renderer-side
	// JS object handle, then invoke `.click()` on it. This is the
	// click-path counterpart to `getAccessibleTree`: capture identifies
	// nodes by backendDOMNodeId, click consumes the same id without any
	// selector reconstruction. `DOM.resolveNode` handles cross-frame
	// nodes natively, and `Runtime.callFunctionOn` runs in the node's
	// own execution context — so the click dispatches against the right
	// document even when the target sits in an iframe.
	async clickByBackendNodeId(
		urlFilter: string,
		backendNodeId: number,
		timeoutMs?: number,
	): Promise<void> {
		await this.evalInMain<null>(
			`
			const { webContents } = process.mainModule.require('electron');
			const all = webContents.getAllWebContents();
			const target = all.find(w => w.getURL().includes(${JSON.stringify(urlFilter)}));
			if (!target) {
				throw new Error('no webContents matching: ${urlFilter.replace(/'/g, "\\'")}');
			}
			if (!target.debugger.isAttached()) {
				target.debugger.attach('1.3');
			}
			const resolved = await target.debugger.sendCommand(
				'DOM.resolveNode',
				{ backendNodeId: ${backendNodeId} },
			);
			const objectId = resolved && resolved.object && resolved.object.objectId;
			if (!objectId) {
				throw new Error(
					'clickByBackendNodeId: DOM.resolveNode returned no objectId for ' +
						${backendNodeId},
				);
			}
			try {
				await target.debugger.sendCommand('Runtime.callFunctionOn', {
					objectId,
					functionDeclaration: 'function() { this.click(); }',
				});
			} finally {
				try {
					await target.debugger.sendCommand('Runtime.releaseObject', {
						objectId,
					});
				} catch (_) {
					// Releasing a stale handle is benign.
				}
			}
			return null;
		`,
			timeoutMs,
		);
	}

	close(): void {
		if (this.closed) return;
		this.closed = true;
		// Drain pending timers + reject in-flight promises so callers
		// don't hang on close. Without this an outstanding send() keeps
		// the event loop alive past close().
		for (const [, pending] of this.pending) {
			clearTimeout(pending.timer);
			pending.reject(new Error('inspector closed'));
		}
		this.pending.clear();
		try {
			this.ws.close();
		} catch {
			// already closed
		}
	}
}
