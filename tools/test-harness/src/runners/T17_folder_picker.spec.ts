import { test } from '@playwright/test';

// T17 has no working runner under the current launch model.
//
// Under `_electron.launch()` (Playwright's native Electron path) the v1
// shallow approach worked: install an `app.evaluate(({ dialog }) => ...)`
// shim on `dialog.showOpenDialog` from the test, click the button, assert the
// shim was called. That gave us "the renderer requested a folder" without
// needing portal-level mocking.
//
// We've moved off `_electron.launch()` because Playwright's inspector ws
// disconnects mid-launch on this Electron 41 + frame-fix-wrapper build (see
// lib/electron.ts comments). The replacement, `chromium.connectOverCDP`,
// gives us renderer-side automation but no main-process control — meaning
// no `app.evaluate()` and therefore no main-process shim. The shallow path
// is closed.
//
// The proper test is the architectural target documented in
// docs/testing/automation.md ("Native dialogs"): register a mock backend
// at `org.freedesktop.portal.FileChooser` via dbus-next, run the test under
// `dbus-run-session` so the mock owns the well-known portal name, click the
// button, assert the mock received an OpenFile call. That's a v2 build-out
// — separate dbus-run-session orchestration plus a small portal-mock library
// in lib/portal.ts.
//
// Skipping cleanly here is more honest than a shim that doesn't run; the
// JUnit output will mark T17 as `<skipped>` (which renders to `?` in the
// matrix per Decision 7) until the v2 path is built.

test('T17 — Folder picker opens', async () => {
	test.skip(
		true,
		'Awaiting v2 portal mock under dbus-run-session — see ' +
			'docs/testing/automation.md "Native dialogs" and the comment in ' +
			'src/runners/T17_folder_picker.spec.ts',
	);
});
