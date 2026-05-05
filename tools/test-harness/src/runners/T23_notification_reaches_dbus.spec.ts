import { test, expect } from '@playwright/test';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { launchClaude } from '../lib/electron.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { sleep } from '../lib/retry.js';

const exec = promisify(execFile);

// T23 — Desktop notification fires and reaches the session bus.
//
// Tier 2 reframe of the case-doc T23. The full case-doc claim is
// "trigger notification source (T27 scheduled task / T22 PR
// completion / S24 dispatch), observe notification appears in DE
// notification area" — that's Tier 3 because every source needs a
// signed-in account + extra fixtures. Here we collapse the question
// to "does Electron's Notification API on this build still hit
// org.freedesktop.Notifications.Notify on the session bus?" and
// answer it from the inspector with a unique-titled notification
// while a dbus-monitor subprocess records bus traffic.
//
// Code anchors (build-reference/app-extracted/.vite/build/index.js):
//   :494456 — `new hA.Notification(r)` (backed by Electron's
//             libnotify-equivalent on Linux: a DBus call to
//             org.freedesktop.Notifications.Notify).
//   :495110 — `showNotification(title, body, tag, navigateTo)` is
//             the dispatcher; on Linux it routes through the
//             Electron Notification path.
// We don't drive showNotification directly (it's behind minified
// internal modules) — using `electron.Notification` proves the
// underlying surface is reachable, which is the load-bearing claim.
//
// Why a subprocess for monitoring rather than dbus-next:
//   - org.freedesktop.Notifications.Notify is a method *call*, not a
//     signal. dbus-next's match-rule API is shaped for signals;
//     observing method calls TO another connection requires
//     `eavesdrop=true` and the broker may reject it. dbus-monitor
//     handles the eavesdrop dance for us when broker policy allows.
//   - The existing lib/dbus.ts session-bus connection is for
//     well-known method calls (GetConnectionUnixProcessID etc.); the
//     monitor is short-lived and easier to clean up as a subprocess.
//
// Why dbus-monitor and not gdbus monitor:
//   - `gdbus monitor --dest <name>` only sees signals OWNED BY that
//     destination (e.g. PropertiesChanged on the daemon), not
//     method calls TO it. The Notify is a method call FROM Electron
//     TO the daemon, so gdbus monitor can't observe it. dbus-monitor
//     installs a real match rule with eavesdrop support.
//
// Skip rules (cleanly, not failures — these are environment shapes,
// not regressions):
//   1. `dbus-monitor` not on PATH (rare on desktop Linux but
//      possible in stripped CI containers).
//   2. No owner for `org.freedesktop.Notifications` on the bus
//      (no notification daemon registered — minimal session, CI
//      runner without a notification daemon, etc.).
//
// No row gate — Notification is a generic Electron surface; every
// row should support it.

// Default timeout (60s) leaves ~no margin around waitForReady's 90s
// budget plus our 5s monitor poll plus subprocess teardown. Match
// the T25 / T17 pattern.
test.setTimeout(120_000);

async function isOnPath(bin: string): Promise<boolean> {
	try {
		await exec('which', [bin], { timeout: 2_000 });
		return true;
	} catch {
		return false;
	}
}

async function notificationDaemonRegistered(): Promise<boolean> {
	// `gdbus call` against o.f.DBus.NameHasOwner returns "(true,)" or
	// "(false,)". Subprocess form keeps us off the shared lib/dbus.ts
	// connection — this check runs before launchClaude and we don't
	// want to warm up a bus connection just for one query.
	try {
		const { stdout } = await exec(
			'gdbus',
			[
				'call',
				'--session',
				'--dest',
				'org.freedesktop.DBus',
				'--object-path',
				'/org/freedesktop/DBus',
				'--method',
				'org.freedesktop.DBus.NameHasOwner',
				'org.freedesktop.Notifications',
			],
			{ timeout: 5_000 },
		);
		return stdout.trim().startsWith('(true');
	} catch {
		return false;
	}
}

