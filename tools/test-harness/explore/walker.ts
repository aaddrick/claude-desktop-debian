// BFS walker that crawls the live signed-in claude.ai renderer and
// enumerates every reachable interactive element (buttons, menuitems,
// links, tabs). Output is a JSON inventory committed to the repo as
// the source of truth for downstream render-spec generation.
//
// Why BFS, not DFS: the user wants a breadth-first inventory so the
// top of the file is always the surface map; deep popovers come later
// in the queue. Ctrl-C at any time still leaves a useful prefix.
//
// Why no depth limit: per spec — "it's not a deep app." `maxElements`
// is the only safety cap. The walker emits inventory entries for
// denylisted elements (with `denylisted: true`) but never clicks them,
// so destructive controls stay recorded without being triggered.
//
// Re-drive strategy: after popping a queue item we navigate to the
// recorded `startUrl`, wait for stable, and replay the entire
// `navigationPath` step-by-step. We re-drive from scratch (rather
// than backing out via Escape / browser-back) because the renderer's
// transient overlays, focus traps, and route-less tab switches mean
// "back out" can leave the DOM in a half-collapsed state. Re-drive
// is O(N²) in path length but path length stays small in this app
// and correctness wins. See `redrivePath` for details.
//
// Visited-set keying: a surface is canonicalized as
// `${pageUrl} :: ${sortedFingerprintIds.join('|')}` taken from the
// snapshot at that surface — same URL + same set of interactive
// elements = same surface. We never visit the same surface twice
// even if multiple elements lead there.
//
// Fingerprinting (per spec, in priority order):
//   1. aria-label
//   2. role + accessible name (aria-labelledby resolved, else text)
//   3. text content (trimmed, original-case)
//   4. structural position within parent surface (`{tag}#N`) — last resort
// Generated React IDs and Tailwind classes are explicitly NOT used.

import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import type { AxNode, InspectorClient } from '../src/lib/inspector.js';
import {
	classifyName,
	INSTANCE_SHAPES,
	type Vocabulary,
} from '../src/lib/name-classifier.js';
import { sleep } from '../src/lib/retry.js';

// Bumped whenever the inventory output shape changes. Downstream
// generators check this and refuse to operate on mismatched versions.
// v2 added optional `instanceCount` / `instanceLabelPattern` fields and
// tightened the renderer-side filters (drops zero-box, no-offsetParent,
// in-<style>/<script>/<head>/<template>/<noscript>, and content-less
// buttons), so the entry set itself differs from v1.
// v3 added `kind: 'persistent'` + optional `surfaces[]` for sidebar /
// chrome elements that show up across many surfaces (post-walk collapse
// pass), and a per-surface element cap (--max-elements-per-surface) to
// stop one busy surface from eating the global budget before deeper
// menus / dialogs get a chance.
// v4 reshapes that per-surface cap. v3 truncated emitted entries from
// the tail of the snapshot, which silently dropped important bottom-
// of-page controls (Send button, model picker, …) before we could even
// attest they rendered. v4 emits ALL entries unconditionally and only
// caps how many of them get pushed onto the BFS drilling queue
// (--max-drills-per-surface). It also adds an in-flight persistent
// skip: when the same fingerprint has already been queued from another
// surface, subsequent surfaces emit it but do NOT requeue it, which is
// what actually frees BFS budget for deeper levels (the v3 post-walk
// collapse only cleaned output, by which point the duplicate clicks
// had already happened). The post-walk collapse is retained as a
// defensive cleanup for fingerprints first seen on later surfaces.
// v5 adds incremental checkpointing: the walker now invokes an
// optional writer every N emitted entries so a hang/crash/Ctrl-C
// preserves a partial inventory on disk. The meta.json shape gains a
// `partial: boolean` flag — true on intermediate writes, false on the
// final write — so downstream readers can tell whether they're seeing
// a complete walk. v5 also wraps every inspector call inside the BFS
// loop in a timeout-tolerant catch (skip-and-continue) so a single
// renderer hang doesn't freeze the whole walk; 5 consecutive timeouts
// abort the walk with a clear error.
// v6 splits v5's single failure counter into TWO: real
// `inspector_timeout` errors (from InspectorClient.send) keep the
// 5-strike abort threshold; `lookup_failure` errors (clickById can't
// resolve a stale fingerprint on the current surface) get their own
// 25-strike threshold. The two counters are independent — a timeout
// doesn't reset the lookup counter and vice versa — but BOTH reset on
// any successful inspector call (the underlying signal both are trying
// to capture is "renderer is healthy"). v6 also adds subtree pruning:
// when a redrive fails on a step, every queued item whose path shares
// the failed step's prefix is dropped at once (a stale-sidebar drift
// no longer burns N lookup-failure strikes for N siblings). The CLI
// gains a `collapse` subcommand to re-run the post-walk persistent-
// element collapse against an existing inventory file (lets us salvage
// a partial checkpoint without re-running the walk), and meta.json
// gains a `collapsedAt` timestamp recorded on the post-collapse write.
// v7 (account-portable) replaces the per-element selector with an
// accessibility-path fingerprint. Each element carries:
//   - `ariaPath`: landmark/grouping ancestors from outermost to leaf,
//     each step recording (role, optional accessible-name matcher).
//   - `leaf`: the element's own role, an optional name matcher
//     (literal or instance-shape regex), and an optional sibling index
//     fallback for positional-only elements.
//   - `classification`: drives resolver strictness — 'stable' /
//     'positional' / 'instance'.
// Inventory IDs are derived from the structural ariaPath, not the
// label. So `root.button.awaaddrick-max` (v6, hard-coded the walker-
// author's plan badge) becomes something like
// `root.banner.button-by-shape.plan-badge` — same element, no
// per-account text baked in. See docs/testing/fingerprint-v7-plan.md
// for the design rationale and the resolver / drift-warning shape.
// v7 capture substrate moved from a renderer-side DOM walk to
// Chromium's accessibility tree (`Accessibility.getFullAXTree` over
// CDP). Role + accessible name are now whatever the platform AX
// implementation computed — covering aria-owns reparenting, aria-hidden
// pruning, implicit name sources (`<input value>`, `<img alt>`, SVG
// `<title>`, `<label for>`), and computed role overrides (`<button
// role="link">` is a link, not a button). RawElement loses tagName,
// ariaLabel, textContent, dataState, parentChainSignature, and
// ancestorAriaLabel; accessibleName is now the single name source and
// the renderer-side filters (`NON_RENDERED_TAGS`, zero-box,
// content-less buttons) are gone — AX's `ignored` flag covers them.
// Click correlation switches from selector reconstruction to AX-supplied
// `backendDOMNodeId` invoked via `DOM.resolveNode` + `Runtime.callFunctionOn`.
//
// Atomic cutover: v6 inventories no longer load. Re-walk is required.
export const WALKER_VERSION = '7';

export type NavStep =
	| { action: 'navigate'; url: string }
	| { action: 'click'; id: string }
	| { action: 'press-key'; key: string }
	| { action: 'wait-for-stable' };

export type NameMatcher =
	| { kind: 'literal'; value: string }
	| { kind: 'pattern'; regex: string };

export interface AriaStep {
	role: string;
	name: NameMatcher | null;
}

export interface SiblingIndex {
	role: string;
	position: number;
	total: number;
}

export interface Fingerprint {
	ariaPath: AriaStep[];
	leaf: {
		role: string;
		name: NameMatcher | null;
		siblingIndex: SiblingIndex | null;
	};
	classification: 'stable' | 'positional' | 'instance';
}

export interface InventoryEntry {
	id: string;
	label: string;
	role: string;
	fingerprint: Fingerprint;
	navigationPath: NavStep[];
	surface: string;
	kind: 'structural' | 'instance' | 'dialog' | 'menu' | 'persistent';
	// Present iff `kind === 'instance'`. instanceCount is the size of
	// the collapsed sibling group; instanceLabelPattern is the regex /
	// shape that defined membership (e.g. `"Untitled"` or
	// `"More options[ for *]"`).
	instanceCount?: number;
	instanceLabelPattern?: string;
	// Present iff `kind === 'persistent'`. Sorted unique list of every
	// surface where this element was observed. The `surface` field above
	// stays set to the survivor's first/canonical surface so consumers
	// that don't care about persistence keep working unchanged.
	surfaces?: string[];
	denylisted: boolean;
	discoveredAt: string;
	appVersion: string;
}

export interface Inventory {
	capturedAt: string;
	appVersion: string;
	walkerVersion: string;
	startUrl: string;
	totalElements: number;
	deniedActions: number;
	entries: InventoryEntry[];
}

export interface WalkOptions {
	maxElements?: number;
	// Per-surface drilling cap applied after instance grouping. Caps the
	// number of children from one surface that get pushed onto the BFS
	// queue; ALL children are still emitted to the inventory, only the
	// drilling fan-out is bounded. Stops a single busy surface (sidebar +
	// long recent-conversations list) from monopolising the budget so
	// deeper popovers / menus get explored.
	maxDrillsPerSurface?: number;
	allowlist?: string[]; // entry IDs exempted from the default denylist
	verbose?: boolean;
	logger?: (msg: string) => void;
	// Incremental checkpointing. Walker calls `checkpointWriter` every
	// `checkpointEvery` newly-emitted entries with a partial inventory
	// snapshot so a hang/crash/Ctrl-C preserves progress. Default 100;
	// 0 disables. The CLI provides a writer that does an atomic .tmp +
	// rename to the configured output path, with `partial: true` in
	// meta.json on every checkpoint and `partial: false` on the final
	// write. Tests / library callers can pass a no-op writer.
	checkpointEvery?: number;
	checkpointWriter?: (inventory: Inventory) => void | Promise<void>;
	// v7: name-classifier vocabulary. Falls back to disk if not
	// supplied (loadVocabulary reads docs/testing/ui-vocabulary.json).
	// Tests / library callers can pass an empty vocabulary —
	// `classifyName` defaults unrecognized names to 'suspect', which
	// the walker treats as stable for matching purposes.
	vocabulary?: Vocabulary;
}

// loadVocabulary reads the committed corpus from docs/testing. Empty
// vocabulary if the file is absent — the walker still works, just
// downgrades unfamiliar names to 'suspect' (which behaves like
// 'stable' for matching) without flagging anything as known-stable.
function loadVocabulary(): Vocabulary {
	const here = dirname(fileURLToPath(import.meta.url));
	const path = resolve(
		here,
		'..',
		'..',
		'..',
		'docs',
		'testing',
		'ui-vocabulary.json',
	);
	if (!existsSync(path)) {
		return { stable: new Set(), suspect: new Set() };
	}
	try {
		const v = JSON.parse(readFileSync(path, 'utf8')) as {
			stable?: string[];
			suspect?: string[];
		};
		return {
			stable: new Set(v.stable ?? []),
			suspect: new Set(v.suspect ?? []),
		};
	} catch {
		return { stable: new Set(), suspect: new Set() };
	}
}

