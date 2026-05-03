// AUTO-GENERATED FROM docs/testing/ui-inventory.json
// DO NOT EDIT — regenerate with `npm run gen:render-specs`
// Source inventory: walker v7 (account-portable ariaPath fingerprints), captured 2026-05-03T07:13:20.024Z, app 1.5354.0
// Entries: 90 (6 denylisted), 12 surfaces
// Meta: partial=false

import { test, expect } from '@playwright/test';

import { launchClaude } from '../lib/electron.js';
import type { ClaudeApp } from '../lib/electron.js';
import { createIsolation } from '../lib/isolation.js';
import { InspectorClient } from '../lib/inspector.js';
import { captureSessionEnv } from '../lib/diagnostics.js';
import {
	currentUrl,
	findByFingerprint,
	redrivePath,
	waitForStable,
} from '../../explore/walker.js';
import type { InventoryEntry } from '../../explore/walker.js';

// U01 — UI visibility sweep.
//
// One Playwright test per inventory entry. Each test re-drives the
// entry's recorded navigationPath against the live signed-in
// renderer, then asserts the entry's fingerprint resolves to a
// visible element. The full inventory acts as a render contract:
// any entry that no longer renders (selector drift, route change,
// permission change) shows up as exactly one failed test, with the
// triage payload (entry JSON + observed DOM neighbourhood)
// attached to that test only.
//
// Skip semantics mirror H05: the suite skips cleanly if the host
// isn't signed in (claude.ai webContents never reaches the
// userLoaded level). Default path: kill any running host Claude,
// copy the auth-relevant subset of ~/.config/Claude into a
// hermetic tmpdir, and launch against that copy. Host config is
// left untouched after the kill+seed. CLAUDE_TEST_USE_HOST_CONFIG=1
// opts out and shares the host's actual config directory (no
// kill+seed) — use only when you've manually closed the host first.
//
// Denylisted entries: we still assert they render, but the
// generator strips any navigationPath step that would CLICK the
// denylisted entry itself. Per the spec brief: never trigger
// destructive controls from a render check.
//
// Persistent entries: each persistent entry is asserted on its
// canonical surface only (the `surface` field). The cross-surface
// `surfaces[]` list is intentionally unused here — a strict
// "renders on every surface it was observed" mode is a future
// follow-up.
//
// Instance entries: assert that AT LEAST ONE element matching the
// fingerprint exists. We don't assert the recorded instanceCount
// — list lengths legitimately fluctuate across sessions.

// Per-test budget covers a path redrive (~1 nav + ~N clicks * 1.5s)
// plus a fingerprint resolve. Generous to ride out a slow first
// route load; later tests in the same suite reuse the warmed app.
test.setTimeout(120_000);

const useHostConfig = process.env.CLAUDE_TEST_USE_HOST_CONFIG === '1';

// Single shared launch + inspector across the whole suite. N
// tests at one launch each would burn 30+ minutes on cold-start
// alone. We pay for setup once, then each test re-drives from the
// recorded startUrl so prior-test side effects (open menus, route
// changes) get reset before the next assertion runs.
let app: ClaudeApp | null = null;
let sharedInspector: InspectorClient | null = null;
let sharedStartUrl: string | null = null;
let suiteSkipReason: string | null = null;

