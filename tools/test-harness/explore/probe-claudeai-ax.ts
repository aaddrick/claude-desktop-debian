// Live AX-tree probe for the claudeai.ts migration. Connects to the
// host's main-process Node inspector on :9229 (must be enabled via
// "Developer → Enable Main Process Debugger"), pulls the claude.ai
// AX tree, and reports what the page-object discrimination shapes
// will actually see.
//
// Read-only — no clicks, no state mutation.
//
// Run: cd tools/test-harness && npx tsx explore/probe-claudeai-ax.ts

import { InspectorClient } from '../src/lib/inspector.js';
import { axTreeToSnapshot, type RawElement } from './walker.js';

const INSPECTOR_PORT = 9229;
const ROW_MORE_OPTIONS_RE = /^More options for /;
const MENU_ITEM_ROLES = new Set([
	'menuitem',
	'menuitemradio',
	'menuitemcheckbox',
]);

function landmarkTrail(el: RawElement): string {
	const trail = el.ancestors
		.filter((a) => a.role !== null)
		.map((a) => (a.name ? `${a.role}[${a.name}]` : (a.role as string)));
	return trail.join(' › ') || '<no ancestors>';
}

function fmtElement(el: RawElement): string {
	const name = el.accessibleName ?? '<no-name>';
	const popup = el.hasPopup ?? '-';
	return (
		`  • role=${el.computedRole} hasPopup=${popup} ` +
		`name=${JSON.stringify(name).slice(0, 90)}\n` +
		`    landmarks: ${landmarkTrail(el)}`
	);
}

