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
}

export class InspectorClient {
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
			const { resolve, reject } = this.pending.get(msg.id)!;
			this.pending.delete(msg.id);
			if (msg.error) {
				reject(new Error(JSON.stringify(msg.error)));
			} else {
				resolve(msg.result);
			}
		}
	}

	send(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
		const id = ++this.nextId;
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			this.ws.send(JSON.stringify({ id, method, params }));
		});
	}

	// Evaluate an async expression in the main process; the expression body
	// must end with `return X` (or set a value). Returns the JSON-parsed
	// value. JSON-stringification inside the IIFE dodges the inspector's
	// Promise-result deep-marshaling quirks (returnByValue produces empty
	// objects for awaited Promise resolutions on this build).
	async evalInMain<T = unknown>(body: string): Promise<T> {
		const expression =
			'globalThis.__r = (async () => { ' +
			'const __v = await (async () => { ' +
			body +
			' })(); ' +
			'return JSON.stringify(__v === undefined ? null : __v); ' +
			'})(); globalThis.__r;';
		const result = (await this.send('Runtime.evaluate', {
			expression,
			awaitPromise: true,
			returnByValue: true,
		})) as { result?: { value?: unknown }; exceptionDetails?: unknown };

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
	): Promise<T> {
		const escaped = JSON.stringify(js);
		const result = await this.evalInMain<T>(`
			const { webContents } = process.mainModule.require('electron');
			const all = webContents.getAllWebContents();
			const target = all.find(w => w.getURL().includes(${JSON.stringify(urlFilter)}));
			if (!target) {
				throw new Error('no webContents matching: ${urlFilter.replace(/'/g, "\\'")}');
			}
			return await target.executeJavaScript(${escaped});
		`);
		return result;
	}

	close(): void {
		if (this.closed) return;
		this.closed = true;
		try {
			this.ws.close();
		} catch {
			// already closed
		}
	}
}
