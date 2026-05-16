// Standalone probe for issue #601 — verifies what's actually driving the
// yukonSilver Cowork support status on a running claude-desktop, and
// whether any code path the reporter claimed exists (server-pushed
// `setYukonSilverConfig` → `fHA="app_too_old"`) is reachable.
//
// Static analysis says no: in both 1.6608.2 (reporter's version) and
// 1.7196.0 (current upstream), the only non-definition call site of the
// `fHA`/`xJA` setter is the Developer → Emulate Support → "Desktop app
// too old (unavailable)" menu item. `setYukonSilverConfig` writes to a
// separate schema-typed store whose subscriber only resolves a
// wait-for-config Promise — it does not feed `fHA`.
//
// This probe captures the runtime evidence:
//   1. The `lam_feature_support_evaluated` telemetry entries from
//      main.log — what `pHA()`/`YJA()` actually returned (status,
//      unsupported_code).
//   2. The Developer menu — whether the "Emulate yukonSilver" submenu
//      has any item checked (the only thing that can put `fHA` into
//      `app_too_old` at runtime).
//   3. The full feature-support snapshot from `mD()`/`pw()` — invoked
//      by calling `AppFeatures.getSupportedFeatures` directly through
//      the per-webContents IPC registry with a synthetic event. The
//      origin gate is duck-typed (`event.senderFrame.url`), so a
//      synthesized `{senderFrame: {url: 'https://claude.ai/'}}` passes.
//
// Run from tools/test-harness against a running claude-desktop with the
// main-process debugger enabled (Developer → Enable Main Process Debugger,
// or launch with `--inspect=9229`):
//   npx tsx cowork-fha-probe.ts
//
// Non-destructive. Reads only — doesn't toggle the dev menu, doesn't
// call any `set*`/`start*`/`write*` handlers.