test('T23 — notification reaches org.freedesktop.Notifications.Notify', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Desktop notifications',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Pre-flight skip checks — environment-shape, not regression.
	if (!(await isOnPath('dbus-monitor'))) {
		test.skip(
			true,
			'dbus-monitor not on PATH (install dbus-tools / dbus package); ' +
				'cannot observe Notify method calls without it',
		);
		return;
	}
	if (!(await notificationDaemonRegistered())) {
		test.skip(
			true,
			'no owner for org.freedesktop.Notifications on the session bus ' +
				'(no notification daemon running) — environment limitation, ' +
				'not a regression',
		);
		return;
	}

	const uniqueTitle = `T23-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
	await testInfo.attach('unique-title', {
		body: uniqueTitle,
		contentType: 'text/plain',
	});

	// Spawn dbus-monitor BEFORE firing the notification so we can't
	// race the Notify call. Match rule scopes us to just the Notify
	// method on the Notifications interface — keeps the buffer small
	// and avoids parsing unrelated bus chatter.
	const matchRule =
		"interface='org.freedesktop.Notifications',member='Notify'";
	const monitor = spawn(
		'dbus-monitor',
		['--session', matchRule],
		{ stdio: ['ignore', 'pipe', 'pipe'] },
	);

	let buffer = '';
	monitor.stdout.on('data', (chunk: Buffer) => {
		buffer += chunk.toString('utf8');
	});
	let stderr = '';
	monitor.stderr.on('data', (chunk: Buffer) => {
		stderr += chunk.toString('utf8');
	});

	// Give dbus-monitor ~250ms to install its match rule before
	// firing. Without this, a fast Notify can arrive before the
	// match rule is registered and we'd never see it.
	await sleep(250);

	const app = await launchClaude();

	let observedAtMs: number | null = null;
	let firedAtMs: number | null = null;

	try {
		const { inspector } = await app.waitForReady('mainVisible');

		// `electron.Notification` is the public Electron API and on
		// Linux thin-wraps libnotify (a DBus Notify call to the
		// daemon). Returning .show() synchronously is fine — the bus
		// call is async-fire from JS's perspective, and we poll the
		// monitor buffer below.
		firedAtMs = Date.now();
		await inspector.evalInMain<null>(`
			const { Notification } = process.mainModule.require('electron');
			const n = new Notification({
				title: ${JSON.stringify(uniqueTitle)},
				body: 'T23 harness probe — ignore me',
				silent: true,
			});
			n.show();
			return null;
		`);

		// Poll buffer for our unique title. 5s budget — notification
		// daemons respond fast (sub-100ms typical); if we don't see
		// it within 5s the call almost certainly didn't reach the bus.
		const deadline = Date.now() + 5_000;
		while (Date.now() < deadline) {
			if (buffer.includes(uniqueTitle)) {
				observedAtMs = Date.now();
				break;
			}
			await sleep(100);
		}
	} finally {
		// Tear down monitor + app in a deterministic order. Monitor
		// first so a kill failure doesn't block the (longer) app
		// teardown. SIGTERM is enough for dbus-monitor.
		try {
			monitor.kill('SIGTERM');
		} catch {
			// already dead
		}
		await app.close();
	}

	// Trim buffer to last ~5KB for the attachment. dbus-monitor's
	// per-call output is ~600 bytes for a tiny payload, so 5KB is
	// plenty of context (last ~8 calls) without bloating the report.
	const TRIM = 5 * 1024;
	const trimmedBuffer =
		buffer.length > TRIM
			? `…(${buffer.length - TRIM}b truncated)…\n` + buffer.slice(-TRIM)
			: buffer;
	const elapsedMs =
		observedAtMs !== null && firedAtMs !== null
			? observedAtMs - firedAtMs
			: null;

	await testInfo.attach('dbus-monitor-buffer', {
		body: trimmedBuffer || '(empty)',
		contentType: 'text/plain',
	});
	if (stderr) {
		await testInfo.attach('dbus-monitor-stderr', {
			body: stderr,
			contentType: 'text/plain',
		});
	}
	await testInfo.attach('observation', {
		body: JSON.stringify(
			{
				uniqueTitle,
				firedAtMs,
				observedAtMs,
				elapsedMsFireToObserve: elapsedMs,
				bufferBytes: buffer.length,
				monitorMatchRule: matchRule,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		observedAtMs,
		'unique-titled Notify method call appeared on the session bus ' +
			'within 5s of firing — see dbus-monitor-buffer attachment for ' +
			'the captured trace',
	).not.toBeNull();
});
