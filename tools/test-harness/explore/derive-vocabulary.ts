// Derives the stable-UI vocabulary corpus from an existing inventory.
// Output is committed at docs/testing/ui-vocabulary.json and consumed
// by the v7 walker (Phase 2) when classifying captured accessible-
// names. Re-run on each major upstream release.
//
// Rules (adapted from the v7 plan to the v6-collapsed inventory shape):
//   - Persistent entries collapse to one inventory entry with a
//     `surfaces[]` array recording every surface the element was
//     observed on. Any persistent label whose surfaces[] has length
//     >= 2 is stable by definition.
//   - Structural / menu entries: stable if the label is shared by 3+
//     entries OR appears on 2+ distinct surfaces. Either signal is
//     enough — the plan's strict 3-and-2 conjunction over-rejects
//     against a v6-collapsed inventory where most chrome already
//     deduped to one entry.
//   - Names matching any INSTANCE_SHAPES regex go to instanceShapes
//     and are excluded from stable / suspect even if they would have
//     qualified — the instance-shape pattern is the canonical
//     representation for those at resolve time.
//   - kind: instance entries are excluded from the stable corpus
//     entirely — those labels by definition vary per session. (A
//     label that appears in BOTH instance and structural entries
//     follows the structural / menu rule.)
//   - Everything else falls through to `suspect`, queued for human
//     reconciliation.

import {
	existsSync,
	readFileSync,
	renameSync,
	writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { INSTANCE_SHAPES } from '../src/lib/name-classifier.js';
import type { Inventory, InventoryEntry } from './walker.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const TESTING_DIR = resolve(HERE, '..', '..', '..', 'docs', 'testing');
const DEFAULT_INVENTORY = resolve(TESTING_DIR, 'ui-inventory.json');
const DEFAULT_OUTPUT = resolve(TESTING_DIR, 'ui-vocabulary.json');

interface CliOpts {
	inventory: string;
	output: string;
	help: boolean;
}

interface InstanceShapeOutput {
	id: string;
	regex: string;
	flags: string;
	pattern: string | null;
	matchedNames: string[];
}

interface VocabularyOutput {
	derivedAt: string;
	sourceInventory: {
		capturedAt: string;
		appVersion: string;
		walkerVersion: string;
		totalElements: number;
	};
	stable: string[];
	instanceShapes: InstanceShapeOutput[];
	suspect: string[];
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
				process.stderr.write(
					`derive-vocabulary: unknown argument: ${a}\n`,
				);
				printUsage();
				process.exit(1);
		}
	}
	return opts;
}

function printUsage(): void {
	process.stdout.write(
		'Usage: tsx explore/derive-vocabulary.ts [options]\n' +
			'\n' +
			'Derives docs/testing/ui-vocabulary.json from an existing\n' +
			'inventory walk. Output records the stable-UI corpus, the\n' +
			'instance-shape registry hits, and any names flagged for\n' +
			'human triage.\n' +
			'\n' +
			'Options:\n' +
			'  --inventory <path>  Override default inventory path\n' +
			'                      (default: docs/testing/ui-inventory.json)\n' +
			'  --output <path>     Override default vocabulary output path\n' +
			'                      (default: docs/testing/ui-vocabulary.json)\n' +
			'  -h, --help          Print this help and exit\n',
	);
}

function loadInventory(path: string): Inventory {
	if (!existsSync(path)) {
		process.stderr.write(
			`derive-vocabulary: inventory not found: ${path}\n`,
		);
		process.exit(1);
	}
	try {
		return JSON.parse(readFileSync(path, 'utf8')) as Inventory;
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		process.stderr.write(
			`derive-vocabulary: failed to parse inventory: ${msg}\n`,
		);
		process.exit(1);
	}
}

interface LabelStats {
	kinds: Set<InventoryEntry['kind']>;
	surfaces: Set<string>;
	entryCount: number;
	maxPersistentSpan: number;
}

function aggregate(inv: Inventory): Map<string, LabelStats> {
	const stats = new Map<string, LabelStats>();
	for (const e of inv.entries) {
		const lbl = e.label;
		if (!lbl) continue;
		let s = stats.get(lbl);
		if (!s) {
			s = {
				kinds: new Set(),
				surfaces: new Set(),
				entryCount: 0,
				maxPersistentSpan: 0,
			};
			stats.set(lbl, s);
		}
		s.kinds.add(e.kind);
		s.surfaces.add(e.surface);
		s.entryCount += 1;
		if (e.kind === 'persistent' && e.surfaces) {
			s.maxPersistentSpan = Math.max(
				s.maxPersistentSpan,
				e.surfaces.length,
			);
		}
	}
	return stats;
}

function classify(inv: Inventory): VocabularyOutput {
	const stats = aggregate(inv);
	const stable = new Set<string>();
	const suspect = new Set<string>();
	const instanceHits = new Map<string, Set<string>>();
	for (const shape of INSTANCE_SHAPES) {
		instanceHits.set(shape.id, new Set());
	}

	for (const [lbl, s] of stats) {
		// Pure-instance label — exclude entirely.
		if (s.kinds.size === 1 && s.kinds.has('instance')) {
			continue;
		}

		// Instance-shape regex match — record + skip stable/suspect.
		let shapeMatched = false;
		for (const shape of INSTANCE_SHAPES) {
			if (shape.regex.test(lbl)) {
				instanceHits.get(shape.id)!.add(lbl);
				shapeMatched = true;
				break;
			}
		}
		if (shapeMatched) continue;

		// Persistent: surfaces[] >= 2 carries the proof that the chrome
		// element actually spans surfaces.
		if (s.maxPersistentSpan >= 2) {
			stable.add(lbl);
			continue;
		}

		// Structural / menu: 3+ entries OR 2+ distinct surfaces.
		if (s.entryCount >= 3 || s.surfaces.size >= 2) {
			stable.add(lbl);
			continue;
		}

		suspect.add(lbl);
	}

	const instanceShapesOut: InstanceShapeOutput[] = INSTANCE_SHAPES.map(
		(shape) => ({
			id: shape.id,
			regex: shape.regex.source,
			flags: shape.regex.flags,
			pattern: shape.pattern,
			matchedNames: [...instanceHits.get(shape.id)!].sort(),
		}),
	);

	return {
		derivedAt: new Date().toISOString(),
		sourceInventory: {
			capturedAt: inv.capturedAt,
			appVersion: inv.appVersion,
			walkerVersion: inv.walkerVersion,
			totalElements: inv.totalElements,
		},
		stable: [...stable].sort(),
		instanceShapes: instanceShapesOut,
		suspect: [...suspect].sort(),
	};
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
	const out = classify(inv);
	const body = `${JSON.stringify(out, null, 2)}\n`;
	atomicWrite(opts.output, body);

	const shapeHitTotal = out.instanceShapes.reduce(
		(n, s) => n + s.matchedNames.length,
		0,
	);
	process.stdout.write(
		`derive-vocabulary: wrote ${opts.output}\n` +
			`  source: ${opts.inventory} (${inv.totalElements} entries)\n` +
			`  stable: ${out.stable.length}, ` +
			`instance-shaped: ${shapeHitTotal} (${out.instanceShapes.filter((s) => s.matchedNames.length > 0).length} shapes hit), ` +
			`suspect: ${out.suspect.length}\n`,
	);
}

main();
