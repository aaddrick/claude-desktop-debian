// Read files out of the installed app.asar without on-disk extraction.
//
// Used by the patch-fingerprint specs (H03, S09) and the asar
// content probes (S21/S22/S26-S28, T11/T14a/T18/T22/T30-T38 file
// probes). Reading via @electron/asar avoids the
// `npx asar extract /tmp/inspect-installed` dance — same outcome, no
// temp tree, JSON-grepable from inside a TS spec.
//
// Path resolution mirrors lib/electron.ts:resolveInstall(): respect
// CLAUDE_DESKTOP_APP_ASAR if set, otherwise probe the deb and rpm
// install locations.

import { extractFile, listPackage } from '@electron/asar';
import { existsSync } from 'node:fs';

const DEFAULT_ASAR_PATHS = [
	// v3.x official bare co-located layout
	'/usr/lib/claude-desktop/resources/app.asar',
	// 2.x layouts
	'/usr/lib/claude-desktop/app.asar',
	'/opt/Claude/resources/app.asar',
	'/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar',
	'/opt/Claude/node_modules/electron/dist/resources/app.asar',
];

export function resolveAsarPath(): string {
	const env = process.env.CLAUDE_DESKTOP_APP_ASAR;
	if (env) return env;
	for (const candidate of DEFAULT_ASAR_PATHS) {
		if (existsSync(candidate)) return candidate;
	}
	throw new Error(
		'Could not locate app.asar. Set CLAUDE_DESKTOP_APP_ASAR or install ' +
			'the deb/rpm package.',
	);
}

export function readAsarFile(filename: string, asarPath?: string): string {
	const archive = asarPath ?? resolveAsarPath();
	const buf = extractFile(archive, filename);
	return buf.toString('utf8');
}

export function asarContains(
	filename: string,
	needle: string | RegExp,
	asarPath?: string,
): boolean {
	const contents = readAsarFile(filename, asarPath);
	return typeof needle === 'string'
		? contents.includes(needle)
		: needle.test(contents);
}

export function listAsar(asarPath?: string): string[] {
	const archive = asarPath ?? resolveAsarPath();
	return listPackage(archive, { isPack: false });
}
