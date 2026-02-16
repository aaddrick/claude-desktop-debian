// Stub implementation of claude-native for Linux
// Uses Electron's native Linux support where possible instead of no-ops
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);

// Helper: get the focused BrowserWindow (lazy-loaded to avoid circular deps)
// Filters destroyed/invisible windows from fallback to avoid errors like
// flashFrame() on a destroyed window or getIsMaximized() on a popup
function getWindow() {
  try {
    const { BrowserWindow } = require('electron');
    const focused = BrowserWindow.getFocusedWindow();
    if (focused) return focused;
    const visible = BrowserWindow.getAllWindows().find(
      (w) => !w.isDestroyed() && w.isVisible()
    );
    return visible || null;
  } catch (e) {
    console.warn('[Claude Native Stub] getWindow() failed:', e);
    return null;
  }
}

// AuthRequest stub - not available on Linux, will cause fallback to system browser
class AuthRequest {
  static isAvailable() {
    return false;
  }

  async start(url, scheme, windowHandle) {
    throw new Error('AuthRequest not available on Linux');
  }

  cancel() {
    // no-op
  }
}

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},

  // Functional on Linux via Electron's native support
  getIsMaximized: () => {
    const win = getWindow();
    return win ? win.isMaximized() : false;
  },

  // Fixes: #149 - KDE Plasma: Window demands attention
  // flashFrame is natively supported on Linux Electron.
  // Note: frame-fix-wrapper.js auto-clears flashFrame on window focus
  // (see the 'focus' event handler in BrowserWindowWithFrame constructor).
  flashFrame: (flash) => {
    const win = getWindow();
    if (win) win.flashFrame(typeof flash === 'boolean' ? flash : true);
  },
  clearFlashFrame: () => {
    const win = getWindow();
    if (win) win.flashFrame(false);
  },

  showNotification: () => {},

  // Progress bar is natively supported on Linux (Unity/KDE/GNOME)
  setProgressBar: (progress) => {
    const win = getWindow();
    if (win && typeof progress === 'number') {
      win.setProgressBar(Math.max(0, Math.min(1, progress)));
    }
  },
  clearProgressBar: () => {
    const win = getWindow();
    if (win) win.setProgressBar(-1);
  },

  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey,
  AuthRequest
};
