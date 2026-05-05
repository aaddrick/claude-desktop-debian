// Probe to verify whether the eipc channel registry (LocalSessions_$_*,
// CustomPlugins_$_*) is reachable from main via webContents.ipc._invokeHandlers
// instead of the empty-on-this-build globalThis.ipcMain._invokeHandlers.
//
// Run from tools/test-harness against a running claude-desktop with the
// main-process debugger enabled (Developer → Enable Main Process Debugger
// in the app menu, or `claude-desktop` was launched with --inspect):
//   npx tsx eipc-registry-probe.ts
//
// Useful states to probe (re-run to compare):
//   * fresh launch — whichever tab opens by default
//   * /epitaxy with a Code session open
//   * /chats with a chat thread open
//   * cowork tab loaded
// The per-interface breakdown surfaces which interfaces register lazily
// vs eagerly — useful for designing the lib/eipc.ts primitive's wait
// semantics.
//
// Non-destructive — read-only enumeration of handler keys. Doesn't invoke
// anything, doesn't register anything, doesn't mutate state.

import { InspectorClient } from './src/lib/inspector.js';
import { writeFileSync } from 'node:fs';

interface InterfaceCount {
	scope: string;
	iface: string;
	count: number;
	sampleMethods: string[];
}

interface PerWcReport {
	id: number;
	url: string;
	type: string;
	hasIpc: boolean;
	hasInvokeHandlers: boolean;
	totalHandlers: number;
	framedCount: number;
	unframedCount: number;
	scopes: string[];
	byInterface: InterfaceCount[];
	unframedSample: string[];
}

