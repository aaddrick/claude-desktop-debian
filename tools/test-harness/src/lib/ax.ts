// AX-tree loading + traversal primitives — shared substrate for any
// test that reads from Chromium's accessibility tree.
//
// Why this exists
// ---------------
// Sessions 1-12 grew two parallel AX consumers without consolidating
// the loading shape:
//
//   1. `lib/claudeai.ts` page-objects (CodeTab.activate, openPill,
//      clickMenuItem, findCompactPills) carry a private `snapshotAx`
//      that gates on `waitForAxTreeStable` then calls
//      `inspector.getAccessibleTree('claude.ai')` and converts via
//      `axTreeToSnapshot`. Every page-object that polls for a node
//      rolls its own retryUntil/while loop around that helper.
//
//   2. `src/runners/T26_routines_page_renders.spec.ts` re-implemented
//      the same `snapshotAx` shape inline because the claudeai.ts
//      version isn't exported. Its leading comment explicitly noted
//      this was "premature abstraction" at 1 consumer; with 2 it is
//      threshold-driven extraction.
//
// Plus the user reports recurring flake in tests that use the AX tree:
// queries fire before the relevant subtree is mounted, and individual
// specs each pick their own retryUntil budget. The proposed
// `waitForAxNode` primitive collapses the snapshot+find+retry shape
// into one helper with a single tunable budget per consumer, reducing
// both the surface area for budget drift and the duplication.
//
// What this primitive does
// ------------------------
// - `snapshotAx(inspector, opts)` — single AX tree read with the
//   stability gate. Replaces the duplicated implementations in
//   `claudeai.ts` (private) and `T26_routines_page_renders.spec.ts`
//   (inlined). `opts.fast` skips the stability gate for inside-poll
//   callers (matches the existing claudeai.ts contract).
// - `waitForAxNode(inspector, predicate, opts)` — repeatedly snapshot
//   the AX tree and return the first element matching `predicate`,
//   subject to a timeout. Built against the loops in `CodeTab.activate`
//   (poll for compact pills), `openPill` (poll for menu items),
//   `clickMenuItem` (poll for matching menuitem), and T26's pre/post-
//   click anchor scans. The predicate carries the discrimination
//   logic the caller already had inline; the primitive owns the
//   stability-gate + retry loop.
// - Re-exports `RawElement`, `axTreeToSnapshot`, `waitForAxTreeStable`
//   from `explore/walker.ts` so consumers don't need to reach across
//   the lib/explore boundary themselves. The walker stays the source
//   of truth for the AX-snapshot shape; this file is the runner-
//   facing surface.
//
// Scope boundaries
// ----------------
// This is NOT a "wait for surface rendered" registry. The plan-doc
// proposal mentioned `waitForRenderedSurface(client, surfaceKey)`
// with a registry of named surface anchors — that's still
// speculative (no consumer asks for it). When a third consumer
// emerges that already knows it wants a named surface anchor (e.g.
// "the Code tab body has mounted"), promote the relevant claudeai.ts
// page-object into a registry entry. Today, `waitForAxNode` with a
// predicate covers every observed callsite.
//
// This is also NOT a CSS-querySelector primitive. T07 polls the DOM
// via `document.querySelector('[data-testid=...]')` for the topbar;
// that's a different abstraction (DOM, not AX) with no extraction
// signal yet — leave it inline in T07 until a second consumer
// surfaces.

import type { AxNode, InspectorClient } from './inspector.js';
import {
	type RawElement,
	axTreeToSnapshot,
	waitForAxTreeStable,
} from '../../explore/walker.js';
import { retryUntil } from './retry.js';

// Re-exports for consumer convenience. Anything that today imports
// `RawElement` / `axTreeToSnapshot` / `waitForAxTreeStable` from
// `../../explore/walker.js` can switch to this file as the import
// path. Keeping the walker as the source of truth — these are the
// runner-facing aliases.
export type { AxNode } from './inspector.js';
export {
	type RawElement,
	axTreeToSnapshot,
	waitForAxTreeStable,
} from '../../explore/walker.js';

// Re-export the AxNode -> RawElement[] conversion as a single import
// point. (Kept distinct from `axTreeToSnapshot`'s walker-side export
// so future renames in `explore/walker.ts` don't churn the runner-
// facing API.)
export interface SnapshotAxOptions {
	// Skip the upfront `waitForAxTreeStable` gate. Default false —
	// i.e. callers gate by default. Pass true inside polling loops
	// where the gate fights the loop: each iteration would block
	// waiting for "no node-count change" even when the change we're
	// polling for is exactly the AX tree updating.
	//
	// `waitForAxNode` itself uses fast=true on every iteration after
	// gating once at the start; consumers calling `snapshotAx` from
	// inside a hand-rolled loop should do the same.
	fast?: boolean;
	// AX-stability gate budget when `fast` is false. Default 10000ms
	// — matches the existing claudeai.ts/T26 inline implementations.
	// Increase for cold-cache cases on slow machines.
	stabilityTimeoutMs?: number;
	// Renderer URL filter for `inspector.getAccessibleTree`. Default
	// 'claude.ai'. Tests against a different webContents (find_in_page,
	// main_window) can override but the AX tree on those is much
	// simpler — `claude.ai` is the only one current consumers care
	// about.
	urlFilter?: string;
}

