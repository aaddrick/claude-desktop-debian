# Plugin Install Flow — Learnings

## Why This Exists

The Directory → "Anthropic & Partners" tab has a non-obvious
install flow that caused a structural bug (#396) on older
versions. Key insight: **the renderer that populates
`pluginContext.mode` and `pluginContext.pluginSource` is served
remotely from claude.ai in a BrowserView**, not bundled locally.
Static source inspection only sees the main-process gate; its
inputs originate in server-rendered JS outside the asar.

## Architecture

The main window is `https://claude.ai/task/new` loaded in a
BrowserView. Only ~288 KB of JS lives locally under
`.vite/renderer/main_window/assets/`; neither `installPlugin` nor
`pluginContext` appears there.

When the user clicks install on a plugin:

1. Remote web UI calls `CustomPlugins.installPlugin(pluginId,
   egressAllowedDomains, pluginContext)` via IPC (preload bridge
   → main process).
2. Main-process IPC handler validates `pluginContext` via `Qg()`
   (runtime type check):
   `{ mode: string, workspacePath?, settingsLevel?,
      pluginSource?, marketplaceScope?, telemetryAttempt? }`.
3. Main-process `installPlugin` applies the gate, optionally
   calls the Anthropic API, and falls back to the `claude` CLI if
   the remote path is skipped or fails.

The **values of `mode` and `pluginSource` are decided remotely**
by claude.ai based on which UI surface called install. The
desktop app has no control over them; it only enforces the gate.

## Install Gate (current, 1.3109.0)

Location: `index.js:490853` inside the minified app.asar.

```js
const a = s?.pluginSource === "local";   // user-uploaded .zip
const c = s?.pluginSource === "remote";  // remote marketplace install
if (!a && (c || s?.mode === "cowork") && (await A0())) {
  // remote API: /api/organizations/{orgId}/plugins/...
} else {
  // skip, log reason: "local-sourced" |
  //                   "not-cowork-not-remote" |
  //                   "sparkplug-disabled"
}
// always falls through to CLI install on failure
```

- `A0()` (`index.js:489947`) = GrowthBook flag `"2340532315"` via
  `isFeatureEnabled()`, cached locally. Server-controlled.
- On CLI fallback for a non-local marketplace like
  `knowledge-work-plugins`, install fails with
  `Plugin "X" not found in marketplace "knowledge-work-plugins"`.

## Plugin Listing Filter

Four places in 1.3109.0 gate on `A0()`:

| Line | Function | If flag off |
|---|---|---|
| 490342 | `syncRemotePlugins` | `{newlyInstalled: []}` |
| 490355 | `getDownloadedRemotePlugins` | `[]` |
| 491026 | `listAvailablePlugins` | local plugins only |
| 491060 | `listRemotePluginsPage` | `{plugins: [], hasMore: false}` |

**If `A0()` is false, the Anthropic & Partners tab is empty.**
Users whose account doesn't have the flag enabled server-side
never see these plugins at all.

## Backend Endpoints

All served from `https://claude.ai` (base URL from `Jr()` =
main-window URL). Main-process `net.fetch` adds identity headers
via an `onBeforeSendHeaders` interceptor at `index.js:504876`:

| Header | Value |
|---|---|
| `anthropic-client-platform` | `"desktop_app"` (constant) |
| `anthropic-client-app` | `"com.anthropic.claudefordesktop"` |
| `anthropic-client-version` | `app.getVersion()` |
| `anthropic-client-os-platform` | `process.platform` — `"linux"` / `"darwin"` / `"win32"` |
| `anthropic-client-os-version` | `process.getSystemVersion()` |
| `anthropic-desktop-topbar` | `"1"` |

Key endpoints:

| Purpose | URL | Source line |
|---|---|---|
| GrowthBook flags | `GET /api/desktop/features` | 190336 |
| Default marketplaces (Directory source) | `GET /api/organizations/{orgId}/marketplaces/list-default-marketplaces` | — |
| Account-attached marketplaces (user-added) | `GET /api/organizations/{orgId}/marketplaces/list-account-marketplaces` | — |
| Directory feed | `GET /api/organizations/{orgId}/plugins/list-plugins?installation_preference=...` | 246164 |
| Plugin by-id | `GET /api/organizations/{orgId}/plugins/{id}` | 246212 |
| Plugin by-name | `GET /api/organizations/{orgId}/plugins/by-name/{name}?marketplace_name=...` | 246221 |
| Plugin download | `GET /api/organizations/{orgId}/plugins/{id}/download` | 246229 |

Auth is via the `sessionKey` cookie. `orgId` is read from the
`lastActiveOrg` cookie by `an()` at `index.js:191235`. No orgId →
fetchers return null → install falls back to CLI.

## Issue #396 Post-Mortem

Filed on Claude Desktop 1.1.7714. That version had:

**Install gate** (`index.js:230901` in 1.1.7714):
```js
if (!c && (a?.mode) === "cowork" && (await Tg())) {
  // remote API
}
// reasons: "local-sourced" | "not-cowork" | "sparkplug-disabled"
```

**Listing filter** (`index.js:231032`):
```js
if ((s?.mode) !== "cowork" || !(await Tg())) return o;  // local only
// else merge remote
```

**`listRemotePluginsPage`** (`index.js:231066`):
```js
if (!(await Tg())) return { plugins: [], hasMore: !1 };
// else fetch and return
```

`listRemotePluginsPage` gated only on `Tg()`, not on cowork mode,
so the Directory **showed** remote plugins whenever the sparkplug
flag was on. But the install gate required `mode === "cowork"`
specifically. Users browsing the Directory outside a cowork
session received `pluginContext` without `mode: "cowork"` from
the renderer → install gate failed → `reason=not-cowork` → CLI
fallback → "marketplace not found."

Structural bug: plugins visible but uninstallable unless the user
was actively inside a cowork session.

**Fixed upstream in 1.3109.0** via two coordinated Anthropic-side
changes:

1. Install gate relaxed to accept `pluginSource === "remote"` as
   equivalent to `mode === "cowork"`.
2. claude.ai renderer updated to send `pluginSource: "remote"`
   for installs from the Anthropic & Partners Directory
   regardless of cowork session state.

PR #435 proposed a client-side Linux-specific short-circuit
(`process.platform === "linux" || ...`). Correct strategy for the
bug as it existed; obsolete after upstream fix. Closed as
obsolete.

## Live Investigation Recipe

To debug plugin-flow bugs on a running client:

### 1. Enable main-process DevTools

```bash
echo '{"allowDevTools": true}' > ~/.config/Claude/developer_settings.json
```

Then fully quit and relaunch the app. Open the (now visible)
**Enable Main Process Debugger** menu item (under Help when dev
tools are enabled) — this starts a Node inspector on
`127.0.0.1:9229`. Connect via `chrome://inspect` in any Chromium
browser and click **inspect** on the Node target.

Source refs:
- `allowDevTools` schema: `index.js:299085`
- `developer_settings.json` path: `index.js:299089`
- Debugger menu: `index.js:494282`

### 2. List webContents

```js
require('electron').webContents.getAllWebContents()
  .map(w => ({ id: w.id, type: w.getType(), url: w.getURL() }))
```

Typically three: the find-in-page overlay, the claude.ai
BrowserView (id 2), and the main window shell (id 1). The
claude.ai one is where the plugin directory UI lives; open its
DevTools separately via `webContents.fromId(n).openDevTools()` to
inspect the renderer-side code.

### 3. Check the cached GrowthBook flag state

```js
(async () => {
  const res = await require('electron').net.fetch(
    'https://claude.ai/api/desktop/features');
  const body = await res.json();
  console.log(body.features['2340532315']);
})();
```

Expected for users with the force rule:
`{value: true, source: "force", ruleId: "fr_..."}`. If it's
`{value: false, source: "defaultValue", ruleId: null}`, the user
won't see any remote plugins — `listAvailablePlugins` and
`listRemotePluginsPage` filter them out.

### 4. Header-spoofing harness

Electron only allows one `onBeforeSendHeaders` listener at a
time. Registering a test listener replaces the app's injector
(`index.js:504876`), so the harness re-implements the baseline
injection and adds a per-test override layer:

```js
const { app, session, net } = require('electron');

const APP_HEADERS = {
  'anthropic-client-platform': 'desktop_app',
  'anthropic-client-app': 'com.anthropic.claudefordesktop',
  'anthropic-client-version': app.getVersion(),
  'anthropic-client-os-platform': process.platform,
  'anthropic-client-os-version': process.getSystemVersion(),
  'anthropic-desktop-topbar': '1',
};

globalThis.__testOverrides = {};
globalThis.__testRemove = new Set();

session.defaultSession.webRequest.onBeforeSendHeaders(
  { urls: ['https://claude.ai/*', 'https://claude.com/*'] },
  (d, cb) => {
    const h = { ...d.requestHeaders, ...APP_HEADERS,
                ...globalThis.__testOverrides };
    for (const k of globalThis.__testRemove) delete h[k];
    cb({ requestHeaders: h });
  }
);

async function runTest(label, { set = {}, remove = [] } = {},
                      url = 'https://claude.ai/api/desktop/features') {
  globalThis.__testOverrides = set;
  globalThis.__testRemove = new Set(remove);
  const res = await net.fetch(url);
  const ct = res.headers.get('content-type') || '';
  const body = ct.includes('json') ? await res.json()
                                   : await res.text();
  globalThis.__testOverrides = {};
  globalThis.__testRemove = new Set();
  return { label, status: res.status, body };
}
```

Example: test whether flag depends on OS claim:
```js
(async () => {
  const r = await runTest('darwin', {
    set: { 'anthropic-client-os-platform': 'darwin',
           'anthropic-client-os-version': '15.0' } });
  console.log(r.body.features['2340532315']);
})();
```

If the flag value changes when you spoof OS, the server is
platform-gating; if not, the gate lives at a different layer
(account-scoped rule, tier, cohort, or the remote renderer's
local JS gating).

### 5. Breakpoint on the install gate

In main-process DevTools **Sources**: Ctrl+P → `index.js` →
Ctrl+F → search `installPlugin: attempting remote API install`.
Click the line number to set a breakpoint. Trigger an install in
the app. When it breaks, inspect `s` (the pluginContext) and
evaluate `await A0()` in a watch expression.

The companion breakpoint on `installPlugin: skipping remote API
path` tells you which `reason` the gate chose if it failed.

## Getting the Minified Source for Any Shipped Version

The repo's releases include `reference-source.tar.gz`
(~6.5 MB) — beautified asar contents of the exact Claude Desktop
build that was packaged. Much smaller than the AppImage (~133 MB)
and sufficient for code diffing between versions.

```bash
gh release download "v1.3.23+claude1.1.7714" \
  -R aaddrick/claude-desktop-debian \
  -p 'reference-source.tar.gz' \
  -D /tmp/old-version --clobber
tar -xzf /tmp/old-version/reference-source.tar.gz -C /tmp/old-version
# Compare with current: /tmp/old-version/app-extracted/.vite/build/index.js
```

This is how #396's post-mortem was done — side-by-side comparison
of `installPlugin` (230901 old vs 490853 current) and
`listAvailablePlugins` (231032 old vs 491026 current) revealed
both the structural bug and the upstream fix.

## Key Files

- [`build.sh`](../../build.sh) — `patch_cowork_linux()` applies
  the cowork patches to the asar. Patches 1–10 handle cowork mode
  infrastructure on Linux.
- [`scripts/cowork-vm-service.js`](../../scripts/cowork-vm-service.js)
  — Linux cowork VM daemon (separate subsystem, see
  [`cowork-vm-daemon.md`](cowork-vm-daemon.md)).
- Minified install flow in the running app:
  `app.asar.contents/.vite/build/index.js` around line 490853 on
  1.3109.0 (subject to minifier drift — anchor on the log string
  `[CustomPlugins] installPlugin: attempting remote API install`
  when writing patches).
