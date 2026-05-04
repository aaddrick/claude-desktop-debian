// "eipc" channel-registry primitive — runtime discovery of the custom
// `$eipc_message$_<UUID>_$_<scope>_$_<iface>_$_<method>` handlers
// registered on each per-webContents IPC scope.
//
// Why this exists
// ---------------
// Sessions 2-6 of the runner-implementation work treated the eipc
// registry as unreachable from main: the standard Electron
// `ipcMain._invokeHandlers` map only carries 3 chat-tab MCP-bridge
// handlers (`list-mcp-servers`, `connect-to-mcp-server`,
// `request-open-mcp-settings`); the 700+ `claude.web_$_*` /
// `claude.settings_$_*` etc. channels were assumed to be closure-
// local. Session 3's `globalThis` walk came up empty, which kept
// T22/T31/T33/T38 stuck as Tier 1 asar fingerprints rather than
// runtime registry probes.
//
// Session 7 found the missing piece: handlers DO go through
// Electron's stdlib `IpcMainImpl` — just not the GLOBAL `ipcMain`
// instance. Each `webContents` has its own `webContents.ipc` (per-
// `WebContents` IPC scope, introduced in Electron 17+), and that's
// where every `e.ipc.handle("$eipc_message$_..._$_<scope>_$_<iface>_$_<method>", fn)`
// call lands. Verified empirically against a debugger-attached
// running Claude:
//   - find_in_page wc:    78 handlers (settings/find-in-page only)
//   - main_window wc:     79 handlers (settings/title-bar only)
//   - claude.ai wc:      490 handlers (full surface — including
//                                       117 LocalSessions, 16 CustomPlugins)
//   - global ipcMain:      3 handlers (the chat-tab MCP-bridge trio)
//
// All `claude.web_$_*` interfaces (LocalSessions, CustomPlugins,
// CoworkSpaces, CoworkArtifacts, CoworkMemory, ClaudeCode, etc.)
// register on the claude.ai webContents. They're sticky across route
// changes — once registered (during webContents init), they don't
// deregister when the user navigates between /chats and /epitaxy.
// So the wait-for-channel poll just needs claude.ai to be alive +
// finished initial handler registration, NOT a specific route.
//
// What this primitive does NOT do
// -------------------------------
// Read-only enumeration. No invocation. The `_invokeHandlers` map
// holds the handler functions but they expect a synthesized
// `IpcMainInvokeEvent` with a real sender, and most claude.web_$_*
// handlers have side effects (`startSideChat` writes to the user's
// account; `openInEditor` shells out to a real editor). T22/T31/T33/T38
// only need handler PRESENCE — that's strictly stronger than the asar
// fingerprint (a handler registered at runtime is a handler that
// actually wired up, not just a string in the bundle).
//
// Future T35 Phase 2 / T37 Phase 2 may want invocation against
// read-only handlers like `claude.settings/MCP/getMcpServersConfig`
// or `claude.web/CoworkMemory/readGlobalMemory`. When that happens
// the right shape is a separate `invokeEipcChannel(inspector, suffix,
// args)` helper here — keep this file the single home for eipc surface
// abstractions. Don't add it speculatively until a consumer needs it
// (same anti-speculation rule as `lib/electron-mocks.ts` /
// `lib/input.ts` / `lib/input-niri.ts`).
//
// Framing opacity
// ---------------
// The `$eipc_message$_<UUID>_$_<scope>_$_<iface>_$_<method>` framing
// has been UUID-stable across builds (session 2 noted
// `c0eed8c9-c94a-4931-8cc3-3a08694e9863`; session 7 confirmed it's
// still that, single UUID across all 647 per-wc handlers). The
// primitive does not pin the UUID — match by suffix so a future
// build that rotates the UUID doesn't silently break every consuming
// spec. Suffix matching is also what the case-doc anchors use
// (`LocalSessions_$_getPrChecks` etc.), so consumers can pass the
// case-doc string verbatim.

import { retryUntil } from './retry.js';
import type { InspectorClient } from './inspector.js';

