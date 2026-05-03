// Entry point for the explore CLI.
//
// Subcommand surface (matches docs/testing/claudeai-ui-mapping-plan.md
// Phase 1):
//
//   explore                    full snapshot to stdout
//   explore pills              df-pills + compact-pills + state
//   explore menu               currently-open menu structure
//   explore snapshot <name>    write to docs/testing/ui-snapshots/<name>.json
//   explore diff <a> <b>       diff two snapshots
//   explore find <regex>       search renderer for matching text/aria-label
//
// Why a hand-rolled dispatcher: the surface is six cases. A flag parser
// adds a dependency and obscures which command takes which positional.
// Keep the routing visible.
//
// Exit codes:
//   0  success (including a clean diff)
//   1  caller error (bad args, missing file)
//   2  runtime error (no debugger, no claude.ai webContents)
//   3  diff non-empty AND `--exit-on-diff` was set — opt-in, off by
//      default so `explore diff` from a script can read entries
//      without conflating "drift" with "tool blew up".

import {
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { InspectorClient } from '../src/lib/inspector.js';
import { capture, capturePills, captureOpenMenu } from './snapshot.js';
import type { Snapshot } from './snapshot.js';
import { diff, formatDiff } from './diff.js';
import { findInRenderer, formatHits } from './find.js';
import {
	collapsePersistentEntries,
	walkRenderer,
	WALKER_VERSION,
} from './walker.js';
import type { Inventory } from './walker.js';

const INSPECTOR_PORT = 9229;
// Resolve relative to this source file so the CLI works regardless of
// cwd (npm script vs. ad-hoc tsx invocation from elsewhere).
const TESTING_DIR = resolve(
	dirname(fileURLToPath(import.meta.url)),
	'..',
	'..',
	'..',
	'docs',
	'testing',
);
const SNAPSHOT_DIR = resolve(TESTING_DIR, 'ui-snapshots');
const INVENTORY_PATH = resolve(TESTING_DIR, 'ui-inventory.json');
const INVENTORY_META_PATH = resolve(TESTING_DIR, 'ui-inventory.meta.json');

async function main(): Promise<void> {
	const argv = process.argv.slice(2);
	const cmd = argv[0];
	const rest = argv.slice(1);
	try {
		switch (cmd) {
			case undefined:
				await runFullSnapshot();
				return;
			case 'pills':
				await runPills();
				return;
			case 'menu':
				await runMenu();
				return;
			case 'snapshot':
				await runSnapshot(rest);
				return;
			case 'diff':
				await runDiff(rest);
				return;
			case 'find':
				await runFind(rest);
				return;
			case 'walk':
				await runWalk(rest);
				return;
			case 'collapse':
				await runCollapse(rest);
				return;
			case '-h':
			case '--help':
			case 'help':
				printUsage();
				return;
			default:
				console.error(`unknown subcommand: ${cmd}`);
				printUsage();
				process.exit(1);
		}
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		console.error(`explore: ${msg}`);
		process.exit(2);
	}
}

async function runFullSnapshot(): Promise<void> {
	const client = await connect();
	try {
		const snap = await capture(client);
		console.log(JSON.stringify(snap, null, 2));
	} finally {
		client.close();
	}
}

async function runPills(): Promise<void> {
	const client = await connect();
	try {
		const pills = await capturePills(client);
		console.log(JSON.stringify(pills, null, 2));
	} finally {
		client.close();
	}
}

async function runMenu(): Promise<void> {
	const client = await connect();
	try {
		const menu = await captureOpenMenu(client);
		if (!menu) {
			console.log('null');
			return;
		}
		console.log(JSON.stringify(menu, null, 2));
	} finally {
		client.close();
	}
}

async function runSnapshot(args: string[]): Promise<void> {
	const name = args[0];
	if (!name) {
		console.error('snapshot: missing <name> argument');
		console.error('usage: explore snapshot <name>');
		process.exit(1);
	}
	if (!/^[a-zA-Z0-9._-]+$/.test(name)) {
		console.error(
			`snapshot: name ${JSON.stringify(name)} contains characters ` +
				`outside [a-zA-Z0-9._-] — choose a slug-safe name`,
		);
		process.exit(1);
	}
	const client = await connect();
	let snap: Snapshot;
	try {
		snap = await capture(client);
	} finally {
		client.close();
	}
	if (!existsSync(SNAPSHOT_DIR)) {
		mkdirSync(SNAPSHOT_DIR, { recursive: true });
	}
	const outPath = resolve(SNAPSHOT_DIR, `${name}.json`);
	writeFileSync(outPath, JSON.stringify(snap, null, 2) + '\n', 'utf8');
	console.log(`wrote ${outPath}`);
}

async function runDiff(args: string[]): Promise<void> {
	const opts = { json: false, exitOnDiff: false };
	const positional: string[] = [];
	for (const a of args) {
		if (a === '--json') opts.json = true;
		else if (a === '--exit-on-diff') opts.exitOnDiff = true;
		else positional.push(a);
	}
	if (positional.length !== 2) {
		console.error('diff: expected exactly two snapshot names or paths');
		console.error('usage: explore diff <a> <b> [--json] [--exit-on-diff]');
		process.exit(1);
	}
	const a = readSnapshot(positional[0]!);
	const b = readSnapshot(positional[1]!);
	const result = diff(a, b);
	if (opts.json) {
		console.log(JSON.stringify(result, null, 2));
	} else {
		console.log(formatDiff(result));
	}
	if (opts.exitOnDiff && result.entries.length > 0) {
		process.exit(3);
	}
}

// `walk` parses its own flags; --max-elements 0 prints usage and exits
// (a cheap dry-run for "is the CLI loadable" without touching CDP).
async function runWalk(args: string[]): Promise<void> {
	const opts: {
		maxElements: number;
		maxDrillsPerSurface: number;
		checkpointEvery: number;
		allowlist: string | null;
		output: string;
		verbose: boolean;
		help: boolean;
	} = {
		maxElements: 1000,
		maxDrillsPerSurface: 50,
		checkpointEvery: 100,
		allowlist: null,
		output: INVENTORY_PATH,
		verbose: false,
		help: false,
	};
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i]!;
		if (a === '-h' || a === '--help') {
			opts.help = true;
		} else if (a === '--max-elements') {
			const n = Number(args[i + 1]);
			if (!Number.isFinite(n) || n < 0) {
				console.error('walk: --max-elements requires a non-negative integer');
				process.exit(1);
			}
			opts.maxElements = n;
			i += 1;
		} else if (a === '--checkpoint-every') {
			const n = Number(args[i + 1]);
			if (!Number.isFinite(n) || n < 0 || !Number.isInteger(n)) {
				console.error(
					'walk: --checkpoint-every requires a non-negative integer (0 disables)',
				);
				process.exit(1);
			}
			opts.checkpointEvery = n;
			i += 1;
		} else if (
			a === '--max-drills-per-surface' ||
			a === '--max-elements-per-surface'
		) {
			// v4 renamed the flag from --max-elements-per-surface (which
			// truncated emissions) to --max-drills-per-surface (which only
			// caps queue pushes; all entries are still emitted). Keep the
			// old name as a deprecated alias.
			if (a === '--max-elements-per-surface') {
				process.stderr.write(
					'walk: --max-elements-per-surface is deprecated; ' +
						'use --max-drills-per-surface (semantics changed: now ' +
						'caps drilling fan-out, not emission count)\n',
				);
			}
			const n = Number(args[i + 1]);
			if (!Number.isFinite(n) || n < 0) {
				console.error(`walk: ${a} requires a non-negative integer`);
				process.exit(1);
			}
			opts.maxDrillsPerSurface = n;
			i += 1;
		} else if (a === '--allowlist') {
			const p = args[i + 1];
			if (!p) {
				console.error('walk: --allowlist requires a path');
				process.exit(1);
			}
			opts.allowlist = p;
			i += 1;
		} else if (a === '--output') {
			const p = args[i + 1];
			if (!p) {
				console.error('walk: --output requires a path');
				process.exit(1);
			}
			opts.output = resolve(p);
			i += 1;
		} else if (a === '--verbose') {
			opts.verbose = true;
		} else {
			console.error(`walk: unknown argument: ${a}`);
			printWalkUsage();
			process.exit(1);
		}
	}
	if (opts.help || opts.maxElements === 0) {
		printWalkUsage();
		return;
	}
	let allowlist: string[] = [];
	if (opts.allowlist) {
		const raw = readFileSync(opts.allowlist, 'utf8');
		try {
			const parsed = JSON.parse(raw) as { exemptions?: string[] };
			allowlist = parsed.exemptions ?? [];
		} catch (err) {
			const msg = err instanceof Error ? err.message : String(err);
			console.error(`walk: allowlist ${opts.allowlist}: invalid JSON — ${msg}`);
			process.exit(1);
		}
	}
	const outDir = dirname(opts.output);
	if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
	const metaPath =
		opts.output === INVENTORY_PATH
			? INVENTORY_META_PATH
			: opts.output.replace(/\.json$/, '.meta.json');

	// Atomic writer: write to <path>.tmp, then rename. Survives a kill
	// between writes — readers always see either the prior complete file
	// or the new one, never a half-written buffer. Used for both the
	// in-flight checkpoint writes and the final write. `partial` is
	// recorded in meta.json (true on intermediate writes, false on the
	// final write) so downstream readers can tell whether the inventory
	// is complete; the inventory file itself stays shape-compatible.
	const writeCheckpoint = (
		inventory: Inventory,
		isPartial: boolean,
	): void => {
		const invTmp = `${opts.output}${INVENTORY_TMP_SUFFIX}`;
		writeFileSync(
			invTmp,
			JSON.stringify(inventory, null, 2) + '\n',
			'utf8',
		);
		renameSync(invTmp, opts.output);
		const meta = {
			capturedAt: inventory.capturedAt,
			appVersion: inventory.appVersion,
			walkerVersion: WALKER_VERSION,
			startUrl: inventory.startUrl,
			totalElements: inventory.totalElements,
			deniedActions: inventory.deniedActions,
			partial: isPartial,
			denylistDescription:
				'Default destructive-action labels (see DEFAULT_DENYLIST in walker.ts) ' +
				'plus optional allowlist exemptions.',
			allowlistEntries: allowlist,
		};
		const metaTmp = `${metaPath}${INVENTORY_TMP_SUFFIX}`;
		writeFileSync(metaTmp, JSON.stringify(meta, null, 2) + '\n', 'utf8');
		renameSync(metaTmp, metaPath);
	};

	const client = await connect();
	let inventory: Inventory;
	try {
		inventory = await walkRenderer(client, {
			maxElements: opts.maxElements,
			maxDrillsPerSurface: opts.maxDrillsPerSurface,
			allowlist,
			verbose: opts.verbose,
			checkpointEvery: opts.checkpointEvery,
			checkpointWriter:
				opts.checkpointEvery > 0
					? (inv) => writeCheckpoint(inv, true)
					: undefined,
		});
	} finally {
		client.close();
	}
	writeCheckpoint(inventory, false);
	console.log(
		`wrote ${opts.output} (${inventory.totalElements} entries, ` +
			`${inventory.deniedActions} denylisted)`,
	);
	console.log(`wrote ${metaPath}`);
}