async function main(): Promise<void> {
	const inspector = await InspectorClient.connect(INSPECTOR_PORT);
	try {
		// What URL is the renderer on right now?
		const url = await inspector.evalInRenderer<string>(
			'claude.ai',
			'(() => location.href)()',
		);
		process.stdout.write(`renderer URL: ${url}\n\n`);

		const nodes = await inspector.getAccessibleTree('claude.ai');
		process.stdout.write(`raw AX nodes: ${nodes.length}\n`);
		const elements = axTreeToSnapshot(nodes);
		process.stdout.write(
			`interactive elements (post-filter): ${elements.length}\n\n`,
		);

		// Bucket by role for a quick overall shape.
		const byRole = new Map<string, number>();
		for (const el of elements) {
			byRole.set(el.computedRole, (byRole.get(el.computedRole) ?? 0) + 1);
		}
		process.stdout.write('role histogram:\n');
		for (const [role, n] of [...byRole.entries()].sort()) {
			process.stdout.write(`  ${role}: ${n}\n`);
		}
		process.stdout.write('\n');

		// THE KEY QUESTION: do any buttons report hasPopup === 'menu'?
		// If yes, the migration's discrimination shape is sound. If no,
		// claude.ai exposes the popover trigger via a different AX
		// signal and we need a different filter.
		const buttonsWithPopup = elements.filter(
			(el) => el.computedRole === 'button' && el.hasPopup !== null,
		);
		process.stdout.write(
			`buttons with hasPopup set (any value): ${buttonsWithPopup.length}\n`,
		);
		const popupValues = new Map<string, number>();
		for (const b of buttonsWithPopup) {
			const v = b.hasPopup ?? '<null>';
			popupValues.set(v, (popupValues.get(v) ?? 0) + 1);
		}
		for (const [v, n] of [...popupValues.entries()].sort()) {
			process.stdout.write(`  hasPopup="${v}": ${n}\n`);
		}
		process.stdout.write('\n');

		// What findCompactPills() would return.
		const compactPills = elements.filter(
			(el) =>
				el.computedRole === 'button' &&
				el.hasPopup === 'menu' &&
				el.accessibleName !== null &&
				el.accessibleName.length > 0 &&
				!ROW_MORE_OPTIONS_RE.test(el.accessibleName),
		);
		process.stdout.write(
			`findCompactPills() would return ${compactPills.length} candidate(s):\n`,
		);
		for (const el of compactPills) process.stdout.write(`${fmtElement(el)}\n`);
		process.stdout.write('\n');

		// What the row-more-options filter is dropping.
		const rowMore = elements.filter(
			(el) =>
				el.computedRole === 'button' &&
				el.hasPopup === 'menu' &&
				el.accessibleName !== null &&
				ROW_MORE_OPTIONS_RE.test(el.accessibleName),
		);
		process.stdout.write(
			`row-more-options filter dropped ${rowMore.length} button(s) ` +
				`(showing first 5):\n`,
		);
		for (const el of rowMore.slice(0, 5)) {
			process.stdout.write(`${fmtElement(el)}\n`);
		}
		process.stdout.write('\n');

		// Top-level tabs: activateTab() looks for `role: 'button'` with
		// accessibleName === 'Chat' | 'Cowork' | 'Code'. Probe each one.
		process.stdout.write('top-level tab probe:\n');
		for (const name of ['Chat', 'Cowork', 'Code']) {
			const matches = elements.filter(
				(el) =>
					el.computedRole === 'button' && el.accessibleName === name,
			);
			process.stdout.write(`  "${name}": ${matches.length} match(es)\n`);
			for (const el of matches) {
				process.stdout.write(
					`    landmarks: ${landmarkTrail(el)} hasPopup=${el.hasPopup ?? '-'}\n`,
				);
			}
		}
		process.stdout.write('\n');

		// Open menu? Anything in MENU_ITEM_ROLES right now would mean a
		// menu happens to be open at probe time — useful context for
		// callers reading the output.
		const items = elements.filter((el) =>
			MENU_ITEM_ROLES.has(el.computedRole),
		);
		process.stdout.write(
			`menuitem* elements currently in tree: ${items.length}` +
				(items.length > 0 ? ' (a menu is open — surprise context)' : '') +
				'\n\n',
		);

		// Diagnostic: is `properties[]` even being returned? Dump the
		// raw shape of the first button node and any node that has a
		// non-empty properties array, so we can tell whether
		// (a) Chromium isn't surfacing aria-haspopup, or
		// (b) properties[] is just absent from the response.
		const firstButton = nodes.find((n) => n.role?.value === 'button');
		if (firstButton) {
			process.stdout.write('first raw button AxNode (full JSON):\n');
			process.stdout.write(`${JSON.stringify(firstButton, null, 2)}\n\n`);
		}

		const nodesWithProps = nodes.filter(
			(n) => Array.isArray(n.properties) && n.properties.length > 0,
		);
		process.stdout.write(
			`raw nodes with non-empty properties[]: ${nodesWithProps.length}\n`,
		);
		// Histogram of property names actually present.
		const propNames = new Map<string, number>();
		for (const n of nodesWithProps) {
			const props = n.properties as { name?: string }[];
			for (const p of props) {
				if (typeof p.name === 'string') {
					propNames.set(p.name, (propNames.get(p.name) ?? 0) + 1);
				}
			}
		}
		for (const [name, n] of [...propNames.entries()].sort()) {
			process.stdout.write(`  property "${name}": ${n}\n`);
		}
		process.stdout.write('\n');

		// Spot-check the model picker if visible — it should be the
		// canonical "menu trigger" on every surface.
		const modelLikely = elements.filter(
			(el) =>
				el.accessibleName !== null &&
				/^(Opus|Sonnet|Haiku|Claude)\b/i.test(el.accessibleName),
		);
		process.stdout.write(
			`model-picker-like elements (name starts with Opus/Sonnet/Haiku/Claude): ` +
				`${modelLikely.length}\n`,
		);
		for (const el of modelLikely.slice(0, 5)) {
			process.stdout.write(`${fmtElement(el)}\n`);
		}
	} finally {
		inspector.close();
	}
}

main().catch((err) => {
	process.stderr.write(`probe failed: ${err}\n`);
	process.exit(1);
});
