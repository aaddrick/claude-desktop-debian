// Snapshot comparator.
//
// Diff semantics, in priority order:
//   - removed:  an element keyed in A is absent from B  → drift signal.
//   - changed:  same key, different visible text or aria-label  → drift.
//   - added:    new key in B  → informational only (UI gained surface).
//
// Keys are stable identity tokens chosen per element class:
//   - df-pill:        aria-label  (Chat / Cowork / Code)
//   - compactPill:    inner text  (env value, "Select folder…", …)
//   - ariaButton:     aria-label  (sidebar "more" buttons share labels;
//                     we de-dup by counting; see compareCounts below)
//   - modal:          headingText ?? aria-label ?? aria-labelledby
//   - openMenu:       items diffed by `${role}::${text}`
//
// Pure module — no I/O, no process.exit. The dispatcher reads files
// and prints; this file just produces a Diff value.

import type {
	AriaButton,
	CompactPillSnap,
	DfPill,
	MenuItem,
	ModalSnap,
	OpenMenu,
	Snapshot,
} from './snapshot.js';

export interface DiffEntry {
	kind: 'removed' | 'changed' | 'added';
	category: string;
	key: string;
	before?: string;
	after?: string;
}

export interface DiffResult {
	a: { capturedAt: string; url: string; appVersion: string | null };
	b: { capturedAt: string; url: string; appVersion: string | null };
	entries: DiffEntry[];
	summary: { removed: number; changed: number; added: number };
}

export function diff(a: Snapshot, b: Snapshot): DiffResult {
	const entries: DiffEntry[] = [];
	entries.push(...diffDfPills(a.dfPills, b.dfPills));
	entries.push(...diffCompactPills(a.compactPills, b.compactPills));
	entries.push(...diffAriaButtons(a.ariaLabeledButtons, b.ariaLabeledButtons));
	entries.push(...diffModals(a.modals, b.modals));
	entries.push(...diffOpenMenu(a.openMenu, b.openMenu));
	const summary = entries.reduce(
		(acc, e) => {
			acc[e.kind] += 1;
			return acc;
		},
		{ removed: 0, changed: 0, added: 0 },
	);
	return {
		a: {
			capturedAt: a.capturedAt,
			url: a.claudeAiUrl,
			appVersion: a.appVersion,
		},
		b: {
			capturedAt: b.capturedAt,
			url: b.claudeAiUrl,
			appVersion: b.appVersion,
		},
		entries,
		summary,
	};
}

// Human-readable formatter. Removed/changed first (they're failures
// in spirit), added last (informational). Empty diff prints a single
// line so CI logs stay tidy.
export function formatDiff(d: DiffResult): string {
	const lines: string[] = [];
	lines.push(`A: ${d.a.capturedAt}  (${d.a.url})  app=${d.a.appVersion}`);
	lines.push(`B: ${d.b.capturedAt}  (${d.b.url})  app=${d.b.appVersion}`);
	lines.push('');
	if (d.entries.length === 0) {
		lines.push('No differences.');
		return lines.join('\n');
	}
	const order: DiffEntry['kind'][] = ['removed', 'changed', 'added'];
	for (const kind of order) {
		const group = d.entries.filter((e) => e.kind === kind);
		if (group.length === 0) continue;
		lines.push(`# ${kind.toUpperCase()} (${group.length})`);
		for (const e of group) {
			if (e.kind === 'changed') {
				lines.push(
					`  [${e.category}] ${e.key}: ${e.before ?? ''} → ${e.after ?? ''}`,
				);
			} else if (e.kind === 'removed') {
				lines.push(`  [${e.category}] ${e.key}: ${e.before ?? ''}`);
			} else {
				lines.push(`  [${e.category}] ${e.key}: ${e.after ?? ''}`);
			}
		}
		lines.push('');
	}
	lines.push(
		`Summary: ${d.summary.removed} removed, ` +
			`${d.summary.changed} changed, ${d.summary.added} added`,
	);
	return lines.join('\n');
}

function diffDfPills(a: DfPill[], b: DfPill[]): DiffEntry[] {
	const aMap = byKey(a, (p) => p.ariaLabel ?? p.text);
	const bMap = byKey(b, (p) => p.ariaLabel ?? p.text);
	return compareMaps(aMap, bMap, 'dfPill', (p) => p.text);
}

function diffCompactPills(
	a: CompactPillSnap[],
	b: CompactPillSnap[],
): DiffEntry[] {
	// Compact pills can repeat by text in pathological cases, so we
	// disambiguate by appending an ordinal when needed. The ordinal is
	// stable as long as DOM order is — same approach `findCompactPills`
	// callers rely on.
	const aMap = byKeyOrdinal(a, (p) => p.text);
	const bMap = byKeyOrdinal(b, (p) => p.text);
	return compareMaps(aMap, bMap, 'compactPill', (p) => `maxW=${p.maxW}`);
}