// Suffix used by the atomic-write helper. Kept module-level so any
// future readers know which dotfile to ignore in tooling/gitignore.
const INVENTORY_TMP_SUFFIX = '.tmp';

// `collapse [<path>]` re-runs the post-walk persistent-element
// collapse against an existing inventory file. Use case: a partial
// checkpoint (walker aborted mid-walk) skipped the in-loop collapse
// and so has 0 persistent entries — this command salvages it without
// re-running the walker. Also useful if collapse heuristics change
// and we want to refresh an existing inventory.
async function runCollapse(args: string[]): Promise<void> {
	let path = INVENTORY_PATH;
	let help = false;
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i]!;
		if (a === '-h' || a === '--help') help = true;
		else if (!a.startsWith('-')) path = resolve(a);
		else {
			console.error(`collapse: unknown argument: ${a}`);
			printCollapseUsage();
			process.exit(1);
		}
	}
	if (help) {
		printCollapseUsage();
		return;
	}
	if (!existsSync(path)) {
		console.error(`collapse: inventory not found: ${path}`);
		process.exit(1);
	}
	let inventory: Inventory;
	try {
		inventory = JSON.parse(readFileSync(path, 'utf8')) as Inventory;
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		console.error(`collapse: invalid JSON in ${path} — ${msg}`);
		process.exit(1);
	}
	// v7-only gate. The v6 → v7 fingerprint cutover invalidated all
	// older inventory shapes; re-running the persistent collapse on a
	// v6 inventory would mint v7-key collisions against v6 selectors
	// and drop unrelated entries. Re-walk first.
	const wv = inventory.walkerVersion;
	if (wv !== '7') {
		console.error(
			`collapse: walkerVersion ${wv} is not supported (need v7; ` +
				`re-walk after the v6 → v7 fingerprint cutover)`,
		);
		process.exit(1);
	}
	const before = inventory.entries.length;
	const result = collapsePersistentEntries(inventory.entries);
	const after = result.entries.length;
	const dropped = before - after;
	const collapsedAt = new Date().toISOString();
	const updated: Inventory = {
		...inventory,
		walkerVersion: WALKER_VERSION,
		totalElements: after,
		entries: result.entries,
		capturedAt: inventory.capturedAt,
	};

	// Atomic write inventory + meta. Mirror the walk subcommand: write
	// to .tmp, rename. Meta gets `partial: false` (collapse closes out
	// a partial checkpoint) and `collapsedAt`; everything else carries
	// through from the existing meta where present.
	const invTmp = `${path}${INVENTORY_TMP_SUFFIX}`;
	writeFileSync(invTmp, JSON.stringify(updated, null, 2) + '\n', 'utf8');
	renameSync(invTmp, path);

	const metaPath =
		path === INVENTORY_PATH
			? INVENTORY_META_PATH
			: path.replace(/\.json$/, '.meta.json');
	let existingMeta: Record<string, unknown> = {};
	if (existsSync(metaPath)) {
		try {
			existingMeta = JSON.parse(readFileSync(metaPath, 'utf8')) as Record<
				string,
				unknown
			>;
		} catch {
			// Carry the inventory through even if meta is malformed; meta
			// is recoverable, the entries are not.
		}
	}
	const meta = {
		...existingMeta,
		capturedAt: updated.capturedAt,
		appVersion: updated.appVersion,
		walkerVersion: WALKER_VERSION,
		startUrl: updated.startUrl,
		totalElements: updated.totalElements,
		deniedActions: updated.deniedActions,
		partial: false,
		collapsedAt,
	};
	const metaTmp = `${metaPath}${INVENTORY_TMP_SUFFIX}`;
	writeFileSync(metaTmp, JSON.stringify(meta, null, 2) + '\n', 'utf8');
	renameSync(metaTmp, metaPath);

	console.log(
		`collapse: read ${before} entries → wrote ${after} entries ` +
			`(${dropped} dropped via persistent collapse, ` +
			`${result.persistentSurvivors} shells emitted)`,
	);
	console.log(`wrote ${path}`);
	console.log(`wrote ${metaPath}`);
}

