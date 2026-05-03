// Generate the U01 UI-visibility Playwright spec from the captured
// inventory at docs/testing/ui-inventory.json. Reads the inventory +
// its meta sidecar offline (no live app needed), groups entries by
// canonical surface, and emits a single .spec.ts file with one
// `test()` per inventory entry under one `test.describe()` per
// surface.
//
// The generated spec asserts each entry's recorded fingerprint still
// resolves to a visible element on the live signed-in renderer. It's
// the inventory's "do these things still render" sibling — H05
// detects shape drift across snapshots, U01 detects per-entry render
// failures across the whole inventory.
//
// Pure file in/out: no network, no inspector. The spec it emits is
// where the live app gets touched. Run via `npm run gen:render-specs`.
//
// Refuses to operate on a stale walker version or a partial inventory
// — generating a passing spec from a half-walked DOM would silently
// shrink the assertion surface to whatever the walker happened to
// reach before crashing.

import {
	existsSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { WALKER_VERSION } from './walker.js';
import type { Inventory, InventoryEntry, NavStep } from './walker.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const TESTING_DIR = resolve(HERE, '..', '..', '..', 'docs', 'testing');
const DEFAULT_INVENTORY = resolve(TESTING_DIR, 'ui-inventory.json');
const DEFAULT_META = resolve(TESTING_DIR, 'ui-inventory.meta.json');
const DEFAULT_OUTPUT = resolve(
	HERE,
	'..',
	'src',
	'runners',
	'U01_ui_visibility.spec.ts',
);

interface MetaSidecar {
	walkerVersion: string;
	partial: boolean;
	capturedAt: string;
	appVersion: string;
}

interface CliOpts {
	inventory: string;
	output: string;
	help: boolean;
}

function parseCli(argv: string[]): CliOpts {
	const opts: CliOpts = {
		inventory: DEFAULT_INVENTORY,
		output: DEFAULT_OUTPUT,
		help: false,
	};
	for (let i = 0; i < argv.length; i += 1) {
		const a = argv[i]!;
		switch (a) {
			case '-h':
			case '--help':
				opts.help = true;
				break;
			case '--inventory': {
				const v = argv[++i];
				if (!v) {
					process.stderr.write('--inventory requires a path\n');
					process.exit(1);
				}
				opts.inventory = resolve(v);
				break;
			}
			case '--output': {
				const v = argv[++i];
				if (!v) {
					process.stderr.write('--output requires a path\n');
					process.exit(1);
				}
				opts.output = resolve(v);
				break;
			}
			default:
				process.stderr.write(`gen-render-specs: unknown argument: ${a}\n`);
				printUsage();
				process.exit(1);
		}
	}
	return opts;
}

function printUsage(): void {
	process.stdout.write(
		'Usage: tsx explore/gen-render-specs.ts [options]\n' +
			'\n' +
			'Generates src/runners/U01_ui_visibility.spec.ts from\n' +
			'docs/testing/ui-inventory.json. Refuses to run if the inventory\n' +
			'is partial or was produced by a walker older than v' +
			WALKER_VERSION +
			'.\n' +
			'\n' +
			'Options:\n' +
			'  --inventory <path>  Override default inventory path\n' +
			'                      (default: docs/testing/ui-inventory.json)\n' +
			'  --output <path>     Override default spec output path\n' +
			'                      (default: src/runners/U01_ui_visibility.spec.ts)\n' +
			'  -h, --help          Print this help and exit\n',
	);
}

function loadInventory(path: string): Inventory {
	if (!existsSync(path)) {
		process.stderr.write(`gen-render-specs: inventory not found: ${path}\n`);
		process.exit(1);
	}
	try {
		return JSON.parse(readFileSync(path, 'utf8')) as Inventory;
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		process.stderr.write(`gen-render-specs: failed to parse inventory: ${msg}\n`);
		process.exit(1);
	}
}

function loadMeta(invPath: string): MetaSidecar {
	const metaPath = invPath.replace(/\.json$/, '.meta.json');
	const fallbackPath =
		invPath === DEFAULT_INVENTORY ? DEFAULT_META : metaPath;
	const path = existsSync(metaPath) ? metaPath : fallbackPath;
	if (!existsSync(path)) {
		process.stderr.write(
			`gen-render-specs: meta sidecar not found at ${metaPath} ` +
				'(needed for partial/walkerVersion gating)\n',
		);
		process.exit(1);
	}
	try {
		return JSON.parse(readFileSync(path, 'utf8')) as MetaSidecar;
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		process.stderr.write(`gen-render-specs: failed to parse meta: ${msg}\n`);
		process.exit(1);
	}
}

// Refuse on stale walker versions or partial inventories. The point of
// this generator is to emit a spec that asserts the FULL inventory
// renders; gating on these two flags is what stops a half-walked
// checkpoint from quietly shrinking the assertion set.
function validate(inv: Inventory, meta: MetaSidecar): void {
	const seen = Number.parseInt(inv.walkerVersion, 10);
	const required = Number.parseInt(WALKER_VERSION, 10);
	if (Number.isNaN(seen) || seen < required) {
		process.stderr.write(
			`gen-render-specs: walkerVersion ${inv.walkerVersion} < ${WALKER_VERSION}; ` +
				'inventory shape may be incompatible. Re-walk with the current ' +
				'explore CLI before regenerating the spec.\n',
		);
		process.exit(1);
	}
	if (meta.partial === true) {
		process.stderr.write(
			'gen-render-specs: inventory meta reports partial=true (walk did ' +
				'not finish). Refusing to generate a spec from a half-walked DOM ' +
				'— complete the walk first or pass --inventory to a known-good file.\n',
		);
		process.exit(1);
	}
}

// Deterministic surface→entries grouping. Sort surfaces alphabetically
// and entries within each surface by id, so a re-run produces an
// identical spec file when the inventory hasn't changed (the file is
// checked in; no-op regeneration shouldn't mint diffs).
function groupBySurface(
	entries: InventoryEntry[],
): { surface: string; entries: InventoryEntry[] }[] {
	const buckets = new Map<string, InventoryEntry[]>();
	for (const e of entries) {
		const list = buckets.get(e.surface) ?? [];
		list.push(e);
		buckets.set(e.surface, list);
	}
	const surfaces = [...buckets.keys()].sort();
	return surfaces.map((surface) => {
		const list = buckets.get(surface)!.slice();
		list.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
		return { surface, entries: list };
	});
}

// Strip any navigationPath step that would CLICK the entry under
// test, when that entry is denylisted. Per the spec brief: never click
// denylisted controls, just assert they exist. In practice the
// recorded path's last click is the surface-opener (entry's own id is
// `surface.role.label`, distinct from any path step), so this filter
// usually no-ops — but it's the safety net the brief calls for.
function safeNavigationPath(entry: InventoryEntry): NavStep[] {
	if (!entry.denylisted) return entry.navigationPath;
	return entry.navigationPath.filter(
		(s) => !(s.action === 'click' && s.id === entry.id),
	);
}

// JS string literal for embedding in generated source. Use JSON.stringify
// — handles all the escapes (backslash, quotes, newlines, unicode) that
// hand-rolling would miss on entries with weird labels.
function js(value: unknown): string {
	return JSON.stringify(value);
}

// Sanitize a surface name into a `test.describe()` block label that
// reads cleanly. Surfaces are dot-separated paths like
// `root.button.search.option.x`; the raw form is fine for grouping
// but we annotate the count so the report shows scope at a glance.
function describeLabel(surface: string, count: number): string {
	return `surface: ${surface} (${count} ${count === 1 ? 'entry' : 'entries'})`;
}

function testTitle(entry: InventoryEntry): string {
	const tags: string[] = [entry.kind];
	if (entry.denylisted) tags.push('denylist');
	const tagStr = tags.length ? ` [${tags.join(',')}]` : '';
	return `${entry.id}${tagStr} — ${entry.role}: ${entry.label}`;
}

function generateSpec(
	inv: Inventory,
	meta: MetaSidecar,
	groups: { surface: string; entries: InventoryEntry[] }[],
): string {
	const out: string[] = [];
	out.push(
		'// AUTO-GENERATED FROM docs/testing/ui-inventory.json',
		'// DO NOT EDIT — regenerate with `npm run gen:render-specs`',
		`// Source inventory: walker v${inv.walkerVersion} (account-portable ariaPath ` +
			`fingerprints), captured ${inv.capturedAt}, app ${inv.appVersion}`,
		`// Entries: ${inv.totalElements} ` +
			`(${inv.deniedActions} denylisted), ` +
			`${groups.length} surfaces`,
		`// Meta: partial=${meta.partial}`,
		'',
		"import { test, expect } from '@playwright/test';",
		'',
		"import { launchClaude } from '../lib/electron.js';",
		"import type { ClaudeApp } from '../lib/electron.js';",
		"import { createIsolation } from '../lib/isolation.js';",
		"import { InspectorClient } from '../lib/inspector.js';",
		"import { captureSessionEnv } from '../lib/diagnostics.js';",
		'import {',
		'\tcurrentUrl,',
		'\tfindByFingerprint,',
		'\tredrivePath,',
		'\twaitForStable,',
		"} from '../../explore/walker.js';",
		"import type { InventoryEntry } from '../../explore/walker.js';",
		'',
		'// U01 — UI visibility sweep.',
		'//',
		'// One Playwright test per inventory entry. Each test re-drives the',
		"// entry's recorded navigationPath against the live signed-in",
		"// renderer, then asserts the entry's fingerprint resolves to a",
		'// visible element. The full inventory acts as a render contract:',
		'// any entry that no longer renders (selector drift, route change,',
		'// permission change) shows up as exactly one failed test, with the',
		'// triage payload (entry JSON + observed DOM neighbourhood)',
		'// attached to that test only.',
		'//',
		'// Skip semantics mirror H05: the suite skips cleanly if the host',
		"// isn't signed in (claude.ai webContents never reaches the",
		"// userLoaded level). Default path: kill any running host Claude,",
		"// copy the auth-relevant subset of ~/.config/Claude into a",
		"// hermetic tmpdir, and launch against that copy. Host config is",
		"// left untouched after the kill+seed. CLAUDE_TEST_USE_HOST_CONFIG=1",
		"// opts out and shares the host's actual config directory (no",
		"// kill+seed) — use only when you've manually closed the host first.",
		'//',
		"// Denylisted entries: we still assert they render, but the",
		"// generator strips any navigationPath step that would CLICK the",
		'// denylisted entry itself. Per the spec brief: never trigger',
		'// destructive controls from a render check.',
		'//',
		'// Persistent entries: each persistent entry is asserted on its',
		'// canonical surface only (the `surface` field). The cross-surface',
		'// `surfaces[]` list is intentionally unused here — a strict',
		'// "renders on every surface it was observed" mode is a future',
		'// follow-up.',
		'//',
		'// Instance entries: assert that AT LEAST ONE element matching the',
		"// fingerprint exists. We don't assert the recorded instanceCount",
		'// — list lengths legitimately fluctuate across sessions.',
		'',
		"// Per-test budget covers a path redrive (~1 nav + ~N clicks * 1.5s)",
		'// plus a fingerprint resolve. Generous to ride out a slow first',
		'// route load; later tests in the same suite reuse the warmed app.',
		'test.setTimeout(120_000);',
		'',
		'const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === \'1\';',
		'',
		"// Single shared launch + inspector across the whole suite. N",
		'// tests at one launch each would burn 30+ minutes on cold-start',
		'// alone. We pay for setup once, then each test re-drives from the',
		'// recorded startUrl so prior-test side effects (open menus, route',
		'// changes) get reset before the next assertion runs.',
		'let app: ClaudeApp | null = null;',
		'let sharedInspector: InspectorClient | null = null;',
		'let sharedStartUrl: string | null = null;',
		'let suiteSkipReason: string | null = null;',
		'',
		"test.describe('U01 — UI visibility sweep (auto-generated)', () => {",
		'\ttest.beforeAll(async () => {',
		'\t\t// Default path: kill any host Claude, copy auth-relevant',
		"\t\t// subset of ~/.config/Claude into a hermetic tmpdir, launch",
		"\t\t// against that copy. Host config is left untouched after the",
		"\t\t// kill+seed. CLAUDE_TEST_USE_HOST_CONFIG=1 opts out — shares",
		"\t\t// the host's actual config directory (no kill+seed); use only",
		"\t\t// when you've manually closed the host first.",
		'\t\tif (useHostConfig) {',
		'\t\t\tapp = await launchClaude({ isolation: null });',
		'\t\t} else {',
		'\t\t\tconst seeded = await createIsolation({ seedFromHost: true });',
		'\t\t\tapp = await launchClaude({ isolation: seeded });',
		'\t\t}',
		"\t\tconst ready = await app.waitForReady('userLoaded');",
		'\t\tif (!ready.postLoginUrl) {',
		"\t\t\tsuiteSkipReason = 'claude.ai never reached a post-login URL — host ' +",
		"\t\t\t\t'profile is not signed in. Sign in via the host app first.';",
		'\t\t\treturn;',
		'\t\t}',
		'\t\tsharedInspector = ready.inspector;',
		'\t\tsharedStartUrl = await currentUrl(sharedInspector);',
		'\t\tawait waitForStable(sharedInspector);',
		'\t});',
		'',
		'\ttest.afterAll(async () => {',
		'\t\tif (sharedInspector) {',
		'\t\t\ttry {',
		'\t\t\t\tsharedInspector.close();',
		'\t\t\t} catch {',
		'\t\t\t\t// inspector may already be closed by app.close()',
		'\t\t\t}',
		'\t\t\tsharedInspector = null;',
		'\t\t}',
		'\t\tif (app) {',
		'\t\t\tawait app.close();',
		'\t\t\tapp = null;',
		'\t\t}',
		'\t});',
		'',
		'\t// why: shared per-test runner. Each generated `test()` packs the',
		'\t// entry as a literal and calls this — keeps the file scannable',
		'\t// (one block per entry) without duplicating the assertion logic',
		"\t// 383 times. Throws on its own when the suite was skipped so",
		"\t// each test's status reflects the actual render check, not a",
		'\t// mis-attributed setup failure.',
		'\tasync function runEntry(',
		'\t\tentry: InventoryEntry,',
		"\t\ttestInfo: import('@playwright/test').TestInfo,",
		'\t): Promise<void> {',
		'\t\tif (suiteSkipReason) {',
		'\t\t\ttestInfo.skip(true, suiteSkipReason);',
		'\t\t\treturn;',
		'\t\t}',
		'\t\tif (!sharedInspector || !sharedStartUrl) {',
		'\t\t\tthrow new Error(',
		"\t\t\t\t'U01: beforeAll did not initialize the inspector — check the ' +",
		"\t\t\t\t\t'session-env attachment for the launch failure.',",
		'\t\t\t);',
		'\t\t}',
		"\t\ttestInfo.annotations.push({ type: 'severity', description: 'Should' });",
		'\t\ttestInfo.annotations.push({',
		"\t\t\ttype: 'surface',",
		'\t\t\tdescription: entry.surface,',
		'\t\t});',
		'\t\ttestInfo.annotations.push({',
		"\t\t\ttype: 'kind',",
		'\t\t\tdescription: entry.kind,',
		'\t\t});',
		'',
		'\t\ttry {',
		'\t\t\tawait redrivePath(sharedInspector, sharedStartUrl, entry.navigationPath);',
		'\t\t} catch (err) {',
		'\t\t\tconst msg = err instanceof Error ? err.message : String(err);',
		"\t\t\tawait testInfo.attach('redrive-failure', {",
		'\t\t\t\tbody: JSON.stringify(',
		'\t\t\t\t\t{',
		'\t\t\t\t\t\tentry,',
		'\t\t\t\t\t\terror: msg,',
		'\t\t\t\t\t\tnote:',
		"\t\t\t\t\t\t\t'redrivePath threw before we could assert visibility — ' +",
		"\t\t\t\t\t\t\t'usually a stale fingerprint along the path. Re-walk the ' +",
		"\t\t\t\t\t\t\t'inventory and regenerate.',",
		'\t\t\t\t\t},',
		'\t\t\t\t\tnull,',
		'\t\t\t\t\t2,',
		'\t\t\t\t),',
		"\t\t\t\tcontentType: 'application/json',",
		'\t\t\t});',
		'\t\t\tthrow err;',
		'\t\t}',
		'\t\tawait waitForStable(sharedInspector);',
		'',
		'\t\tconst result = await findByFingerprint(',
		'\t\t\tsharedInspector,',
		'\t\t\tentry.fingerprint,',
		'\t\t\tentry.kind,',
		'\t\t);',
		'\t\tif (!result.found) {',
		"\t\t\tawait testInfo.attach('fingerprint-miss', {",
		'\t\t\t\tbody: JSON.stringify(',
		'\t\t\t\t\t{',
		'\t\t\t\t\t\tentry,',
		'\t\t\t\t\t\treason: result.reason,',
		'\t\t\t\t\t\tobservedOuterHTML: result.outerHTMLSnippet,',
		'\t\t\t\t\t},',
		'\t\t\t\t\tnull,',
		'\t\t\t\t\t2,',
		'\t\t\t\t),',
		"\t\t\t\tcontentType: 'application/json',",
		'\t\t\t});',
		'\t\t}',
		"\t\t// Soft drift: primary aria-tree match failed but a relaxed-",
		"\t\t// scope fallback recovered. Test still passes — but a",
		"\t\t// drift-warning attachment surfaces it so the sweep summary",
		"\t\t// can flag re-walk before drift compounds.",
		'\t\tif (result.found && result.drift) {',
		"\t\t\tawait testInfo.attach('drift-warning', {",
		'\t\t\t\tbody: JSON.stringify(',
		'\t\t\t\t\t{',
		'\t\t\t\t\t\tentryId: entry.id,',
		'\t\t\t\t\t\texpected: entry.fingerprint.ariaPath,',
		'\t\t\t\t\t\tmatchedVia: result.strategy,',
		'\t\t\t\t\t\tdrift: result.drift,',
		"\t\t\t\t\t\tnote:",
		"\t\t\t\t\t\t\t'primary aria-tree match failed; recovered via fallback. ' +",
		"\t\t\t\t\t\t\t'Re-walk inventory before drift compounds.',",
		'\t\t\t\t\t},',
		'\t\t\t\t\tnull,',
		'\t\t\t\t\t2,',
		'\t\t\t\t),',
		"\t\t\t\tcontentType: 'application/json',",
		'\t\t\t});',
		"\t\t\ttestInfo.annotations.push({",
		"\t\t\t\ttype: 'drift',",
		'\t\t\t\tdescription: result.strategy ?? \'unknown\',',
		'\t\t\t});',
		'\t\t}',
		'\t\texpect(',
		'\t\t\tresult.found,',
		'\t\t\t`fingerprint did not resolve: ${result.reason ?? \'unknown\'}`,',
		'\t\t).toBe(true);',
		'\t}',
		'',
		'\ttest.beforeAll(async ({}, testInfo) => {',
		"\t\tawait testInfo.attach('session-env', {",
		'\t\t\tbody: JSON.stringify(captureSessionEnv(), null, 2),',
		"\t\t\tcontentType: 'application/json',",
		'\t\t});',
		'\t});',
		'',
	);

	// One describe per surface, one test per entry. Strings are
	// JSON-encoded so labels with quotes/backticks/unicode survive.
	for (const group of groups) {
		out.push(
			`\ttest.describe(${js(describeLabel(group.surface, group.entries.length))}, () => {`,
		);
		for (const entry of group.entries) {
			const safe: InventoryEntry = {
				...entry,
				navigationPath: safeNavigationPath(entry),
			};
			out.push(
				`\t\ttest(${js(testTitle(entry))}, async ({}, testInfo) => {`,
				`\t\t\tconst entry: InventoryEntry = ${js(safe)};`,
				'\t\t\tawait runEntry(entry, testInfo);',
				'\t\t});',
			);
		}
		out.push('\t});', '');
	}

	out.push('});', '');
	return out.join('\n');
}

function atomicWrite(path: string, body: string): void {
	const tmp = `${path}.tmp`;
	writeFileSync(tmp, body, 'utf8');
	renameSync(tmp, path);
}

function main(): void {
	const opts = parseCli(process.argv.slice(2));
	if (opts.help) {
		printUsage();
		return;
	}
	const inv = loadInventory(opts.inventory);
	const meta = loadMeta(opts.inventory);
	validate(inv, meta);

	const groups = groupBySurface(inv.entries);
	const body = generateSpec(inv, meta, groups);
	atomicWrite(opts.output, body);

	const testCount = inv.entries.length;
	process.stdout.write(
		`gen-render-specs: wrote ${opts.output}\n` +
			`  ${testCount} test() across ${groups.length} test.describe() ` +
			`(${inv.deniedActions} denylisted)\n`,
	);
}

main();
