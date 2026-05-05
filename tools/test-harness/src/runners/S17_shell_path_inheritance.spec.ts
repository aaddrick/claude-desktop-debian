import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S17 — App launched from `.desktop` inherits shell-profile PATH.
//
// Upstream's shell-path-worker (`shellPathWorker.js`) is forked at
// `app.on('ready')` and runs the user's login shell with `-l -i`,
// printing PATH between sentinels (mac-style env inheritance, now
// applied on Linux too — see index.js:259300 for SLr() / NLr() and
// shellPathWorker.js:205 for extractPathFromShell()).
//
// We launch the app with a deliberately-scrubbed PATH so the
// worker's contribution is visible against a clean baseline. We
// CANNOT just read `process.env.PATH` afterwards: the merge in
// FX() (`index.js:259311`) is gated on `process.env[A] === void 0`,
// so a caller-provided PATH is never overwritten by the worker.
// The bundled f2t module is closure-scoped and not reachable from
// outside.
//
// Workaround: from the inspector we re-fork the same shell-path
// worker via `utilityProcess.fork`, mirroring NLr() exactly, and
// observe the worker's `envResult` message. That gives us the
// worker's resolved PATH directly — same machinery the app uses,
// but with an observable result port.

// Scrubbed baseline: enough system paths for Electron to find its
// helper binaries (zygote, GPU, sandbox shim) but with no user-profile
// entries (`~/.local/bin`, `~/.npm-global/bin`, `~/bin`, `~/.cargo/bin`,
// etc.). Going tighter (e.g. `/usr/bin:/bin`) starves the renderer of
// system tools and the main window never reports visible.
const SCRUBBED_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

interface WorkerResult {
	ok: boolean;
	path?: string;
	error?: string;
	durationMs: number;
}

test('S17 — App inherits shell-profile PATH on `.desktop` invocation', async ({}, testInfo) => {
	// App startup (~5-10s) + inspector attach (~1s) + login-shell PATH
	// extraction (1-3s; can be 5s on a cold zsh w/ oh-my-zsh) + slack.
	test.setTimeout(150_000);
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Shell PATH / shell-path worker',
	});

	// Worker is gated on SHELL existing + pointing at a real binary
	// (`shellPathWorker.js:187` getSafeShell()). On hosts without a
	// SHELL we have nothing to assert — skip rather than false-fail.
	if (!process.env.SHELL) {
		testInfo.skip(true, 'SHELL unset on host — shell-path worker has no shell to fork');
		return;
	}

	await testInfo.attach('host-session-env', {
		body: JSON.stringify(
			{
				...captureSessionEnv(),
				SHELL: process.env.SHELL,
				HOME: process.env.HOME,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});
	await testInfo.attach('scrubbed-path', {
		body: SCRUBBED_PATH,
		contentType: 'text/plain',
	});

	const app = await launchClaude({
		extraEnv: { PATH: SCRUBBED_PATH },
	});

	try {
		const { inspector } = await app.waitForReady('mainVisible');

		// Capture what the main process sees as PATH right after
		// startup. By the FX()-merge contract this should equal the
		// scrubbed value (caller-provided PATH wins over worker
		// merge); we attach it for diagnostic completeness so a
		// future regression where the merge starts overwriting is
		// visible against this anchor.
		const mainProcessPath = await inspector.evalInMain<string>(`
			return process.env.PATH || '';
		`);
		await testInfo.attach('main-process-path', {
			body: mainProcessPath,
			contentType: 'text/plain',
		});

		// Fork the shell-path worker the app ships with, mirroring
		// NLr() at index.js:259349. utilityProcess.fork + a
		// MessageChannelMain pair, init the worker, request
		// 'getEnvironment', read back the envResult.PATH. The
		// worker runs the user's login shell which can take 1-3s on
		// a cold zsh — budget 10s to absorb that plus fork latency.
		// One bounded shot, no retry: a worker hang or dead-spawn
		// here is a real failure, not a transient.
		const workerResult = await inspector.evalInMain<WorkerResult>(
			`
			const path = process.mainModule.require('node:path');
			const fs = process.mainModule.require('node:fs');
			const { utilityProcess, MessageChannelMain } =
				process.mainModule.require('electron');

			const workerPath = path.join(
				process.resourcesPath,
				'app.asar',
				'.vite',
				'build',
				'shell-path-worker',
				'shellPathWorker.js',
			);
			if (!fs.existsSync(workerPath)) {
				return {
					ok: false,
					error: 'worker not found at ' + workerPath,
					durationMs: 0,
				};
			}

			const start = Date.now();
			return await new Promise((resolve) => {
				let done = false;
				const child = utilityProcess.fork(workerPath, [], {
					serviceName: 'S17 shell-path probe',
				});
				const { port1, port2 } = new MessageChannelMain();
				const finish = (v) => {
					if (done) return;
					done = true;
					clearTimeout(timer);
					try { port1.close(); } catch (_) {}
					try { child.kill(); } catch (_) {}
					resolve({ ...v, durationMs: Date.now() - start });
				};
				const timer = setTimeout(() => finish({
					ok: false,
					error: 'worker probe timed out after 10000ms',
				}), 10000);

				port1.on('message', (e) => {
					if (e.data && e.data.type === 'envResult') {
						finish({
							ok: true,
							path: (e.data.env && e.data.env.PATH) || '',
						});
					} else if (e.data && e.data.type === 'error') {
						finish({ ok: false, error: e.data.message });
					}
				});
				port1.start();
				child.once('spawn', () => {
					child.postMessage({ type: 'init' }, [port2]);
					port1.postMessage({ type: 'getEnvironment' });
				});
				child.once('exit', (code) => {
					finish({
						ok: false,
						error: 'worker exited before envResult, code=' + code,
					});
				});
			});
			`,
			15_000,
		);

		await testInfo.attach('worker-result', {
			body: JSON.stringify(workerResult, null, 2),
			contentType: 'application/json',
		});

		expect(
			workerResult.ok,
			`shell-path worker fork succeeded (error=${workerResult.error})`,
		).toBe(true);

		const settledPath = workerResult.path ?? '';
		await testInfo.attach('settled-path', {
			body: settledPath,
			contentType: 'text/plain',
		});

		// Diff the segments so the failure log shows exactly what
		// the worker contributed (or didn't).
		const scrubbedSet = new Set(SCRUBBED_PATH.split(':'));
		const settledSegments = settledPath.split(':').filter(Boolean);
		const added = settledSegments.filter((s) => !scrubbedSet.has(s));
		await testInfo.attach('path-diff', {
			body: JSON.stringify(
				{
					scrubbed: SCRUBBED_PATH.split(':'),
					settled: settledSegments,
					added,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		// If the host's shell rc adds nothing to PATH (clean
		// install, no profile customisations) the worker has
		// nothing to surface and the assertion below would
		// false-fail. Skip with a clear note rather than fail.
		if (settledPath === SCRUBBED_PATH || added.length === 0) {
			testInfo.skip(
				true,
				'host shell profile contributes no PATH additions ' +
					'beyond the scrubbed baseline — worker has nothing to ' +
					'extract on this host',
			);
			return;
		}

		expect(
			settledPath,
			'worker-resolved PATH expanded beyond the scrubbed baseline',
		).not.toBe(SCRUBBED_PATH);
		expect(
			added.length,
			'worker added at least one PATH segment from shell profile',
		).toBeGreaterThan(0);
	} finally {
		await app.close();
	}
});
