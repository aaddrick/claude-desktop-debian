import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannel } from '../lib/eipc.js';

// T35b — MCP server config handler invocable at runtime (Tier 2
// sibling of T35's Tier 1 asar fingerprint).
//
// Backs T35 in docs/testing/cases/extensibility.md ("MCP server config
// picked up"). T35 the Tier 1 fingerprint asserts the chat-tab vs
// Code-tab MCP-config separation is wired in the bundle (the four
// load-bearing strings: `claude_desktop_config.json`, `.claude.json`,
// `.mcp.json`, `"user","project","local"`). T35b the Tier 2 runtime
// probe asserts the read-side handler that exposes the parsed Code-tab
// MCP config — `claude.settings/MCP/getMcpServersConfig` — is
// registered AND callable through the eipc wrapper, returning a
// parseable record shape.
//
// Why the fingerprint is not enough
// ---------------------------------
// String presence in the bundle survives a half-applied refactor or a
// dead-code path. Runtime invocation proves the handler actually
// executed `e.ipc.handle(...)` during webContents init, the
// renderer-side wrapper at `window['claude.settings'].MCP.
// getMcpServersConfig` was exposed (i.e. the origin gate let the
// renderer claim claude.ai), and the impl returned the documented
// `Record<string, MCPServerConfig>` shape. If the wiring regresses
// (the `setImplementation` block throws on a side effect, the
// wrapper-exposure gate flips, the impl returns the wrong type), the
// fingerprint still passes but T35b fails.
//
// Why this works (session 8 finding)
// ----------------------------------
// `claude.settings/*` handlers register on the per-`webContents` IPC
// scope (`webContents.ipc._invokeHandlers`, Electron 17+) and are
// exposed to the renderer at `window['claude.settings'].<Iface>.
// <method>` by `mainView.js`'s `contextBridge.exposeInMainWorld` after
// passing `Qc()` (top-frame check + origin allow-list:
// `https://claude.ai`, `https://claude.com`, preview.*, localhost).
// `lib/eipc.ts`'s `invokeEipcChannel` calls through that wrapper via
// `inspector.evalInRenderer('claude.ai', ...)`, which runs against the
// claude.ai renderer where the wrapper is exposed.
//
// Assertion shape
// ---------------
// Empty-config (host has no `~/.claude.json` / `.mcp.json` MCP
// servers) returns `{}`; configured-host returns
// `Record<string, MCPServerConfig>`. The spec asserts the response is
// a plain object (not null, not undefined, not an array, not a
// primitive). That's the strongest assertion that doesn't depend on
// host MCP-config state — confirms the handler is wired AND
// invocable AND returns the documented record shape.
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the wrapper isn't
// exposed. Hosts with no signed-in Claude Desktop skip cleanly via
// `createIsolation`'s throw, mirroring T22b/T31b's pattern.
//
// The `seedFromHost` side effect (kills the running host Claude
// Desktop to release LevelDB / SQLite writer locks) is documented in
// `lib/host-claude.ts`. The host config dir itself is left untouched.

test.setTimeout(60_000);

const EXPECTED_SUFFIX = 'MCP_$_getMcpServersConfig';
// `forceReload: false` — case-doc-anchored bool arg shape; the
// validator accepts `null | boolean`. `false` keeps the call read-only
// (no re-read of `~/.claude.json` from disk).
const FORCE_RELOAD = false;

test('T35b — MCP config handler invocable at runtime', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'MCP / Code tab (eipc invocation)',
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

		// Wait for handler registration first — gives a clean
		// "registered but uninvocable" failure mode if the wrapper-
		// exposure gate has flipped (registration would still happen
		// on the per-wc registry; only the renderer-side wrapper would
		// be missing).
		const channel = await waitForEipcChannel(
			ready.inspector,
			EXPECTED_SUFFIX,
		);
		expect(
			channel,
			`[T35b] eipc channel ending in '${EXPECTED_SUFFIX}' is registered ` +
				'on the claude.ai webContents (case-doc anchor index.js:176766 ' +
				'~/.claude.json reader / :215418 .mcp.json scanner)',
		).not.toBeNull();

		const result = await invokeEipcChannel<unknown>(
			ready.inspector,
			EXPECTED_SUFFIX,
			[FORCE_RELOAD],
		);

		const shape = describeShape(result);
		await testInfo.attach('mcp-config-response', {
			body: JSON.stringify(
				{
					expectedSuffix: EXPECTED_SUFFIX,
					forceReload: FORCE_RELOAD,
					resolvedChannel: channel,
					responseShape: shape,
					// Truncate large responses — most users will have 0-5
					// MCP servers configured, but the case-doc allows
					// arbitrary growth and we don't want a test failure
					// to dump a 100KB response into the JUnit XML.
					responseSample: truncate(result, 4000),
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		expect(
			result,
			`[T35b] getMcpServersConfig response is non-null`,
		).not.toBeNull();
		expect(
			result,
			`[T35b] getMcpServersConfig response is defined`,
		).not.toBeUndefined();
		expect(
			typeof result,
			`[T35b] getMcpServersConfig response is an object ` +
				`(got ${typeof result})`,
		).toBe('object');
		expect(
			Array.isArray(result),
			`[T35b] getMcpServersConfig response is a record, not an array ` +
				`— case-doc anchor :176766 reads ~/.claude.json into a ` +
				`name-keyed map`,
		).toBe(false);
	} finally {
		await app.close();
	}
});

// Describe the response shape without dumping its full contents.
// Useful for diagnostic attachments where the actual MCP config might
// hold tokens or PII a user wouldn't want in the JUnit log.
function describeShape(value: unknown): string {
	if (value === null) return 'null';
	if (value === undefined) return 'undefined';
	if (Array.isArray(value)) return `array(length=${value.length})`;
	if (typeof value === 'object') {
		const keys = Object.keys(value as Record<string, unknown>);
		return `object(keys=${keys.length}, sample=${JSON.stringify(
			keys.slice(0, 5),
		)})`;
	}
	return `${typeof value}(${JSON.stringify(value).slice(0, 60)})`;
}

function truncate(value: unknown, max: number): unknown {
	const s = JSON.stringify(value);
	if (!s || s.length <= max) return value;
	return `${s.slice(0, max)}…(truncated, total=${s.length})`;
}