async function main() {
	const client = await InspectorClient.connect(9229);

	// Confirm globalThis.ipcMain._invokeHandlers is empty (or near-empty)
	// — that's session 3's finding and we want it on the record alongside
	// the per-wc reading for contrast.
	const ipcMainReport = await client.evalInMain<{
		hasIpcMain: boolean;
		ipcMainKeys: string[];
		ipcMainCount: number;
	}>(`
		const electron = process.mainModule.require('electron');
		const ipcMain = electron.ipcMain;
		const map = ipcMain && ipcMain._invokeHandlers;
		if (!map) {
			return { hasIpcMain: !!ipcMain, ipcMainKeys: [], ipcMainCount: 0 };
		}
		const keys = (typeof map.keys === 'function')
			? Array.from(map.keys())
			: Object.keys(map);
		return {
			hasIpcMain: true,
			ipcMainKeys: keys,
			ipcMainCount: keys.length,
		};
	`);

	// Per-webContents enumeration with full framing parse:
	//   $eipc_message$_<UUID>_$_<scope>_$_<interface>_$_<method>
	// Scope examples: claude.settings, claude.web, claude.app_internal.
	// Interface examples: GlobalShortcut, LocalSessions, CustomPlugins.
	// We group by scope.iface to show which feature areas are populated
	// on each webContents — what registers eagerly vs on-tab-load.
	const perWcReports = await client.evalInMain<PerWcReport[]>(`
		const { webContents } = process.mainModule.require('electron');
		const re = /^\\$eipc_message\\$_[0-9a-f-]+_\\$_([^_]+(?:\\.[^_]+)*)_\\$_([^_]+)_\\$_(.+)$/;
		const all = webContents.getAllWebContents();
		const out = [];
		for (const w of all) {
			const ipc = w.ipc;
			const invokeMap = ipc && ipc._invokeHandlers;
			let keys = [];
			let hasInvokeHandlers = false;
			if (invokeMap) {
				hasInvokeHandlers = true;
				if (typeof invokeMap.keys === 'function') {
					keys = Array.from(invokeMap.keys());
				} else {
					keys = Object.keys(invokeMap);
				}
			}
			const groups = new Map();
			const scopes = new Set();
			let framedCount = 0;
			let unframedCount = 0;
			const unframedSample = [];
			for (const k of keys) {
				const m = re.exec(k);
				if (!m) {
					unframedCount++;
					if (unframedSample.length < 8) unframedSample.push(k);
					continue;
				}
				framedCount++;
				const scope = m[1];
				const iface = m[2];
				const method = m[3];
				scopes.add(scope);
				const groupKey = scope + '/' + iface;
				let g = groups.get(groupKey);
				if (!g) {
					g = { scope, iface, count: 0, sampleMethods: [] };
					groups.set(groupKey, g);
				}
				g.count++;
				if (g.sampleMethods.length < 4) g.sampleMethods.push(method);
			}
			const byInterface = Array.from(groups.values())
				.sort((a, b) => b.count - a.count);
			out.push({
				id: w.id,
				url: w.getURL(),
				type: w.getType ? w.getType() : 'unknown',
				hasIpc: !!ipc,
				hasInvokeHandlers,
				totalHandlers: keys.length,
				framedCount,
				unframedCount,
				scopes: Array.from(scopes).sort(),
				byInterface,
				unframedSample,
			});
		}
		return out;
	`);

	// For each case-doc anchored channel, find which webContents (if any)
	// hosts it. The framing prefix `$eipc_message$_<UUID>_$_claude.web_$_`
	// is build-stable per session 2's T38 finding, so we match by suffix.
	const expected = [
		// T22 — gh PR check monitoring
		'LocalSessions_$_getPrChecks',
		// T31 — side chat trio
		'LocalSessions_$_startSideChat',
		'LocalSessions_$_sendSideChatMessage',
		'LocalSessions_$_stopSideChat',
		// T33 — plugin browser
		'CustomPlugins_$_listMarketplaces',
		'CustomPlugins_$_listAvailablePlugins',
		// T38 — Continue in IDE
		'LocalSessions_$_openInEditor',
	];

	const expectedReport = await client.evalInMain<
		Array<{ suffix: string; foundOn: number[]; matchedKeys: string[] }>
	>(`
		const { webContents } = process.mainModule.require('electron');
		const expected = ${JSON.stringify(expected)};
		const all = webContents.getAllWebContents();
		const out = [];
		for (const suffix of expected) {
			const foundOn = [];
			const matchedKeys = [];
			for (const w of all) {
				const ipc = w.ipc;
				const invokeMap = ipc && ipc._invokeHandlers;
				if (!invokeMap) continue;
				const keys = (typeof invokeMap.keys === 'function')
					? Array.from(invokeMap.keys())
					: Object.keys(invokeMap);
				for (const k of keys) {
					if (k.endsWith(suffix)) {
						if (!foundOn.includes(w.id)) foundOn.push(w.id);
						if (!matchedKeys.includes(k)) matchedKeys.push(k);
					}
				}
			}
			out.push({ suffix, foundOn, matchedKeys });
		}
		return out;
	`);

	// Snapshot the framing UUID(s) — useful to confirm build-stability
	// across the per-wc registries (session 2 noted it as build-stable
	// `c0eed8c9-...`).
	const framingReport = await client.evalInMain<{
		uuidsSeen: string[];
		samplesPerUuid: Record<string, string[]>;
	}>(`
		const { webContents } = process.mainModule.require('electron');
		const re = /^\\$eipc_message\\$_([0-9a-f-]+)_\\$_/;
		const uuidsSeen = new Set();
		const samples = {};
		for (const w of webContents.getAllWebContents()) {
			const ipc = w.ipc;
			const invokeMap = ipc && ipc._invokeHandlers;
			if (!invokeMap) continue;
			const keys = (typeof invokeMap.keys === 'function')
				? Array.from(invokeMap.keys())
				: Object.keys(invokeMap);
			for (const k of keys) {
				const m = re.exec(k);
				if (!m) continue;
				const uuid = m[1];
				uuidsSeen.add(uuid);
				if (!samples[uuid]) samples[uuid] = [];
				if (samples[uuid].length < 3) samples[uuid].push(k);
			}
		}
		return {
			uuidsSeen: Array.from(uuidsSeen),
			samplesPerUuid: samples,
		};
	`);

	console.log('=== globalThis.ipcMain._invokeHandlers (session 3 baseline) ===');
	console.log(JSON.stringify(ipcMainReport, null, 2));

	console.log('\n=== Per-webContents IPC registries ===');
	console.log(JSON.stringify(perWcReports, null, 2));

	console.log('\n=== Expected case-doc-anchored channel resolution ===');
	console.log(JSON.stringify(expectedReport, null, 2));

	console.log('\n=== Framing UUID(s) observed ===');
	console.log(JSON.stringify(framingReport, null, 2));

	// Cross-webContents per-interface deltas — useful when comparing
	// "fresh launch" vs "after navigating to /epitaxy" vs "after opening
	// cowork tab". Lists every (scope, iface) seen anywhere with the
	// per-wc breakdown of which has it.
	const interfaceAcrossWcs = (() => {
		const matrix = new Map<string, Map<number, number>>();
		for (const wc of perWcReports) {
			for (const g of wc.byInterface) {
				const key = `${g.scope}/${g.iface}`;
				let row = matrix.get(key);
				if (!row) {
					row = new Map();
					matrix.set(key, row);
				}
				row.set(wc.id, g.count);
			}
		}
		const out: Array<{
			interfaceKey: string;
			perWc: Record<string, number>;
			total: number;
		}> = [];
		for (const [key, row] of matrix) {
			const perWc: Record<string, number> = {};
			let total = 0;
			for (const [wcId, count] of row) {
				perWc[`wc${wcId}`] = count;
				total += count;
			}
			out.push({ interfaceKey: key, perWc, total });
		}
		out.sort((a, b) => b.total - a.total);
		return out;
	})();

	console.log('\n=== Interface presence across webContents ===');
	console.log(JSON.stringify(interfaceAcrossWcs, null, 2));

	const totalAll = perWcReports.reduce((a, r) => a + r.totalHandlers, 0);
	const totalFramed = perWcReports.reduce((a, r) => a + r.framedCount, 0);
	const totalUnframed = perWcReports.reduce((a, r) => a + r.unframedCount, 0);
	const expectedFound = expectedReport.filter((e) => e.foundOn.length > 0).length;
	const totalDistinctInterfaces = new Set(
		perWcReports.flatMap((r) => r.byInterface.map((g) => `${g.scope}/${g.iface}`)),
	).size;

	console.log('\n=== Summary ===');
	console.log(JSON.stringify({
		webContentsCount: perWcReports.length,
		webContentsUrls: perWcReports.map((r) => `wc${r.id}: ${r.url}`),
		ipcMainHandlerCount: ipcMainReport.ipcMainCount,
		perWcTotalHandlerCount: totalAll,
		perWcFramedCount: totalFramed,
		perWcUnframedCount: totalUnframed,
		distinctInterfacesAcrossAllWcs: totalDistinctInterfaces,
		expectedSuffixesFound: `${expectedFound} / ${expected.length}`,
		framingUuidsObserved: framingReport.uuidsSeen.length,
	}, null, 2));

	const out = {
		ipcMainReport,
		perWcReports,
		expectedReport,
		framingReport,
		interfaceAcrossWcs,
	};
	writeFileSync('/tmp/eipc-registry-probe.json', JSON.stringify(out, null, 2));
	console.log('\nFull dump → /tmp/eipc-registry-probe.json');

	client.close();
	process.exit(0);
}

main().catch((err) => {
	console.error('probe failed:', err);
	process.exit(1);
});
