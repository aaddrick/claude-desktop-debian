import { test, expect } from '@playwright/test';
import { launchClaude } from '../lib/electron.js';
import { createIsolation, type Isolation } from '../lib/isolation.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import { invokeEipcChannel, waitForEipcChannels } from '../lib/eipc.js';

// T11 — Plugin install (Anthropic & Partners) IPC surface registered +
// install-flow read-side handlers invocable (Tier 2 reframe of the
// case-doc claim "Click Install → Anthropic & Partners plugin lands in
// Manage plugins → re-install is idempotent").
//
// Sibling to T11_plugin_install_fingerprint.spec.ts — the Tier 1 spec
// asserts the install code path's two case-doc string literals are in
// the bundle (`[CustomPlugins] installPlugin: attempting remote API
// install` at index.js:507193 and `installed_plugins.json` at :465822).
// This Tier 2 spec promotes from "the install code is in the bundle" to
// "the install handlers register at runtime AND the read-sides that
// drive Manage plugins / idempotency-record return the documented
// shapes". A half-applied refactor where the bundle still contains the
// strings but the handlers no longer register / the impl object is
// missing methods would pass Tier 1 and fail Tier 2.
//
// Backs T11 in docs/testing/cases/extensibility.md ("Plugin install
// (Anthropic & Partners)"). Session 7's per-interface registry walk
// listed CustomPlugins (16 methods) and LocalPlugins (15 methods) on
// the claude.ai webContents. Session 12's smoke-test against the
// debugger-attached running Claude confirmed:
//   - `CustomPlugins.listInstalledPlugins(egressAllowedDomains)`
//     accepts `[[]]` (empty allow-list) and returns `Array<…>` (length
//     0 on dev box's host config — no plugins installed).
//   - `LocalPlugins.getPlugins()` accepts `[]` and returns `Array<…>`
//     (length 0 on dev box — `~/.claude/plugins/installed_plugins.json`
//     absent or empty). Same arg-validator-empty pattern as T19/T20's
//     `LocalSessions.getAll`.
//
// Why both layers — registration AND invocation
// ---------------------------------------------
// Registration of the 5 install-flow suffixes proves the lifecycle is
// wired (install / uninstall / update + the two read-sides that drive
// the UX). Invocation of `listInstalledPlugins` (the CustomPlugins-
// side "Manage plugins" reader) and `getPlugins` (the LocalPlugins-
// side `~/.claude/plugins/installed_plugins.json` reader) proves both
// halves of the install flow's read-sides are reachable through the
// renderer wrapper and return arrays. Dual-invocation across two
// distinct interfaces (CustomPlugins + LocalPlugins) gives strictly
// stronger coverage than the single-interface T21 / T33c pattern —
// proves the install plumbing crosses both impl objects intact.
//
// Why these 5 registration suffixes
// ---------------------------------
// The plugin install case-doc maps to:
//   1. Click "Install" → `CustomPlugins.installPlugin` (case-doc
//      anchor :507181, primary write-side).
//   2. "Lands in Manage plugins" → `CustomPlugins.listInstalledPlugins`
//      (read-side, what populates the Manage plugins panel).
//   3. "Re-install is idempotent" → `installPlugin` again, with the
//      idempotency mechanism backed by `LocalPlugins.getPlugins`
//      reading `~/.claude/plugins/installed_plugins.json` (case-doc
//      anchor :465822 + :465816).
// Plus the install-lifecycle complements `uninstallPlugin` and
// `updatePlugin` for register-only drift coverage — a build that ships
// `installPlugin` without its lifecycle siblings would be a half-
// applied refactor, and registration probes are cheap. All five must
// register; partial registration breaks the case-doc claim.
//
// Why these 2 invocation targets
// ------------------------------
// Both `CustomPlugins.listInstalledPlugins(egressAllowedDomains) →
// Array<Plugin>` and `LocalPlugins.getPlugins() → Array<Plugin>` are
// pure read-side handlers — no fs writes, no network egress, no
// process spawn. The empty `egressAllowedDomains = []` arg follows
// T33c's pattern (the safety property is that the empty allow-list
// blocks all network access if the underlying impl shells out to the
// CLI — for `listInstalledPlugins` the local-only path is used and
// the allow-list is effectively a no-op). `getPlugins` takes no args
// and reads `~/.claude/plugins/` directly. Mixed-arg-shape dual
// invocation is fine — same pattern as T21 (one handler takes a `cwd`
// string, another doesn't).
//
// Read-only by design — neither handler mutates user state. Dev-box
// observation: both return empty arrays (no plugins installed on the
// harness's `~/.claude/plugins/` tree).
//
// Skip semantics
// --------------
// `seedFromHost: true` is required — without a signed-in claude.ai,
// the renderer never reaches claude.ai origin and the CustomPlugins /
// LocalPlugins wrappers aren't exposed (mirrors T19 / T20 / T21 /
// T22b / T31b / T33b / T33c / T35b / T37b / T38b pattern).

test.setTimeout(90_000);

