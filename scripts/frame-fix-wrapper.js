// Inject frame fix before main app loads
const Module = require('module');
const originalRequire = Module.prototype.require;

console.log('[Frame Fix] Wrapper loaded');

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
              // Hide the menu bar by default (Alt key will toggle it)
              options.autoHideMenuBar = true;
              // Remove custom titlebar options
              delete options.titleBarStyle;
              delete options.titleBarOverlay;
              console.log(`[Frame Fix] Modified frame from ${originalFrame} to true`);
            }
          }
          super(options);

          if (process.platform === 'linux') {
            // Hide menu bar after window creation
            this.setMenuBarVisibility(false);

            // Inject CSS for Linux scrollbar styling
            this.webContents.on('did-finish-load', () => {
              this.webContents.insertCSS(LINUX_CSS).catch(() => {});
            });

            // Ensure menu bar stays hidden on show events
            this.on('show', () => {
              this.setMenuBarVisibility(false);
            });

            if (!popup) {
              // Directly set child view bounds to match content size.
              // This bypasses Chromium's stale LayoutManagerBase cache
              // (only invalidated via _NET_WM_STATE atom changes, which
              // KWin corner-snap/quick-tile never sets). Instead of
              // monkey-patching getContentBounds() (which causes drag
              // resize jitter at ~60Hz), we only act on discrete state
              // changes. Fixes: #239
              const fixChildBounds = () => {
                if (this.isDestroyed()) return;
                const children = this.contentView?.children;
                if (!children?.length) return;
                const [cw, ch] = this.getContentSize();
                if (cw <= 0 || ch <= 0) return;
                const cur = children[0].getBounds();
                if (cur.width !== cw || cur.height !== ch) {
                  children[0].setBounds({ x: 0, y: 0, width: cw, height: ch });
                }
              };

              // Geometry settles in stages after state changes.
              // Three passes at 0/16/150ms cover immediate, next-frame,
              // and compositor-animation-complete timing.
              const fixAfterStateChange = () => {
                fixChildBounds();
                setTimeout(fixChildBounds, 16);
                setTimeout(fixChildBounds, 150);
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
                if (this.isDestroyed()) return;
                const [w, h] = this.getSize();
                if (w !== lastSize[0] || h !== lastSize[1]) {
                  lastSize = [w, h];
                  fixAfterStateChange();
                }
              });

              // ready-to-show fires once per window lifecycle
              this.once('ready-to-show', () => {
                this.setMenuBarVisibility(false);
                // One-time jiggle for initial layout. Fixes: #84
                const [w, h] = this.getSize();
                this.setSize(w + 1, h + 1);
                setTimeout(() => {
                  if (this.isDestroyed()) return;
                  this.setSize(w, h);
                  fixAfterStateChange();
                }, 50);
              });

              // Fixes: #149 - KDE Plasma: Window demands attention on Alt+Tab
              this.on('focus', () => {
                this.flashFrame(false);
              });
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

      // Intercept Menu.setApplicationMenu to hide menu bar on Linux
      const originalSetAppMenu = OriginalMenu.setApplicationMenu.bind(OriginalMenu);
      patchedSetApplicationMenu = function(menu) {
        console.log('[Frame Fix] Intercepting setApplicationMenu');
        originalSetAppMenu(menu);
        if (process.platform === 'linux') {
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