// Conservative default. These labels never get clicked but the walker
// still emits the inventory entry so downstream tooling sees them.
// Anchored with ^…$ so partial matches like "Send a follow-up message"
// don't trip "Send".
export const DEFAULT_DENYLIST: RegExp[] = [
	// eslint-disable-next-line max-len
	/^(Send|Submit|Delete|Remove|Sign out|Log out|Disconnect|Uninstall|Confirm|OK|Yes|Apply|Save|Create|Pay|Subscribe|Cancel subscription|Authorize|Allow|Continue|Trust|Install)$/i,
];

interface RawAncestor {
	// Computed role from the AX tree (`AxNode.role.value`). Null only
	// when the AX node has no role assignment at all.
	role: string | null;
	// Accessible name as Chromium's AX tree resolved it (covers
	// aria-label, aria-labelledby, implicit name sources, and the
	// platform name-computation cascade).
	name: string | null;
}

interface RawElement {
	// Per-element data sourced from Chromium's accessibility tree.
	// `computedRole` is `AxNode.role.value` — the platform-computed role
	// rather than the tag-derived one, so `<button role="link">` is a
	// link.
	computedRole: string;
	// Accessible name as the AX tree computed it. Single source of truth
	// for the leaf's identity — there is no separate aria-label /
	// text-content fallback.
	accessibleName: string | null;
	// `!ignored` from the AX tree. The walker filters ignored nodes out
	// at snapshot construction time, so this is always true post-filter;
	// kept on the type so resolver-side code (`queryAccessibleTree`) can
	// still gate on it without special-casing AX-derived inputs.
	visible: boolean;
	// Any landmark dialog / alertdialog ancestor in the AX path.
	// `aria-modal=true` is no longer separately probed — AX exposes
	// modality via `properties[]` which we don't read; the destructive-
	// dialog heuristic accepts the broadening as a tradeoff.
	insideModalDialog: boolean;
	// Outermost-to-innermost AX ancestor chain (excluding the element
	// itself and any ignored nodes). `walkLandmarkAncestors` filters
	// this to the landmark / grouping subset for the fingerprint's
	// ariaPath.
	ancestors: RawAncestor[];
	// Among the parent AX node's non-ignored children that share this
	// element's computed role, where does it sit and how many siblings
	// of that role exist? Drives the positional-fallback step in
	// `captureFingerprint`.
	siblingPosition: number;
	siblingTotal: number;
	// `AxNode.backendDOMNodeId`. Required for the click path
	// (`DOM.resolveNode` → `Runtime.callFunctionOn`); null only on AX
	// nodes that don't back a DOM element (which won't reach this list,
	// since interactive ARIA roles always do).
	backendDOMNodeId: number | null;
}

interface SurfaceSnapshot {
	url: string;
	elements: RawElement[];
}

// Exported for the self-test (Test D) and the prune helper signature.
// Not part of the public schema; consumers shouldn't rely on the shape.
export interface QueueItem {
	path: NavStep[];
	// Surface key recorded *before* the final click in `path` — used so
	// that after we re-drive `path`, we can diff the resulting surface
	// against this baseline to identify newly-rendered children.
	parentSurfaceKey: string | null;
	parentRawCount: number;
}

