import { test, expect } from '@playwright/test';
import { spawn, execFile } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mkdtemp, rm } from 'node:fs/promises';

const exec = promisify(execFile);

// S01 — AppImage launches without manual `libfuse2t64` install.
//
// Per docs/testing/cases/distribution.md S01: on Ubuntu 24.04+ the
// project AppImage currently fails with `dlopen(): error loading
// libfuse.so.2` unless the user manually installs `libfuse2t64`.
// The case-doc anchor (scripts/packaging/appimage.sh:226) notes the
// upstream `appimagetool` runtime is bundled as-is — no FUSE shim,
// no postinst dep declaration, no clear error message. CI papers
// over the gap by `apt install libfuse2`-ing before exec
// (.github/workflows/test-artifacts.yml:47).
//
// Assertion shape:
//   1. Locate an AppImage. Skip cleanly if not running from one.
//   2. Spawn the AppImage with a brief grace window. Capture stderr.
//   3. Assert stderr does NOT contain `libfuse.so.2` (or the broader
//      `dlopen` failure pattern that the AppImage runtime emits when
//      FUSE is missing).
//   4. Kill the proc — we don't need a full launch, just the FUSE
//      load attempt which happens before any squashfs mount.
//
// Why a runtime spawn rather than a static probe: the failure mode
// is `dlopen()` of libfuse.so.2 inside the AppImage runtime ELF
// itself, not anything our scripts produce. Only a real spawn on
// the target host exercises that dynamic loader path.
//
// Approach choice: we do NOT use `--appimage-version`. That flag is
// handled by the AppImage runtime BEFORE any FUSE mount, so it
// would exit 0 even on a host missing libfuse2 and silently pass
// the test. Instead we let the runtime reach its mount step, watch
// stderr for the dlopen error (which fires within ~100ms when the
// lib is absent), then kill before the Electron child has a chance
// to persist anything.
//
// Isolation: we spawn with a temp `XDG_CONFIG_HOME` / `HOME`-adjacent
// override so even if Electron does come up briefly before we kill
// it, nothing lands in `~/.config/Claude`.
//
// Row gating: this isn't matrix-row-driven — it's install-method-
// driven. The harness's `ROW` env doesn't carry "is this row's
// install an AppImage?", so we detect at runtime via launcher path
// + magic-byte sniff. Skip when the local install isn't AppImage.

interface AppImageProbeResult {
	path: string | null;
	reason: string;
}

// AppImages are ELF executables containing a squashfs image with a
// magic header at offset 8: `AI\x02` for type 2 (the format our build
// emits) or `AI\x01` for type 1. The magic is also visible to `file`,
// but ELF + extension + magic is cheap enough to inline.
async function probeAppImagePath(): Promise<AppImageProbeResult> {
	const explicit = process.env.CLAUDE_DESKTOP_LAUNCHER;
	const candidates: string[] = [];
	if (explicit) candidates.push(explicit);

	// Fallback search: project test-build dir holds AppImages from
	// `./build.sh --build appimage`. Resolve relative to this spec
	// so the search works regardless of CWD.
	const projectRoot = '/home/aaddrick/source/claude-desktop-debian';
	const testBuildDir = `${projectRoot}/test-build`;
	if (existsSync(testBuildDir)) {
		try {
			const fs = await import('node:fs/promises');
			const entries = await fs.readdir(testBuildDir);
			for (const entry of entries) {
				if (entry.endsWith('.AppImage')) {
					candidates.push(`${testBuildDir}/${entry}`);
				}
			}
		} catch {
			// best-effort
		}
	}

	for (const candidate of candidates) {
		if (!existsSync(candidate)) continue;
		try {
			const st = statSync(candidate);
			if (!st.isFile()) continue;
			// Quick filename hint: skip the magic-byte read entirely
			// for unambiguous .AppImage suffixes.
			if (candidate.endsWith('.AppImage')) {
				return { path: candidate, reason: 'matched .AppImage suffix' };
			}
			// Magic-byte sniff: ELF (`\x7fELF`) at offset 0, AppImage
			// type marker `AI\x02` at offset 8.
			const fh = await open(candidate, 'r');
			try {
				const buf = Buffer.alloc(12);
				await fh.read(buf, 0, 12, 0);
				const elf = buf.subarray(0, 4).toString('hex') === '7f454c46';
				const aiMagic = buf.subarray(8, 11);
				const isAppImage =
					elf &&
					aiMagic[0] === 0x41 &&
					aiMagic[1] === 0x49 &&
					(aiMagic[2] === 0x01 || aiMagic[2] === 0x02);
				if (isAppImage) {
					return {
						path: candidate,
						reason: 'matched AppImage magic bytes',
					};
				}
			} finally {
				await fh.close();
			}
		} catch {
			// fall through to next candidate
		}
	}

	return {
		path: null,
		reason:
			'no AppImage found via CLAUDE_DESKTOP_LAUNCHER or ' +
			`${testBuildDir}/*.AppImage`,
	};
}

