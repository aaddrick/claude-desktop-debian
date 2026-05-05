import { test, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { launchClaude } from '../lib/electron.js';
import { killHostClaude } from '../lib/host-claude.js';
import { retryUntil } from '../lib/retry.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

const exec = promisify(execFile);

// T05 — `claude://` URL delivers to the running app via xdg-open.
//
// Tier-3 delivery probe. The earlier Tier-2 attempt
// (`app.isDefaultProtocolClient('claude')`) doesn't work in the
// harness: ELECTRON_FORCE_IS_PACKAGED=true makes `app.getName()`
// resolve to `Claude`, so the runtime registration call is a no-op
// and the API can't tell us anything useful. Instead we drive the
// real OS path: install a `second-instance` listener in the main
// process, fire `xdg-open 'claude://test/<marker>'` from a separate
// process, and verify the URL appears in the captured argv.
//
// Routing: `xdg-open` resolves `x-scheme-handler/claude` to
// `claude-desktop.desktop` and execs claude-desktop. The new
// process calls `app.requestSingleInstanceLock()` (upstream
// build-reference/app-extracted/.vite/build/index.js:525162),
// loses to our running instance, and the primary's
// `app.on('second-instance', ...)` handler at index.js:525163-525172
// fires with the spawned child's argv. The URL is in that argv —
// `uPn(t)` extracts it and routes to `fCA(r)` → `bEe(...)`.
//
// Why isolation: null. xdg-open's spawn always lands under the
// user's `~/.config/Claude` (the SingletonLock path is fixed in
// `app.getPath('userData')`, derived from XDG_CONFIG_HOME at
// child-process spawn time — we can't influence the spawned
// child's env from here). For the SingletonLock collision to route
// the URL to OUR instance, OUR instance must hold the lock at
// `~/.config/Claude/SingletonLock`. Default isolation gives us a
// tmpdir lock, so xdg-open's child wouldn't collide with us — it'd
// either start as a fresh primary (if no host claude-desktop is
// running) or route to the host's actual claude-desktop. Sharing
// host config is the only way the second-instance hook fires.
//
// Side effect: this test runs against the real `~/.config/Claude`
// and any host claude-desktop must be killed first. The URL is a
// synthetic `claude://test/<marker>` that hits `bEe()`'s default
// branch (no Preview/Hotkey/DebugHandoff host match) — no
// navigation, no destructive side effect.

test.setTimeout(60_000);

test('T05 — claude:// URL delivers to running app via xdg-open', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Smoke' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'URL scheme / protocol delivery',
	});

	// Skip cleanly when the prerequisites aren't on this host.
	try {
		await exec('which', ['xdg-open']);
	} catch {
		test.skip(true, 'xdg-open not available');
		return;
	}

	const xdgMime = await exec('xdg-mime', [
		'query',
		'default',
		'x-scheme-handler/claude',
	])
		.then((r) => r.stdout.trim())
		.catch(() => '');
	if (!xdgMime.includes('claude-desktop')) {
		test.skip(
			true,
			`claude:// not registered as default scheme handler (xdg-mime: "${xdgMime}")`,
		);
		return;
	}

	await testInfo.attach('xdg-mime', {
		body: xdgMime,
		contentType: 'text/plain',
	});
	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// xdg-open's spawned child binds the SingletonLock at
	// `~/.config/Claude/SingletonLock`; we must hold that lock so
	// the child loses and routes via second-instance instead of
	// becoming a fresh primary. Kill any host instance first, then
	// launch with `isolation: null` so OUR XDG_CONFIG_HOME matches
	// the child's.
	await killHostClaude();

	const app = await launchClaude({ isolation: null });
	const marker = `t05-${Date.now()}-${Math.random()
		.toString(36)
		.slice(2, 8)}`;
	const url = `claude://test/${marker}`;

	try {
		const { inspector } = await app.waitForReady('mainVisible');

		// Install a main-process hook that captures every
		// second-instance payload into a global. The handler
		// signature is (event, argv, cwd, additionalData) per
		// Electron docs and the upstream call site at index.js
		// :525163.
		await inspector.evalInMain<null>(`
			const { app } = process.mainModule.require('electron');
			global.__T05_argvCaptures = global.__T05_argvCaptures || [];
			if (!global.__T05_handlerInstalled) {
				app.on('second-instance', (event, argv, cwd) => {
					global.__T05_argvCaptures.push({
						argv,
						cwd,
						ts: Date.now(),
					});
				});
				global.__T05_handlerInstalled = true;
			}
			return null;
		`);

		// Fire the URL from a separate process. xdg-open execs
		// claude-desktop with the URL on argv; that child loses
		// the SingletonLock to us and routes via second-instance.
		// Capture exec output so a failure mode where xdg-open
		// itself errored shows up in the attached diagnostics.
		let xdgOpenStdout = '';
		let xdgOpenStderr = '';
		let xdgOpenError: string | null = null;
		try {
			const r = await exec('xdg-open', [url], { timeout: 10_000 });
			xdgOpenStdout = r.stdout;
			xdgOpenStderr = r.stderr;
		} catch (err) {
			const e = err as {
				stdout?: string;
				stderr?: string;
				message?: string;
			};
			xdgOpenStdout = e.stdout ?? '';
			xdgOpenStderr = e.stderr ?? '';
			xdgOpenError = e.message ?? String(err);
		}

		// Poll the captured argv list until our marker shows up.
		// 10s is generous: xdg-open returns immediately, the spawned
		// claude-desktop reaches `app.on('ready', ...)` in ~2-4s on
		// a warm cache, and `requestSingleInstanceLock()` losing
		// fires the parent's second-instance synchronously.
		interface Capture {
			argv: string[];
			cwd: string;
			ts: number;
		}
		const captured = await retryUntil<Capture>(
			async () => {
				const dump = await inspector.evalInMain<Capture[]>(`
					return global.__T05_argvCaptures || [];
				`);
				return (
					dump.find((c) =>
						(c.argv ?? []).some((a) => a.includes(marker)),
					) ?? null
				);
			},
			{ timeout: 10_000, interval: 250 },
		);

		const allCaptures = await inspector.evalInMain<Capture[]>(`
			return global.__T05_argvCaptures || [];
		`);

		await testInfo.attach('marker', {
			body: marker,
			contentType: 'text/plain',
		});
		await testInfo.attach('url', {
			body: url,
			contentType: 'text/plain',
		});
		await testInfo.attach(
			'xdg-open',
			{
				body: JSON.stringify(
					{
						stdout: xdgOpenStdout,
						stderr: xdgOpenStderr,
						error: xdgOpenError,
					},
					null,
					2,
				),
				contentType: 'application/json',
			},
		);
		await testInfo.attach('captured-second-instance', {
			body: JSON.stringify(allCaptures, null, 2),
			contentType: 'application/json',
		});

		expect(
			captured,
			`second-instance handler should fire with argv containing "${marker}"`,
		).toBeTruthy();
	} finally {
		await app.close();
	}
});