export async function walkRenderer(
	inspector: InspectorClient,
	options: WalkOptions = {},
): Promise<Inventory> {
	const maxElements = options.maxElements ?? 1000;
	const maxDrillsPerSurface = options.maxDrillsPerSurface ?? 50;
	const allowlist = new Set(options.allowlist ?? []);
	const log = options.logger ?? ((m) => process.stderr.write(`${m}\n`));
	const verbose = options.verbose ?? false;
	const checkpointEvery = options.checkpointEvery ?? 100;
	const checkpointWriter = options.checkpointWriter;
	const vocabulary = options.vocabulary ?? loadVocabulary();

	log(
		`walker: caps — global=${maxElements} drilling=${maxDrillsPerSurface}`,
	);

	// Seeding phase still throws on inspector failure: if we can't even
	// read the URL / snapshot the root surface, there's no walk to do.
	const startUrl = await currentUrl(inspector);
	const appVersion = (await readAppVersion(inspector)) ?? 'unknown';
	await waitForStable(inspector);
	const seedTreeSize = await waitForAxTreeStable(inspector, { minNodes: 20 });
	log(`walker: AX tree settled at ${seedTreeSize} nodes`);

	const entries: InventoryEntry[] = [];
	const visitedSurfaces = new Set<string>();
	const visitedElementIds = new Set<string>();
	let deniedActions = 0;

	// Two independent failure counters. Both reset on any successful
	// inspector call (one signal: "renderer is healthy") but they do NOT
	// reset each other — a real timeout shouldn't paper over a cascade
	// of stale-state lookups, and lookup failures shouldn't paper over a
	// real wedge.
	//   - inspector_timeout: InspectorClient.send() actually timed out
	//     (defaultTimeoutMs = 30s). Renderer main thread blocked or CDP
	//     reply lost. 5 in a row → abort, renderer is stuck.
	//   - lookup_failure: clickById couldn't resolve a fingerprint on
	//     the current surface. Inspector eval succeeded; the walker's
	//     own logic decided the recorded element is no longer present.
	//     Common during sidebar drift (recents reorder, conversations
	//     shift). 25 in a row → abort, discovered DOM has drifted too
	//     far from current state to be useful.
	const MAX_CONSECUTIVE_TIMEOUTS = 5;
	// Bumped from 25 to 75 after the v7 AX migration: claude.ai's
	// virtualized sidebar lists return slightly different membership on
	// each fresh load, so a stretch of cowork-sidebar / region-list
	// drills can produce double-digit consecutive lookup misses without
	// the renderer being meaningfully wedged. The list-row instance
	// collapse and the `cowork-session` / `row-more-options` shapes
	// reduce the burst size on the queue but don't eliminate residual
	// per-row drift; a 75-strike threshold absorbs that without
	// masking a true wedge (which lights up the timeout counter, not
	// this one).
	const MAX_CONSECUTIVE_LOOKUP_FAILURES = 75;
	const counters = { inspector_timeout: 0, lookup_failure: 0 };
	let lastEmittedAtCheckpoint = 0;

	// why: classify inspector errors so a stale-sidebar cascade doesn't
	// trip the (much tighter) timeout abort threshold. The pattern match
	// is on the substring `inspector.send timed out` (emitted by
	// InspectorClient.send when the CDP reply never arrives) vs anything
	// else — currently `clickById: no element matches "X" on current
	// surface`. Returns a discriminated result so the loop body stays
	// readable; the caller (BFS loop) inspects `err` to drive subtree
	// pruning when appropriate.
	const tryInspector = async <T>(
		action: string,
		ctx: string,
		fn: () => Promise<T>,
	): Promise<{ ok: true; value: T } | { ok: false; err: Error }> => {
		try {
			const value = await fn();
			counters.inspector_timeout = 0;
			counters.lookup_failure = 0;
			return { ok: true, value };
		} catch (err) {
			const e = err instanceof Error ? err : new Error(String(err));
			if (e.message.includes('inspector.send timed out')) {
				counters.inspector_timeout += 1;
				process.stderr.write(
					`walker: inspector timeout on ${action} (${ctx}) — skipping ` +
						`(consecutive=${counters.inspector_timeout}/${MAX_CONSECUTIVE_TIMEOUTS}): ` +
						`${e.message}\n`,
				);
			} else {
				counters.lookup_failure += 1;
				process.stderr.write(
					`walker: redrive lookup failed for ${ctx} (${action}) — ` +
						`skipping (consecutive=${counters.lookup_failure}/` +
						`${MAX_CONSECUTIVE_LOOKUP_FAILURES}, subtree pruned): ` +
						`${e.message}\n`,
				);
			}
			return { ok: false, err: e };
		}
	};

	// why: build a partial Inventory for checkpointing. Same shape the
	// final return uses, but with `partial: true` carried via the meta
	// writer (the inventory itself doesn't get a partial flag — the
	// shape is unchanged so downstream parsers stay compatible).
	const buildInventory = (): Inventory => ({
		capturedAt: new Date().toISOString(),
		appVersion,
		walkerVersion: WALKER_VERSION,
		startUrl,
		totalElements: entries.length,
		deniedActions,
		entries: [...entries],
	});

	const maybeCheckpoint = async (): Promise<void> => {
		if (!checkpointWriter || checkpointEvery <= 0) return;
		if (entries.length - lastEmittedAtCheckpoint < checkpointEvery) return;
		lastEmittedAtCheckpoint = entries.length;
		try {
			await checkpointWriter(buildInventory());
			log(
				`walker: checkpoint — ${entries.length} entries written`,
			);
		} catch (err) {
			const msg = err instanceof Error ? err.message : String(err);
			process.stderr.write(`walker: checkpoint write failed: ${msg}\n`);
		}
	};

	// In-flight persistent skip: per-fingerprint count of distinct
	// surfaces this fingerprint has been observed on. The key matches
	// `parentChainOf(e)`+selector — same composite the post-walk
	// collapse uses, so the two passes agree on what counts as "the
	// same persistent element". Threshold for skipping a queue push is
	// ≥2 (cost-driven: stop drilling the SECOND time we see it).
	// Compare with post-walk collapse threshold of ≥3 (cleanliness-
	// driven: a pair of duplicates is more often a layout coincidence).
	const fingerprintSurfaces = new Map<string, Set<string>>();
	let inFlightSkipCount = 0;

	// Seed: the root surface (no clicks). Snapshot, emit entries, queue
	// each non-denylisted element.
	const rootSnap = await snapshotSurface(inspector);
	const rootSurfaceKey = surfaceKey(rootSnap);
	visitedSurfaces.add(rootSurfaceKey);
	const rootSurfaceId = 'root';

	const queue: QueueItem[] = [];
	const seedEntries = emitEntries({
		raws: rootSnap.elements,
		parentPath: [],
		surface: rootSurfaceId,
		appVersion,
		allowlist,
		vocabulary,
	});
	let seedDrills = 0;
	for (const e of seedEntries) {
		if (visitedElementIds.has(e.id)) continue;
		visitedElementIds.add(e.id);
		entries.push(e);
		const fpKey = fingerprintKey(e);
		bumpFingerprintSurface(fingerprintSurfaces, fpKey, rootSurfaceId);
		if (e.denylisted) {
			deniedActions += 1;
			continue;
		}
		if (entries.length >= maxElements) break;
		if (seedDrills >= maxDrillsPerSurface) continue;
		// In-flight skip: only relevant from the second surface onward —
		// at the root no fingerprint can have a prior surface, so the
		// check is effectively a no-op here. Kept for symmetry.
		if ((fingerprintSurfaces.get(fpKey)?.size ?? 0) >= 2) {
			inFlightSkipCount += 1;
			continue;
		}
		queue.push({
			path: [{ action: 'click', id: e.id }],
			parentSurfaceKey: rootSurfaceKey,
			parentRawCount: rootSnap.elements.length,
		});
		seedDrills += 1;
	}

	if (verbose) {
		log(
			`walker: seeded ${seedEntries.length} root entries ` +
				`(${queue.length} queued, ${seedEntries.length - queue.length} denylisted)`,
		);
	}

	// why: shared abort-check after any tryInspector failure. Either
	// counter overflow throws — they're independent thresholds.
	const checkAbort = (): void => {
		if (counters.inspector_timeout >= MAX_CONSECUTIVE_TIMEOUTS) {
			throw new Error(
				`walker: ${MAX_CONSECUTIVE_TIMEOUTS} consecutive inspector ` +
					`timeouts; aborting walk — renderer may be stuck`,
			);
		}
		if (counters.lookup_failure >= MAX_CONSECUTIVE_LOOKUP_FAILURES) {
			throw new Error(
				`walker: ${MAX_CONSECUTIVE_LOOKUP_FAILURES} consecutive ` +
					`redrive lookup failures; aborting walk — discovered DOM ` +
					`has drifted significantly from current state`,
			);
		}
	};

	// Main BFS loop.
	while (queue.length > 0 && entries.length < maxElements) {
		const item = queue.shift()!;
		const lastStep = item.path[item.path.length - 1];
		const lastClickId =
			lastStep && lastStep.action === 'click' ? lastStep.id : '<unknown>';

		// Re-drive from scratch. Wrapped via tryInspector so a renderer
		// hang counts toward the consecutive-timeout budget but doesn't
		// crash the walk. A successful redrive resets the counter.
		const redriveResult = await tryInspector(
			'redrive',
			lastClickId,
			() => redrivePath(inspector, startUrl, item.path),
		);
		if (!redriveResult.ok) {
			// Subtree prune: if a clickById lookup failed, every other
			// queued item whose path shares the failed step's prefix is
			// also unreachable (same physical click is broken). Drop them
			// all so a single sidebar drift doesn't burn N strikes for N
			// siblings. We only prune on lookup failures, not on real
			// inspector timeouts — a timeout might clear on retry, but a
			// missing-fingerprint failure is structural for that path.
			if (!redriveResult.err.message.includes('inspector.send timed out')) {
				const failedStep = identifyFailedStep(redriveResult.err, item.path);
				if (failedStep && failedStep.action === 'click') {
					const pruned = pruneDependentItems(queue, item.path, failedStep);
					if (pruned > 0) {
						log(
							`walker: pruned ${pruned} queued items dependent on ` +
								`unreachable element ${failedStep.id}`,
						);
					}
				}
			}
			checkAbort();
			continue;
		}

		const snapResult = await tryInspector(
			'snapshotSurface',
			lastClickId,
			() => snapshotSurface(inspector),
		);
		if (!snapResult.ok) {
			checkAbort();
			continue;
		}
		const afterSnap = snapResult.value;
		const afterKey = surfaceKey(afterSnap);

		// If clicking didn't change the surface fingerprint, treat it as
		// a no-op leaf (toggles, send buttons that we shouldn't have
		// clicked, etc.). Don't requeue children from a duplicate surface.
		if (visitedSurfaces.has(afterKey)) {
			if (verbose) {
				log(
					`walker: click ${lastClickId} → already-visited surface, skip`,
				);
			}
			continue;
		}
		visitedSurfaces.add(afterKey);

		// Diff: anything in afterSnap but missing from the parent snapshot
		// (by stable canonical-id) is a child of the just-clicked element.
		// We don't need to re-snapshot the parent — we recorded its raw
		// element count and we recompute IDs deterministically below.
		const childSurfaceId = lastClickId;
		const childKind = inferSurfaceKind(afterSnap.elements);
		const childRaws = afterSnap.elements;

		// Emit entries for the new surface. emitEntries dedupes within a
		// single call by canonicalId. We then dedupe globally against
		// visitedElementIds so e.g. a sidebar "Search" button visible from
		// every popover is only recorded once.
		if (verbose) {
			log(
				`walker: click ${lastClickId} → surface "${childSurfaceId}" ` +
					`(${childRaws.length} elements, kind=${childKind}, depth=${item.path.length})`,
			);
		}

		const newChildEntries = emitEntries({
			raws: childRaws,
			parentPath: item.path,
			surface: childSurfaceId,
			appVersion,
			allowlist,
			vocabulary,
			kindOverride: childKind,
		});

		let surfaceDrills = 0;
		for (const e of newChildEntries) {
			if (visitedElementIds.has(e.id)) continue;
			visitedElementIds.add(e.id);
			entries.push(e);
			const fpKey = fingerprintKey(e);
			bumpFingerprintSurface(fingerprintSurfaces, fpKey, childSurfaceId);
			if (e.denylisted) {
				deniedActions += 1;
				continue;
			}
			if (entries.length >= maxElements) break;
			if (surfaceDrills >= maxDrillsPerSurface) continue;
			// In-flight persistent skip: count of distinct surfaces this
			// fingerprint has been seen on (including the current one). ≥2
			// means at least one other surface already queued it, so we
			// emit but do not requeue. Saves the BFS budget that v3 was
			// burning on duplicate sidebar clicks.
			if ((fingerprintSurfaces.get(fpKey)?.size ?? 0) >= 2) {
				inFlightSkipCount += 1;
				continue;
			}
			queue.push({
				path: [...item.path, { action: 'click', id: e.id }],
				parentSurfaceKey: afterKey,
				parentRawCount: childRaws.length,
			});
			surfaceDrills += 1;
		}

		// Periodic checkpoint write. Cost is one disk write per ~N
		// entries; keeps progress on disk so a hang/crash/Ctrl-C doesn't
		// erase the run. Failures here log but don't abort — losing one
		// checkpoint is recoverable, losing the walk isn't.
		await maybeCheckpoint();
	}

	if (entries.length >= maxElements) {
		log(
			`walker: reached --max-elements=${maxElements} cap; ` +
				`queue still has ${queue.length} items`,
		);
	}

	if (inFlightSkipCount > 0) {
		log(
			`walker: in-flight skip prevented ${inFlightSkipCount} ` +
				`redundant queue pushes`,
		);
	}

	// Post-walk persistent-element collapse: chrome / sidebar elements
	// reappear on every surface; collapse N copies → 1 entry tagged
	// `kind: 'persistent'` with the full `surfaces[]` list. After v4's
	// in-flight skip this is largely defensive — leftovers here are
	// fingerprints first observed on later surfaces (so the in-flight
	// skip couldn't predict them) plus anything that crossed the
	// threshold only after the walk.
	const collapsed = collapsePersistentEntries(entries);
	const droppedByCollapse = entries.length - collapsed.entries.length;
	if (droppedByCollapse > 0) {
		log(
			`walker: collapsed ${droppedByCollapse} entries into ` +
				`${collapsed.persistentSurvivors} persistent shells`,
		);
	}

	return {
		capturedAt: new Date().toISOString(),
		appVersion,
		walkerVersion: WALKER_VERSION,
		startUrl,
		totalElements: collapsed.entries.length,
		deniedActions,
		entries: collapsed.entries,
	};
}

// Extract the failed step from a clickById error. The error message
// format is `clickById: no element matches "X" on current surface`
// where X is the element ID. We map that ID back to the matching
// click-step in the path. Returns null if we can't pin a step (which
// means the prune path skips — better to lose a prune optimization
// than to prune wrong items). Exported for the self-test only.
export function identifyFailedStep(
	err: Error,
	path: NavStep[],
): NavStep | null {
	const m = err.message.match(/no element matches "([^"]+)"/);
	if (!m) return null;
	const failedId = m[1]!;
	for (const step of path) {
		if (step.action === 'click' && step.id === failedId) return step;
	}
	return null;
}

// Drop any queue item whose path shares the same prefix as the failed
// item's path up through and including the failed step. Matches on
// step.id for clicks (the structural identity of the click) AND on
// the prefix actually matching the failed item's path — the "same
// physical click that just broke", not a coincidentally-same element
// ID further down some unrelated subtree. Returns the number of items
// removed. Exported for the self-test only.
export function pruneDependentItems(
	queue: QueueItem[],
	failedPath: NavStep[],
	failedStep: NavStep,
): number {
	if (failedStep.action !== 'click') return 0;
	// Find the failed step's index in the failed path; the prefix to
	// match against other items is everything up to and including it.
	const idx = failedPath.findIndex(
		(s) => s.action === 'click' && s.id === failedStep.id,
	);
	if (idx < 0) return 0;
	const prefix = failedPath.slice(0, idx + 1);
	let pruned = 0;
	for (let i = queue.length - 1; i >= 0; i -= 1) {
		const it = queue[i]!;
		if (it.path.length < prefix.length) continue;
		let match = true;
		for (let j = 0; j < prefix.length; j += 1) {
			const a = prefix[j]!;
			const b = it.path[j]!;
			if (a.action !== b.action) {
				match = false;
				break;
			}
			if (a.action === 'click' && b.action === 'click' && a.id !== b.id) {
				match = false;
				break;
			}
		}
		if (match) {
			queue.splice(i, 1);
			pruned += 1;
		}
	}
	return pruned;
}

