export interface RetryOptions {
	timeout?: number;
	interval?: number;
	message?: string;
}

export async function retryUntil<T>(
	fn: () => Promise<T | null | undefined>,
	options: RetryOptions = {},
): Promise<T | null> {
	const timeout = options.timeout ?? 10_000;
	const interval = options.interval ?? 250;
	const start = Date.now();

	while (Date.now() - start < timeout) {
		const result = await fn();
		if (result !== null && result !== undefined) {
			return result;
		}
		await sleep(interval);
	}
	return null;
}

export function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}
