// Inject frame fix before main app loads
const Module = require('module');
const path = require('path');
const originalRequire = Module.prototype.require;

console.log('[Frame Fix] Wrapper loaded');

// Fix process.resourcesPath to match the actual location of app.asar.
// In Nix builds, electron is a separate store path so process.resourcesPath
// points to the Electron package's resources dir, not where our tray icons
// and app.asar.unpacked live. Deriving from __dirname (the asar root) gives
// the correct path; for deb/AppImage builds the values already match.
const derivedResourcesPath = path.dirname(__dirname);
if (derivedResourcesPath !== process.resourcesPath) {
  console.log('[Frame Fix] Correcting process.resourcesPath');
  console.log('[Frame Fix]   Was:', process.resourcesPath);
  console.log('[Frame Fix]   Now:', derivedResourcesPath);
  process.resourcesPath = derivedResourcesPath;
}

// Menu bar visibility mode, controlled by CLAUDE_MENU_BAR env var:
//   'auto'    - hidden by default, Alt toggles visibility (current default)
//   'visible' - always visible, Alt does not toggle (stable layout)
//   'hidden'  - always hidden, Alt does not toggle
// Also accepts boolean-style aliases: 1/true/yes/on -> visible, 0/false/no/off -> hidden
const VALID_MENU_BAR_MODES = ['auto', 'visible', 'hidden'];
const MENU_BAR_ALIASES = {
  '1': 'visible', 'true': 'visible', 'yes': 'visible', 'on': 'visible',
  '0': 'hidden', 'false': 'hidden', 'no': 'hidden', 'off': 'hidden',
};
const rawMenuBarMode = (process.env.CLAUDE_MENU_BAR || 'auto').toLowerCase();
const resolvedMode = MENU_BAR_ALIASES[rawMenuBarMode] || rawMenuBarMode;
const MENU_BAR_MODE = VALID_MENU_BAR_MODES.includes(resolvedMode) ? resolvedMode : 'auto';
if (resolvedMode !== rawMenuBarMode) {
  console.log(`[Frame Fix] CLAUDE_MENU_BAR '${process.env.CLAUDE_MENU_BAR}' resolved to '${resolvedMode}'`);
} else if (resolvedMode !== MENU_BAR_MODE) {
  console.warn(`[Frame Fix] Unknown CLAUDE_MENU_BAR value '${process.env.CLAUDE_MENU_BAR}', falling back to 'auto'. Valid: ${VALID_MENU_BAR_MODES.join(', ')}, or 0/1/true/false/yes/no/on/off`);
}
console.log(`[Frame Fix] Menu bar mode: ${MENU_BAR_MODE}`);

// Detect if a window intends to be frameless (popup/Quick Entry/About)
// Quick Entry: titleBarStyle:"", skipTaskbar:true, transparent:true, resizable:false
// About:       titleBarStyle:"", skipTaskbar:true, resizable:false
// Main:        titleBarStyle:"", titleBarOverlay:false(linux), resizable (has minWidth)
// The main window has minWidth set; popups do not.
function isPopupWindow(options) {
  if (!options) return false;
  if (options.frame === false) return true;
  if (options.titleBarStyle === '' && !options.minWidth) return true;
  return false;
}

// CSS injection for Linux scrollbar styling
// Respects both light and dark themes via prefers-color-scheme
const LINUX_CSS = `
  /* Scrollbar styling - thin, unobtrusive, adapts to theme */
  ::-webkit-scrollbar { width: 8px; height: 8px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb {
    background: rgba(128, 128, 128, 0.3);
    border-radius: 4px;
    transition: background 0.15s ease;
  }
  ::-webkit-scrollbar-thumb:hover {
    background: rgba(128, 128, 128, 0.55);
  }
  @media (prefers-color-scheme: dark) {
    ::-webkit-scrollbar-thumb {
      background: rgba(200, 200, 200, 0.2);
    }
    ::-webkit-scrollbar-thumb:hover {
      background: rgba(200, 200, 200, 0.4);
    }
  }
`;

// Build the patched BrowserWindow class and Menu interceptor once,
// on first require('electron'), then reuse via Proxy on every access.
let PatchedBrowserWindow = null;
let patchedSetApplicationMenu = null;
let electronModule = null;