// Replay each step in a path against a fresh navigation. Per the
// algorithm note at the top, this is intentionally redundant: every
// queue pop re-navigates rather than continuing from the previous
// state. Slow but robust against drift. Exported for the U-prefix
// render-spec runners (auto-generated from the inventory) which
// re-drive each entry's recorded path before asserting visibility.
export async function redrivePath(
	inspector: InspectorClient,
	startUrl: string,
	path: NavStep[],
): Promise<void> {
	// Force a reload before replaying. Two cases:
	//   1. Renderer already at startUrl (walker BFS between drills, or
	//      U01 between two tests with empty/short paths that didn't
	//      change the URL). `navigateTo(startUrl)` short-circuits on
	//      URL match, so a prior drill's residual SPA state (open
	//      dialog, expanded sidebar, scrolled focus) would bleed in.
	//      Use `reloadPage` to discard the React tree.
	//   2. Renderer drifted to a deeper URL (U01 between a test that
	//      drilled into /settings/customize and a test starting from
	//      /epitaxy). `reloadPage` would reload the wrong URL and
	//      break the assumed startUrl baseline. Use `navigateTo` so
	//      the React tree remounts at startUrl.
	//
	// After the reload/navigate, AX starts empty and Chromium
	// repopulates it asynchronously. `waitForStable`'s 1.5s ceiling
	// expires long before claude.ai's React tree finishes mounting on
	// a cold load, so the explicit `waitForAxTreeStable({ minNodes: 20 })`
	// gates the first snapshot. Subsequent in-path clicks rely on the
	// AX-stable wait baked into `snapshotSurface`.
	const cur = await currentUrl(inspector);
	if (cur === startUrl) {
		await reloadPage(inspector);
	} else {
		await navigateTo(inspector, startUrl);
	}
	await waitForStable(inspector);
	await waitForAxTreeStable(inspector, { minNodes: 20 });
	for (const step of path) {
		switch (step.action) {
			case 'navigate':
				await navigateTo(inspector, step.url);
				await waitForStable(inspector);
				await waitForAxTreeStable(inspector, { minNodes: 20 });
				break;
			case 'click':
				await clickById(inspector, step.id);
				await waitForStable(inspector);
				break;
			case 'press-key':
				await pressKey(inspector, step.key);
				await waitForStable(inspector);
				break;
			case 'wait-for-stable':
				await waitForStable(inspector);
				break;
		}
	}
}

// Resolve an inventory entry's v7 fingerprint against the current
// renderer state. Used by the auto-generated U-prefix specs to assert
// every recorded element still renders.
//
// Strategy chain (per fingerprint-v7-plan.md "Resolver"):
//   1. Primary — full ariaPath + leaf criteria.
//   2. Relaxed-scope — drop the deepest ariaPath step, retry.
// When (2) succeeds we return `strategy: 'aria-tree-relaxed'` plus a
// `drift` tag so U01 can attach a soft warning rather than failing.
// `kind` from the inventory entry tunes match strictness — see the
// kind-strictness matrix in the plan. `kind === 'instance'` requires
// only ≥1 match scoped to the ariaPath; everything else requires
// exactly one.
export type ResolverStrategy =
	| 'aria-tree'
	| 'aria-tree-relaxed';

export interface FindResult {
	found: boolean;
	reason: string | null;
	outerHTMLSnippet: string | null;
	strategy: ResolverStrategy | null;
	drift: 'scope-shifted' | null;
}

export async function findByFingerprint(
	inspector: InspectorClient,
	fingerprint: Fingerprint,
	kind: InventoryEntry['kind'],
): Promise<FindResult> {
	const snapshot = await snapshotSurface(inspector);
	// Strictness drops to "≥1 match" in two cases: (a) lifecycle kinds
	// where the inventory contract is "this bag of items exists"
	// (instance / menu), or (b) fingerprints whose capture-time shape
	// is degenerate — no leaf name, no siblingIndex, just role-under-
	// path. The post-walk persistent-collapse promotes some entries
	// from kind=instance to kind=persistent (cross-surface chrome),
	// but a degenerate fingerprint can't match exactly one regardless
	// of lifecycle, so we defer to `classification` here too.
	const expectExactlyOne =
		kind !== 'instance' &&
		kind !== 'menu' &&
		fingerprint.classification !== 'instance';

	const tryQuery = (
		path: AriaStep[],
		strategy: ResolverStrategy,
		drift: FindResult['drift'],
	): FindResult | null => {
		const matches = queryAccessibleTree(snapshot.elements, {
			ariaPath: path,
			leaf: {
				role: fingerprint.leaf.role,
				name: fingerprint.leaf.name,
			},
		});
		if (matches.length === 0) return null;
		// kind-strictness: persistent / structural require uniqueness;
		// instance / menu accept ≥1.
		if (expectExactlyOne && matches.length > 1) {
			return {
				found: false,
				reason: `expected exactly one match, got ${matches.length}`,
				outerHTMLSnippet: null,
				strategy,
				drift,
			};
		}
		// siblingIndex narrowing — only when the fingerprint actually
		// recorded one (positional case).
		const si = fingerprint.leaf.siblingIndex;
		const winner = si
			? matches.find(
					(m) =>
						m.computedRole === si.role &&
						m.siblingPosition === si.position,
				)
			: matches[0];
		if (!winner) {
			return {
				found: false,
				reason: 'siblingIndex mismatch (no match at recorded position)',
				outerHTMLSnippet: null,
				strategy,
				drift,
			};
		}
		return {
			found: true,
			reason: null,
			outerHTMLSnippet: null,
			strategy,
			drift,
		};
	};

	const primary = tryQuery(fingerprint.ariaPath, 'aria-tree', null);
	if (primary && primary.found) return primary;

	if (fingerprint.ariaPath.length > 1) {
		const relaxed = tryQuery(
			fingerprint.ariaPath.slice(0, -1),
			'aria-tree-relaxed',
			'scope-shifted',
		);
		if (relaxed && relaxed.found) return relaxed;
	}

	return {
		found: false,
		reason: primary?.reason ?? 'no-match',
		outerHTMLSnippet: null,
		strategy: null,
		drift: null,
	};
}

interface EmitOpts {
	raws: RawElement[];
	parentPath: NavStep[];
	surface: string;
	appVersion: string;
	allowlist: Set<string>;
	vocabulary: Vocabulary;
	kindOverride?: InventoryEntry['kind'];
}

function emitEntries(opts: EmitOpts): InventoryEntry[] {
	// v7 emission: per element, run the captureFingerprint algorithm
	// against the same surface's interactive-element list. The
	// algorithm decides classification (stable / positional / instance)
	// and the leaf's name matcher (literal / pattern / null).
	//
	// Instance-group collapse from v6 is preserved at the *emission*
	// layer: when 3+ siblings produce identical structural fingerprints
	// (same ariaPath + leaf role + classification === 'instance'), we
	// emit a single representative tagged with `+N` so the inventory
	// stays readable. Resolver semantics for `instance` are "≥1 match
	// in scope" so the dropped siblings don't change the assertion
	// surface.
	type Candidate = {
		raw: RawElement;
		label: string;
		fingerprint: Fingerprint;
		idTail: string;
		groupKey: string;
		groupCount: number;
	};
	const candidates: Candidate[] = [];
	const groupCounts = new Map<string, number>();
	for (const raw of opts.raws) {
		if (!raw.visible) continue;
		const label = pickLabel(raw);
		if (!label) continue;
		const fingerprint = captureFingerprint(raw, opts.raws, opts.vocabulary);
		const idTail = idTailFromFingerprint(fingerprint);
		// Group key for instance-collapse: same structural id-tail AND
		// classification === 'instance'. Two stable buttons with the
		// same role at the same path level get the `#N` ordinal scheme;
		// two instances get the `+N` collapse.
		const groupKey =
			fingerprint.classification === 'instance'
				? `${idTail}::instance`
				: '';
		if (groupKey) {
			groupCounts.set(groupKey, (groupCounts.get(groupKey) ?? 0) + 1);
		}
		candidates.push({
			raw,
			label,
			fingerprint,
			idTail,
			groupKey,
			groupCount: 0,
		});
	}

	const collapsedSeen = new Set<string>();
	const ordinalSeen = new Map<string, number>();
	const out: InventoryEntry[] = [];
	const ts = new Date().toISOString();

	for (const cand of candidates) {
		const isInstanceGroup =
			cand.groupKey !== '' && (groupCounts.get(cand.groupKey) ?? 0) >= 3;
		if (isInstanceGroup && collapsedSeen.has(cand.groupKey)) continue;

		const baseId = `${opts.surface}.${cand.idTail}`;
		const ord = (ordinalSeen.get(baseId) ?? 0) + 1;
		ordinalSeen.set(baseId, ord);
		let id = ord === 1 ? baseId : `${baseId}#${ord}`;

		const denylisted =
			!opts.allowlist.has(id) &&
			(matchesDenylist(cand.label) || isDestructiveDialogButton(cand.raw));

		let kind: InventoryEntry['kind'] =
			opts.kindOverride ??
			(cand.raw.insideModalDialog ? 'dialog' : 'structural');
		let instanceCount: number | undefined;
		let instanceLabelPattern: string | undefined;
		if (isInstanceGroup) {
			collapsedSeen.add(cand.groupKey);
			const count = groupCounts.get(cand.groupKey)!;
			kind = 'instance';
			instanceCount = count;
			{
				const ln = cand.fingerprint.leaf.name;
				instanceLabelPattern =
					ln && ln.kind === 'pattern' ? ln.regex : cand.idTail;
			}
			id = `${id}+${count}`;
		}

		const entry: InventoryEntry = {
			id,
			label: cand.label,
			role: cand.fingerprint.leaf.role,
			fingerprint: cand.fingerprint,
			navigationPath: [...opts.parentPath],
			surface: opts.surface,
			kind,
			denylisted,
			discoveredAt: ts,
			appVersion: opts.appVersion,
		};
		if (instanceCount !== undefined) entry.instanceCount = instanceCount;
		if (instanceLabelPattern !== undefined) {
			entry.instanceLabelPattern = instanceLabelPattern;
		}
		out.push(entry);
	}
	return out;
}

// Roles whose computed-role contributes a step to the v7 ariaPath.
// Mirrors the plan's "landmark / region / grouping" set. Anything
// outside this set is ignored when building the path so cosmetic
// `<div>` chrome doesn't bloat the fingerprint.
const ARIA_PATH_ROLES = new Set<string>([
	'banner',
	'main',
	'navigation',
	'region',
	'complementary',
	'contentinfo',
	'search',
	'form',
	'toolbar',
	'menu',
	'menubar',
	'listbox',
	'list',
	'dialog',
	'tablist',
	'tabpanel',
	'group',
]);

// `walkLandmarkAncestors` filters a raw ancestor chain to the landmark
// + grouping subset and returns AriaSteps (role + optional name).
// Names are included only for ancestors whose role is ambiguous
// without one (region, dialog, group, list when more than one of the
// same role would otherwise be indistinguishable). The runtime
// uniqueness check at capture time decides whether each step's name
// is needed; this function emits all available names and lets
// captureFingerprint trim what isn't load-bearing.
export function walkLandmarkAncestors(raw: RawElement): AriaStep[] {
	const out: AriaStep[] = [];
	for (const a of raw.ancestors) {
		if (!a.role || !ARIA_PATH_ROLES.has(a.role)) continue;
		const name: NameMatcher | null = a.name
			? { kind: 'literal', value: a.name }
			: null;
		out.push({ role: a.role, name });
	}
	return out;
}

