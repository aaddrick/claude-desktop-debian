// Read files out of the installed app.asar without on-disk extraction.
//
// Used by QE-19 / S09 (verify the KDE-gate string is in the bundled
// JS) and by future patch-sanity tests for tray.sh / cowork.sh /
// claude-code.sh patches. Reading via @electron/asar avoids the
// `npx asar extract /tmp/inspect-installed` dance — same outcome, no
// temp tree, JSON-grepable from inside a TS spec.
//
// Path resolution mirrors lib/electron.ts:resolveInstall(): respect
// CLAUDE_DESKTOP_APP_ASAR if set, otherwise probe the deb and rpm
// install locations.

import { extractFile, listPackage } from '@electron/asar';
import { existsSync } from 'node:fs';

const DEFAULT_ASAR_PATHS = [
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