Module.prototype.require = function(id) {
  const result = originalRequire.apply(this, arguments);

  if (id === 'electron') {
    // Build patches once from the real electron module
    if (!PatchedBrowserWindow) {
      electronModule = result;
      const OriginalBrowserWindow = result.BrowserWindow;
      const OriginalMenu = result.Menu;

      PatchedBrowserWindow = class BrowserWindowWithFrame extends OriginalBrowserWindow {
        constructor(options) {
          console.log('[Frame Fix] BrowserWindow constructor called');
          let popup = false;
          if (process.platform === 'linux') {
            options = options || {};
            const originalFrame = options.frame;
            popup = isPopupWindow(options);

            if (popup) {
              // Popup/Quick Entry windows: keep frameless for proper UX
              options.frame = false;
              // Remove macOS-specific titlebar options that don't apply on Linux
              delete options.titleBarStyle;
              delete options.titleBarOverlay;
              console.log('[Frame Fix] Popup detected, keeping frameless');
            } else {
              // Main window: force native frame
              options.frame = true;
              // Menu bar behavior depends on CLAUDE_MENU_BAR mode:
              // 'auto' (default): hidden, Alt toggles
              // 'visible'/'hidden': no Alt toggle
              options.autoHideMenuBar = (MENU_BAR_MODE === 'auto');
              // Remove custom titlebar options
              delete options.titleBarStyle;
              delete options.titleBarOverlay;
              console.log(`[Frame Fix] Modified frame from ${originalFrame} to true`);
            }
          }
          super(options);

          if (process.platform === 'linux') {
            // Hide menu bar after window creation (unless user wants it visible)
            if (MENU_BAR_MODE !== 'visible') {
              this.setMenuBarVisibility(false);
            }

            // Inject CSS for Linux scrollbar styling
            this.webContents.on('did-finish-load', () => {
              this.webContents.insertCSS(LINUX_CSS).catch(() => {});
            });

            // Quit on Ctrl+Q, but only when Claude has keyboard focus.
            // Replaces a prior globalShortcut registration that grabbed
            // the key system-wide and, on non-QWERTY layouts (e.g.
            // AZERTY), swallowed other shortcuts like Ctrl+A because
            // Electron matches globals by physical keycode. Fixes: #399
            this.webContents.on('before-input-event', (event, input) => {
              if (input.type !== 'keyDown') return;
              if (!input.control) return;
              if (input.alt || input.shift || input.meta) return;
              if (input.key !== 'q' && input.key !== 'Q') return;
              event.preventDefault();
              electronModule.app.quit();
            });

            // In 'hidden' mode, suppress Alt toggle by re-hiding
            // on every show event. In 'auto' mode, let
            // autoHideMenuBar handle the toggle natively.
            if (MENU_BAR_MODE === 'hidden') {
              this.on('show', () => {
                this.setMenuBarVisibility(false);
              });
            }

            if (!popup) {
              // Directly set child view bounds to match content size.
              // This bypasses Chromium's stale LayoutManagerBase cache
              // (only invalidated via _NET_WM_STATE atom changes, which
              // KWin corner-snap/quick-tile never sets). Instead of
              // monkey-patching getContentBounds() (which causes drag
              // resize jitter at ~60Hz), we only act on discrete state
              // changes. Fixes: #239
              const fixChildBounds = () => {
                if (this.isDestroyed()) return false;
                const children = this.contentView?.children;
                if (!children?.length) return false;
                const [cw, ch] = this.getContentSize();
                if (cw <= 0 || ch <= 0) return false;
                const cur = children[0].getBounds();
                if (cur.width !== cw || cur.height !== ch) {
                  children[0].setBounds({ x: 0, y: 0, width: cw, height: ch });
                  return true;
                }
                return false;
              };

              // Geometry settles in stages after state changes.
              // Three passes at 0/16/150ms cover immediate, next-frame,
              // and compositor-animation-complete timing.
              const fixAfterStateChange = () => {
                fixChildBounds();
                setTimeout(fixChildBounds, 16);
                setTimeout(fixChildBounds, 150);
              };

              // Suppresses resize/moved→fixAfterStateChange cascade
              // during jiggle. Without this, each setSize triggers the
              // resize handler, creating 6+ unnecessary timer callbacks.
              let jiggling = false;

              // Track interactive (user-drag) resizing. will-resize
              // only fires for user-initiated drags, not programmatic
              // setSize() or WM-initiated resizes. On Wayland compositors
              // where will-resize may not fire, the guard stays false —
              // safe because jiggle only triggers from armed pairs.
              let userResizing = false;
              let userResizeTimer = null;
              this.on('will-resize', () => {
                userResizing = true;
                if (userResizeTimer) clearTimeout(userResizeTimer);
                userResizeTimer = setTimeout(() => { userResizing = false; }, 300);
              });

              // Debounced 1px jiggle for workspace switches where tile
              // size is unchanged (bounds match but compositor cache is
              // stale). Only called from armed-pair handlers, never
              // from resize/maximize. Same pattern as ready-to-show
              // but debounced and guarded.
              // INVARIANT: debounce (100ms) must exceed jiggle duration
              // (50ms) to prevent overlapping jiggles on rapid workspace
              // switching. Do not reduce debounce below jiggle timeout.
              let jiggleTimer = null;
              const jiggleIfStale = () => {
                if (jiggleTimer) clearTimeout(jiggleTimer);
                jiggleTimer = setTimeout(() => {
                  jiggleTimer = null;
                  if (this.isDestroyed() || userResizing) return;
                  if (!fixChildBounds()) {
                    jiggling = true;
                    const [w, h] = this.getSize();
                    this.setSize(w + 1, h);
                    setTimeout(() => {
                      if (!this.isDestroyed()) {
                        this.setSize(w, h);
                        fixChildBounds();
                      }
                      jiggling = false;
                    }, 50);
                  }
                }, 100);
              };

              for (const evt of ['maximize', 'unmaximize',
                'enter-full-screen', 'leave-full-screen']) {
                this.on(evt, fixAfterStateChange);
              }

              // KWin corner-snap/quick-tile emits 'moved' but not
              // 'maximize'/'unmaximize'. Guard with a size-change check
              // so normal window drags (position-only) are ignored.
              let lastSize = [0, 0];
              this.on('moved', () => {
                if (this.isDestroyed() || jiggling) return;
                const [w, h] = this.getSize();
                if (w !== lastSize[0] || h !== lastSize[1]) {
                  lastSize = [w, h];
                  fixAfterStateChange();
                }
              });

              // Tiling WMs (Hyprland, i3, sway) emit 'resize' on
              // workspace switches with stale getContentBounds()
              // cache. The size-change guard in fixChildBounds()
              // prevents unnecessary work during drag resize.
              // Fixes: #323
              this.on('resize', () => {
                if (!jiggling) fixAfterStateChange();
              });

              // ready-to-show fires once per window lifecycle
              this.once('ready-to-show', () => {
                if (MENU_BAR_MODE !== 'visible') {
                  this.setMenuBarVisibility(false);
                }
                // One-time jiggle for initial layout. Fixes: #84
                const [w, h] = this.getSize();
                this.setSize(w + 1, h + 1);
                setTimeout(() => {
                  if (this.isDestroyed()) return;
                  this.setSize(w, h);
                  fixAfterStateChange();
                }, 50);
              });

              // Tiling WMs signal workspace switches via blur/focus
              // (Hyprland) or hide/show pairs. Jiggle only fires
              // when fixChildBounds() finds no mismatch (stale
              // compositor cache on same-size workspace switch).
              // Fixes: #323
              const armPair = (armEvt, fireEvt) => {
                let armed = false;
                this.on(armEvt, () => { armed = true; });
                this.on(fireEvt, () => {
                  if (armed) {
                    armed = false;
                    jiggleIfStale();
                  }
                });
              };

              this.on('focus', () => {
                this.flashFrame(false); // Fixes: #149
              });
              armPair('blur', 'focus');
              armPair('hide', 'show');
            }

            console.log('[Frame Fix] Linux patches applied');
          }
        }
      };

      // Copy static methods and properties from original
      for (const key of Object.getOwnPropertyNames(OriginalBrowserWindow)) {
        if (key !== 'prototype' && key !== 'length' && key !== 'name') {
          try {
            const descriptor = Object.getOwnPropertyDescriptor(OriginalBrowserWindow, key);
            if (descriptor) {
              Object.defineProperty(PatchedBrowserWindow, key, descriptor);
            }
          } catch (e) {
            // Ignore errors for non-configurable properties
          }
        }
      }

      // Intercept Menu.setApplicationMenu to hide menu bar on Linux.
      // In 'hidden' mode, force-hide after every menu update.
      // In 'auto' mode, only hide initially (autoHideMenuBar handles
      // Alt toggle — re-hiding here would break that). Fixes: #321
      const originalSetAppMenu = OriginalMenu.setApplicationMenu.bind(OriginalMenu);
      patchedSetApplicationMenu = function(menu) {
        console.log('[Frame Fix] Intercepting setApplicationMenu');
        originalSetAppMenu(menu);
        if (process.platform === 'linux' && MENU_BAR_MODE === 'hidden') {
          for (const win of PatchedBrowserWindow.getAllWindows()) {
            if (win.isDestroyed()) continue;
            win.setMenuBarVisibility(false);
          }
          console.log('[Frame Fix] Menu bar hidden on all windows');
        }
      };

      console.log('[Frame Fix] Patches built successfully');
    }

    // Return a Proxy that intercepts property access on the electron module.
    // This is needed because electron's exports use non-configurable getters,
    // so we cannot directly reassign module.BrowserWindow.
    return new Proxy(result, {
      get(target, prop, receiver) {
        if (prop === 'BrowserWindow') return PatchedBrowserWindow;
        if (prop === 'Menu') {
          // Return a proxy for Menu that intercepts setApplicationMenu
          const originalMenu = target.Menu;
          return new Proxy(originalMenu, {
            get(menuTarget, menuProp) {
              if (menuProp === 'setApplicationMenu') return patchedSetApplicationMenu;
              return Reflect.get(menuTarget, menuProp);
            }
          });
        }
        return Reflect.get(target, prop, receiver);
      }
    });
  }

  return result;
};
