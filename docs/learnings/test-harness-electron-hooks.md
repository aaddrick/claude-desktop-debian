# Hooking Electron from the test harness

Why constructor-level `BrowserWindow` wraps don't work in this
codebase, and the prototype-method hook that does.

## TL;DR

The test harness attaches a Node inspector at runtime (see
[`docs/testing/automation.md`](../testing/automation.md#the-cdp-auth-gate-and-the-runtime-attach-workaround-that-beats-it))
and from there can evaluate arbitrary JS in the main process. To
observe BrowserWindow construction (e.g. find the Quick Entry popup
ref, capture construction-time options), the natural-feeling
approach is to wrap `electron.BrowserWindow`:

```js
const electron = process.mainModule.require('electron');
const Orig = electron.BrowserWindow;
electron.BrowserWindow = function(opts) {
  // record opts...
  return new Orig(opts);
};
```

**This is silently bypassed.** `scripts/frame-fix-wrapper.js`
returns the electron module wrapped in a `Proxy`; the Proxy's
`get` trap returns a closure-captured `PatchedBrowserWindow`
class. Reads of `electron.BrowserWindow` go through the trap and
always return `PatchedBrowserWindow`, regardless of what was
written to the underlying module. Writes succeed (Reflect.set on
the target) but reads ignore them. Upstream code calling
`new hA.BrowserWindow(opts)` constructs from `PatchedBrowserWindow`,
your wrap is never invoked, your registry stays empty.

The reliable hook is at the **prototype-method level**:

```js
const proto = electron.BrowserWindow.prototype;
const origLoadFile = proto.loadFile;
proto.loadFile = function(filePath, ...rest) {
  // every BrowserWindow instance reaches this, regardless of
  // which subclass constructed it
  return origLoadFile.call(this, filePath, ...rest);
};
```

This is what `tools/test-harness/src/lib/quickentry.ts:installInterceptor`
does.

## Why prototype-level works through the Proxy

`electron.BrowserWindow` returns `PatchedBrowserWindow`, which
`extends` the original `BrowserWindow` class. Both share the
underlying Electron-native prototype chain via `extends`. Setting
`PatchedBrowserWindow.prototype.loadFile = wrappedFn` shadows the
inherited method on every instance — `Patched`-constructed,
frame-fix-constructed, plain. There's no Proxy in front of
`PatchedBrowserWindow.prototype`, so the assignment sticks and is
visible to all subsequent `instance.loadFile(...)` calls.

`loadFile` and `loadURL` are reasonable identification points
because every BrowserWindow that displays content calls one of
them shortly after construction. The file path / URL is a stable
upstream-controlled string (no minification — these are file paths
to bundle assets), making it a durable identifier across releases.

## Why constructor-level *can* work elsewhere

If frame-fix-wrapper is removed (or stops returning a Proxy), the
naïve constructor wrap would work. Watch for this: an upstream
fork that adopts `BaseWindow` over `BrowserWindow`, or a
build-time replacement of frame-fix-wrapper, would change the
hook surface. The prototype-method approach survives both.

## What can't be observed at the prototype level

Construction-time options (`transparent: true`, `frame: false`,
`skipTaskbar: true`, etc.) are consumed by the native side
during `super(options)` and not stored on the instance in a
reflective form. The harness reads runtime equivalents instead:

- `transparent` → `getBackgroundColor() === '#00000000'`
- `frame: false` → `getBounds().width === getContentBounds().width`
  (frameless windows have equal frame and content bounds)
- `alwaysOnTop` → `isAlwaysOnTop()` (note: the popup sets this
  via `setAlwaysOnTop()` *after* construction at
  `index.js:515399`, so this is the only viable read regardless of
  hook approach)

`skipTaskbar` has no public getter; if a test needs it, capture
it at the prototype level by hooking a method that takes the same
options shape, or accept that this signal is unobservable
post-construction.

## See also

- [`tools/test-harness/src/lib/quickentry.ts`](../../tools/test-harness/src/lib/quickentry.ts) — `installInterceptor()` worked example
- [`scripts/frame-fix-wrapper.js`](../../scripts/frame-fix-wrapper.js) — the Proxy + closure
- [`tools/test-harness/src/lib/inspector.ts`](../../tools/test-harness/src/lib/inspector.ts) — how the harness gets main-process JS access in the first place
- [`docs/testing/automation.md`](../testing/automation.md) — overall harness architecture