function printCollapseUsage(): void {
	console.log(
		[
			'usage: explore collapse [<path>]',
			'',
			'Re-run the post-walk persistent-element collapse against an',
			'existing inventory file. Useful for salvaging a partial',
			'checkpoint that aborted before the in-loop collapse step.',
			'',
			'  <path>   inventory file to collapse in place (default:',
			'           docs/testing/ui-inventory.json). Must be v5+.',
			'  -h, --help  print this help',
			'',
			'Writes the collapsed inventory and updated meta.json',
			'atomically (.tmp + rename). Meta gains `collapsedAt` and',
			'clears `partial` to false.',
		].join('\n'),
	);
}

function printWalkUsage(): void {
	console.log(
		[
			'usage: explore walk [options]',
			'',
			'options:',
			'  --max-elements N              safety cap on total entries',
			'                                (default 1000; 0 prints this help',
			'                                and exits)',
			'  --max-drills-per-surface N    max number of children to drill into',
			'                                from one surface (default 50). All',
			'                                children are still emitted to the',
			'                                inventory; this only bounds the BFS',
			'                                queue fan-out per surface.',
			'                                (Alias: --max-elements-per-surface,',
			'                                 deprecated — v3 truncated emissions,',
			'                                 v4 only caps drilling.)',
			'  --checkpoint-every N          atomically write the inventory every N',
			'                                newly-emitted entries (default 100;',
			'                                0 disables). Intermediate writes set',
			'                                meta.json `partial: true`; the final',
			'                                write clears it to false.',
			'  --allowlist PATH              JSON file:',
			'                                {"exemptions": ["entry.id", ...]} to',
			'                                remove from the default denylist',
			'  --output PATH                 write inventory to PATH (default',
			'                                docs/testing/ui-inventory.json)',
			'  --verbose                     log every click + surface to stderr',
			'  -h, --help                    print this help',
		].join('\n'),
	);
}

