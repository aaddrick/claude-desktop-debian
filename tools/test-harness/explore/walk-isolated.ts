// Drive a v7 walk inside the test harness's launch-with-isolation
// path so the run lives in a per-launch tmpdir (auth seeded from the
// host config) rather than the running host app's own profile.
//
// Why a separate driver instead of `explore walk`: the standalone CLI
// connects to whatever Node inspector is already on :9229 — i.e. the
// running host Claude Desktop. That path mutates the host profile
// (visited surfaces, navigation history, route changes) and races
// with the human at the keyboard. The launchClaude path here mirrors
// what H05 / U01 do: kill any running host instance, copy auth into
// a tmpdir, spawn a fresh Electron with isolated XDG_CONFIG_HOME,
// attach the inspector via SIGUSR1, and tear everything down on
// exit.
//
// Usage (matches `explore walk` flag set):
//   npx tsx explore/walk-isolated.ts --verbose --max-elements 2000
//
// Flags:
//   --max-elements N            global cap (default 1000)
//   --max-drills-per-surface N  per-surface drilling fan-out cap (default 50)
//   --checkpoint-every N        write inventory every N entries (default 100)
//   --output PATH               inventory output (default docs/testing/
//                                                       ui-inventory.json)
//   --allowlist PATH            JSON file with `exemptions: string[]`
//   --no-seed                   don't copy host auth — fresh sign-in
//                               required (rare; default seeds from host)
//   --verbose                   walker chatter to stderr

import {
	existsSync,
	mkdirSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { launchClaude } from '../src/lib/electron.js';
import { createIsolation } from '../src/lib/isolation.js';
import { walkRenderer, WALKER_VERSION } from './walker.js';
import type { Inventory } from './walker.js';

const TESTING_DIR = resolve(
	dirname(fileURLToPath(import.meta.url)),
	'..',
	'..',
	'..',
	'docs',
	'testing',
);
const INVENTORY_PATH = resolve(TESTING_DIR, 'ui-inventory.json');
const INVENTORY_META_PATH = resolve(TESTING_DIR, 'ui-inventory.meta.json');
const INVENTORY_TMP_SUFFIX = '.tmp';

interface Options {
	maxElements: number;
	maxDrillsPerSurface: number;
	checkpointEvery: number;
	allowlist: string | null;
	output: string;
	verbose: boolean;
	seed: boolean;
	help: boolean;
}

function parseArgs(args: string[]): Options {
	const opts: Options = {
		maxElements: 1000,
		maxDrillsPerSurface: 50,
		checkpointEvery: 100,
		allowlist: null,
		output: INVENTORY_PATH,
		verbose: false,
		seed: true,
		help: false,
	};
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i]!;
		if (a === '-h' || a === '--help') opts.help = true;
		else if (a === '--verbose') opts.verbose = true;
		else if (a === '--no-seed') opts.seed = false;
		else if (a === '--max-elements') {
			const n = Number(args[++i]);
			if (!Number.isFinite(n) || n < 0) die('--max-elements N (N≥0)');
			opts.maxElements = n;
		} else if (a === '--max-drills-per-surface') {
			const n = Number(args[++i]);
			if (!Number.isFinite(n) || n < 0) die('--max-drills-per-surface N');
			opts.maxDrillsPerSurface = n;
		} else if (a === '--checkpoint-every') {
			const n = Number(args[++i]);
			if (!Number.isInteger(n) || n < 0) die('--checkpoint-every N');
			opts.checkpointEvery = n;
		} else if (a === '--allowlist') {
			const p = args[++i];
			if (!p) die('--allowlist PATH');
			opts.allowlist = p;
		} else if (a === '--output') {
			const p = args[++i];
			if (!p) die('--output PATH');
			opts.output = resolve(p);
		} else {
			die(`unknown flag: ${a}`);
		}
	}
	return opts;
}

function die(msg: string): never {
	process.stderr.write(`walk-isolated: ${msg}\n`);
	process.exit(1);
}