import { InspectorClient } from './src/lib/inspector.js';
import { writeFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

interface WcInfo {
	id: number;
	url: string;
	type: string;
}

interface MenuItemSnapshot {
	path: string;
	type: string;
	checked: boolean | undefined;
	enabled: boolean | undefined;
	sublabel: string | undefined;
}

interface FeatureStatus {
	status: string;
	reason?: string;
	unsupportedCode?: string;
}

interface SupportSnapshot {
	yukonSilver: FeatureStatus | null;
	keys: string[];
	error: string | null;
}

interface TelemetryEntry {
	raw: string;
	status: string | null;
	unsupportedCode: string | null;
	ts: string | null;
}

async function main() {
	const client = await InspectorClient.connect(9229);

	// ---- 1. Environment + webContents enumeration ---------------------
	const env = await client.evalInMain<{
		platform: string;
		arch: string;
		appVersion: string;
		electronVersion: string;
		userDataPath: string;
	}>(`
		const { app } = process.mainModule.require('electron');
		return {
			platform: process.platform,
			arch: process.arch,
			appVersion: app.getVersion(),
			electronVersion: process.versions.electron,
			userDataPath: app.getPath('userData'),
		};
	`);

	const webContentsList = await client.evalInMain<WcInfo[]>(`
		const { webContents } = process.mainModule.require('electron');
		return webContents.getAllWebContents().map(w => ({
			id: w.id,
			url: w.getURL(),
			type: w.getType ? w.getType() : 'unknown',
		}));
	`);

	// ---- 2. Application menu walk ------------------------------------
	// The bce setter (`Nvi`/`eJi`) is only called from the "Emulate
	// yukonSilver" submenu's click handler. Capture every item that
	// might be the culprit (`checked: true` on the "Desktop app too old"
	// one is the smoking gun) plus surrounding context for diagnostic
	// completeness.
	const menuSnapshot = await client.evalInMain<MenuItemSnapshot[]>(`
		const { Menu } = process.mainModule.require('electron');
		const out = [];
		function walk(menu, breadcrumb) {
			if (!menu) return;
			for (const item of menu.items || []) {
				const label = item.label || '(unlabeled)';
				const path = breadcrumb.concat(label).join(' > ');
				// Surface anything that could relate to yukonSilver / Cowork /
				// dev menu emulation. Broad on purpose — we'd rather see a
				// red herring than miss the gate.
				const re = /yukon|emulate|cowork|developer|secure vm|app too old|debug/i;
				if (re.test(label)) {
					out.push({
						path,
						type: item.type,
						checked: item.checked,
						enabled: item.enabled,
						sublabel: item.sublabel,
					});
				}
				if (item.submenu) walk(item.submenu, breadcrumb.concat(label));
			}
		}
		walk(Menu.getApplicationMenu(), []);
		return out;
	`);

	// ---- 3. Direct invocation of getSupportedFeatures -----------------
	// The `claude.settings/AppFeatures/getSupportedFeatures` handler
	// returns `{...mD(), louderPenguin, coworkKappa, coworkArtifacts,
	// markTaskComplete}` — i.e. the global feature snapshot keyed by
	// feature name. `yukonSilver` is the result of `pHA()`/`YJA()` in
	// that snapshot, so this read is equivalent to reading the function
	// directly without needing to know its minified name.
	//
	// The handler registers on the main_window webContents and is
	// origin-gated. Its renderer wrapper is *not* exposed (main_window's
	// renderer is file://), so `invokeEipcChannel`'s wrapper path doesn't
	// work. Instead, pull the handler out of `_invokeHandlers` directly
	// and call it with a synthesized event whose `senderFrame.url`
	// satisfies the inlined `Bi()` origin gate. The gate is structural
	// (duck-typed against `event.senderFrame.url`), so this passes.
	const supportSnapshot = await client.evalInMain<SupportSnapshot>(`
		const { webContents } = process.mainModule.require('electron');
		const suffix = '_$_AppFeatures_$_getSupportedFeatures';
		let handler = null;
		let foundOnWc = null;
		let fullKey = null;
		for (const wc of webContents.getAllWebContents()) {
			const map = wc.ipc && wc.ipc._invokeHandlers;
			if (!map) continue;
			const keys = (typeof map.keys === 'function')
				? Array.from(map.keys())
				: Object.keys(map);
			for (const k of keys) {
				if (k.endsWith(suffix)) {
					handler = (typeof map.get === 'function')
						? map.get(k)
						: map[k];
					foundOnWc = wc.id;
					fullKey = k;
					break;
				}
			}
			if (handler) break;
		}
		if (!handler) {
			return {
				yukonSilver: null,
				keys: [],
				error: 'AppFeatures.getSupportedFeatures handler not registered',
			};
		}
		// Synthesized event — origin gate is duck-typed, the file://
		// would-be-senderFrame on main_window is rejected, but a claude.ai
		// senderFrame URL passes. We're not lying about being claude.ai:
		// the value the handler returns is identical regardless of caller
		// (no per-frame branching inside getSupportedFeatures).
		const fakeEvent = {
			senderFrame: {
				url: 'https://claude.ai/',
				parent: null,
			},
		};
		try {
			const result = await handler(fakeEvent);
			return {
				yukonSilver: result && result.yukonSilver
					? result.yukonSilver
					: null,
				keys: result ? Object.keys(result).sort() : [],
				error: null,
			};
		} catch (err) {
			return {
				yukonSilver: null,
				keys: [],
				error: 'invocation threw: ' + (err && err.message || String(err)) +
					' (fullKey=' + fullKey + ', wc=' + foundOnWc + ')',
			};
		}
	`);

	// ---- 4. Main-log telemetry ---------------------------------------
	// `lam_feature_support_evaluated` is emitted by `kz()`/`YW()` (the
	// cache wrapper around the support check), every time pHA()/YJA()
	// resolves to a non-null cacheable result. Tail-grep the log for
	// yukonSilver entries — gives the historical record of what the gate
	// returned, independent of our live invocation above.
	const logPath = join(env.userDataPath, 'logs', 'main.log');
	let telemetry: TelemetryEntry[] = [];
	let logRead: string | null = null;
	if (existsSync(logPath)) {
		try {
			const txt = readFileSync(logPath, 'utf8');
			const lines = txt.split(/\r?\n/);
			const re = /lam_feature_support_evaluated.*yukonSilver/;
			const statusRe = /"status"\s*:\s*"([^"]+)"/;
			const codeRe = /"unsupported_code"\s*:\s*("([^"]+)"|null)/;
			const tsRe = /^\[(.*?)\]/;
			telemetry = lines
				.filter((l) => re.test(l))
				.slice(-10)
				.map((raw) => ({
					raw,
					status: raw.match(statusRe)?.[1] ?? null,
					unsupportedCode: raw.match(codeRe)?.[2] ?? null,
					ts: raw.match(tsRe)?.[1] ?? null,
				}));
		} catch (err) {
			logRead = `failed to read ${logPath}: ${(err as Error).message}`;
		}
	} else {
		logRead = `not found: ${logPath}`;
	}

	// ---- 5. Static scan: count callers of the fHA setter --------------
	// Verify the static-analysis claim at runtime by counting how many
	// places in the bundled index.js call the bce setter. The reporter
	// claims setYukonSilverConfig sets fHA; if true, we'd expect >1
	// callsite (one is the function definition stamp itself). Static
	// scan already shows 1 caller (DevMenu) + the definition; we re-
	// verify against the actual file on disk.
	const setterScan = await client.evalInMain<{
		setterName: string | null;
		callerCount: number;
		callerContexts: string[];
		bundlePath: string | null;
	}>(`
		const fs = process.mainModule.require('node:fs');
		const path = process.mainModule.require('node:path');
		const app = process.mainModule.require('electron').app;
		// Find the bundled index.js. resourcesPath/app.asar.unpacked is
		// not where the bundled code lives — that's only for native
		// modules. The bundle is at resourcesPath/app.asar internally,
		// which we can't read raw from fs. But process.mainModule.filename
		// points into the bundle and we can walk up.
		// Easier: read app.asar via the asar archive's transparent fs
		// shim. The bundled main entry is at .vite/build/index.js inside
		// the asar.
		const candidates = [
			path.join(process.resourcesPath, 'app.asar', '.vite', 'build', 'index.js'),
			path.join(process.resourcesPath, 'app', '.vite', 'build', 'index.js'),
		];
		let bundlePath = null;
		let content = null;
		for (const p of candidates) {
			try {
				content = fs.readFileSync(p, 'utf8');
				bundlePath = p;
				break;
			} catch (_) {}
		}
		if (!content) {
			return {
				setterName: null,
				callerCount: 0,
				callerContexts: [],
				bundlePath: null,
			};
		}
		// The kvi() switch is identified by the case strings. The
		// preceding function (in source order) is the bce setter:
		// function NAME(e){VAR=e,OTHER=null}
		// followed by another function NAME2(){switch(VAR){case"none":...
		const switchRe = /function\\s+(\\w+)\\s*\\(\\)\\s*\\{\\s*switch\\s*\\(\\s*(\\w+)\\s*\\)\\s*\\{\\s*case\\s*"none"\\s*:\\s*return\\s+null\\s*;\\s*case\\s*"app_too_old"/;
		const sm = content.match(switchRe);
		if (!sm) {
			return {
				setterName: null,
				callerCount: 0,
				callerContexts: [],
				bundlePath,
			};
		}
		const bceVar = sm[2];
		// Find the setter that writes to bceVar: function NAME(e){bceVar=e
		// (the second assignment is the cache reset; we anchor on the first)
		const setterRe = new RegExp(
			'function\\\\s+(\\\\w+)\\\\s*\\\\(\\\\s*e\\\\s*\\\\)\\\\s*\\\\{\\\\s*\\\\(?\\\\s*' +
			bceVar +
			'\\\\s*=\\\\s*e\\\\s*[,)]',
		);
		const setMatch = content.match(setterRe);
		if (!setMatch) {
			return {
				setterName: null,
				callerCount: 0,
				callerContexts: [],
				bundlePath,
			};
		}
		const setterName = setMatch[1];
		// Find every call site: setterName followed by an open paren,
		// excluding the function definition itself.
		const callRe = new RegExp(
			'(?:^|[^\\\\w$])' + setterName + '\\\\s*\\\\(',
			'g',
		);
		const callerContexts = [];
		let m;
		while ((m = callRe.exec(content)) !== null) {
			const ctxStart = Math.max(0, m.index - 60);
			const ctxEnd = Math.min(content.length, m.index + 80);
			const ctx = content.substring(ctxStart, ctxEnd).replace(/\\s+/g, ' ');
			callerContexts.push(ctx);
			if (callerContexts.length >= 20) break;
		}
		return {
			setterName,
			callerCount: callerContexts.length,
			callerContexts,
			bundlePath,
		};
	`);

	// ---- Summary -----------------------------------------------------
	console.log('=== Environment ===');
	console.log(JSON.stringify(env, null, 2));

	console.log('\n=== webContents ===');
	console.log(JSON.stringify(webContentsList, null, 2));

	console.log('\n=== Live yukonSilver status (AppFeatures.getSupportedFeatures) ===');
	console.log(JSON.stringify(supportSnapshot, null, 2));

	console.log('\n=== Dev menu — emulation / yukonSilver items ===');
	if (menuSnapshot.length === 0) {
		console.log('  (no matching menu items — Developer menu not exposed?)');
	} else {
		console.log(JSON.stringify(menuSnapshot, null, 2));
	}

	console.log('\n=== Main-log telemetry (last 10 lam_feature_support_evaluated/yukonSilver) ===');
	if (logRead) {
		console.log('  ' + logRead);
	} else if (telemetry.length === 0) {
		console.log('  (no yukonSilver telemetry entries in main.log)');
	} else {
		for (const t of telemetry) {
			console.log(`  [${t.ts ?? '?'}] status=${t.status ?? '?'} code=${t.unsupportedCode ?? 'null'}`);
		}
	}

	console.log('\n=== Static scan: bundled fHA setter call sites ===');
	console.log(JSON.stringify(setterScan, null, 2));

	const out = {
		env,
		webContentsList,
		supportSnapshot,
		menuSnapshot,
		telemetry,
		telemetryReadError: logRead,
		setterScan,
	};
	writeFileSync('/tmp/cowork-fha-probe.json', JSON.stringify(out, null, 2));
	console.log('\nFull dump → /tmp/cowork-fha-probe.json');

	// Verdict — three-way classification of what the probe found.
	console.log('\n=== Verdict ===');
	const live = supportSnapshot.yukonSilver;
	const emulationOn = menuSnapshot.find((m) =>
		/yukon|app too old/i.test(m.path) && m.checked === true);
	if (live && live.status === 'supported') {
		console.log('  LIVE: yukonSilver={status:supported}. pHA()/YJA() returned the patched path. Cowork should be available.');
	} else if (live && live.status === 'unavailable' && !live.unsupportedCode) {
		console.log('  LIVE: yukonSilver={status:unavailable}. fHA is set to "app_too_old" (only the kvi() app_too_old branch returns status:unavailable with no unsupportedCode).');
		if (emulationOn) {
			console.log('  CAUSE: Dev menu emulation is on: ' + emulationOn.path);
		} else {
			console.log('  CAUSE: Unknown — no dev menu emulation toggled. Either a code path we missed, or a third party set fHA. Setter scan above should have ≤2 callers (function def + DevMenu).');
		}
	} else if (live && live.status === 'unsupported' && live.unsupportedCode === 'unsupported_platform') {
		console.log('  LIVE: yukonSilver={status:unsupported, unsupportedCode:unsupported_platform}. rLi()/X2i() platform gate fired — cowork.sh Patch 1 did not apply on this build.');
	} else if (live) {
		console.log('  LIVE: yukonSilver=' + JSON.stringify(live) + ' (different gate fired — see unsupportedCode)');
	} else {
		console.log('  LIVE: handler invocation failed: ' + supportSnapshot.error);
	}

	client.close();
	process.exit(0);
}

main().catch((err) => {
	console.error('probe failed:', err);
	process.exit(1);
});