interface AxQuery {
	ariaPath: AriaStep[];
	leaf: {
		role: string;
		name?: NameMatcher | null;
	};
}

function ariaStepMatches(a: AriaStep, b: AriaStep): boolean {
	if (a.role !== b.role) return false;
	// Path matching is structural — names on path steps are advisory
	// (a literal-named "Recents" toolbar disambiguates from a
	// "Pinned" toolbar but two anonymous toolbars at the same depth
	// still match).
	if (a.name === null || b.name === null) return true;
	const an = a.name;
	const bn = b.name;
	if (an.kind === 'literal' && bn.kind === 'literal') {
		return an.value === bn.value;
	}
	if (an.kind === 'pattern' && bn.kind === 'literal') {
		return new RegExp(an.regex).test(bn.value);
	}
	if (an.kind === 'literal' && bn.kind === 'pattern') {
		return new RegExp(bn.regex).test(an.value);
	}
	if (an.kind === 'pattern' && bn.kind === 'pattern') {
		return an.regex === bn.regex;
	}
	return false;
}

function pathMatches(query: AriaStep[], candidate: AriaStep[]): boolean {
	if (query.length !== candidate.length) return false;
	for (let i = 0; i < query.length; i += 1) {
		if (!ariaStepMatches(query[i]!, candidate[i]!)) return false;
	}
	return true;
}

function nameMatches(matcher: NameMatcher, name: string | null): boolean {
	if (name === null) return false;
	if (matcher.kind === 'literal') return matcher.value === name;
	return new RegExp(matcher.regex).test(name);
}

// `queryAccessibleTree` filters a snapshot's interactive elements
// against an ariaPath + leaf-criteria query. Used at capture time to
// score uniqueness; used at resolve time (Phase 3) for the same query
// against the live snapshot.
export function queryAccessibleTree(
	elements: RawElement[],
	query: AxQuery,
): RawElement[] {
	const out: RawElement[] = [];
	for (const el of elements) {
		if (!el.visible) continue;
		const elPath = walkLandmarkAncestors(el);
		if (!pathMatches(query.ariaPath, elPath)) continue;
		if (el.computedRole !== query.leaf.role) continue;
		if (query.leaf.name !== undefined && query.leaf.name !== null) {
			const elName = bestName(el);
			if (!nameMatches(query.leaf.name, elName)) continue;
		}
		out.push(el);
	}
	return out;
}

function bestName(raw: RawElement): string | null {
	if (raw.accessibleName && raw.accessibleName.trim()) {
		return raw.accessibleName.trim();
	}
	return null;
}

// `captureFingerprint` runs the v7 capture algorithm for one element
// against the surface's interactive-element list (used as the query
// substrate). Returns the structurally-shaped fingerprint with the
// minimal set of disambiguators needed for uniqueness — see
// fingerprint-v7-plan.md "Capture algorithm".
export function captureFingerprint(
	raw: RawElement,
	surface: RawElement[],
	vocabulary: Vocabulary,
): Fingerprint {
	const ariaPath = walkLandmarkAncestors(raw);
	const role = raw.computedRole;
	const name = bestName(raw);

	// Step 1 — uniqueness without the name.
	const step1 = queryAccessibleTree(surface, {
		ariaPath,
		leaf: { role },
	});
	if (step1.length === 1) {
		return {
			ariaPath,
			leaf: { role, name: null, siblingIndex: null },
			classification: 'stable',
		};
	}

	// Step 2 — name as discriminator. Skip when the name is pure-
	// instance (regex hit with no pattern, e.g. long titles) OR when
	// the element is a list-row child (option / listitem / button
	// inside a list / listbox / group) — both are list-membership cases
	// the resolver handles via ancestor scope, not via name match. The
	// list-row rule comes from the v7 plan's "Name classifier" §2 but
	// is applied here because the classifier only sees the name, not
	// the ariaPath.
	//
	// `button` joins option/listitem because claude.ai's session lists
	// expose each row as `button` (not `option`) under a `list`-rolled
	// container — without this rule per-row buttons like "Open session
	// <title>" classify by their literal title, multiplying inventory
	// noise and creating per-account drift the resolver can't recover
	// from. `group` joins list/listbox because Radix-style segmented
	// pickers wrap their options in `group` and the per-option labels
	// are stable enumeration values that vary per surface.
	const cls = classifyName(name, vocabulary);
	const LIST_ROW_ROLES = new Set(['option', 'listitem', 'button']);
	const LIST_ANCESTOR_ROLES = new Set(['listbox', 'list', 'group']);
	// Sibling-count heuristic: any element with ≥15 same-role siblings
	// under the same AX parent is structurally a list row regardless of
	// whether the upstream HTML actually uses `role="list"`. Catches the
	// connect-apps marketplace dialog (~80 install cards under a plain
	// dialog) and the cowork sidebar (72 session buttons under
	// `complementary`) without needing a per-collection regex. Threshold
	// 15 sits well above realistic toolbar / button-group sizes (≤10
	// in practice) and well below the smallest real marketplace
	// (claude.ai's connect-apps catalog at ~80).
	const SIBLING_LIST_THRESHOLD = 15;
	const isListRowChild =
		(LIST_ROW_ROLES.has(raw.computedRole) &&
			ariaPath.some((s) => LIST_ANCESTOR_ROLES.has(s.role))) ||
		raw.siblingTotal >= SIBLING_LIST_THRESHOLD;
	const skipNameStep =
		(cls.kind === 'instance' && cls.pattern === null) || isListRowChild;
	if (!skipNameStep) {
		const matcher: NameMatcher | null = (() => {
			if (cls.kind === 'positional') return null;
			if (cls.kind === 'instance' && cls.pattern) {
				return { kind: 'pattern', regex: cls.pattern };
			}
			return name ? { kind: 'literal', value: name } : null;
		})();
		if (matcher !== null) {
			const step2 = queryAccessibleTree(surface, {
				ariaPath,
				leaf: { role, name: matcher },
			});
			if (step2.length === 1) {
				const classification: Fingerprint['classification'] =
					cls.kind === 'instance'
						? 'instance'
						: cls.kind === 'positional'
							? 'positional'
							: 'stable';
				return {
					ariaPath,
					leaf: { role, name: matcher, siblingIndex: null },
					classification,
				};
			}
		}
	}

	// Step 3 — sibling position. Skipped for list-row children: those
	// already hit step 2's name skip, and assigning them a positional
	// siblingIndex would fragment the row set into N entries (each at a
	// different index) that can't collapse via step 4's `instance`
	// shape. Falling through to step 4 keeps every row sharing the
	// same `<scope>.<role>-instance` id-tail so they fold to one
	// representative.
	if (raw.siblingTotal > 1 && !isListRowChild) {
		return {
			ariaPath,
			leaf: {
				role,
				name: null,
				siblingIndex: {
					role,
					position: raw.siblingPosition,
					total: raw.siblingTotal,
				},
			},
			classification: 'positional',
		};
	}

	// Step 4 — instance, ariaPath-scoped only.
	return {
		ariaPath,
		leaf: { role, name: null, siblingIndex: null },
		classification: 'instance',
	};
}

// Reverse-lookup an INSTANCE_SHAPES entry by its recorded `pattern`
// (the canonical regex string serialised into the fingerprint's
// NameMatcher). The regex source is the durable identity; the
// human-readable shape id is recovered for ID readability only.
function shapeIdForPattern(pattern: string): string | null {
	for (const shape of INSTANCE_SHAPES) {
		if (shape.pattern === pattern) return shape.id;
	}
	return null;
}

// Build the structural-id tail for a fingerprint. Tail = ariaPath
// roles joined + leaf descriptor; the surface prefix is added by the
// caller. Examples:
//   stable, no name:                 banner.button
//   positional sibling:              banner.toolbar.button[2]
//   stable name pattern (plan badge):banner.button-by-shape.plan-badge
//   stable literal name:             banner.button-by-name.search
//   instance (no pattern):           main.list.button-instance
function idTailFromFingerprint(fp: Fingerprint): string {
	const pathSegs = fp.ariaPath.map((s) => s.role);
	const leaf = fp.leaf;
	let leafSeg = leaf.role;
	if (leaf.siblingIndex) {
		leafSeg = `${leaf.role}[${leaf.siblingIndex.position}]`;
	} else if (leaf.name && fp.classification === 'instance') {
		// Instance with a pattern matcher — encode the shape id.
		// (`fp.classification === 'instance'` handles the v7 plan's
		// "instance-shaped, but resolver still scopes to ariaPath" case.)
		const sid =
			leaf.name.kind === 'pattern'
				? shapeIdForPattern(leaf.name.regex)
				: null;
		leafSeg = `${leaf.role}-by-shape.${sid ?? 'pattern'}`;
	} else if (leaf.name && fp.classification === 'stable') {
		// Step-2 stable: include the literal name slug, but only when
		// it's load-bearing (the algorithm only emits a name when step
		// 1 was non-unique).
		const slug = leaf.name.kind === 'literal'
			? slugify(leaf.name.value)
			: 'pattern';
		leafSeg = `${leaf.role}-by-name.${slug}`;
	} else if (fp.classification === 'instance') {
		leafSeg = `${leaf.role}-instance`;
	}
	return [...pathSegs, leafSeg].join('.');
}

// Composite key for the persistent-element collapse. v7 keys on the
// structural ariaPath + leaf role + leaf-name-matcher (when present)
// — same shape as `idTailFromFingerprint` but without the surface
// prefix. Two entries with the same key (across different surfaces)
// represent the same logical chrome element.
function fingerprintKey(e: InventoryEntry): string {
	return idTailFromFingerprint(e.fingerprint);
}

// Track distinct surfaces a fingerprint has appeared on. Set semantics
// matter — the same surface emitting the same fingerprint twice (rare
// after instance grouping but possible) must NOT push count past 1.
function bumpFingerprintSurface(
	map: Map<string, Set<string>>,
	fpKey: string,
	surface: string,
): void {
	let s = map.get(fpKey);
	if (!s) {
		s = new Set();
		map.set(fpKey, s);
	}
	s.add(surface);
}

