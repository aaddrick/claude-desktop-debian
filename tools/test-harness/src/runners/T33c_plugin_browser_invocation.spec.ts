import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T33c — Plugin browser handlers invocable at runtime (Tier 2 Phase 2
// sibling of T33's Tier 1 asar fingerprint and T33b's Tier 2 handler-
// registration probe).
//
// Backs T33 in docs/testing/cases/extensibility.md ("Plugin browser
// opens, shows the marketplace, install completes"). T33 the Tier 1
// fingerprint asserts the channel-name strings are present in the
// bundle (`listMarketplaces`, `listAvailablePlugins`). T33b the Tier 2
// handler-registration probe asserts both are registered on the
// claude.ai webContents at runtime. T33c the Tier 2 invocation probe
// calls each and asserts the response is an array — strictly stronger
// than registration alone, since registration without the impl wired
// through (e.g. half-applied refactor where the registration block
// runs but the impl object is missing the method) would still pass
// T33b but fail T33c.
//
// Why both methods are load-bearing
// ---------------------------------
// `listMarketplaces` populates the marketplace selector in the plugin
// browser modal; `listAvailablePlugins` populates the per-marketplace
// plugin list. Either missing breaks the modal silently.
// `waitForEipcChannels` (plural) holds the pair against a single
// budget; per-method `invokeEipcChannel` runs sequentially with shape
// assertions.
//
// Arg shape (session 9 finding)
// -----------------------------
// Both handlers share a byte-identical hand-rolled validator (NOT Zod
// for the args — the result validator IS Zod, but it runs after the
// impl returns). Args are positional:
//   [0] egressAllowedDomains: string[]   — required, must be Array
//       with every element typeof "string"; empty array passes
//   [1] pluginContext: { mode: string, ...optional } | undefined
//                                        — optional
// `args = [[]]` is the minimal valid form: empty allow-list, omit
// pluginContext. The empty allow-list is the safety property — if the
// underlying impl is the CLI-shelling variant (spawns `claude plugin
// marketplace list --json` / `claude plugin list --json --available`),
// the egress allow-list is forwarded as the spawned subprocess's
// permitted domains, so `[]` blocks any network egress the CLI might
// attempt. The native impl variant just reads
// `knownMarketplacesFile` / scans `marketplacesDir` and ignores
// network entirely. Either variant is read-only.
//
// Runtime side effects
// --------------------
// Read-only by design — no installs, no fs writes to user content, no
// state mutations. The CLI variant spawns a `claude plugin ... list
// --json` subprocess (handler-side timeouts: 30s for marketplaces,
// 60s for plugins). On subprocess failure or `claude` CLI missing on
// PATH, the impl logs to Sentry and returns `[]`, so even a degraded
// host passes the array-shape assertion. The native variant performs a
// JSON file read off the per-account marketplaces store.
//
// Assertion shape
// ---------------
// Each invocation must return an array — no constraint on length or
// contents. Empty arrays (no marketplaces configured, fresh install,
// or CLI failure) all satisfy. Configured hosts return non-empty
// arrays. Strongest assertion that doesn't depend on host state OR
// which impl variant is active.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the wrapper isn't
// exposed (mirrors T33b / T35b / T37b / T27 pattern).
//
// Timeout budget
// --------------
// Worst case is sequential 30s + 60s CLI timeouts plus launch / login
// overhead, so 180s leaves margin without flaking on slow boxes. Most
// runs complete well under 30s (warm CLI or native variant active).

test.setTimeout(180_000);

const EXPECTED_SUFFIXES = [
	'CustomPlugins_$_listMarketplaces',
	'CustomPlugins_$_listAvailablePlugins',
] as const;

// Empty allow-list — both validators accept it and any spawned CLI is
// denied network. Omits the optional pluginContext entirely.
const INVOKE_ARGS: readonly unknown[] = [[]];

test('T33c — Plugin browser handlers invocable at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Plugin browser UI (eipc invocation)',
	});

	await testInfo.attach('session-env', {
		body: JSON.stringify(captureSessionEnv(), null, 2),
		contentType: 'application/json',
	});

	let isolation: Isolation;
	try {
		isolation = await createIsolation({ seedFromHost: true });
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		test.skip(true, `seedFromHost unavailable: ${msg}`);
		return;
	}

	const app = await launchClaude({ isolation });
	try {
		const ready = await app.waitForReady('userLoaded');
		await testInfo.attach('claude-ai-url', {
			body: ready.claudeAiUrl ?? '(no claude.ai webContents observed)',
			contentType: 'text/plain',
		});
		if (!ready.postLoginUrl) {
			test.skip(
				true,
				'seeded auth did not reach post-login URL — host config ' +
					'may be stale (signed out, expired session, etc.)',
			);
			return;
		}
		await testInfo.attach('post-login-url', {
			body: ready.postLoginUrl,
			contentType: 'text/plain',
		});

		// Confirm registration of both handlers first — surfaces
		// "registered but uninvocable" cleanly if the wrapper-exposure
		// gate flips (would still register on the per-wc registry, but
		// `window['claude.web']` namespace would be missing).
		const resolved = await waitForEipcChannels(
			ready.inspector,
			EXPECTED_SUFFIXES,
		);

		// Per-suffix invocation result for the diagnostic attachment.
		// Length only — never the body. Marketplace metadata is mostly
		// public, but per-account `pluginContext`-driven filtering can
		// surface internal-org marketplace pointers on configured-host
		// runs; defensive default mirrors T37b's type-and-length pattern.
		const invocations: Record<string, {
			channelResolved: unknown;
			responseShape: string;
			responseLength: number | null;
		}> = {};

		for (const suffix of EXPECTED_SUFFIXES) {
			const channel = resolved.get(suffix);
			let responseShape = 'not-invoked';
			let responseLength: number | null = null;
			if (channel) {
				const result = await invokeEipcChannel<unknown>(
					ready.inspector,
					suffix,
					INVOKE_ARGS,
				);
				if (Array.isArray(result)) {
					responseShape = `array(length=${result.length})`;
					responseLength = result.length;
				} else if (result === null) {
					responseShape = 'null';
				} else {
					responseShape = typeof result;
				}
				invocations[suffix] = {
					channelResolved: channel,
					responseShape,
					responseLength,
				};
				expect(
					Array.isArray(result),
					`[T33c] ${suffix} response is an array ` +
						`(got ${responseShape}) — case-doc anchor ` +
						':507176 lists marketplaces from the registry; ' +
						'the plugin browser modal consumes an array shape',
				).toBe(true);
			} else {
				invocations[suffix] = {
					channelResolved: null,
					responseShape,
					responseLength,
				};
			}
		}

		await testInfo.attach('plugin-browser-invocations', {
			body: JSON.stringify(
				{
					expectedSuffixes: EXPECTED_SUFFIXES,
					invokeArgs: INVOKE_ARGS,
					invocations,
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T33c] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the plugin ' +
					'browser populate flow (case-doc anchors index.js:71392 ' +
					'/ :71534 / :507176)',
			).not.toBeNull();
		}
	} finally {
		await app.close();
	}
});
