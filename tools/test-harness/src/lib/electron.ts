import { _electron as electron, type ElectronApplication } from 'playwright';

export interface LaunchOptions {
	extraEnv?: Record<string, string>;
	args?: string[];
	timeout?: number;
}

export async function launchClaude(opts: LaunchOptions = {}): Promise<ElectronApplication> {
	const launcher = process.env.CLAUDE_DESKTOP_LAUNCHER ?? 'claude-desktop';

	return electron.launch({
		executablePath: launcher,
		args: opts.args ?? [],
		env: {
			...process.env,
			...opts.extraEnv,
			CI: '1',
		} as Record<string, string>,
		timeout: opts.timeout ?? 30_000,
	});
}