const EXPECTED_SUFFIXES = [
	// case-doc anchor :507181 — primary install write-side
	'CustomPlugins_$_installPlugin',
	// install-lifecycle complement
	'CustomPlugins_$_uninstallPlugin',
	// install-lifecycle complement (re-install vs update path)
	'CustomPlugins_$_updatePlugin',
	// T11 step 3 — "lands in Manage plugins" read-side, also invoked
	'CustomPlugins_$_listInstalledPlugins',
	// T11 step 4 idempotency-record reader (case-doc :465822 / :465816),
	// also invoked
	'LocalPlugins_$_getPlugins',
] as const;

// `egressAllowedDomains` arg shape on CustomPlugins.listInstalledPlugins:
// positional `string[]` at position 0. Hand-rolled validator (NOT Zod)
// per session 9's CustomPlugins finding — `Array.isArray(r) && r.every(a
// => typeof a === "string")`. Empty array passes; the impl forwards the
// allow-list to any spawned subprocess, so `[]` is the "block all
// network egress" path. Smoke-tested session 12 against debugger-
// attached running Claude.
const LIST_INSTALLED_ARGS = [[]] as const;

test('T11 — Plugin install IPC surface + install-flow read-sides invocable', async (
	{},
	testInfo,
) => {
	testInfo.annotations.push({ type: 'severity', description: 'Critical' });
	testInfo.annotations.push({
		type: 'surface',
		description:
			'Plugin install / extensibility (eipc registration + invocation)',
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

		const resolved = await waitForEipcChannels(
			ready.inspector,
			EXPECTED_SUFFIXES,
		);

		// Invoke `CustomPlugins.listInstalledPlugins` — array of
		// installed plugins (CustomPlugins side, drives the Manage
		// plugins panel). Plugin entries may include user-account-scoped
		// metadata (workspace paths, plugin IDs that reveal org-internal
		// marketplace pointers when the user is in an org); log length
		// only, never bodies (mirrors T19/T20/T21/T33c/T37b's defensive
		// default).
		let listInstalledShape = 'not-invoked';
		let listInstalledLength: number | null = null;
		const listInstalledResult = await invokeEipcChannel<unknown>(
			ready.inspector,
			'CustomPlugins_$_listInstalledPlugins',
			LIST_INSTALLED_ARGS,
		);
		if (Array.isArray(listInstalledResult)) {
			listInstalledShape = `array(length=${listInstalledResult.length})`;
			listInstalledLength = listInstalledResult.length;
		} else if (listInstalledResult === null) {
			listInstalledShape = 'null';
		} else {
			listInstalledShape = typeof listInstalledResult;
		}

		// Invoke `LocalPlugins.getPlugins` — array of locally-known
		// plugins (LocalPlugins side, reads
		// `~/.claude/plugins/installed_plugins.json` which is the
		// idempotency record per case-doc anchor :465822). Same length-
		// only logging.
		let getPluginsShape = 'not-invoked';
		let getPluginsLength: number | null = null;
		const getPluginsResult = await invokeEipcChannel<unknown>(
			ready.inspector,
			'LocalPlugins_$_getPlugins',
			[],
		);
		if (Array.isArray(getPluginsResult)) {
			getPluginsShape = `array(length=${getPluginsResult.length})`;
			getPluginsLength = getPluginsResult.length;
		} else if (getPluginsResult === null) {
			getPluginsShape = 'null';
		} else {
			getPluginsShape = typeof getPluginsResult;
		}

		const registration: Record<string, unknown> = {};
		for (const suffix of EXPECTED_SUFFIXES) {
			registration[suffix] = resolved.get(suffix);
		}

		await testInfo.attach('t11-runtime', {
			body: JSON.stringify(
				{
					expectedRegistrationSuffixes: EXPECTED_SUFFIXES,
					registration,
					invocations: [
						{
							suffix: 'CustomPlugins_$_listInstalledPlugins',
							args: LIST_INSTALLED_ARGS,
							responseShape: listInstalledShape,
							responseLength: listInstalledLength,
						},
						{
							suffix: 'LocalPlugins_$_getPlugins',
							args: [],
							responseShape: getPluginsShape,
							responseLength: getPluginsLength,
						},
					],
				},
				null,
				2,
			),
			contentType: 'application/json',
		});

		for (const suffix of EXPECTED_SUFFIXES) {
			expect(
				resolved.get(suffix),
				`[T11] eipc channel ending in '${suffix}' is registered on ` +
					'the claude.ai webContents — load-bearing for the plugin ' +
					'install flow (case-doc anchors index.js:507181 / :465816 / ' +
					':465822)',
			).not.toBeNull();
		}

		expect(
			Array.isArray(listInstalledResult),
			`[T11] CustomPlugins/listInstalledPlugins response is an array ` +
				`(got ${listInstalledShape}) — drives the Manage plugins ` +
				'panel readout; an array result (empty or non-empty) proves ' +
				'the CustomPlugins impl object is reachable through the ' +
				'renderer wrapper and the install-side listing endpoint is wired',
		).toBe(true);

		expect(
			Array.isArray(getPluginsResult),
			`[T11] LocalPlugins/getPlugins response is an array ` +
				`(got ${getPluginsShape}) — reads the local plugin tree ` +
				'(`~/.claude/plugins/installed_plugins.json` per case-doc ' +
				':465822); an array result proves the LocalPlugins impl ' +
				'object is reachable and the idempotency-record read path ' +
				'is wired',
		).toBe(true);
	} finally {
		await app.close();
	}
});