async function runFind(args: string[]): Promise<void> {
	const opts = { json: false, limit: 100 };
	const positional: string[] = [];
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i]!;
		if (a === '--json') opts.json = true;
		else if (a === '--limit') {
			const n = Number(args[i + 1]);
			if (!Number.isFinite(n) || n <= 0) {
				console.error('find: --limit requires a positive integer');
				process.exit(1);
			}
			opts.limit = n;
			i += 1;
		} else positional.push(a);
	}
	const pat = positional[0];
	if (!pat) {
		console.error('find: missing <regex> argument');
		console.error('usage: explore find <regex> [--json] [--limit N]');
		process.exit(1);
	}
	let re: RegExp;
	try {
		re = new RegExp(pat, 'i');
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		console.error(`find: invalid regex: ${msg}`);
		process.exit(1);
	}
	const client = await connect();
	try {
		const hits = await findInRenderer(client, re, { limit: opts.limit });
		if (opts.json) {
			console.log(JSON.stringify(hits, null, 2));
		} else {
			console.log(formatHits(hits));
		}
	} finally {
		client.close();
	}
}

// Snapshot resolver: accept either a bare name (looked up in the
// snapshot dir, .json appended) or an explicit path. Bare names are
// the common case from CI / the README; explicit paths help when
// diffing a snapshot against an out-of-tree fixture.
function readSnapshot(nameOrPath: string): Snapshot {
	const candidates = [
		nameOrPath,
		resolve(SNAPSHOT_DIR, nameOrPath),
		resolve(SNAPSHOT_DIR, `${nameOrPath}.json`),
	];
	const found = candidates.find((p) => existsSync(p));
	if (!found) {
		console.error(`snapshot not found: tried ${candidates.join(', ')}`);
		process.exit(1);
	}
	const raw = readFileSync(found, 'utf8');
	try {
		return JSON.parse(raw) as Snapshot;
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		console.error(`snapshot ${found}: invalid JSON — ${msg}`);
		process.exit(1);
	}
}