// Post-walk persistent collapse. Why a separate pass instead of
// folding into `emitEntries`: the emitter sees one surface at a time,
// so it cannot tell that the sidebar's "More options for …" buttons
// have already been recorded on five other surfaces. Only after the
// full BFS completes do we have the cross-surface view needed to
// detect chrome.
//
// Group key: structural id-tail (`fingerprintKey`). The ariaPath +
// leaf-role + leaf-name-matcher together encode both the element's
// identity (role + name) and its position (landmark scope), giving a
// strong "same logical element seen on multiple surfaces" signal
// without false-positiving on coincidentally-similarly-labelled
// controls in unrelated regions.
//
// Survivor pick: shortest navigationPath wins (cheapest to re-drive
// downstream). Ties broken on lexicographic surface ID so the output
// is deterministic across runs.
//
// Threshold ≥3: matches the instance-grouper threshold. A pair of
// duplicates is more often coincidental layout than a real persistent
// shell; insisting on three prevents false collapses.
export function collapsePersistentEntries(entries: InventoryEntry[]): {
	entries: InventoryEntry[];
	persistentSurvivors: number;
} {
	type Group = { key: string; members: InventoryEntry[] };
	const groups = new Map<string, Group>();
	for (const e of entries) {
		const key = fingerprintKey(e);
		let g = groups.get(key);
		if (!g) {
			g = { key, members: [] };
			groups.set(key, g);
		}
		g.members.push(e);
	}

	// Build the new entry list in original order so consumers reading
	// the inventory top-down still see chrome first, then deeper. We
	// stamp survivors and skip dropped duplicates as we walk.
	const survivorByKey = new Map<string, InventoryEntry>();
	const droppedIds = new Set<symbol>();
	let persistentSurvivors = 0;
	for (const g of groups.values()) {
		const distinctSurfaces = new Set(g.members.map((m) => m.surface));
		if (distinctSurfaces.size < 3) continue;
		// Pick survivor: shortest navigationPath; tie-break on surface ID.
		const sorted = [...g.members].sort((a, b) => {
			const pa = a.navigationPath.length;
			const pb = b.navigationPath.length;
			if (pa !== pb) return pa - pb;
			return a.surface < b.surface ? -1 : a.surface > b.surface ? 1 : 0;
		});
		const survivor = sorted[0]!;
		const surfaces = [...distinctSurfaces].sort();
		survivorByKey.set(g.key, {
			...survivor,
			kind: 'persistent',
			surfaces,
		});
		persistentSurvivors += 1;
		// Mark every non-survivor for removal. Use object identity (via
		// a Map keyed on the original entry reference) so we don't lean
		// on entry.id being unique — instance ids can collide cross-
		// surface in pathological inputs.
		for (const m of g.members) {
			if (m === survivor) continue;
			droppedIds.add(refTag(m));
		}
	}

	const out: InventoryEntry[] = [];
	const emittedKeys = new Set<string>();
	for (const e of entries) {
		const key = fingerprintKey(e);
		const survivor = survivorByKey.get(key);
		if (survivor) {
			if (emittedKeys.has(key)) continue;
			emittedKeys.add(key);
			out.push(survivor);
			continue;
		}
		if (droppedIds.has(refTag(e))) continue;
		out.push(e);
	}
	return { entries: out, persistentSurvivors };
}

// Identity tags for entries; we can't use entry.id alone because two
// surfaces can mint the same id (the prefix is the surface, but the
// id can repeat after slugify). A WeakMap-of-symbols keyed on the
// reference gives us a stable "is this exact object" tag without
// mutating the entries themselves.
const REF_TAGS = new WeakMap<InventoryEntry, symbol>();
function refTag(e: InventoryEntry): symbol {
	let s = REF_TAGS.get(e);
	if (!s) {
		s = Symbol();
		REF_TAGS.set(e, s);
	}
	return s;
}

function pickLabel(raw: RawElement): string {
	// AX has already resolved the name cascade; no separate fallback.
	if (raw.accessibleName && raw.accessibleName.trim().length > 0) {
		return raw.accessibleName.trim();
	}
	return '';
}

function slugify(s: string): string {
	return s
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '')
		.slice(0, 60);
}

function matchesDenylist(label: string): boolean {
	for (const re of DEFAULT_DENYLIST) {
		if (re.test(label)) return true;
	}
	return false;
}

// Heuristic: any element inside a dialog ancestor whose AX-derived
// name reads as primary-destructive. AX doesn't expose `data-state`
// or `aria-modal` cheaply (would need per-node `properties[]` parsing),
// so we accept matching non-modal dialogs too — better to over-protect
// against auto-clicking a destructive control than to chase the modal
// distinction.
function isDestructiveDialogButton(raw: RawElement): boolean {
	if (!raw.insideModalDialog) return false;
	const lab = (raw.accessibleName ?? '').toLowerCase();
	return /delete|remove|destroy|wipe|sign out|log out/.test(lab);
}

function inferSurfaceKind(raws: RawElement[]): InventoryEntry['kind'] {
	if (
		raws.some(
			(r) =>
				r.computedRole === 'menuitem' ||
				r.computedRole === 'menuitemradio',
		)
	) {
		return 'menu';
	}
	if (raws.some((r) => r.insideModalDialog)) return 'dialog';
	return 'structural';
}

function surfaceKey(snap: SurfaceSnapshot): string {
	const ids = snap.elements
		.filter((r) => r.visible)
		.map((r) => {
			const lab = pickLabel(r) || '<no-label>';
			return `${r.computedRole.toLowerCase()}::${lab}`;
		})
		.sort();
	return `${snap.url} :: ${ids.join('|')}`;
}

// Roles we treat as "interactive leaves" — emitted to the inventory
// and used as queue seeds. Mirrors the v6 selector set, expressed in
// AX-role terms (so `<button role="link">` shows up as `link`, which
// is what AX reports).
const INTERACTIVE_AX_ROLES = new Set<string>([
	'button',
	'link',
	'menuitem',
	'menuitemradio',
	'menuitemcheckbox',
	'tab',
	'option',
]);

// Roles that indicate a dialog ancestor; any such ancestor flips
// `insideModalDialog`. The destructive-button heuristic is the only
// downstream consumer.
const DIALOG_AX_ROLES = new Set<string>(['dialog', 'alertdialog']);

// `axTreeToSnapshot` adapts CDP's `Accessibility.getFullAXTree` output
// into the RawElement shape the rest of the walker consumes. Filtering
// rules:
//   - `ignored` nodes are dropped from emission and from sibling counts
//     (they're not exposed to assistive tech and we don't want to
//     drill into them either). Their children remain visible to the
//     ancestor walk via the raw tree links — but `walkLandmarkAncestors`
//     only consumes landmark roles, so generic ignored containers
//     filter themselves out anyway.
//   - Only nodes whose `role.value` is in `INTERACTIVE_AX_ROLES` get
//     emitted as elements. Everything else (RootWebArea, generics,
//     paragraphs) shows up only as ancestors.
export function axTreeToSnapshot(nodes: AxNode[]): RawElement[] {
	const byId = new Map<string, AxNode>();
	for (const n of nodes) byId.set(n.nodeId, n);

	const childrenById = new Map<string, AxNode[]>();
	for (const n of nodes) {
		if (n.parentId === undefined) continue;
		let arr = childrenById.get(n.parentId);
		if (!arr) {
			arr = [];
			childrenById.set(n.parentId, arr);
		}
		arr.push(n);
	}

	const ancestorName = (n: AxNode): string | null => {
		const v = n.name?.value;
		return v && v.trim().length > 0 ? v : null;
	};

	const out: RawElement[] = [];
	for (const node of nodes) {
		if (node.ignored === true) continue;
		const role = node.role?.value;
		if (!role || !INTERACTIVE_AX_ROLES.has(role)) continue;

		const accessibleName = ancestorName(node);

		const ancestors: RawAncestor[] = [];
		let modal = false;
		{
			let pid = node.parentId;
			while (pid !== undefined) {
				const p = byId.get(pid);
				if (!p) break;
				if (p.ignored !== true) {
					const arole = p.role?.value ?? null;
					ancestors.push({ role: arole, name: ancestorName(p) });
					if (arole && DIALOG_AX_ROLES.has(arole)) modal = true;
				}
				pid = p.parentId;
			}
		}
		ancestors.reverse();

		let siblingPosition = 0;
		let siblingTotal = 1;
		if (node.parentId !== undefined) {
			const sibs = (childrenById.get(node.parentId) ?? []).filter(
				(c) => c.ignored !== true && c.role?.value === role,
			);
			const idx = sibs.indexOf(node);
			if (idx >= 0) {
				siblingPosition = idx;
				siblingTotal = Math.max(sibs.length, 1);
			}
		}

		out.push({
			computedRole: role,
			accessibleName,
			visible: true,
			insideModalDialog: modal,
			ancestors,
			siblingPosition,
			siblingTotal,
			backendDOMNodeId: node.backendDOMNodeId ?? null,
		});
	}
	return out;
}

async function snapshotSurface(
	inspector: InspectorClient,
): Promise<SurfaceSnapshot> {
	const url = await currentUrl(inspector);
	// Always wait for two consecutive AX reads at the same node count
	// before treating the snapshot as authoritative. claude.ai's React
	// tree updates within ~50ms of a click and Chromium's accessibility
	// tree lags behind by several hundred ms on most surfaces — a single
	// `getFullAXTree` taken right after `clickById` reliably sees a
	// stale-or-partial tree, so suffix-matching against `idTailFromFingerprint`
	// fails for any element that just appeared. Cost on an already-stable
	// surface is ~800ms (one read + 400ms poll + one read); cold loads
	// take longer but are gated separately by the seed/navigation
	// `waitForAxTreeStable({ minNodes: 20 })` calls.
	await waitForAxTreeStable(inspector, { minNodes: 1, timeoutMs: 10000 });
	const nodes = await inspector.getAccessibleTree('claude.ai');
	return { url, elements: axTreeToSnapshot(nodes) };
}

// Wait for the AX tree to stop growing/shrinking — two consecutive
// reads at the same node count means Chromium has finished computing
// the accessibility tree for the current DOM. Used by the walker's
// seed phase because:
//   1. `Accessibility.enable` is implicit on the first `getFullAXTree`
//      call, and the very first tree is often a partial computation.
//   2. claude.ai's SPA mounts ~5–8s after the renderer signals
//      `claudeAi` ready — `waitForStable` (1.5s ceiling) returns long
//      before the React tree has rendered, so a snapshot taken right
//      after `waitForStable` reliably sees an empty surface.
// Cheap to call (≥800ms when already stable, on the order of seconds
// when not). Not called between clicks — `waitForStable` handles those
// because the existing DOM-mutation observer is the right gate for an
// already-mounted SPA.
export async function waitForAxTreeStable(
	inspector: InspectorClient,
	opts: { timeoutMs?: number; pollMs?: number; minNodes?: number } = {},
): Promise<number> {
	const timeoutMs = opts.timeoutMs ?? 30000;
	const pollMs = opts.pollMs ?? 400;
	const minNodes = opts.minNodes ?? 1;
	const deadline = Date.now() + timeoutMs;
	let prevSize = -1;
	let stableReads = 0;
	let lastSize = 0;
	while (Date.now() < deadline) {
		const nodes = await inspector.getAccessibleTree('claude.ai');
		lastSize = nodes.length;
		if (lastSize === prevSize && lastSize >= minNodes) {
			stableReads += 1;
			if (stableReads >= 2) return lastSize;
		} else {
			stableReads = 0;
			prevSize = lastSize;
		}
		if (Date.now() < deadline) await sleep(pollMs);
	}
	return lastSize;
}