function printUsage(): void {
	process.stdout.write(
		[
			'usage: npx tsx explore/walk-isolated.ts [flags]',
			'',
			'flags:',
			'  --max-elements N             global cap (default 1000)',
			'  --max-drills-per-surface N   drilling fan-out cap (default 50)',
			'  --checkpoint-every N         partial-write cadence (default 100; 0 disables)',
			'  --output PATH                inventory output path',
			'  --allowlist PATH             JSON { exemptions: string[] }',
			'  --no-seed                    skip host-config auth seeding',
			'  --verbose                    walker chatter on stderr',
			'',
		].join('\n'),
	);
}

async function main(): Promise<void> {
	const opts = parseArgs(process.argv.slice(2));
	if (opts.help) {
		printUsage();
		return;
	}

	let allowlist: string[] = [];
	if (opts.allowlist) {
		const raw = readFileSync(opts.allowlist, 'utf8');
		const parsed = JSON.parse(raw) as { exemptions?: string[] };
		allowlist = parsed.exemptions ?? [];
	}

	const outDir = dirname(opts.output);
	if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
	const metaPath =
		opts.output === INVENTORY_PATH
			? INVENTORY_META_PATH
			: opts.output.replace(/\.json$/, '.meta.json');

	const writeCheckpoint = (inventory: Inventory, isPartial: boolean): void => {
		const invTmp = `${opts.output}${INVENTORY_TMP_SUFFIX}`;
		writeFileSync(invTmp, JSON.stringify(inventory, null, 2) + '\n', 'utf8');
		renameSync(invTmp, opts.output);
		const meta = {
			capturedAt: inventory.capturedAt,
			appVersion: inventory.appVersion,
			walkerVersion: WALKER_VERSION,
			startUrl: inventory.startUrl,
			totalElements: inventory.totalElements,
			deniedActions: inventory.deniedActions,
			partial: isPartial,
			isolation: 'launchClaude (test-harness path)',
			seededFromHost: opts.seed,
			allowlistEntries: allowlist,
		};
		const metaTmp = `${metaPath}${INVENTORY_TMP_SUFFIX}`;
		writeFileSync(metaTmp, JSON.stringify(meta, null, 2) + '\n', 'utf8');
		renameSync(metaTmp, metaPath);
	};

	process.stderr.write(
		`walk-isolated: creating isolation (seedFromHost=${opts.seed})\n`,
	);
	const isolation = await createIsolation({ seedFromHost: opts.seed });
	let app: Awaited<ReturnType<typeof launchClaude>> | null = null;
	try {
		process.stderr.write('walk-isolated: spawning Claude Desktop\n');
		app = await launchClaude({ isolation });
		process.stderr.write(
			'walk-isolated: waiting for claude.ai webContents (90s budget)\n',
		);
		const { inspector, claudeAiUrl } = await app.waitForReady('claudeAi');
		if (!claudeAiUrl) {
			throw new Error(
				'claude.ai webContents never loaded — host likely not signed in. ' +
					'Open Claude Desktop, sign in, fully close, and re-run.',
			);
		}
		process.stderr.write(`walk-isolated: at ${claudeAiUrl}\n`);

		const inventory = await walkRenderer(inspector, {
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
		writeCheckpoint(inventory, false);
		process.stdout.write(
			`wrote ${opts.output} (${inventory.totalElements} entries, ` +
				`${inventory.deniedActions} denylisted)\n`,
		);
		process.stdout.write(`wrote ${metaPath}\n`);
	} finally {
		if (app) {
			try {
				await app.close();
			} catch (err) {
				process.stderr.write(
					`walk-isolated: app.close() failed: ${
						err instanceof Error ? err.message : String(err)
					}\n`,
				);
			}
		}
		try {
			await isolation.cleanup();
		} catch (err) {
			process.stderr.write(
				`walk-isolated: isolation.cleanup() failed: ${
					err instanceof Error ? err.message : String(err)
				}\n`,
			);
		}
	}
}

main().catch((err) => {
	const msg = err instanceof Error ? err.message : String(err);
	process.stderr.write(`walk-isolated: ${msg}\n`);
	process.exit(2);
});
