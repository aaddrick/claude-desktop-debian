// Row-aware skip primitive.
//
// Spec files declare which matrix rows they apply to. Anything else is
// skipped (not failed) so the JUnit run carries `<skipped>` →
// `matrix.md` cell `-`. See Decision 1 in docs/testing/automation.md
// for the JUnit-to-cell mapping.
//
// Usage in a runner:
//   skipUnlessRow(testInfo, ['KDE-W', 'GNOME-W', 'Ubu-W']);
//
// The reason is auto-formatted from the row list so the dashboard
// caller doesn't have to write it.

import type { TestInfo } from '@playwright/test';
import { getEnv } from './env.js';

export type Row =
	| 'KDE-W'
	| 'KDE-X'
	| 'GNOME-W'
	| 'GNOME-X'
	| 'Ubu-W'
	| 'Ubu-X'
	| 'COSMIC'
	| 'Sway'
	| 'Niri'
	| 'Hypr-O'
	| 'Hypr-N'
	| 'i3';

export function currentRow(): string {
	return getEnv().row;
}

export function skipUnlessRow(testInfo: TestInfo, allowed: Row[]): void {
	const row = currentRow();
	if (allowed.includes(row as Row)) return;
	testInfo.skip(
		true,
		`row ${row} not in [${allowed.join(', ')}] — applies-to mismatch`,
	);
}

export function skipOnRow(testInfo: TestInfo, blocked: Row[]): void {
	const row = currentRow();
	if (!blocked.includes(row as Row)) return;
	testInfo.skip(true, `row ${row} excluded`);
}