// Exported for the U-prefix render-spec runners — they need the same
// "what URL is the renderer on right now" probe the walker uses, so
// the spec and the inventory agree on the surface they're comparing.
export async function currentUrl(inspector: InspectorClient): Promise<string> {
	return await inspector.evalInRenderer<string>(
		'claude.ai',
		`(() => location.href)()`,
	);
}

async function readAppVersion(
	inspector: InspectorClient,
): Promise<string | null> {
	try {
		return await inspector.evalInMain<string>(`
			const { app } = process.mainModule.require('electron');
			return app.getVersion();
		`);
	} catch {
		return null;
	}
}

// Mutation-quiescence: wait for `document.readyState === 'complete'`
// then for ~250ms with no DOM mutations. The window is small because
// claude.ai's React tree mutates constantly (typing indicators, etc.);
// we just need "no in-flight render is replacing the surface we're
// about to probe". 1.5s ceiling stops us hanging on a chat that's
// actively streaming a response. Exported so the U-prefix render-spec
// runners use the exact same quiescence the walker used.
export async function waitForStable(inspector: InspectorClient): Promise<void> {
	await inspector.evalInRenderer<null>(
		'claude.ai',
		`(async () => {
			const wait = (ms) => new Promise(r => setTimeout(r, ms));
			const deadline = Date.now() + 1500;
			while (document.readyState !== 'complete' && Date.now() < deadline) {
				await wait(50);
			}
			let lastMutation = Date.now();
			const obs = new MutationObserver(() => { lastMutation = Date.now(); });
			obs.observe(document.body, {
				childList: true,
				subtree: true,
				attributes: true,
			});
			try {
				while (Date.now() < deadline) {
					if (Date.now() - lastMutation >= 250) return null;
					await wait(50);
				}
			} finally {
				obs.disconnect();
			}
			return null;
		})()`,
	);
	// Tiny extra settle outside the renderer in case the inspector
	// round-trip itself returned mid-frame.
	await sleep(50);
}

async function navigateTo(
	inspector: InspectorClient,
	url: string,
): Promise<void> {
	const cur = await currentUrl(inspector);
	if (cur === url) return;
	await inspector.evalInRenderer<null>(
		'claude.ai',
		`(() => { location.href = ${JSON.stringify(url)}; return null; })()`,
	);
	// Brief grace period for the navigation event to fire before the
	// next waitForStable kicks in.
	await sleep(150);
}

// Force-reload the renderer in place. Used by the redrive path's
// initial step: every BFS pop re-navigates to startUrl, but if a prior
// drill left state in the SPA (open dialog, expanded sidebar,
// scrolled focus) and `currentUrl` already matches startUrl, plain
// `navigateTo` is a no-op and the next clickById snapshots the
// contaminated state. `location.reload()` discards the SPA's React
// tree and forces a fresh render — same path browsers take when the
// user hits the reload button.
async function reloadPage(inspector: InspectorClient): Promise<void> {
	await inspector.evalInRenderer<null>(
		'claude.ai',
		'(() => { location.reload(); return null; })()',
	);
	await sleep(150);
}

