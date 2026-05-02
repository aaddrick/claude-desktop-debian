import { test } from '@playwright/test';
import { skipUnlessRow } from '../lib/row.js';

// S37 — Quick Entry popup remains functional after main window
// destroy. Backs QE-24 in docs/testing/quick-entry-closeout.md.
//
// Per the closeout doc:
//   "Likely unreachable on Linux without a debug build, due to
//    project's hide-to-tray override of the X button. Mark `-`
//    (N/A) on rows where the destroy path can't be triggered."
//
// On every supported Linux row, scripts/frame-fix-wrapper.js
// intercepts the X button to call hide() instead of close()/
// destroy() (the close-to-tray behavior). DevTools'
// `remote.getCurrentWindow().destroy()` would work in principle,
// but `remote` isn't exposed in modern Electron and adding it as
// a test-only patch is more invasive than this case is worth.
//
// All Linux rows skip this with the upstream-rationale message.
// If a non-Linux row is added later (FreeBSD?), revisit; the spec
// remains useful as the "what would happen if" reference.

test('S37 — Quick Entry popup remains functional after main window destroy', async ({}, testInfo) => {
	testInfo.annotations.push({ type: 'severity', description: 'Should' });
	testInfo.annotations.push({
		type: 'surface',
		description: 'Popup lifecycle independence from main window',
	});
	skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W', 'KDE-X', 'GNOME-X']);

	testInfo.skip(
		true,
		'main-window destroy is unreachable on Linux without a debug ' +
			'build (close-to-tray override intercepts the X button to ' +
			'hide() rather than destroy()). Marked N/A in the matrix ' +
			'per docs/testing/quick-entry-closeout.md QE-24.',
	);
});
