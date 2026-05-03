// Name-classifier vocabulary + instance-shape registry. The v7 walker
// (Phase 2) consumes this to decide whether a captured accessible-name
// is stable copy ("Search", "Send"), instance-shaped ("AWAaddrick·Max",
// "Today+12"), or unknown copy that needs human triage. The vocabulary
// `stable` / `suspect` arrays are derived from a prior inventory walk
// by `explore/derive-vocabulary.ts` and re-derived on each major
// upstream release.
//
// First-match-wins ordering: more specific shapes go before general
// ones so e.g. a model-version pattern hits before a generic
// title-case-words pattern.

export interface InstanceShape {
	id: string;
	regex: RegExp;
	// Canonical pattern recorded into the v7 fingerprint's NameMatcher
	// when this shape matches. Null on shapes that should *not*
	// contribute a regex matcher — those entries fall through to
	// `kind: instance` ancestor-presence checks at resolve time.
	pattern: string | null;
}

export const INSTANCE_SHAPES: readonly InstanceShape[] = [
	// Plan badge — `<handle>·<tier>` with optional trailing PUA glyph
	// (Claude Desktop ships private-area font icons as the badge
	// ornament; e.g. AWAaddrick·Max).
	{
		id: 'plan-badge',
		regex: /^.+·(Free|Pro|Max|Team|Enterprise)[-\s]*$/u,
		pattern: '\\w+·(Free|Pro|Max|Team|Enterprise)',
	},
	// Model-version names. Stable across users, versioned across
	// releases — recording as a pattern lets a re-walked inventory
	// keep resolving when upstream bumps "Opus 4.7" → "Opus 4.8".
	{ id: 'opus-version', regex: /^Opus \d/, pattern: '^Opus \\d' },
	{ id: 'sonnet-version', regex: /^Sonnet \d/, pattern: '^Sonnet \\d' },
	{ id: 'haiku-version', regex: /^Haiku \d/, pattern: '^Haiku \\d' },
	// Usage / quota percentage suffix ("Usage: plan 11%").
	{ id: 'percentage', regex: /\d{1,3}%$/, pattern: '\\d{1,3}%' },
	// Relative date a list row often appends to a title ("Untitled
	// conversationToday+12"). The shape includes an optional `+N`
	// counter for collapsed-instance groupings.
	{
		id: 'relative-date',
		regex:
			/(Today|Yesterday|\d+\s(day|hour|minute|second|week|month|year)s?\sago)/,
		pattern:
			'(Today|Yesterday|\\d+\\s(day|hour|minute|second|week|month|year)s?\\sago)(\\+\\d+)?',
	},
	// File / quota size suffix ("1.5 GB").
	{
		id: 'size-with-unit',
		regex: /^\d+\.\d+\s\w+/,
		pattern: '^\\d+\\.\\d+\\s\\w+',
	},
	// User handle prefix ("@aaddrick").
	{ id: 'user-handle', regex: /@\w+/, pattern: '@\\w+' },
	// Cowork session row in the sidebar. Names are status-prefixed
	// session titles ("Idle Review PR 555…", "Awaiting input Plan
	// automated testing strategy…", "Pull request merged Review issue
	// 373"). The status enum is bounded; the title varies per session.
	// Recording as a pattern lets the v7 instance-collapse fold the
	// whole sidebar list into one representative entry — without this
	// shape the title classifies as `suspect` (or `stable` if literal-
	// matching once) and each session is captured + drilled
	// individually. Placed before `long-title` so the more specific
	// shape wins (long-title returns `pattern: null`, which loses
	// account-portability for these rows).
	{
		id: 'cowork-session',
		regex:
			/^(Idle|Ready|Working|Awaiting input|Pull request merged|Done|Failed|Cancelled)\s/,
		pattern:
			'^(Idle|Ready|Working|Awaiting input|Pull request merged|Done|Failed|Cancelled)\\s',
	},
	// Per-row action triggers in list-row contexts. Claude.ai exposes a
	// "⋮" menu next to each cowork session / conversation row with an
	// aria-label `More options for <row title>` — one button per row.
	// Without this shape the per-row title makes each button literally
	// unique, so each gets its own stable entry and the BFS drills
	// every one. With the shape they collapse to a single representative
	// per surface, mirroring the cowork-session row collapse above.
	{
		id: 'row-more-options',
		regex: /^More options for /,
		pattern: '^More options for ',
	},
	// 3+ word title-case prose. No pattern recorded — the title is
	// per-conversation, not a recurring shape, so the resolver should
	// fall back to ancestor-presence rather than try to match the
	// literal text.
	{
		id: 'long-title',
		regex: /^[A-Z][a-z]+ [A-Z][a-z]+ [a-z]/,
		pattern: null,
	},
] as const;

export type NameClass = 'stable' | 'instance' | 'positional' | 'suspect';

export interface NameClassification {
	kind: NameClass;
	// Present iff `kind === 'instance'`.
	shapeId?: string;
	// Present iff `kind === 'instance'`. Null when the matched shape
	// has no canonical regex (e.g. long-title) — caller should drop the
	// name from the fingerprint and rely on ariaPath + ancestor
	// presence.
	pattern?: string | null;
}

export interface Vocabulary {
	stable: ReadonlySet<string>;
	suspect: ReadonlySet<string>;
}

// classifyName decides how a captured accessible-name should be
// matched at resolve time. Priority order tracks the v7 plan's "Name
// classifier" §:
//   1. Empty / whitespace → 'positional' (no usable name)
//   2. Matches an instance-shape regex → 'instance' + shapeId
//   3. Present in vocabulary.stable → 'stable'
//   4. Default → 'suspect' (treated as stable by the walker but
//      surfaced for reconciliation review)
//
// The list-row-child rule from the plan ('option/listitem inside
// listbox/list' → 'instance') depends on ariaPath context the
// classifier doesn't have access to here. The walker checks that
// condition before calling classifyName.
export function classifyName(
	name: string | null,
	vocabulary: Vocabulary,
): NameClassification {
	if (name === null || name.trim() === '') {
		return { kind: 'positional' };
	}
	for (const shape of INSTANCE_SHAPES) {
		if (shape.regex.test(name)) {
			return {
				kind: 'instance',
				shapeId: shape.id,
				pattern: shape.pattern,
			};
		}
	}
	if (vocabulary.stable.has(name)) {
		return { kind: 'stable' };
	}
	return { kind: 'suspect' };
}