// Re-locate an element by its canonical v7 ID and click it. The ID
// alone identifies the *target* structurally; we recover a clickable
// DOM handle by snapshotting, computing each candidate's structural
// id-tail with `captureFingerprint`, and matching by suffix.
//
// Suffix-match (rather than full-id equality) is what makes path
// replay survive mid-path surface IDs the caller doesn't know — every
// click surface emits the same id-tail for the target regardless of
// the parent prefix. Disambiguation:
//   - `#N` ordinal: same id-tail collided cross-element on the source
//     surface; pick the Nth.
//   - `+N` instance-collapse suffix: stripped before matching (the
//     suffix is metadata, not part of the target's identity).
async function clickById(
	inspector: InspectorClient,
	id: string,
): Promise<void> {
	const snap = await snapshotSurface(inspector);
	const candidates = snap.elements.filter((r) => r.visible);
	const seen = new Map<string, number>();

	let normalizedId = id.replace(/\+\d+$/, '');
	const ordMatch = normalizedId.match(/#(\d+)$/);
	const wanted = ordMatch ? Number(ordMatch[1]) : 1;
	if (ordMatch) normalizedId = normalizedId.slice(0, ordMatch.index);

	// Per-snapshot vocabulary doesn't matter much for the click path —
	// the requested id was emitted by `emitEntries` against the
	// real walk-time vocabulary, but for re-location any vocabulary
	// produces the same structural id-tail (vocabulary only affects
	// classification, not the structural ariaPath / role chain). Use
	// the empty vocabulary to skip the disk read.
	const emptyVocab: Vocabulary = {
		stable: new Set(),
		suspect: new Set(),
	};
	for (const raw of candidates) {
		const label = pickLabel(raw);
		if (!label) continue;
		const fp = captureFingerprint(raw, snap.elements, emptyVocab);
		const tail = idTailFromFingerprint(fp);
		if (!normalizedId.endsWith(`.${tail}`) && normalizedId !== tail) continue;
		const ord = (seen.get(tail) ?? 0) + 1;
		seen.set(tail, ord);
		if (ord !== wanted) continue;
		await clickRawElement(inspector, raw, label);
		return;
	}
	throw new Error(`clickById: no element matches "${id}" on current surface`);
}

async function clickRawElement(
	inspector: InspectorClient,
	raw: RawElement,
	label: string,
): Promise<void> {
	if (raw.backendDOMNodeId === null) {
		throw new Error(
			`clickRawElement: AX node for "${label}" has no backendDOMNodeId; ` +
				`cannot click without a DOM handle`,
		);
	}
	await inspector.clickByBackendNodeId('claude.ai', raw.backendDOMNodeId);
}

async function pressKey(
	inspector: InspectorClient,
	key: string,
): Promise<void> {
	await inspector.evalInRenderer<null>(
		'claude.ai',
		`(() => {
			document.dispatchEvent(new KeyboardEvent('keydown', {
				key: ${JSON.stringify(key)},
				bubbles: true, cancelable: true,
			}));
			return null;
		})()`,
	);
}
// Inline self-test: exercises the v7 capture algorithm against the
// plan's example cases without booting a renderer. Run with
// `npx tsx explore/walker.ts`. Kept inline because the asserts are
// one block; pulling in a runner would be heavier than the
// assertions themselves.
//
// Examples traced (from fingerprint-v7-plan.md "Kind-strictness matrix"):
//   - root.button.search           — stable, no name
//   - root.button.awaaddrick-max   — stable, plan-badge pattern name
//   - search.option.untitled-…     — instance, no name
//   - pinned-list.button-by-shape  — instance via long-title shape
async function selfTest(): Promise<void> {
	const fail = (msg: string): never => {
		throw new Error(`selfTest: ${msg}`);
	};

	const stableVocab: Vocabulary = {
		stable: new Set(['Search', 'Pinned', 'Recents']),
		suspect: new Set(),
	};

	// Synthetic AxNode tree builder. The full CDP shape carries many
	// fields the walker doesn't read (`properties[]`, `frameId`,
	// `ignoredReasons`, …); we populate only what the adapter consumes
	// so the tests stay focused on the substrate the walker observes.
	type AxSpec = {
		role: string;
		name?: string;
		ignored?: boolean;
		backendDOMNodeId?: number;
		children?: AxSpec[];
	};
	const buildAxTree = (root: AxSpec): AxNode[] => {
		const nodes: AxNode[] = [];
		let nextId = 1;
		const visit = (s: AxSpec, parentId: string | undefined): string => {
			const id = String(nextId++);
			const childIds: string[] = [];
			const node: AxNode = {
				nodeId: id,
				childIds,
				role: { type: 'role', value: s.role },
				ignored: s.ignored === true,
			};
			if (parentId !== undefined) node.parentId = parentId;
			if (s.name !== undefined) {
				node.name = { type: 'computedString', value: s.name };
			}
			if (s.backendDOMNodeId !== undefined) {
				node.backendDOMNodeId = s.backendDOMNodeId;
			}
			nodes.push(node);
			for (const c of s.children ?? []) {
				childIds.push(visit(c, id));
			}
			return id;
		};
		visit(root, undefined);
		return nodes;
	};

	// Case 1 — root-level search button, only button at the top level.
	// Should hit step 1: classification 'stable', no name needed.
	const searchSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'banner',
					children: [{ role: 'button', name: 'Search' }],
				},
			],
		}),
	);
	const search = searchSurface.find((r) => r.accessibleName === 'Search')!;
	const fpSearch = captureFingerprint(search, searchSurface, stableVocab);
	if (fpSearch.classification !== 'stable') {
		fail(`search: expected classification=stable, got ${fpSearch.classification}`);
	}
	if (fpSearch.leaf.name !== null) {
		fail(`search: expected leaf.name=null, got ${JSON.stringify(fpSearch.leaf.name)}`);
	}
	if (fpSearch.ariaPath.length !== 1 || fpSearch.ariaPath[0]!.role !== 'banner') {
		fail(`search: expected ariaPath=[banner], got ${JSON.stringify(fpSearch.ariaPath)}`);
	}
	const searchTail = idTailFromFingerprint(fpSearch);
	if (searchTail !== 'banner.button') {
		fail(`search: expected tail "banner.button", got "${searchTail}"`);
	}

	// Case 2 — plan badge (AWAaddrick·Max). Two buttons in the banner;
	// step 1 is non-unique. Step 2 with the plan-badge pattern matcher
	// produces classification 'instance' (per classifyName) but with a
	// regex-shaped name matcher — uniqueness via shape. The PUA
	// glyph that follows "Max" in production builds is irrelevant here:
	// the regex anchors on the "·<plan>" suffix, not the trailing
	// ornament.
	const bannerSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'banner',
					children: [
						{ role: 'button', name: 'AWAaddrick·Max' },
						{ role: 'button', name: 'Menu' },
					],
				},
			],
		}),
	);
	const planBadge = bannerSurface.find(
		(r) => r.accessibleName === 'AWAaddrick·Max',
	)!;
	const fpBadge = captureFingerprint(planBadge, bannerSurface, stableVocab);
	if (fpBadge.classification !== 'instance') {
		fail(
			`plan-badge: expected classification=instance, got ${fpBadge.classification}`,
		);
	}
	if (fpBadge.leaf.name?.kind !== 'pattern') {
		fail(
			`plan-badge: expected leaf.name.kind=pattern, got ${JSON.stringify(fpBadge.leaf.name)}`,
		);
	}
	const badgeTail = idTailFromFingerprint(fpBadge);
	if (badgeTail !== 'banner.button-by-shape.plan-badge') {
		fail(
			`plan-badge: expected tail "banner.button-by-shape.plan-badge", got "${badgeTail}"`,
		);
	}

	// Case 3 — pinned conversation under listbox. Step 1 is ambiguous
	// (two ariaPath-equivalent option matches across separate listboxes),
	// the long-title classifier hits 'instance' with no pattern AND the
	// list-row early-out triggers, so the fingerprint falls through to
	// step 4 (instance scoped to ariaPath, no name). Each option lives
	// in its own listbox so siblingTotal=1 — that's what skips step
	// 3; pathMatches still treats the two listboxes as the same path
	// because it compares step shape, not parent-node identity.
	const pinnedSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'main',
					children: [
						{
							role: 'listbox',
							name: 'Pinned',
							children: [
								{
									role: 'option',
									name: 'Fine-tuning diffusion models with reinforcement learning',
								},
							],
						},
						{
							role: 'listbox',
							name: 'Pinned',
							children: [
								{
									role: 'option',
									name: 'Adversarial resume review platform MVP',
								},
							],
						},
					],
				},
			],
		}),
	);
	const pinned1 = pinnedSurface.find(
		(r) => r.accessibleName?.startsWith('Fine-tuning'),
	)!;
	const fpPinned = captureFingerprint(pinned1, pinnedSurface, stableVocab);
	if (fpPinned.classification !== 'instance') {
		fail(
			`pinned: expected classification=instance, got ${fpPinned.classification}`,
		);
	}
	if (fpPinned.leaf.name !== null) {
		fail(
			`pinned: expected leaf.name=null (long-title shape has no pattern), ` +
				`got ${JSON.stringify(fpPinned.leaf.name)}`,
		);
	}
	const pinnedTail = idTailFromFingerprint(fpPinned);
	if (pinnedTail !== 'main.listbox.option-instance') {
		fail(
			`pinned: expected tail "main.listbox.option-instance", got "${pinnedTail}"`,
		);
	}

	// Case 4 — siblings of same role with no usable name discriminator.
	// Two anonymous buttons at the same path level → positional path.
	// Real AX usually marks nameless buttons `ignored: true`; the fixture
	// leaves them visible to exercise the positional fallback.
	const sibSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'toolbar',
					children: [{ role: 'button' }, { role: 'button' }],
				},
			],
		}),
	);
	if (sibSurface.length !== 2) {
		fail(`siblings: expected 2 raw elements, got ${sibSurface.length}`);
	}
	const sib2 = sibSurface[1]!;
	const fpSib = captureFingerprint(sib2, sibSurface, stableVocab);
	if (fpSib.classification !== 'positional') {
		fail(`siblings: expected classification=positional, got ${fpSib.classification}`);
	}
	if (!fpSib.leaf.siblingIndex || fpSib.leaf.siblingIndex.position !== 1) {
		fail(`siblings: expected siblingIndex.position=1, got ${JSON.stringify(fpSib.leaf.siblingIndex)}`);
	}
	const sibTail = idTailFromFingerprint(fpSib);
	if (sibTail !== 'toolbar.button[1]') {
		fail(`siblings: expected tail "toolbar.button[1]", got "${sibTail}"`);
	}

	// Case 5 — name classifier vocabulary lookup: "Pinned" is in the
	// stable vocab so a button labelled "Pinned" should classify 'stable'
	// when used at step 2.
	const navSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'navigation',
					children: [
						{ role: 'button', name: 'Pinned' },
						{ role: 'button', name: 'Recents' },
					],
				},
			],
		}),
	);
	const pinnedBtn = navSurface.find((r) => r.accessibleName === 'Pinned')!;
	const fpPinnedBtn = captureFingerprint(pinnedBtn, navSurface, stableVocab);
	if (fpPinnedBtn.classification !== 'stable') {
		fail(
			`stable-vocab: expected classification=stable for known label "Pinned", ` +
				`got ${fpPinnedBtn.classification}`,
		);
	}
	if (fpPinnedBtn.leaf.name?.kind !== 'literal') {
		fail(
			`stable-vocab: expected leaf.name.kind=literal, got ${JSON.stringify(fpPinnedBtn.leaf.name)}`,
		);
	}
	const navTail = idTailFromFingerprint(fpPinnedBtn);
	if (navTail !== 'navigation.button-by-name.pinned') {
		fail(`stable-vocab: expected tail "navigation.button-by-name.pinned", got "${navTail}"`);
	}

	// Case 6 — walkLandmarkAncestors filters non-landmark ancestors.
	// Generic divs/spans between landmark roles must NOT contribute a
	// path step.
	const filterSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'banner',
					children: [
						{
							role: 'generic',
							children: [
								{
									role: 'toolbar',
									children: [
										{
											role: 'generic',
											children: [{ role: 'button', name: 'X' }],
										},
									],
								},
							],
						},
					],
				},
			],
		}),
	);
	const filterLeaf = filterSurface[0]!;
	const path = walkLandmarkAncestors(filterLeaf);
	if (path.length !== 2 || path[0]!.role !== 'banner' || path[1]!.role !== 'toolbar') {
		fail(`walkLandmarkAncestors: expected [banner, toolbar], got ${JSON.stringify(path)}`);
	}

	// Case 7 — emitEntries collapses an instance group of 4 into one
	// representative entry tagged with `+4` and kind: 'instance'. Each
	// option lives in its own listbox so siblingTotal=1 — that's
	// what skips step 3 and lets step 4 classify as instance. Step 1
	// still sees 4 ariaPath-equivalent matches because pathMatches
	// compares path shape, not parent-node identity.
	const collapseSurface = axTreeToSnapshot(
		buildAxTree({
			role: 'WebArea',
			children: [
				{
					role: 'main',
					children: [
						{
							role: 'listbox',
							name: 'Recents',
							children: [
								{ role: 'option', name: 'Conversation One Today' },
							],
						},
						{
							role: 'listbox',
							name: 'Recents',
							children: [
								{ role: 'option', name: 'Conversation Two Today' },
							],
						},
						{
							role: 'listbox',
							name: 'Recents',
							children: [
								{ role: 'option', name: 'Conversation Three Today' },
							],
						},
						{
							role: 'listbox',
							name: 'Recents',
							children: [
								{ role: 'option', name: 'Conversation Four Today' },
							],
						},
					],
				},
			],
		}),
	);
	const opts: EmitOpts = {
		raws: collapseSurface,
		parentPath: [],
		surface: 'root',
		appVersion: 'test',
		allowlist: new Set(),
		vocabulary: stableVocab,
	};
	const emitted = emitEntries(opts);
	if (emitted.length !== 1) {
		fail(`instance collapse: expected 1 emitted entry, got ${emitted.length}`);
	}
	const inst = emitted[0]!;
	if (inst.kind !== 'instance') {
		fail(`instance collapse: expected kind=instance, got ${inst.kind}`);
	}
	if (inst.instanceCount !== 4) {
		fail(`instance collapse: expected instanceCount=4, got ${inst.instanceCount}`);
	}
	if (!inst.id.endsWith('+4')) {
		fail(`instance collapse: expected id to end with +4, got "${inst.id}"`);
	}

	// Case 8 — error classification (timeout vs lookup). Carried over
	// from the v6 selfTest; doesn't depend on fingerprint shape.
	const cCounters = { inspector_timeout: 0, lookup_failure: 0 };
	const cTry = async <T>(fn: () => Promise<T> | T): Promise<void> => {
		try {
			await fn();
			cCounters.inspector_timeout = 0;
			cCounters.lookup_failure = 0;
		} catch (err) {
			const e = err instanceof Error ? err : new Error(String(err));
			if (e.message.includes('inspector.send timed out')) {
				cCounters.inspector_timeout += 1;
			} else {
				cCounters.lookup_failure += 1;
			}
		}
	};
	await cTry(() => {
		throw new Error(
			'inspector.send timed out after 30000ms (method=Runtime.evaluate)',
		);
	});
	if (cCounters.inspector_timeout !== 1 || cCounters.lookup_failure !== 0) {
		fail(
			`error class (timeout): expected timeout=1 lookup=0, got ` +
				`timeout=${cCounters.inspector_timeout} lookup=${cCounters.lookup_failure}`,
		);
	}
	await cTry(() => {
		throw new Error('clickById: no element matches "x" on current surface');
	});
	if (cCounters.inspector_timeout !== 1 || cCounters.lookup_failure !== 1) {
		fail(
			`error class (lookup): expected timeout=1 lookup=1, got ` +
				`timeout=${cCounters.inspector_timeout} lookup=${cCounters.lookup_failure}`,
		);
	}

	// Case 9 — subtree prune (carried over from v6 selfTest).
	const click = (id: string): NavStep => ({ action: 'click', id });
	const mkItem = (p: NavStep[]): QueueItem => ({
		path: p,
		parentSurfaceKey: null,
		parentRawCount: 0,
	});
	const dQueue: QueueItem[] = [
		mkItem([click('D')]),
		mkItem([click('A'), click('B'), click('C'), click('child1')]),
		mkItem([click('A'), click('B'), click('C'), click('child2')]),
		mkItem([click('A'), click('B'), click('C'), click('child3')]),
		mkItem([click('A'), click('B'), click('E')]),
	];
	const failedPath = [
		click('A'),
		click('B'),
		click('C'),
		click('child1'),
	];
	const failedErr = new Error(
		'clickById: no element matches "C" on current surface',
	);
	const failedStep = identifyFailedStep(failedErr, failedPath);
	if (!failedStep || failedStep.action !== 'click' || failedStep.id !== 'C') {
		fail(
			`prune: expected to identify click(C), got ${JSON.stringify(failedStep)}`,
		);
	}
	const droppedCount = pruneDependentItems(dQueue, failedPath, failedStep!);
	if (droppedCount !== 3) {
		fail(`prune: expected 3 dropped, got ${droppedCount}`);
	}
	if (dQueue.length !== 2) {
		fail(`prune: expected 2 remaining, got ${dQueue.length}`);
	}

	process.stdout.write('selfTest: OK\n');
}

if (
	import.meta.url ===
	`file://${process.argv[1] ?? ''}`.replace(/\\/g, '/')
) {
	selfTest().catch((err) => {
		process.stderr.write(`${err}\n`);
		process.exit(1);
	});
}
