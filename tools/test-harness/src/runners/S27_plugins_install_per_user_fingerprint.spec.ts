import { test, expect } from '@playwright/test';
import { readAsarFile, resolveAsarPath } from '../lib/asar.js';

// S27 — Plugins install per-user, not into system paths (file probe).
//
// Tier 1 file-level signal that plugin storage is rooted under the
// user's `~/.claude` tree, not under `/usr/share/...` or any other
// system-managed prefix. The full Tier 3 form — install a plugin
// end-to-end and `find /usr -newer /tmp/marker -name '*claude*'` to
// prove nothing landed system-wide — still lives in the case doc as
// a manual step. This spec catches the failure mode where an
// upstream refactor switches the resolver to a system path; the
// runtime install would still need a Tier 3 to catch a path that
// only diverges once the install actually runs.
//
// Three fingerprints, all targeting the SAME plugin storage code
// path documented in extensibility.md S27 anchors at
// `:283107` cE() and `:465815` dx() / `:465821` `installed_plugins.json`:
//
//   1. `installed_plugins.json` is in the bundle. This is the
//      idempotency record that `dx()` (= `cE() + "/plugins"`) sits
//      atop. Sibling assertion to T11; same surface, narrower claim.
//   2. The bundle contains a homedir+".claude" resolver pattern
//      (matches `cE()` at :283107 — `homedir(), ".claude"` paired
//      string-literally regardless of the minified function name).
//      Anchors the per-user claim independent of `cE()`'s rotating
//      identifier.
//   3. The bundle contains NO `/usr/share/claude/plugins`,
//      `/usr/share/claude-desktop/plugins`, `/etc/claude/plugins`,
//      or `/var/lib/claude/plugins` strings. (`/etc/claude-code`
//      and `/etc/claude/vertex-sa.json` exist for unrelated
//      subsystems — managed-settings lookup at :465788 and Vertex
//      AI fallback at :139930 — neither is the plugin store. The
//      forbidden list is scoped to `*/plugins` to avoid matching
//      those.)
//
// The "per-user" claim is structural: (1) confirms the bundle ships
// plugin storage at all, (2) confirms the resolver is homedir-based,
// (3) rules out the obvious system-path alternatives. Together they
// pin the Tier 1 surface; runtime confirmation stays in the case doc.
//
// Pure file probe — no app launch. Fast (<1s). Row-independent.

test('S27 — plugins install path resolves to ~/.claude, not system paths', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Plugin install / per-user storage',
	});

	const asarPath = resolveAsarPath();
	await testInfo.attach('asar-path', {
		body: asarPath,
		contentType: 'text/plain',
	});

	const indexJs = readAsarFile('.vite/build/index.js', asarPath);

	// (1) Plugin storage is in the bundle at all. `installed_plugins.json`
	//     is the idempotency record `dx()` writes — sibling fingerprint
	//     to T11 plugin-install, narrower claim here.
	const installedPluginsRecord = indexJs.includes(
		'installed_plugins.json',
	);

	// (2) Homedir-based resolver pattern — matches `cE()` at :283107
	//     (`homedir(), ".claude"`) without depending on the minified
	//     function name `cE`, which rotates every release. The regex
	//     tolerates the import alias on `os` (`yi` / `zc` etc.) by
	//     anchoring on the call shape `<ident>.homedir(),<ws>".claude"`.
	const homedirResolverRe = /\.homedir\(\)\s*,\s*"\.claude"/;
	const homedirResolverPresent = homedirResolverRe.test(indexJs);

	// (3) No system-path plugin store. Scoped to `*/plugins` so that
	//     unrelated /etc/claude-code (managed-settings) and
	//     /etc/claude/vertex-sa.json (Vertex AI fallback) don't trip
	//     this — neither is on the plugin install code path.
	const FORBIDDEN_SYSTEM_PATHS = [
		'/usr/share/claude/plugins',
		'/usr/share/claude-desktop/plugins',
		'/usr/lib/claude/plugins',
		'/usr/lib/claude-desktop/plugins',
		'/usr/local/share/claude/plugins',
		'/etc/claude/plugins',
		'/etc/claude-desktop/plugins',
		'/var/lib/claude/plugins',
		'/opt/Claude/plugins',
		'/opt/claude-desktop/plugins',
	];
	const systemPathHits = FORBIDDEN_SYSTEM_PATHS.filter((p) =>
		indexJs.includes(p),
	);

	await testInfo.attach('s27-evidence', {
		body: JSON.stringify(
			{
				installedPluginsRecord,
				homedirResolverPresent,
				homedirResolverRegex: homedirResolverRe.source,
				systemPathHits,
				forbiddenChecked: FORBIDDEN_SYSTEM_PATHS,
			},
			null,
			2,
		),
		contentType: 'application/json',
	});

	expect(
		installedPluginsRecord,
		'app.asar contains `installed_plugins.json` (plugin storage record at extensibility.md S27 anchor :465821)',
	).toBe(true);
	expect(
		homedirResolverPresent,
		'app.asar contains a `homedir(), ".claude"` resolver pattern (cE() at extensibility.md S27 anchor :283107)',
	).toBe(true);
	expect(
		systemPathHits,
		'app.asar contains no `*/plugins` system-path strings (S27 per-user-only invariant)',
	).toEqual([]);
});