async function captureFuseDpkg(): Promise<string> {
	// Best-effort context capture for the case-doc's listed
	// "Diagnostics on failure". `dpkg -l` is Debian-only — we still
	// run it and let it fail cleanly on RPM hosts (the empty/error
	// output is itself diagnostic).
	try {
		const { stdout, stderr } = await exec(
			'sh',
			['-c', 'dpkg -l 2>&1 | grep -i fuse || true'],
			{ timeout: 5_000 },
		);
		return `${stdout}${stderr}`.trim() || '(no fuse-related dpkg entries)';
	} catch (err) {
		const e = err as { stdout?: string; stderr?: string; code?: number };
		return (
			`dpkg query failed (exit ${e.code ?? '?'})\n` +
			`${(e.stdout ?? '').trim()}\n` +
			`${(e.stderr ?? '').trim()}`
		).trim();
	}
}

// Matches the dlopen failure pattern the AppImage runtime prints
// when libfuse2 is missing. The case-doc lists `libfuse.so.2` as the
// canonical token; we also flag the broader `dlopen` + `fuse`
// combination so a future runtime that changes the wording without
// fixing the underlying bug still trips the test.
function fuseFailureFound(stderr: string): { found: boolean; match?: string } {
	const lower = stderr.toLowerCase();
	if (lower.includes('libfuse.so.2')) {
		return { found: true, match: 'libfuse.so.2' };
	}
	// Both 'dlopen' and 'fuse' on the same line of stderr — wider net
	// for future-proofing.
	for (const line of stderr.split('\n')) {
		const ll = line.toLowerCase();
		if (ll.includes('dlopen') && ll.includes('fuse')) {
			return { found: true, match: line.trim() };
		}
	}
	return { found: false };
}

test.setTimeout(30_000);

