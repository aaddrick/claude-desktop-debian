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
// - Owns the AX-snapshot substrate: `RawElement`, `axTreeToSnapshot`,
//   and `waitForAxTreeStable`. These are the runner-facing surface for
//   converting Chromium's `Accessibility.getFullAXTree` output into
//   a flat snapshot the page-objects and specs can search.
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
import { retryUntil, sleep } from './retry.js';

export type { AxNode } from './inspector.js';

// Outermost-to-innermost AX ancestor chain. `walkLandmarkAncestors`
// (in lib/claudeai.ts) filters this to the landmark / grouping subset
// for fingerprint paths.
interface RawAncestor {
	role: string | null;
	name: string | null;
}

export interface RawElement {
	// Per-element data sourced from Chromium's accessibility tree.
	// `computedRole` is `AxNode.role.value` — the platform-computed role
	// rather than the tag-derived one, so `<button role="link">` is a
	// link.
	computedRole: string;
	// Accessible name as the AX tree computed it. Single source of
	// truth for the leaf's identity — there is no separate aria-label
	// / text-content fallback.
	accessibleName: string | null;
	// `!ignored` from the AX tree. The walker filters ignored nodes
	// out at snapshot construction time, so this is always true post-
	// filter; kept on the type so resolver-side code can still gate
	// on it without special-casing AX-derived inputs.
	visible: boolean;
	// Any landmark dialog / alertdialog ancestor in the AX path.
	insideModalDialog: boolean;
	// Outermost-to-innermost AX ancestor chain (excluding the element
	// itself and any ignored nodes).
	ancestors: RawAncestor[];
	// Among the parent AX node's non-ignored children that share this
	// element's computed role, where does it sit and how many siblings
	// of that role exist?
	siblingPosition: number;
	siblingTotal: number;
	// `AxNode.backendDOMNodeId`. Required for the click path
	// (`DOM.resolveNode` → `Runtime.callFunctionOn`); null only on AX
	// nodes that don't back a DOM element (which won't reach this
	// list, since interactive ARIA roles always do).
	backendDOMNodeId: number | null;
	// AX `haspopup` token (`<button aria-haspopup="menu">` →
	// `'menu'`). null when the property is absent or its value is the
	// literal string `'false'`. Surfaced for claudeai.ts page-objects,
	// which use it to discriminate menu triggers from ordinary action
	// buttons that happen to share an accessible name.
	hasPopup: string | null;
}

// Roles we treat as "interactive leaves" — emitted to the snapshot
// and used as queue seeds. Expressed in AX-role terms so
// `<button role="link">` shows up as `link`, which is what AX reports.
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
// `insideModalDialog`.
const DIALOG_AX_ROLES = new Set<string>(['dialog', 'alertdialog']);

// Pull the AX `hasPopup` token out of `node.properties[]`. CDP
// exposes it as `{ name: 'hasPopup', value: { type: 'token', value:
// 'menu' } }` on supporting elements (note the camelCase — the
// underlying ARIA attribute is `aria-haspopup` lowercase, but
// Chromium's AXProperty name is `hasPopup`). Absent properties array,
// missing entry, or the literal string `'false'` all collapse to
// `null` so consumers don't have to special-case those.
function readHasPopup(node: AxNode): string | null {
	const props = node.properties;
	if (!Array.isArray(props)) return null;
	for (const p of props) {
		if (p?.name !== 'hasPopup') continue;
		const v = p.value?.value;
		if (typeof v !== 'string') return null;
		if (v === '' || v === 'false') return null;
		return v;
	}
	return null;
}

// `axTreeToSnapshot` adapts CDP's `Accessibility.getFullAXTree`
// output into the RawElement shape the rest of the harness consumes.
// Filtering rules:
//   - `ignored` nodes are dropped from emission and from sibling
//     counts (they're not exposed to assistive tech and we don't want
//     to drill into them either). Their children remain visible to
//     the ancestor walk via the raw tree links.
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
			hasPopup: readHasPopup(node),
		});
	}
	return out;
}

// Wait for the AX tree to stop growing/shrinking — two consecutive
// reads at the same node count means Chromium has finished computing
// the accessibility tree for the current DOM. Used by the seed phase
// because:
//   1. `Accessibility.enable` is implicit on the first
//      `getFullAXTree` call, and the very first tree is often a
//      partial computation.
//   2. claude.ai's SPA mounts ~5–8s after the renderer signals
//      `claudeAi` ready; a snapshot taken too early reliably sees an
//      empty surface.
// Cheap to call (≥800ms when already stable, on the order of seconds
// when not).
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
