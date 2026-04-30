# Linux desktop topbar — design and history

How claude.ai's in-app topbar (hamburger / sidebar / search / nav /
Cowork ghost) is wired up on Linux, why the upstream frameless-WCO
config doesn't work on X11, and how the **hybrid mode** (system
frame + in-app topbar shim) lands functional buttons at the cost
of a stacked-bar layout.

## Status

**Resolved 2026-04-29 via hybrid mode.** Default
`CLAUDE_TITLEBAR_STYLE` is `hybrid`: native OS frame plus the
wco-shim that convinces claude.ai's bundle to render its in-app
topbar. Topbar buttons are clickable. The trade-off vs Windows is
a stacked layout (DE-drawn titlebar on top, in-app topbar below)
instead of Windows's combined single bar.

![Hybrid mode on KDE Plasma — DE-drawn "Claude" titlebar on top, claude.ai's in-app topbar (hamburger / search / back-forward) directly below it](images/linux-topbar-hybrid.png)

Modes:

| mode | frame | shim | layout | notes |
|---|---|---|---|---|
| `hybrid` (default) | system | active | stacked: OS bar + in-app bar | clickable ✓ |
| `native` | system | inactive | OS bar only | no in-app topbar |
| `hidden` | frameless | active | Windows-style single bar | **clicks broken on X11** — kept for Wayland / future investigation |

## How the topbar gets to render

The topbar is **not bundled in `app.asar`**. claude.ai's web app
inside the BrowserView renders it. Rendering is gated by an
independent stack — each gate must pass.

### Gate 1: server-delivered markup

Every request to claude.ai/claude.com from the desktop shell
carries unconditional headers set in `index.js:504876-504907`:

- `anthropic-desktop-topbar: 1`
- `anthropic-client-platform: desktop_app`
- `anthropic-client-os-platform: <process.platform>` (literal `linux`)

The topbar markup *is* delivered to Linux clients — this gate
isn't load-bearing for our scenario.

### Gate 2: Electron-shell boot features

`index.js` builds a feature-flag object via `J0()` (line 301965)
and passes it to the BrowserView via
`webPreferences.additionalArguments=['--desktop-features=<JSON>']`.
`mainView.js` parses the arg and exposes the parsed object via
`contextBridge` as `window.desktopBootFeatures`. The relevant key
`desktopTopBar.status` is `"supported"` on Linux, so this gate
also isn't load-bearing.

### Gate 3: the `isWindows()` user-agent check

**Load-bearing.** The React bundle
(`https://assets-proxy.anthropic.com/.../index-*.js`) contains:

```js
const HV = /(win32|win64|windows|wince)/i;
function WV() {
  if (typeof window === "undefined") return false;
  // ... HV.test(window.navigator.userAgent)
}
```

This function and a sibling gate the topbar JSX. Linux's UA
contains `X11; Linux x86_64`, fails the regex, and React skips
rendering the entire `<div class="draggable absolute top-0 ...">`
topbar tree (note the `topbar-windows-menu` test ID — upstream
treats this as Windows-specific).

The shim's `navigator.userAgent` override appends `" Windows"`
page-side so the regex passes. HTTP request UA is unchanged so
analytics, anti-bot fingerprints, and the
`anthropic-client-os-platform` header stay honest.

### Gate 4: `-webkit-app-region: drag` on the topbar parent

On Linux X11 with frameless windows, this is what kills clicks in
hidden mode. The topbar's `<div class="draggable absolute top-0
inset-x-0">` would normally trigger the CSS rule
`.draggable { -webkit-app-region: drag }`. On Windows, Chromium
hit-tests per pixel and child `app-region: no-drag` regions are
clickable; on Linux X11, Chromium pushes a drag-region map to the
WM as a region for `_NET_WM_MOVERESIZE` and the WM intercepts
mouse events before the page sees them. Critically: that map is
**sticky** — not refreshable from CSS, DOM mutations, setSize
jiggles, or hide/show cycles after first paint.

In hybrid mode (frame:true) this isn't an issue. The OS handles
window dragging via the native titlebar; Chromium doesn't push a
drag-region map for framed windows. The shim's className intercept
strips `'draggable'` from any DOM class assignment as
belt-and-suspenders against the `.draggable` rule producing
surprise click-eaten regions inside the page.

## The shim: what each part does

Inlined into mainView.js by `patch_wco_shim`. Skipped in `native`
mode; active in `hybrid` (default) and `hidden`.

| component | role | load-bearing? |
|---|---|---|
| Native-state probes | Capture Chromium's WCO state for launcher.log diagnostics. Phase 1 syncs non-DOM values; Phase 2 reads `env(titlebar-area-*)` via custom-property indirection on DOMContentLoaded. Bypassed by `CLAUDE_WCO_NATIVE=1`. | No (diagnostic) |
| `navigator.windowControlsOverlay` shim | Returns `visible: true` and synthesized rect. | No (defensive — bundle grep shows no current use) |
| `matchMedia` shim | Returns `matches: true` for `(display-mode: window-controls-overlay)` queries. | No (defensive — same) |
| **`navigator.userAgent` shim** | Appends `" Windows"` so Gate 3 passes. | **Yes** |
| className intercept | Strips `'draggable'` from any class assignment via `Element.prototype.className`, `setAttribute`, `DOMTokenList.prototype.add` overrides. Three vectors covered. | Defensive (belt-and-suspenders) |
| Event nudge | Dispatches `geometrychange` + `resize` to wake any framework that rendered before the shim arrived. | No (defensive) |

## Investigation chain — why hybrid

Two phases. Phase 1: render the topbar at all. Phase 2: figure
out why the buttons don't fire mouse events. Phase 2 went through
several false hypotheses before landing on hybrid.

### Phase 1: render-the-topbar

Original assumption was WCO `@media` gating. Several wasted
attempts at activating WCO at the page level
(`titleBarStyle:hidden` + `titleBarOverlay`; explicit object form;
`--enable-features=WindowControlsOverlay`; native Wayland) all
failed at the time, leading to the empirical conclusion that
"Linux Electron doesn't activate WCO." Bundle probing eventually
surfaced **Gate 3** (the UA regex). UA spoof made the topbar
render. The other shims stayed in as defensive forward-compat.

### Phase 2: clicks-don't-fire

Six escape attempts at defeating the X11 drag-region map all
failed:

1. CSS override of `.draggable` to `no-drag !important` — computed
   style flipped, clicks still broken
2. `MutationObserver` stripping the class on attach — DOM correct,
   clicks broken
3. IPC-triggered `setSize` jiggle — no effect
4. `setSize` + hide/show cycle — no effect
5. JS-side `programmaticClickFired: true` confirmed — handlers
   wire correctly, problem is purely OS/WM-level
6. Preemptive global `.draggable { no-drag !important }` from
   preload — no effect

All six targeted the `.draggable` class as the source. The 7th
attempt — a JS-DOM API intercept stripping `'draggable'` from any
class assignment via `Element.prototype` overrides — also failed,
even though probes confirmed *zero* elements ended up with the
class. The drag region wasn't coming from `.draggable` at all.

### Narrowing the source

With no element having computed `app-region: drag` yet clicks
still broken, the source had to be at the Electron/Chromium
config layer. Three diagnostic experiments narrowed it:

| experiment | result |
|---|---|
| `CLAUDE_TBO_HEIGHT=off` (omit `titleBarOverlay`) | clicks still broken |
| `CLAUDE_TBS_DISABLE=1` (also omit `titleBarStyle:'hidden'`) | clicks still broken |
| `frame: true` (hybrid mode) | **clicks work** |

So the source is **`frame: false` itself**, not anything we can
configure at the Electron API level. Chromium-Linux-X11 has a
hardcoded behavior that creates an implicit drag region for the
top of `frame: false` windows. The fix is to not be frameless.
Hybrid trades a stacked layout for clickability.

## Outstanding upstream bugs

Two unrelated Linux-X11 / Electron 41 / Chromium 146 issues
surfaced during the investigation. Worth filing if someone has
time. Bug A is the most actionable.

### Bug A: WCO `@media` query doesn't match where WCO is otherwise active

In the **main window** webContents of a `frame:false +
titleBarStyle:'hidden' + titleBarOverlay:{...}` BrowserWindow,
runtime probe 2026-04-29:

| signal | value |
|---|---|
| `navigator.windowControlsOverlay.visible` | true |
| `windowControlsOverlay.getTitlebarAreaRect()` | 1131×40 (matches config) |
| `env(titlebar-area-width)` (via custom-property indirection) | 1131px (matches) |
| `matchMedia('(display-mode: window-controls-overlay)').matches` | **false** ✗ |

Three of four WCO entry points agree; only the documented `@media`
detection point is broken.

Minimal repro after `did-finish-load`:

```js
const wco = navigator.windowControlsOverlay;
const r = wco.getTitlebarAreaRect();
const s = document.createElement('style');
s.textContent = ':root { --w: env(titlebar-area-width) }';
document.head.appendChild(s);
({
  visible: wco.visible,                                              // true
  rect: { width: r.width, height: r.height },                        // populated
  cssEnvWidth: getComputedStyle(document.documentElement)
    .getPropertyValue('--w'),                                        // populated
  mediaQueryMatches:
    matchMedia('(display-mode: window-controls-overlay)').matches,   // false
});
```

### Bug B: WCO state doesn't propagate to BrowserView webContents

Same parent BrowserWindow, probing the BrowserView instead:

| signal | value |
|---|---|
| `navigator.windowControlsOverlay.visible` | false |
| `getTitlebarAreaRect()` | 0×0 |
| `env(titlebar-area-width)` | empty |
| `matchMedia('(display-mode: window-controls-overlay)').matches` | false |

The BrowserView sees nothing. May be intentional isolation (each
webContents independent) — could be working-as-designed and not
worth filing. Means any WCO-aware page hosted in a BrowserView
never sees WCO regardless of parent config.

### Bug C: implicit drag region for `frame:false` Linux windows

The root cause of the hidden-mode click problem. Investigation
ruled out `.draggable`, `titleBarOverlay`, and `titleBarStyle` as
the source — what remains is some hardcoded behavior in
Chromium's ozone backend that creates a non-overridable drag
region for the top of frameless windows. **Confirmed present on
both X11 and Wayland (2026-04-29):** running
`CLAUDE_USE_WAYLAND=1 CLAUDE_TITLEBAR_STYLE=hidden` produces the
same unclickable topbar as X11, ruling out a Wayland-only
shipping path. Characterizing this as a filable bug would
require source-level inspection of `ui/ozone/platform/{x11,wayland}/`.
The combined impact of A + B + C is that WCO is effectively
unusable on Linux today.

## Future directions

- **Wayland-only shipping (ruled out 2026-04-29).** Wayland WCO
  landed in Electron 38.2 / 41 with apparently fuller support
  ([Electron Wayland tech talk](https://www.electronjs.org/blog/tech-talk-wayland)),
  raising the possibility that hidden mode might work on native
  Wayland even though X11 is broken. Tested with
  `CLAUDE_USE_WAYLAND=1 CLAUDE_TITLEBAR_STYLE=hidden`: topbar
  clicks are still unresponsive. The implicit drag region (Bug C)
  exists on both backends. Hybrid is the answer everywhere.
- **Bundle rewriting via `session.protocol.handle()`** — was the
  proposed last-resort path before hybrid worked. Would intercept
  claude.ai's React bundle and regex-replace `class="draggable
  absolute top-0` to remove the `draggable` token before Chromium
  parses it. Now obsolete given hybrid; documented for posterity.

## Files

- `scripts/wco-shim.js` — shim source
- `scripts/patches/wco-shim.sh` — inlines shim into mainView.js
- `scripts/frame-fix-wrapper.js` — main-process BrowserWindow
  patching, mode resolution, diagnostic probes
- `scripts/launcher-common.sh` — Chromium feature flags per mode
- `scripts/doctor.sh` — `--doctor` reports the resolved titlebar
  style (`PASS` for `hybrid`/`native`, `WARN` for `hidden` with a
  pointer to the working modes, `WARN` + valid-value hint for
  unrecognized values)
- `tests/launcher-common.bats` — covers `_resolve_titlebar_style`
  (default + each mode + case-insensitivity + invalid fallback),
  `build_electron_args` flag selection per mode, and
  `setup_electron_env` `ELECTRON_USE_SYSTEM_TITLE_BAR` wiring per
  mode. Shim runtime behavior (className intercept, UA spoof) is
  not unit-tested — verified empirically via the click test in
  this doc
- `docs/CONFIGURATION.md` — user-facing env-var docs

## Diagnostic recipes

### Bundle probe — re-discover gates if claude.ai changes the bundle

```js
(async () => {
  const reactBundle = [...document.scripts]
    .map(s => s.src).filter(Boolean)
    .find(s => /index-[A-Za-z0-9]+\.js/.test(s));
  const text = await (await fetch(reactBundle)).text();
  const ctx = (term, len = 200) => {
    const i = text.indexOf(term);
    return i < 0 ? null : text.slice(Math.max(0, i - len), i + term.length + len);
  };
  return {
    bundleSize: text.length,
    ctx_topbar_windows: ctx('topbar-windows'),
    ctx_isWindows_regex: ctx('win32|win64'),
    ctx_desktopTopBar: ctx('desktopTopBar'),
    ctx_windowControlsOverlay: ctx('windowControlsOverlay'),
  };
})();
```

Inspect the regex pattern, gate variable names, and any new
condition strings. The shim probably needs an update if any of
those move.

### Drag-region search

Should return `[]` in hybrid mode (className intercept strips the
class). If it returns elements, the intercept missed a vector
(e.g. `dangerouslySetInnerHTML`, parser-set classes) — investigate
where the class came from.

```js
[...document.querySelectorAll('*')].filter(el =>
  getComputedStyle(el).webkitAppRegion === 'drag'
).map(el => ({
  tag: el.tagName,
  cls: (el.className || '').toString().slice(0, 100),
  rect: el.getBoundingClientRect().toJSON(),
}));
```

### Click-state diagnostic

Confirms a click problem is OS-level rather than CSS or JS:

```js
const hamburger = document.querySelector('[data-testid="topbar-windows-menu"]');
const topbar = document.querySelector('div.absolute.top-0.inset-x-0');
const ts = getComputedStyle(topbar);
const hs = getComputedStyle(hamburger);
let clickFired = false;
hamburger.addEventListener('click', () => { clickFired = true; }, { once: true });
hamburger.click();
const r = hamburger.getBoundingClientRect();
const elemAtCenter = document.elementFromPoint(r.x + r.width/2, r.y + r.height/2);
({
  topbarAppRegion: ts.webkitAppRegion,
  hamburgerAppRegion: hs.webkitAppRegion,
  topbarPointerEvents: ts.pointerEvents,
  hamburgerPointerEvents: hs.pointerEvents,
  programmaticClickFired: clickFired,
  hitIsHamburgerOrDescendant: hamburger.contains(elemAtCenter),
});
```

When this looks correct (`no-drag`, `auto`, `true`, `true`) but
real mouse clicks don't fire, the click is being intercepted at
the WM level — same failure mode as the hidden-mode investigation.

### Pitfalls (don't repeat)

- DOM probes that search `[class*="topbar" i]` or
  `header[role="banner"]` won't find the topbar. It identifies
  via `data-testid="topbar-windows-menu"` and uses
  `class="draggable absolute top-0 ..."`. Search by
  `data-testid` first.
- A relative `require('./wco-shim.js')` from the sandboxed
  preload **aborts the entire preload** because sandboxed
  preloads can only require an allowlist (`electron`,
  `ipcRenderer`, `contextBridge`, `webFrame`, ...). The shim
  must be inlined into mainView.js, not pulled in via require.
- `webFrame.executeJavaScript` may fire before
  `document.documentElement` exists. Probe code that calls
  `getComputedStyle(document.documentElement)` immediately
  throws "parameter 1 is not of type 'Element'". Defer to
  `DOMContentLoaded` if needed.