// Aria-labeled buttons frequently repeat (sidebar's ~80 conversation-row
// "more" buttons all share a label). We compare by *count per label*
// instead of per-instance: a delta in count surfaces as a single
// changed entry, which is far more readable than 80 added/removed
// rows. Per-label text is omitted since duplicate labels mean text is
// not a stable identity.
function diffAriaButtons(a: AriaButton[], b: AriaButton[]): DiffEntry[] {
	return compareCounts(
		countBy(a, (x) => x.ariaLabel),
		countBy(b, (x) => x.ariaLabel),
		'ariaButton',
	);
}

function diffModals(a: ModalSnap[], b: ModalSnap[]): DiffEntry[] {
	const key = (m: ModalSnap) =>
		m.headingText ?? m.ariaLabel ?? m.ariaLabelledBy ?? '<unlabeled-modal>';
	const aMap = byKeyOrdinal(a, key);
	const bMap = byKeyOrdinal(b, key);
	return compareMaps(aMap, bMap, 'modal', (m) =>
		`buttons=${m.buttonLabels.join('|')}`,
	);
}

// Menu diff is special: the "key" is the menu identity, but a menu
// diff is really an item-set diff. We compare item lists, scoped under
// the menu's labelledBy/ariaLabel for context.
function diffOpenMenu(
	a: OpenMenu | null,
	b: OpenMenu | null,
): DiffEntry[] {
	if (!a && !b) return [];
	const scope =
		(a?.ariaLabel ?? b?.ariaLabel) ||
		(a?.ariaLabelledBy ?? b?.ariaLabelledBy) ||
		'<menu>';
	if (a && !b) {
		return [
			{
				kind: 'removed',
				category: 'openMenu',
				key: scope,
				before: a.items.map(itemKey).join(' | '),
			},
		];
	}
	if (!a && b) {
		return [
			{
				kind: 'added',
				category: 'openMenu',
				key: scope,
				after: b.items.map(itemKey).join(' | '),
			},
		];
	}
	if (!a || !b) return [];
	const aMap = byKeyOrdinal(a.items, itemKey);
	const bMap = byKeyOrdinal(b.items, itemKey);
	return compareMaps(
		aMap,
		bMap,
		`openMenu[${scope}]`,
		(it) =>
			`disabled=${it.disabled}` +
			(it.ariaChecked !== null ? ` checked=${it.ariaChecked}` : ''),
	);
}

function itemKey(it: MenuItem): string {
	return `${it.role}::${it.text}`;
}

function byKey<T>(arr: T[], k: (t: T) => string): Map<string, T> {
	const m = new Map<string, T>();
	for (const it of arr) m.set(k(it), it);
	return m;
}

// When keys collide, append `#2`, `#3`, … so the comparator can still
// detect "we used to have 3, now we have 2" (one #N drops out as
// removed). Ordinals are local to this snapshot — they don't cross
// snapshot boundaries.
function byKeyOrdinal<T>(arr: T[], k: (t: T) => string): Map<string, T> {
	const m = new Map<string, T>();
	const counts = new Map<string, number>();
	for (const it of arr) {
		const base = k(it);
		const n = (counts.get(base) ?? 0) + 1;
		counts.set(base, n);
		m.set(n === 1 ? base : `${base}#${n}`, it);
	}
	return m;
}

function countBy<T>(arr: T[], k: (t: T) => string): Map<string, number> {
	const m = new Map<string, number>();
	for (const it of arr) {
		const key = k(it);
		m.set(key, (m.get(key) ?? 0) + 1);
	}
	return m;
}

function compareMaps<T>(
	a: Map<string, T>,
	b: Map<string, T>,
	category: string,
	describe: (t: T) => string,
): DiffEntry[] {
	const out: DiffEntry[] = [];
	for (const [k, v] of a) {
		const bv = b.get(k);
		if (bv === undefined) {
			out.push({
				kind: 'removed',
				category,
				key: k,
				before: describe(v),
			});
			continue;
		}
		const before = describe(v);
		const after = describe(bv);
		if (before !== after) {
			out.push({
				kind: 'changed',
				category,
				key: k,
				before,
				after,
			});
		}
	}
	for (const [k, v] of b) {
		if (!a.has(k)) {
			out.push({
				kind: 'added',
				category,
				key: k,
				after: describe(v),
			});
		}
	}
	return out;
}

function compareCounts(
	a: Map<string, number>,
	b: Map<string, number>,
	category: string,
): DiffEntry[] {
	const out: DiffEntry[] = [];
	for (const [k, n] of a) {
		const m = b.get(k);
		if (m === undefined) {
			out.push({
				kind: 'removed',
				category,
				key: k,
				before: `count=${n}`,
			});
		} else if (m !== n) {
			out.push({
				kind: 'changed',
				category,
				key: k,
				before: `count=${n}`,
				after: `count=${m}`,
			});
		}
	}
	for (const [k, m] of b) {
		if (!a.has(k)) {
			out.push({
				kind: 'added',
				category,
				key: k,
				after: `count=${m}`,
			});
		}
	}
	return out;
}