test('S01 — AppImage launches without manual libfuse2t64', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Distribution / AppImage',
	});

	const probe = await probeAppImagePath();
	await testInfo.attach('appimage-probe', {
		body: JSON.stringify(probe, null, 2),
		contentType: 'application/json',
	});

	if (!probe.path) {
		test.skip(true, `S01 only applies to AppImage installs: ${probe.reason}`);
		return;
	}

	const appimagePath = probe.path;

	// Always-on context: dpkg fuse state. Cheap, useful for triage
	// regardless of pass/fail.
	const dpkgFuse = await captureFuseDpkg();
	await testInfo.attach('dpkg-fuse', {
		body: dpkgFuse,
		contentType: 'text/plain',
	});

	// Per-test sandbox so a brief Electron child doesn't pollute the
	// host's ~/.config/Claude. We don't use launchClaude()'s isolation
	// because it spawns the bundled Electron directly (bypassing the
	// AppImage runtime's FUSE mount, which is exactly what we're
	// trying to exercise here).
	const sandboxRoot = await mkdtemp(join(tmpdir(), 'claude-s01-'));
	const sandboxConfig = join(sandboxRoot, 'config');
	const sandboxHome = join(sandboxRoot, 'home');

	let exitCode: number | null = null;
	let signalCode: NodeJS.Signals | null = null;
	let timedOutBeforeFuseSignal = false;
	const stderrChunks: Buffer[] = [];
	const stdoutChunks: Buffer[] = [];
	const start = Date.now();

	try {
		const proc = spawn(appimagePath, [], {
			cwd: sandboxRoot,
			env: {
				...process.env,
				HOME: sandboxHome,
				XDG_CONFIG_HOME: sandboxConfig,
				XDG_DATA_HOME: join(sandboxRoot, 'data'),
				XDG_CACHE_HOME: join(sandboxRoot, 'cache'),
				// Surface FUSE mount errors loudly; the AppImage runtime
				// honours this for its diagnostic output.
				APPIMAGE_DEBUG: '1',
			},
			stdio: ['ignore', 'pipe', 'pipe'],
			detached: false,
		});

		proc.stderr?.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
		proc.stdout?.on('data', (chunk: Buffer) => stdoutChunks.push(chunk));

		// Race three outcomes:
		//   (a) process exits on its own (FUSE failure exits ~100-300ms)
		//   (b) we observed a FUSE error in stderr — kill early
		//   (c) timeout: app probably mounted fine and is starting up,
		//       in which case absence of FUSE error in stderr is a PASS
		const fuseSignal = new Promise<'fuse-error'>((resolve) => {
			const checkInterval = setInterval(() => {
				const so_far = Buffer.concat(stderrChunks).toString('utf8');
				if (fuseFailureFound(so_far).found) {
					clearInterval(checkInterval);
					resolve('fuse-error');
				}
			}, 100);
			proc.once('exit', () => clearInterval(checkInterval));
		});
		const exitSignal = new Promise<'exit'>((resolve) => {
			proc.once('exit', (code, signal) => {
				exitCode = code;
				signalCode = signal;
				resolve('exit');
			});
		});
		const timeoutSignal = new Promise<'timeout'>((resolve) => {
			setTimeout(() => {
				timedOutBeforeFuseSignal = true;
				resolve('timeout');
			}, 8_000);
		});

		const winner = await Promise.race([
			fuseSignal,
			exitSignal,
			timeoutSignal,
		]);

		// Whatever happened, kill the process so we don't leave
		// Electron running. SIGTERM first, SIGKILL backstop.
		if (proc.exitCode === null && proc.signalCode === null) {
			proc.kill('SIGTERM');
			await Promise.race([
				new Promise<void>((resolve) =>
					proc.once('exit', (code, signal) => {
						exitCode = code;
						signalCode = signal;
						resolve();
					}),
				),
				new Promise<void>((resolve) => setTimeout(resolve, 3_000)),
			]);
			if (proc.exitCode === null && proc.signalCode === null) {
				proc.kill('SIGKILL');
				await new Promise<void>((resolve) => {
					proc.once('exit', (code, signal) => {
						exitCode = code;
						signalCode = signal;
						resolve();
					});
					setTimeout(() => resolve(), 2_000);
				});
			}
		}

		await testInfo.attach('race-winner', {
			body: winner,
			contentType: 'text/plain',
		});
	} finally {
		await rm(sandboxRoot, { recursive: true, force: true }).catch(() => {});
	}

	const elapsedMs = Date.now() - start;
	const stderrFull = Buffer.concat(stderrChunks).toString('utf8');
	const stdoutFull = Buffer.concat(stdoutChunks).toString('utf8');
	const stderrTail =
		stderrFull.length > 4096 ? stderrFull.slice(-4096) : stderrFull;
	const stdoutTail =
		stdoutFull.length > 4096 ? stdoutFull.slice(-4096) : stdoutFull;

	const fuseCheck = fuseFailureFound(stderrFull);

	await testInfo.attach('appimage-path', {
		body: appimagePath,
		contentType: 'text/plain',
	});
	await testInfo.attach('exit-info', {
		body: JSON.stringify(
			{
				exitCode,
				signalCode,
				timedOutBeforeFuseSignal,
				elapsedMs,
				fuseFailureMatch: fuseCheck.match ?? null,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});
	await testInfo.attach('stderr-tail-4k', {
		body: stderrTail || '(empty)',
		contentType: 'text/plain',
	});
	await testInfo.attach('stdout-tail-4k', {
		body: stdoutTail || '(empty)',
		contentType: 'text/plain',
	});

	expect(
		fuseCheck.found,
		`AppImage stderr should not report a libfuse.so.2 dlopen failure ` +
			`(matched: ${fuseCheck.match ?? 'n/a'}). The case-doc S01 ` +
			`scenario fails on Ubuntu 24.04 unless libfuse2t64 is manually ` +
			`installed; see scripts/packaging/appimage.sh:226 for the ` +
			`upstream-runtime-as-is build choice.`,
	).toBe(false);
});
