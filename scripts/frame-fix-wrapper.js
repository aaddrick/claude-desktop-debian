// Inject frame fix before main app loads
const Module = require('module');
const originalRequire = Module.prototype.require;

console.log('[Frame Fix] Wrapper loaded');

// Detect if a window intends to be frameless (popup/Quick Entry/About)
// The app uses titleBarStyle:"" for frameless-intent windows on macOS.
// Main window also has titleBarStyle:"" but pairs it with titleBarOverlay,
// so we check for titleBarStyle:"" WITHOUT titleBarOverlay to identify popups.
function isPopupWindow(options) {
  if (!options) return false;
  if (options.frame === false) return true;
  if (options.titleBarStyle === '' && !options.titleBarOverlay) return true;
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

Module.prototype.require = function(id) {
  const module = originalRequire.apply(this, arguments);

  if (id === 'electron') {
    console.log('[Frame Fix] Intercepting electron module');
    const OriginalBrowserWindow = module.BrowserWindow;
    const OriginalMenu = module.Menu;

    module.BrowserWindow = class BrowserWindowWithFrame extends OriginalBrowserWindow {
      constructor(options) {
        console.log('[Frame Fix] BrowserWindow constructor called');
        if (process.platform === 'linux') {
          options = options || {};
          const originalFrame = options.frame;
          const popup = isPopupWindow(options);

          if (popup) {
            // Popup/Quick Entry windows: keep frameless for proper UX
            // Note: skipTaskbar intentionally not set - the original app
            // never sets it, and it breaks Alt+Tab on Xfce/tiling WMs (#231)
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
          // Fixes: #172 - Menu bar still visible despite disabling flags
          this.setMenuBarVisibility(false);

          // Inject CSS for Linux scrollbar styling
          this.webContents.on('did-finish-load', () => {
            this.webContents.insertCSS(LINUX_CSS).catch(() => {});
          });

          // Ensure menu bar stays hidden on show events
          this.on('show', () => {
            this.setMenuBarVisibility(false);
          });

          // ready-to-show fires once per window lifecycle
          this.once('ready-to-show', () => {
            this.setMenuBarVisibility(false);

            if (!popup) {
              // Fixes: #84 - Content not sized correctly unless resized
              // Only applies to main windows; popups don't need resize jiggle
              const [w, h] = this.getSize();
              this.setSize(w + 1, h + 1);
              setTimeout(() => {
                if (!this.isDestroyed()) this.setSize(w, h);
              }, 50);
            }
          });

          if (!popup) {
            // Fixes: #149 - KDE Plasma: Window demands attention on Alt+Tab
            // Auto-clear flashFrame attention state when the user focuses
            // the window (flashFrame is set via claude-native-stub.js)
            this.on('focus', () => {
              this.flashFrame(false);
            });
          }

          console.log('[Frame Fix] Linux patches applied');
        }
      }
    };

    // Copy static methods and properties (but NOT prototype, that's already set by extends)
    for (const key of Object.getOwnPropertyNames(OriginalBrowserWindow)) {
      if (key !== 'prototype' && key !== 'length' && key !== 'name') {
        try {
          const descriptor = Object.getOwnPropertyDescriptor(OriginalBrowserWindow, key);
          if (descriptor) {
            Object.defineProperty(module.BrowserWindow, key, descriptor);
          }
        } catch (e) {
          // Ignore errors for non-configurable properties
        }
      }
    }

    // Intercept Menu.setApplicationMenu to hide menu bar on Linux
    // This catches the app's later calls to setApplicationMenu that would show the menu
    const originalSetAppMenu = OriginalMenu.setApplicationMenu.bind(OriginalMenu);
    module.Menu.setApplicationMenu = function(menu) {
      console.log('[Frame Fix] Intercepting setApplicationMenu');
      originalSetAppMenu(menu);
      if (process.platform === 'linux') {
        // Hide menu bar on all existing windows after menu is set
        for (const win of module.BrowserWindow.getAllWindows()) {
          if (win.isDestroyed()) continue;
          win.setMenuBarVisibility(false);
        }
        console.log('[Frame Fix] Menu bar hidden on all windows');
      }
    };
  }

  return module;
};
