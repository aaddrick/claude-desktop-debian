import { defineConfig } from '@playwright/test';

const resultsDir = process.env.RESULTS_DIR ?? './results/local';

export default defineConfig({
	testDir: './src/runners',
	testMatch: /.*\.spec\.ts$/,
	fullyParallel: false,
	workers: 1,
	retries: 0,
	timeout: 60_000,
	expect: { timeout: 10_000 },
	outputDir: `${resultsDir}/test-output`,
	reporter: [
		['list'],
		['junit', { outputFile: `${resultsDir}/junit.xml` }],
		['html', { outputFolder: `${resultsDir}/html`, open: 'never' }],
	],
	use: {
		trace: 'retain-on-failure',
		screenshot: 'only-on-failure',
	},
});
