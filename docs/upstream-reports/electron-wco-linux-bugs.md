# Upstream report draft: three WCO-on-Linux Electron bugs (Bugs A/B/C)

Technical extraction of the three Linux WCO bugs surfaced by the 2026-04
topbar investigation, preserved here because the diagnosing doc
([`linux-topbar-shim.md`](../archive/linux-topbar-shim.md)) was archived
when the v3.0.0 rebase deleted the wco-shim. Filing target is
`electron/electron` GitHub Issues.

**Before filing:** the probes below were captured 2026-04-29 on
Electron 41 / Chromium 146 via our then-shipped frameless builds. The
official Linux build runs Electron 42.5.1 and ships `frame:true`-style
windows, so each bug needs re-verification on a current Electron
Fiddle (not a Claude build) before it goes upstream. Run the drafts
through the voice workflow at filing time.

## Bug A — WCO `@media` query doesn't match where WCO is otherwise active

In the main-window webContents of a `frame:false` +
`titleBarStyle:'hidden'` + `titleBarOverlay:{...}` BrowserWindow on
Linux X11, three of the four documented WCO detection points agree and
the fourth is broken:

| signal | value (2026-04-29) |
|---|---|
| `navigator.windowControlsOverlay.visible` | true |
| `windowControlsOverlay.getTitlebarAreaRect()` | 1131×40 (matches config) |
| `env(titlebar-area-width)` via custom-property indirection | 1131px |
| `matchMedia('(display-mode: window-controls-overlay)').matches` | **false** |

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

Impact: any page that follows the documented `@media` detection
pattern concludes WCO is inactive on Linux even when it is active.
This is the most actionable of the three.

## Bug B — WCO state doesn't propagate to BrowserView webContents

Same parent BrowserWindow, probing the attached BrowserView instead of
the main webContents: `visible` is false, the rect is 0×0,
`env(titlebar-area-width)` is empty, and the media query is false. A
WCO-aware page hosted in a BrowserView never sees WCO regardless of
parent configuration.

Caveat for the filing text: this may be working-as-designed webContents
isolation (each webContents independent). Frame it as a question, not
a defect claim, and note BrowserView's deprecation in favor of
WebContentsView — re-verify against WebContentsView first; if it
reproduces there, that is the version worth filing.

## Bug C — implicit, non-overridable drag region on `frame:false` Linux windows

The top strip of a frameless window eats mouse events at the WM level
on Linux, and no page- or app-level configuration can reclaim it. The
2026-04 investigation ruled out every configurable source:

- CSS `-webkit-app-region: no-drag !important` on the affected
  elements — computed style flips, clicks still dead
- MutationObserver stripping the `draggable` class — DOM clean, clicks
  dead
- `setSize` jiggle and hide/show cycles — no effect
- Omitting `titleBarOverlay` entirely — no effect
- Omitting `titleBarStyle:'hidden'` too — no effect
- `frame: true` — **clicks work**

So the trigger is `frame:false` itself: Chromium's ozone backend
appears to install an implicit drag region for the top of frameless
windows, and the region map is sticky — pushed to the WM at first
paint and not refreshable from CSS or DOM mutations afterwards.
Confirmed on **both** X11 and native Wayland (`--ozone-platform=wayland`)
on 2026-04-29, so it is not an X11-only quirk. Characterizing the
exact source needs `ui/ozone/platform/{x11,wayland}/` inspection;
programmatic `.click()` fires while real mouse clicks die, which is
the diagnostic separating this from CSS/JS causes (recipe in the
archived doc).

Combined impact of A + B + C: WCO is effectively unusable on Linux —
detection is broken for media-query consumers, embedded views never
see it, and the frameless mode it requires makes the top of the page
unclickable.

## Filing checklist

1. Re-verify each bug on current Electron via Fiddle (A and C are
   quick; B needs a WebContentsView variant).
2. Draft the issue text through the aaddrick-voice workflow, one issue
   per bug (A and C stand alone; B may fold into A's issue as a
   related observation if it turns out to be by-design).
3. File at https://github.com/electron/electron/issues, link back to
   the archived investigation doc for provenance.

---
Written by Claude Fable 5 via [Claude Code](https://claude.ai/code)
