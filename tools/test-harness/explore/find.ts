// Renderer search by regex over text content + aria-label.
//
// Why text+aria together: a "Send" button might have aria-label="Send"
// but textContent="" (icon child); a heading might be the inverse.
// Searching both lets the human ask "where does the word X appear?"
// without first guessing which surface labels it.
//
// We restrict the candidate set to interactive + landmark elements
// (button, [role], a, h1-h6, [aria-label]) rather than walking the
// entire document — claude.ai's chat history dumps thousands of
// <span>/<p> nodes that swamp signal. If a future need wants the
// broader sweep, add a `--all` flag here rather than expanding the
// default.

import type { InspectorClient } from '../src/lib/inspector.js';

export interface FindHit {
	tag: string;
	role: string | null;
	ariaLabel: string | null;
	text: string;
	matchedField: 'text' | 'ariaLabel' | 'both';
	visible: boolean;
}

// Regex source + flags travel as JSON strings into the renderer eval —
// same encoding pattern as openPill / clickMenuItem in lib/claudeai.ts.
export async function findInRenderer(
	client: InspectorClient,
	pattern: RegExp,
	opts: { limit?: number } = {},
): Promise<FindHit[]> {
	const limit = opts.limit ?? 100;
	const reSrc = JSON.stringify(pattern.source);
	const reFlags = JSON.stringify(pattern.flags);
	return await client.evalInRenderer<FindHit[]>(
		'claude.ai',
		`(() => {
			const re = new RegExp(${reSrc}, ${reFlags});
			const sel = 'button, a, h1, h2, h3, h4, h5, h6, ' +
				'[role], [aria-label]';
			const nodes = Array.from(document.querySelectorAll(sel));
			const hits = [];
			for (const el of nodes) {
				const text = (el.textContent || '').trim().slice(0, 200);
				const aria = el.getAttribute('aria-label');
				const textHit = text.length > 0 && re.test(text);
				const ariaHit = aria !== null && re.test(aria);
				if (!textHit && !ariaHit) continue;
				hits.push({
					tag: el.tagName.toLowerCase(),
					role: el.getAttribute('role'),
					ariaLabel: aria,
					text,
					matchedField: textHit && ariaHit
						? 'both'
						: (textHit ? 'text' : 'ariaLabel'),
					visible: !!el.getClientRects().length,
				});
				if (hits.length >= ${limit}) break;
			}
			return hits;
		})()`,
	);
}

export function formatHits(hits: FindHit[]): string {
	if (hits.length === 0) return 'No matches.';
	const lines: string[] = [];
	for (const h of hits) {
		const vis = h.visible ? '' : ' [hidden]';
		const role = h.role ? ` role=${h.role}` : '';
		const aria = h.ariaLabel !== null ? ` aria-label=${q(h.ariaLabel)}` : '';
		lines.push(
			`${h.tag}${role}${aria} (${h.matchedField})${vis}` +
				(h.text ? `\n    text: ${h.text}` : ''),
		);
	}
	lines.push('');
	lines.push(`${hits.length} match(es).`);
	return lines.join('\n');
}

function q(s: string): string {
	return JSON.stringify(s);
}