test.describe('U01 — UI visibility sweep (auto-generated)', () => {
	test.beforeAll(async () => {
		// Default path: kill any host Claude, copy auth-relevant
		// subset of ~/.config/Claude into a hermetic tmpdir, launch
		// against that copy. Host config is left untouched after the
		// kill+seed. CLAUDE_TEST_USE_HOST_CONFIG=1 opts out — shares
		// the host's actual config directory (no kill+seed); use only
		// when you've manually closed the host first.
		if (useHostConfig) {
			app = await launchClaude({ isolation: null });
		} else {
			const seeded = await createIsolation({ seedFromHost: true });
			app = await launchClaude({ isolation: seeded });
		}
		const ready = await app.waitForReady('userLoaded');
		if (!ready.postLoginUrl) {
			suiteSkipReason = 'claude.ai never reached a post-login URL — host ' +
				'profile is not signed in. Sign in via the host app first.';
			return;
		}
		sharedInspector = ready.inspector;
		sharedStartUrl = await currentUrl(sharedInspector);
		await waitForStable(sharedInspector);
	});

	test.afterAll(async () => {
		if (sharedInspector) {
			try {
				sharedInspector.close();
			} catch {
				// inspector may already be closed by app.close()
			}
			sharedInspector = null;
		}
		if (app) {
			await app.close();
			app = null;
		}
	});

	// why: shared per-test runner. Each generated `test()` packs the
	// entry as a literal and calls this — keeps the file scannable
	// (one block per entry) without duplicating the assertion logic
	// 383 times. Throws on its own when the suite was skipped so
	// each test's status reflects the actual render check, not a
	// mis-attributed setup failure.
	async function runEntry(
		entry: InventoryEntry,
		testInfo: import('@playwright/test').TestInfo,
	): Promise<void> {
		if (suiteSkipReason) {
			testInfo.skip(true, suiteSkipReason);
			return;
		}
		if (!sharedInspector || !sharedStartUrl) {
			throw new Error(
				'U01: beforeAll did not initialize the inspector — check the ' +
					'session-env attachment for the launch failure.',
			);
		}
		testInfo.annotations.push({ type: 'severity', description: 'Should' });
		testInfo.annotations.push({
			type: 'surface',
			description: entry.surface,
		});
		testInfo.annotations.push({
			type: 'kind',
			description: entry.kind,
		});

		try {
			await redrivePath(sharedInspector, sharedStartUrl, entry.navigationPath);
		} catch (err) {
			const msg = err instanceof Error ? err.message : String(err);
			await testInfo.attach('redrive-failure', {
				body: JSON.stringify(
					{
						entry,
						error: msg,
						note:
							'redrivePath threw before we could assert visibility — ' +
							'usually a stale fingerprint along the path. Re-walk the ' +
							'inventory and regenerate.',
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
			throw err;
		}
		await waitForStable(sharedInspector);

		const result = await findByFingerprint(
			sharedInspector,
			entry.fingerprint,
			entry.kind,
		);
		if (!result.found) {
			await testInfo.attach('fingerprint-miss', {
				body: JSON.stringify(
					{
						entry,
						reason: result.reason,
						observedOuterHTML: result.outerHTMLSnippet,
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
		}
		// Soft drift: primary aria-tree match failed but a relaxed-
		// scope fallback recovered. Test still passes — but a
		// drift-warning attachment surfaces it so the sweep summary
		// can flag re-walk before drift compounds.
		if (result.found && result.drift) {
			await testInfo.attach('drift-warning', {
				body: JSON.stringify(
					{
						entryId: entry.id,
						expected: entry.fingerprint.ariaPath,
						matchedVia: result.strategy,
						drift: result.drift,
						note:
							'primary aria-tree match failed; recovered via fallback. ' +
							'Re-walk inventory before drift compounds.',
					},
					null,
					2,
				),
				contentType: 'application/json',
			});
			testInfo.annotations.push({
				type: 'drift',
				description: result.strategy ?? 'unknown',
			});
		}
		expect(
			result.found,
			`fingerprint did not resolve: ${result.reason ?? 'unknown'}`,
		).toBe(true);
	}

	test.beforeAll(async ({}, testInfo) => {
		await testInfo.attach('session-env', {
			body: JSON.stringify(captureSessionEnv(), null, 2),
			contentType: 'application/json',
		});
	});

	test.describe("surface: root (28 entries)", () => {
		test("root.button-by-name.back [persistent] — button: Back", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.back","label":"Back","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Back"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.customize","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.expand-sidebar [structural] — button: Expand sidebar", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.expand-sidebar","label":"Expand sidebar","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Expand sidebar"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.forward [persistent] — button: Forward", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.forward","label":"Forward","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Forward"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.customize","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.menu [persistent] — button: Menu", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.menu","label":"Menu","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Menu"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.customize","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search [persistent] — button: Search", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search","label":"Search","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Search"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.customize","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.aaddrick-max [persistent] — button: Aaddrick Max", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.aaddrick-max","label":"Aaddrick Max","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Aaddrick Max"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.appearance [persistent] — button: Appearance", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.appearance","label":"Appearance","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Appearance"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize [persistent] — button: Customize", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize","label":"Customize","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Customize"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.filter [persistent] — button: Filter", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.filter","label":"Filter","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Filter"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.more-navigation-items [persistent] — button: More navigation items", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.more-navigation-items","label":"More navigation items","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"More navigation items"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.new-session-n [persistent] — button: New session ⌘N", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.new-session-n","label":"New session ⌘N","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"New session ⌘N"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.pinned [persistent] — button: Pinned", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.pinned","label":"Pinned","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Pinned"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.recents [persistent] — button: Recents", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.recents","label":"Recents","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Recents"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.routines [persistent] — button: Routines", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.routines","label":"Routines","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Routines"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-instance+72 [persistent] — button: Idle Review PR 555 for issue 558 fix", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-instance+72","label":"Idle Review PR 555 for issue 558 fix","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","instanceCount":72,"instanceLabelPattern":"complementary.button-instance","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.group.button-instance+3 [persistent] — button: Chat", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.group.button-instance+3","label":"Chat","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null},{"role":"group","name":{"kind":"literal","value":"Mode"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","instanceCount":3,"instanceLabelPattern":"complementary.group.button-instance","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.link [persistent] — link: Skip to content", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.link","label":"Skip to content","role":"link","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.accept-edits [persistent] — button: Accept edits", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.accept-edits","label":"Accept edits","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Accept edits"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.add [persistent] — button: Add", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.add","label":"Add","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Add"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.local [persistent] — button: Local", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.local","label":"Local","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Local"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.select-folder [persistent] — button: Select folder…", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.select-folder","label":"Select folder…","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Select folder…"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.send [persistent,denylist] — button: Send", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.send","label":"Send","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Send"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":true,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.show-5-more [persistent] — button: Show 5 more", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.show-5-more","label":"Show 5 more","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Show 5 more"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-name.transcript-view-mode [persistent] — button: Transcript view mode", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-name.transcript-view-mode","label":"Transcript view mode","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Transcript view mode"},"siblingIndex":null},"classification":"stable"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-shape.opus-version [persistent] — button: Opus 4.7 1M · Extra high", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-shape.opus-version","label":"Opus 4.7 1M · Extra high","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"pattern","regex":"^Opus \\d"},"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.button-by-shape.percentage [persistent] — button: Usage: plan 13%", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.button-by-shape.percentage","label":"Usage: plan 13%","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"pattern","regex":"\\d{1,3}%"},"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.group.button-instance [persistent] — button: Press and hold to record", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.group.button-instance","label":"Press and hold to record","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"group","name":{"kind":"literal","value":"Dictation"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
		test("root.main.region.list.button-instance+5 [persistent] — button: Open session Find contact method for Claude Desktop issue", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.main.region.list.button-instance+5","label":"Open session Find contact method for Claude Desktop issue","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"list","name":null}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[],"surface":"root","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:17.893Z","appVersion":"1.5354.0","instanceCount":5,"instanceLabelPattern":"main.region.list.button-instance","surfaces":["root","root.button-by-name.expand-sidebar","root.complementary.button-by-name.new-session-n","root.complementary.link"]};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.expand-sidebar (1 entry)", () => {
		test("root.button-by-name.expand-sidebar.button-by-name.collapse-sidebar [persistent] — button: Collapse sidebar", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.expand-sidebar.button-by-name.collapse-sidebar","label":"Collapse sidebar","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Collapse sidebar"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.expand-sidebar"}],"surface":"root.button-by-name.expand-sidebar","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:09:58.876Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.expand-sidebar","root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","root.complementary.button-by-name.customize","root.complementary.button-by-name.new-session-n","root.complementary.button-by-name.routines"]};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search (2 entries)", () => {
		test("root.button-by-name.search.dialog.button [dialog] — button: Close", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.button","label":"Close","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Dialog"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"}],"surface":"root.button-by-name.search","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:10:07.123Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25 [instance] — option: Claude Desktop Debian Enter", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25","label":"Claude Desktop Debian Enter","role":"option","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Dialog"}},{"role":"listbox","name":{"kind":"literal","value":"Search results"}}],"leaf":{"role":"option","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"}],"surface":"root.button-by-name.search","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:10:07.123Z","appVersion":"1.5354.0","instanceCount":25,"instanceLabelPattern":"dialog.listbox.option-instance"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search.dialog.listbox.option-instance+25 (16 entries)", () => {
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts [persistent] — button: Artifacts", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","label":"Artifacts","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Artifacts"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.draft-pr-visibility-on-github [persistent] — button: Draft PR visibility on GitHub", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.draft-pr-visibility-on-github","label":"Draft PR visibility on GitHub","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Draft PR visibility on GitHub"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.elko-hrn-33-and-hrn-31-manuals [persistent] — button: ELKO HRN-33 and HRN-31 manuals", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.elko-hrn-33-and-hrn-31-manuals","label":"ELKO HRN-33 and HRN-31 manuals","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"ELKO HRN-33 and HRN-31 manuals"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.feedback-submission [persistent] — button: Feedback submission", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.feedback-submission","label":"Feedback submission","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Feedback submission"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions [persistent] — button: Get apps and extensions", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","label":"Get apps and extensions","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Get apps and extensions"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n [persistent] — button: New chat ⌘N", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","label":"New chat ⌘N","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"New chat ⌘N"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects [persistent] — button: Projects", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","label":"Projects","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Projects"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.star-charts-in-github-readme-files [persistent] — button: Star charts in GitHub readme files", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.star-charts-in-github-readme-files","label":"Star charts in GitHub readme files","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Star charts in GitHub readme files"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.view-all [persistent] — button: View all", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.view-all","label":"View all","role":"button","fingerprint":{"ariaPath":[{"role":"complementary","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"View all"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"persistent","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","surfaces":["root.button-by-name.search.dialog.listbox.option-instance+25","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"]};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.link [structural] — link: All projects", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.link","label":"All projects","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.add-files [structural] — button: Add files", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.add-files","label":"Add files","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Add files"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.edit-instructions [structural] — button: Edit Instructions", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.edit-instructions","label":"Edit Instructions","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Edit Instructions"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.pin-project [structural] — button: Pin project", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.pin-project","label":"Pin project","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Pin project"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.start-a-task-in-cowork [structural] — button: Start a task in Cowork", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-name.start-a-task-in-cowork","label":"Start a task in Cowork","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Start a task in Cowork"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-shape.row-more-options [structural] — button: More options for Claude Desktop Debian", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.button-by-shape.row-more-options","label":"More options for Claude Desktop Debian","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"pattern","regex":"^More options for "},"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.group.button-instance+4 [instance] — button: Press and hold to record", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.main.region.main.group.button-instance+4","label":"Press and hold to record","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"group","name":null}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:12:08.559Z","appVersion":"1.5354.0","instanceCount":4,"instanceLabelPattern":"main.region.main.group.button-instance"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts (3 entries)", () => {
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.button [structural] — button: New artifact", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.button","label":"New artifact","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:05.215Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.main.link [structural] — link: Your artifacts", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.main.link","label":"Your artifacts","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:05.215Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.main.list.link [structural] — link: Electron apps Linux users desperately want but can't have Despite Electron's cross-platform promise, several high-profile applications deliberately skip Linux even though the framework makes it technically trivial to support. The most glaring Electron Apps Linux Users Want But Cannot Have: The Cross-Platform Promise Gap Last edited 3 months ago", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts.main.region.main.list.link","label":"Electron apps Linux users desperately want but can't have Despite Electron's cross-platform promise, several high-profile applications deliberately skip Linux even though the framework makes it technically trivial to support. The most glaring Electron Apps Linux Users Want But Cannot Have: The Cross-Platform Promise Gap Last edited 3 months ago","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"list","name":{"kind":"literal","value":"Artifacts"}}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.artifacts","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:05.215Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions (8 entries)", () => {
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.banner.button-by-name.back-to-claude [structural] — button: Back to Claude", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.banner.button-by-name.back-to-claude","label":"Back to Claude","role":"button","fingerprint":{"ariaPath":[{"role":"banner","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Back to Claude"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.banner.button-by-name.menu [structural] — button: Menu", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.banner.button-by-name.menu","label":"Menu","role":"button","fingerprint":{"ariaPath":[{"role":"banner","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Menu"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.illustration-of-claude-placing-a-grocery-order-in-chrome-cla [structural] — button: Illustration of Claude placing a grocery order in Chrome Claude Create a shopping list, go on Chrome, and make an order", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.illustration-of-claude-placing-a-grocery-order-in-chrome-cla","label":"Illustration of Claude placing a grocery order in Chrome Claude Create a shopping list, go on Chrome, and make an order","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Illustration of Claude placing a grocery order in Chrome Claude Create a shopping list, go on Chrome, and make an order"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.my-downloads-folder-is-a-mess-can-you-clean-it-up [structural] — button: My downloads folder is a mess! Can you clean it up?", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.my-downloads-folder-is-a-mess-can-you-clean-it-up","label":"My downloads folder is a mess! Can you clean it up?","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"My downloads folder is a mess! Can you clean it up?"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.read-health-data [structural] — button: Read health data", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.read-health-data","label":"Read health data","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Read health data"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.turn-these-receipts-into-an-expense-report [structural] — button: Turn these receipts into an expense report", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-by-name.turn-these-receipts-into-an-expense-report","label":"Turn these receipts into an expense report","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Turn these receipts into an expense report"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-instance+5 [instance,denylist] — button: Install", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.button-instance+5","label":"Install","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"instance","denylisted":true,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0","instanceCount":5,"instanceLabelPattern":"button-instance"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.link-instance+7 [instance,denylist] — link: Install", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions.link-instance+7","label":"Install","role":"link","fingerprint":{"ariaPath":[],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.get-apps-and-extensions","kind":"instance","denylisted":true,"discoveredAt":"2026-05-03T07:13:15.693Z","appVersion":"1.5354.0","instanceCount":7,"instanceLabelPattern":"link-instance"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n (6 entries)", () => {
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.group.button-instance+4 [instance] — button: Press and hold to record", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.group.button-instance+4","label":"Press and hold to record","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"group","name":null}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0","instanceCount":4,"instanceLabelPattern":"main.region.main.group.button-instance"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.code [structural] — tab: Code", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.code","label":"Code","role":"tab","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"tablist","name":{"kind":"literal","value":"Prompt categories"}}],"leaf":{"role":"tab","name":{"kind":"literal","value":"Code"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.from-calendar [structural] — tab: From Calendar", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.from-calendar","label":"From Calendar","role":"tab","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"tablist","name":{"kind":"literal","value":"Prompt categories"}}],"leaf":{"role":"tab","name":{"kind":"literal","value":"From Calendar"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.from-gmail [structural] — tab: From Gmail", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.from-gmail","label":"From Gmail","role":"tab","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"tablist","name":{"kind":"literal","value":"Prompt categories"}}],"leaf":{"role":"tab","name":{"kind":"literal","value":"From Gmail"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.learn [structural] — tab: Learn", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.learn","label":"Learn","role":"tab","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"tablist","name":{"kind":"literal","value":"Prompt categories"}}],"leaf":{"role":"tab","name":{"kind":"literal","value":"Learn"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.write [structural] — tab: Write", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n.main.region.main.tablist.tab-by-name.write","label":"Write","role":"tab","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}},{"role":"main","name":null},{"role":"tablist","name":{"kind":"literal","value":"Prompt categories"}}],"leaf":{"role":"tab","name":{"kind":"literal","value":"Write"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.new-chat-n","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:43.243Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects (5 entries)", () => {
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.new-project [structural] — button: New project", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.new-project","label":"New project","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"New project"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:54.282Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.search-projects [structural] — button: Search projects", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.search-projects","label":"Search projects","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Search projects"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:54.282Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.sort-by [structural] — button: Sort by", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-by-name.sort-by","label":"Sort by","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Sort by"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:12:54.282Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-instance+3 [instance] — button: Project actions", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.button-instance+3","label":"Project actions","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:12:54.282Z","appVersion":"1.5354.0","instanceCount":3,"instanceLabelPattern":"main.region.button-instance"};
			await runEntry(entry, testInfo);
		});
		test("root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.link-instance+3 [instance] — link: Claude Desktop Debian 1 year ago", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects.main.region.link-instance+3","label":"Claude Desktop Debian 1 year ago","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.button-by-name.search"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25"},{"action":"click","id":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects"}],"surface":"root.button-by-name.search.dialog.listbox.option-instance+25.complementary.button-by-name.projects","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:12:54.282Z","appVersion":"1.5354.0","instanceCount":3,"instanceLabelPattern":"main.region.link-instance"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.complementary.button-by-name.customize (9 entries)", () => {
		test("root.complementary.button-by-name.customize.main.button-by-name.back-to-claude [structural] — button: Back to Claude", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.back-to-claude","label":"Back to Claude","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Back to Claude"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.browse-plugins-add-pre-built-knowledge-for-your-field [structural] — button: Browse plugins Add pre-built knowledge for your field.", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.browse-plugins-add-pre-built-knowledge-for-your-field","label":"Browse plugins Add pre-built knowledge for your field.","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Browse plugins Add pre-built knowledge for your field."},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you [structural] — button: Connect your apps Let Claude read and write to the tools you already use.", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","label":"Connect your apps Let Claude read and write to the tools you already use.","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Connect your apps Let Claude read and write to the tools you already use."},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.link [structural] — link: Create new skills Teach Claude your processes, team norms, and expertise.", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.link","label":"Create new skills Teach Claude your processes, team norms, and expertise.","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null}],"leaf":{"role":"link","name":null,"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.navigation.button-by-name.add-plugin [structural] — button: Add plugin", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.navigation.button-by-name.add-plugin","label":"Add plugin","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"navigation","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Add plugin"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.navigation.button-by-name.browse-plugins [structural] — button: Browse plugins", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.navigation.button-by-name.browse-plugins","label":"Browse plugins","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"navigation","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Browse plugins"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.navigation.button-by-name.select-a-folder [structural] — button: Select a folder", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.navigation.button-by-name.select-a-folder","label":"Select a folder","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"navigation","name":null}],"leaf":{"role":"button","name":{"kind":"literal","value":"Select a folder"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.navigation.link-by-name.connectors [structural] — link: Connectors", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.navigation.link-by-name.connectors","label":"Connectors","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"navigation","name":null}],"leaf":{"role":"link","name":{"kind":"literal","value":"Connectors"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.navigation.link-by-name.skills [structural] — link: Skills", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.navigation.link-by-name.skills","label":"Skills","role":"link","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"navigation","name":null}],"leaf":{"role":"link","name":{"kind":"literal","value":"Skills"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"}],"surface":"root.complementary.button-by-name.customize","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:29.597Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you (8 entries)", () => {
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.anthropic-partners [dialog] — button: Anthropic & Partners", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.anthropic-partners","label":"Anthropic & Partners","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Anthropic & Partners"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.close [dialog] — button: Close", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.close","label":"Close","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Close"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.filter-by [dialog] — button: Filter by", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.filter-by","label":"Filter by","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Filter by"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.sort-by [dialog] — button: Sort by", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-by-name.sort-by","label":"Sort by","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Sort by"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-instance+704 [instance] — button: Google Drive Most popular Install Search, read, and upload files instantly", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.button-instance+704","label":"Google Drive Most popular Install Search, read, and upload files instantly","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}}],"leaf":{"role":"button","name":null,"siblingIndex":null},"classification":"instance"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"instance","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0","instanceCount":704,"instanceLabelPattern":"dialog.button-instance"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.connectors [dialog] — button: Connectors", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.connectors","label":"Connectors","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}},{"role":"complementary","name":null},{"role":"navigation","name":{"kind":"literal","value":"Directory sections"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Connectors"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.plugins [dialog] — button: Plugins", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.plugins","label":"Plugins","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}},{"role":"complementary","name":null},{"role":"navigation","name":{"kind":"literal","value":"Directory sections"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Plugins"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.skills [dialog] — button: Skills", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you.dialog.complementary.navigation.button-by-name.skills","label":"Skills","role":"button","fingerprint":{"ariaPath":[{"role":"dialog","name":{"kind":"literal","value":"Directory"}},{"role":"complementary","name":null},{"role":"navigation","name":{"kind":"literal","value":"Directory sections"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Skills"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.customize"},{"action":"click","id":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you"}],"surface":"root.complementary.button-by-name.customize.main.button-by-name.connect-your-apps-let-claude-read-and-write-to-the-tools-you","kind":"dialog","denylisted":false,"discoveredAt":"2026-05-03T07:12:27.946Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.complementary.button-by-name.routines (3 entries)", () => {
		test("root.complementary.button-by-name.routines.main.region.button-by-name.all [structural] — button: All", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.routines.main.region.button-by-name.all","label":"All","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"All"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.routines"}],"surface":"root.complementary.button-by-name.routines","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:22.997Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.routines.main.region.button-by-name.calendar [structural] — button: Calendar", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.routines.main.region.button-by-name.calendar","label":"Calendar","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"Calendar"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.routines"}],"surface":"root.complementary.button-by-name.routines","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:22.997Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
		test("root.complementary.button-by-name.routines.main.region.button-by-name.new-routine [structural] — button: New routine", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.button-by-name.routines.main.region.button-by-name.new-routine","label":"New routine","role":"button","fingerprint":{"ariaPath":[{"role":"main","name":null},{"role":"region","name":{"kind":"literal","value":"Primary pane"}}],"leaf":{"role":"button","name":{"kind":"literal","value":"New routine"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.button-by-name.routines"}],"surface":"root.complementary.button-by-name.routines","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:10:22.997Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

	test.describe("surface: root.complementary.link (1 entry)", () => {
		test("root.complementary.link.button-by-name.expand-sidebar [structural] — button: Expand sidebar", async ({}, testInfo) => {
			const entry: InventoryEntry = {"id":"root.complementary.link.button-by-name.expand-sidebar","label":"Expand sidebar","role":"button","fingerprint":{"ariaPath":[],"leaf":{"role":"button","name":{"kind":"literal","value":"Expand sidebar"},"siblingIndex":null},"classification":"stable"},"navigationPath":[{"action":"click","id":"root.complementary.link"}],"surface":"root.complementary.link","kind":"structural","denylisted":false,"discoveredAt":"2026-05-03T07:09:51.202Z","appVersion":"1.5354.0"};
			await runEntry(entry, testInfo);
		});
	});

});