// Single AX-tree read, returning the walker's flat RawElement[]
// snapshot. Identical contract to the private `snapshotAx` formerly in
// `claudeai.ts` and the inlined one formerly in T26 — extracted here
// so both consumers share an implementation.
//
// Cost: ~800ms when the stability gate hits "stable" on the first
// pair of reads (interior-loop fast=true callers skip this); a few
// seconds on cold-cache. The AX tree itself is comparatively cheap
// to fetch and convert (~50-100ms).
export async function snapshotAx(
	inspector: InspectorClient,
	opts: SnapshotAxOptions = {},
): Promise<RawElement[]> {
	if (!opts.fast) {
		await waitForAxTreeStable(inspector, {
			minNodes: 1,
			timeoutMs: opts.stabilityTimeoutMs ?? 10_000,
		});
	}
	const url = opts.urlFilter ?? 'claude.ai';
	const nodes: AxNode[] = await inspector.getAccessibleTree(url);
	return axTreeToSnapshot(nodes);
}

export interface WaitForAxNodeOptions {
	// Total budget for the polling loop. Default 5000ms — matches the
	// claudeai.ts / T26 callsites that the primitive replaces. Override
	// upward for cold-cache or post-click cases (T26 uses 10s post-
	// click; CodeTab.activate uses 5s default but T16 passes 15s).
	timeoutMs?: number;
	// Per-iteration interval. Default 200ms — matches the existing
	// inline retryUntil({ interval: 200 }) calls. The AX tree fetch
	// itself dominates the loop cost; a shorter interval gives no
	// throughput benefit and a longer one delays the resolution.
	intervalMs?: number;
	// Renderer URL filter passed through to `snapshotAx`. Default
	// 'claude.ai'.
	urlFilter?: string;
	// Whether to gate on `waitForAxTreeStable` once before entering
	// the poll loop. Default true. When the caller has just mutated
	// the page (e.g. clicked a button and is waiting for the
	// resulting menu to render) the upfront stability gate is what
	// keeps the first iteration from racing the in-flight render.
	// After the upfront gate, every iteration uses fast=true so the
	// loop iterates without re-blocking on stability.
	stabilityGate?: boolean;
	// AX-stability gate budget for the upfront `waitForAxTreeStable`
	// when `stabilityGate` is true. Default 5000ms. Independent from
	// the outer poll budget — the gate is a hard precondition, not
	// part of the find loop.
	stabilityTimeoutMs?: number;
}

// Poll the AX tree until the predicate matches a node, or the budget
// runs out. Returns the matched RawElement on success, null on
// timeout.
//
// The predicate runs over RawElement (the walker-snapshot shape) so
// callers can use the same `el.computedRole === 'button' &&
// el.accessibleName === 'Code'` form they already have inline. The
// helper does NOT click the matched node — callers receive the
// RawElement and can pass `el.backendDOMNodeId` to
// `inspector.clickByBackendNodeId` if a click follows. Keeping click
// out of the find primitive lets composite consumers (e.g. "find then
// click then poll for the menu") chain cleanly.
//
// On timeout, returns null. Callers that want a hard fail with a
// diagnostic should pattern-match `if (!found) throw new Error(...)`
// — the primitive doesn't throw because some specs surface
// missing-node as a clean fail with a JSON snapshot attachment
// rather than an uncaught timeout.
//
// The `name` param is purely for diagnostic message hygiene if a
// consumer wraps a throw around the null return — it's appended to
// the implicit "looking for a node matching <predicate>" so failure
// logs read meaningfully. Optional; pass an empty string to suppress.
export async function waitForAxNode(
	inspector: InspectorClient,
	predicate: (el: RawElement) => boolean,
	opts: WaitForAxNodeOptions = {},
): Promise<RawElement | null> {
	const stabilityGate = opts.stabilityGate ?? true;
	if (stabilityGate) {
		await waitForAxTreeStable(inspector, {
			minNodes: 1,
			timeoutMs: opts.stabilityTimeoutMs ?? 5_000,
		});
	}
	return retryUntil(
		async () => {
			const elements = await snapshotAx(inspector, {
				fast: true,
				urlFilter: opts.urlFilter,
			});
			return elements.find(predicate) ?? null;
		},
		{
			timeout: opts.timeoutMs ?? 5_000,
			interval: opts.intervalMs ?? 200,
		},
	);
}

// Same shape as `waitForAxNode` but returns every match rather than
// the first. Useful for consumers that want to enumerate all menu
// items or all compact pills after a stability point — the
// findCompactPills caller in claudeai.ts is a one-shot snapshot
// today, but if a consumer needs to wait for "at least one compact
// pill" plus enumerate the resulting set, this avoids a second
// round-trip.
//
// Returns the (possibly empty) array on success, null on timeout
// when no element ever matched. A successful call with zero matches
// is impossible by construction — the loop only resolves once the
// post-filter array is non-empty.
export async function waitForAxNodes(
	inspector: InspectorClient,
	predicate: (el: RawElement) => boolean,
	opts: WaitForAxNodeOptions = {},
): Promise<RawElement[] | null> {
	const stabilityGate = opts.stabilityGate ?? true;
	if (stabilityGate) {
		await waitForAxTreeStable(inspector, {
			minNodes: 1,
			timeoutMs: opts.stabilityTimeoutMs ?? 5_000,
		});
	}
	return retryUntil(
		async () => {
			const elements = await snapshotAx(inspector, {
				fast: true,
				urlFilter: opts.urlFilter,
			});
			const matches = elements.filter(predicate);
			return matches.length > 0 ? matches : null;
		},
		{
			timeout: opts.timeoutMs ?? 5_000,
			interval: opts.intervalMs ?? 200,
		},
	);
}