// One handler entry on a webContents. `suffix` is the part after the
// UUID — `<scope>_$_<iface>_$_<method>` — useful for dedup / display.
// `fullKey` is the full registry key including the framing prefix and
// UUID, kept for diagnostic attachments where the raw form matters
// (drift detection, regression triage). `webContentsId` lets a caller
// disambiguate when a future scope registers the same suffix on
// multiple webContents (today only `claude.settings/*` does this and
// every wc gets the same set; non-issue for current consumers).
export interface EipcChannel {
	suffix: string;
	fullKey: string;
	webContentsId: number;
	webContentsUrl: string;
}

export interface GetEipcChannelsOptions {
	// Substring match on `webContents.getURL()`. Default: 'claude.ai'.
	// Pass an empty string to enumerate every webContents.
	urlFilter?: string;
	// Optional scope filter — e.g. 'claude.web' to drop settings-
	// scope handlers. Matched against the segment immediately after
	// the UUID. Empty / undefined returns all scopes.
	scope?: string;
	// Optional interface filter — e.g. 'LocalSessions'. Matched
	// against the segment after the scope. Empty / undefined returns
	// all interfaces.
	iface?: string;
}

// Internal: shape returned by the inspector eval below. Kept private
// so the `EipcChannel` interface above is the public type contract.
interface RawEntry {
	wcId: number;
	wcUrl: string;
	fullKey: string;
}

// Enumerate every eipc-framed handler key registered on every matching
// webContents. The UUID is opaque to the caller — only the suffix
// (`<scope>_$_<iface>_$_<method>`) is exposed via the EipcChannel
// type. Filtering by `scope` / `iface` happens after the inspector
// eval (the eval keeps its filter set minimal so a single eval call
// covers every consumer's needs).
//
// Returns an empty array when no matching webContents exists (e.g.
// the spec called this before claude.ai loaded). Callers that need
// a "wait until present" semantic should use `waitForEipcChannel`
// instead.
export async function getEipcChannels(
	inspector: InspectorClient,
	opts: GetEipcChannelsOptions = {},
): Promise<EipcChannel[]> {
	const urlFilter = opts.urlFilter ?? 'claude.ai';
	const raw = await inspector.evalInMain<RawEntry[]>(`
		const { webContents } = process.mainModule.require('electron');
		const urlFilter = ${JSON.stringify(urlFilter)};
		const out = [];
		for (const wc of webContents.getAllWebContents()) {
			const url = wc.getURL();
			if (urlFilter && !url.includes(urlFilter)) continue;
			const ipc = wc.ipc;
			const map = ipc && ipc._invokeHandlers;
			if (!map) continue;
			const keys = (typeof map.keys === 'function')
				? Array.from(map.keys())
				: Object.keys(map);
			for (const k of keys) {
				out.push({ wcId: wc.id, wcUrl: url, fullKey: k });
			}
		}
		return out;
	`);

	// Match the framing prefix and capture the suffix. Anything that
	// doesn't match (e.g. a non-eipc handler that snuck onto a wc
	// scope) gets filtered out — only eipc-framed entries are part of
	// this primitive's contract.
	const re = /^\$eipc_message\$_[0-9a-f-]+_\$_(.+)$/;
	const out: EipcChannel[] = [];
	for (const entry of raw) {
		const m = re.exec(entry.fullKey);
		if (!m) continue;
		const suffix = m[1]!;
		if (opts.scope) {
			// Suffix shape: `<scope>_$_<iface>_$_<method>`. Anchor at
			// the start so 'claude.web' matches but 'web' doesn't
			// match `claude.settings` etc.
			if (!suffix.startsWith(`${opts.scope}_$_`)) continue;
		}
		if (opts.iface) {
			// Interface segment is after the scope — search for
			// `_$_<iface>_$_` in the suffix. Anchored separators
			// avoid accidentally matching a method name that happens
			// to contain the iface string.
			if (!suffix.includes(`_$_${opts.iface}_$_`)) continue;
		}
		out.push({
			suffix,
			fullKey: entry.fullKey,
			webContentsId: entry.wcId,
			webContentsUrl: entry.wcUrl,
		});
	}
	return out;
}

export interface FindEipcChannelOptions {
	// Substring match on `webContents.getURL()`. Default: 'claude.ai'.
	urlFilter?: string;
}