async function connect(): Promise<InspectorClient> {
	try {
		return await InspectorClient.connect(INSPECTOR_PORT);
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		throw new Error(
			`could not attach to debugger on :${INSPECTOR_PORT} — ${msg}. ` +
				`Enable the main-process debugger via the in-app menu first.`,
		);
	}
}

function printUsage(): void {
	console.log(
		[
			'usage:',
			'  explore                    full snapshot to stdout',
			'  explore pills              df-pills + compact-pills + state',
			'  explore menu               currently-open menu structure',
			'  explore snapshot <name>    write snapshot to ui-snapshots/<name>.json',
			'  explore diff <a> <b> [--json] [--exit-on-diff]',
			'                             compare two snapshots',
			'  explore find <regex> [--json] [--limit N]',
			'                             search renderer text + aria-label',
			'  explore walk [options]     BFS walker → docs/testing/ui-inventory.json',
			'                             (see `explore walk --help` for options)',
			'  explore collapse [<path>]  re-run persistent-element collapse against',
			'                             an existing inventory (salvages partial',
			'                             checkpoints; see `explore collapse --help`)',
		].join('\n'),
	);
}

main().catch((err) => {
	const msg = err instanceof Error ? err.message : String(err);
	console.error(`explore: ${msg}`);
	process.exit(2);
});
