import { test, expect } from '@playwright/test';
import { join } from 'node:path';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';

// S25 — Mobile pairing survives Linux session restart (Tier 2 slice).
//
// Full S25 (case-doc platform-integration.md:250) is a Tier 3 mobile-
// pairing flow needing a paired phone. The Linux-side persistence
// half is independently testable: upstream caches the trusted-device
// token via `safeStorage.encryptString` (libsecret on Linux) so a
// successful pair survives restart without re-enrolling. The
// load-bearing contract on Linux is "encrypt-decrypt round-trip is
// stable across an Electron process restart against the system
// keyring backend." That's what this runner exercises.
//
// Code anchors (case-doc S25):
//   - index.js:511984 — ZEe = "coworkTrustedDeviceToken" electron-
//     store key for the trusted-device token.
//   - index.js:511989 — oYn() writes via safeStorage.encryptString
//     (libsecret on Linux); aYn() (:512003) decrypts on read.
//   - index.js:512022 — gYn() re-enrolls via POST /api/auth/
//     trusted_devices only when there's no cached token.
//
// Approach: bypass electron-store entirely. The store is incidental —
// what's load-bearing is that the keyring resolves the same encryption
// key between launches. We:
//   1. Fresh isolation handle (clean state — no seedFromHost; this
//      isn't an auth test).
//   2. Launch 1, check safeStorage.isEncryptionAvailable() (skip if
//      false — common on headless rows / no keyring backend).
//   3. Encrypt a known plaintext via safeStorage.encryptString, write
//      the ciphertext bytes to ${configDir}/test-token.bin, close.
//   4. Launch 2, read ${configDir}/test-token.bin, decrypt via
//      safeStorage.decryptString, assert decrypted text equals
//      plaintext.
//   5. Cleanup the isolation handle (we own it — passing it to
//      launchClaude doesn't transfer ownership).
//
// Why compare decrypted plaintext, not ciphertext: safeStorage on
// Linux uses libsecret-derived AES-128 with random IVs, so the same
// plaintext yields different ciphertext on re-encrypt. The round-
// trip is the contract — ciphertext equality isn't.

const PLAINTEXT = 'S25-trusted-device-token-' + Date.now();
const TOKEN_FILE_NAME = 'test-token.bin';

// Two launches at ~60s each plus settle / waitForReady budget.
test.setTimeout(180_000);

test('S25 — safeStorage token round-trip survives app restart', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Dispatch pairing persistence',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	// Fresh isolation, shared across both launches. No seedFromHost —
	// the keyring backend is process-scoped, not config-scoped, so a
	// signed-out clean isolation still exercises the same code path.
	const isolation: Isolation = await createIsolation();
	const tokenFile = join(isolation.configDir, TOKEN_FILE_NAME);

	let encryptionAvailable = false;
	let cipherLen = 0;

	try {
		// Launch 1: encrypt + write.
		const app1 = await launchClaude({ isolation });
		try {
			const { inspector } = await app1.waitForReady('mainVisible');

			encryptionAvailable = await inspector.evalInMain<boolean>(`
				const { safeStorage } = process.mainModule.require('electron');
				return safeStorage.isEncryptionAvailable();
			`);
			await testInfo.attach('encryption-available-launch1', {
				body: JSON.stringify({ encryptionAvailable }, null, 2),
				contentType: 'application/json',
			});

			if (!encryptionAvailable) {
				testInfo.skip(
					true,
					'safeStorage.isEncryptionAvailable() === false — no ' +
						'keyring backend on this row (libsecret/kwallet/' +
						'gnome-keyring not running, or running headless)',
				);
				return;
			}

			// Encrypt + write to tokenFile. base64-encode the ciphertext
			// for transport across the inspector boundary (evalInMain
			// returns JSON, and Buffers serialize as { type, data } —
			// base64 in/out is simpler and lossless).
			const writeResult = await inspector.evalInMain<{
				cipherLen: number;
				path: string;
			}>(`
				const { safeStorage } = process.mainModule.require('electron');
				const fs = process.mainModule.require('node:fs');
				const cipher = safeStorage.encryptString(${JSON.stringify(PLAINTEXT)});
				fs.mkdirSync(${JSON.stringify(isolation.configDir)}, {
					recursive: true,
				});
				fs.writeFileSync(${JSON.stringify(tokenFile)}, cipher);
				return { cipherLen: cipher.length, path: ${JSON.stringify(tokenFile)} };
			`);
			cipherLen = writeResult.cipherLen;
			await testInfo.attach('encrypt-and-write', {
				body: JSON.stringify(
					{
						plaintextPreview: PLAINTEXT,
						tokenFile: writeResult.path,
						cipherLen,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});

			// Sanity check: in-session round-trip. Catches the case where
			// safeStorage reports available but the backend is broken
			// (e.g. locked keyring with no unlock prompt). Without this,
			// a backend failure would surface as a launch-2 read error
			// that's harder to distinguish from a cross-restart break.
			const inSessionRoundTrip = await inspector.evalInMain<string>(`
				const { safeStorage } = process.mainModule.require('electron');
				const fs = process.mainModule.require('node:fs');
				const cipher = fs.readFileSync(${JSON.stringify(tokenFile)});
				return safeStorage.decryptString(cipher);
			`);
			expect(
				inSessionRoundTrip,
				'in-session encrypt+decrypt round-trip works',
			).toBe(PLAINTEXT);

			inspector.close();
		} finally {
			await app1.close();
		}

		// Launch 2: read + decrypt with the same isolation handle.
		const app2 = await launchClaude({ isolation });
		let decrypted: string | null = null;
		try {
			const { inspector } = await app2.waitForReady('mainVisible');

			const stillAvailable = await inspector.evalInMain<boolean>(`
				const { safeStorage } = process.mainModule.require('electron');
				return safeStorage.isEncryptionAvailable();
			`);
			await testInfo.attach('encryption-available-launch2', {
				body: JSON.stringify({ stillAvailable }, null, 2),
				contentType: 'application/json',
			});
			expect(
				stillAvailable,
				'safeStorage still available on launch 2',
			).toBe(true);

			decrypted = await inspector.evalInMain<string>(`
				const { safeStorage } = process.mainModule.require('electron');
				const fs = process.mainModule.require('node:fs');
				const cipher = fs.readFileSync(${JSON.stringify(tokenFile)});
				return safeStorage.decryptString(cipher);
			`);
			await testInfo.attach('decrypt-after-restart', {
				body: JSON.stringify(
					{
						tokenFile,
						cipherLen,
						decrypted,
						match: decrypted === PLAINTEXT,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});

			inspector.close();
		} finally {
			await app2.close();
		}

		expect(
			decrypted,
			'safeStorage.decryptString returned a value after restart',
		).not.toBeNull();
		expect(
			decrypted,
			'decrypted plaintext matches what was written before restart — ' +
				'keyring backend resolved the same encryption key across ' +
				'process restart',
		).toBe(PLAINTEXT);
	} finally {
		await isolation.cleanup();
	}
});