// Locate the first registered handler whose suffix ends with
// `caseDocSuffix`. Designed so callers can pass the case-doc-anchored
// string verbatim — e.g. `LocalSessions_$_getPrChecks`. Returns null
// when no match exists (caller decides whether to fail, skip, or
// retry).
//
// This is a synchronous one-shot; for the populate-on-init wait, use
// `waitForEipcChannel` — it wraps this in a retryUntil.
export async function findEipcChannel(
	inspector: InspectorClient,
	caseDocSuffix: string,
	opts: FindEipcChannelOptions = {},
): Promise<EipcChannel | null> {
	const channels = await getEipcChannels(inspector, {
		urlFilter: opts.urlFilter,
	});
	for (const ch of channels) {
		if (ch.suffix.endsWith(caseDocSuffix)) return ch;
	}
	return null;
}

export interface WaitForEipcChannelOptions {
	urlFilter?: string;
	// Total budget for the poll. Default 15s — the claude.ai
	// webContents' initial handler registration completes within a
	// second of `userLoaded` on the dev box, so 15s leaves wide
	// margin for slow-cache cases.
	timeoutMs?: number;
	intervalMs?: number;
}

// Poll until the named channel is registered, or the budget runs out.
// Use this when the spec just reached `waitForReady('userLoaded')` —
// the claude.ai webContents may exist but its handlers might not have
// finished registering yet. The poll is cheap (one inspector eval per
// tick + a string scan) so the default interval can be aggressive.
//
// Returns the EipcChannel on success, null on timeout. Callers that
// want a hard fail on timeout should `expect(channel, '...').not.toBeNull()`
// — the primitive doesn't throw because some specs want to surface
// missing-handler as a clean fail with diagnostics rather than an
// uncaught timeout.
export async function waitForEipcChannel(
	inspector: InspectorClient,
	caseDocSuffix: string,
	opts: WaitForEipcChannelOptions = {},
): Promise<EipcChannel | null> {
	return retryUntil(
		() => findEipcChannel(inspector, caseDocSuffix, opts),
		{
			timeout: opts.timeoutMs ?? 15_000,
			interval: opts.intervalMs ?? 250,
		},
	);
}

// Convenience: resolve a list of case-doc suffixes in one round-trip.
// Returns a Map keyed by the input suffix so callers can iterate the
// expected list and report per-suffix presence. Missing suffixes have
// `null` values.
//
// Single inspector call by design — the `getEipcChannels` cost is
// dominated by the eval round-trip, not the in-process filtering, so
// batching is strictly cheaper than N calls to `findEipcChannel`.
export async function findEipcChannels(
	inspector: InspectorClient,
	caseDocSuffixes: readonly string[],
	opts: FindEipcChannelOptions = {},
): Promise<Map<string, EipcChannel | null>> {
	const channels = await getEipcChannels(inspector, {
		urlFilter: opts.urlFilter,
	});
	const out = new Map<string, EipcChannel | null>();
	for (const suffix of caseDocSuffixes) {
		const hit = channels.find((c) => c.suffix.endsWith(suffix));
		out.set(suffix, hit ?? null);
	}
	return out;
}

// Wait until ALL of the listed suffixes are registered, or the budget
// runs out. Useful for trios like T31's side-chat (start/send/stop) —
// the trio is load-bearing as a unit; partial registration is a fail.
//
// Returns the resolved Map on full success. On timeout, returns the
// last-observed Map (some entries may be null) so callers can surface
// the partial state in their diagnostic attachment before failing.
export async function waitForEipcChannels(
	inspector: InspectorClient,
	caseDocSuffixes: readonly string[],
	opts: WaitForEipcChannelOptions = {},
): Promise<Map<string, EipcChannel | null>> {
	let lastSnapshot = new Map<string, EipcChannel | null>();
	const result = await retryUntil(
		async () => {
			const snap = await findEipcChannels(
				inspector,
				caseDocSuffixes,
				opts,
			);
			lastSnapshot = snap;
			for (const v of snap.values()) if (v === null) return null;
			return snap;
		},
		{
			timeout: opts.timeoutMs ?? 15_000,
			interval: opts.intervalMs ?? 250,
		},
	);
	return result ?? lastSnapshot;
}
