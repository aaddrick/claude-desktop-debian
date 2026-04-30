import { sessionBus, type MessageBus, type ClientInterface } from 'dbus-next';

let cached: MessageBus | null = null;

export function getSessionBus(): MessageBus {
	if (!cached) {
		cached = sessionBus();
	}
	return cached;
}

export async function disconnectBus(): Promise<void> {
	if (cached) {
		cached.disconnect();
		cached = null;
	}
}

// dbus-next exposes interface methods as dynamic properties typed loosely. Cast
// at the call site rather than re-typing every D-Bus interface we touch.
type DynamicMethod = (...args: unknown[]) => Promise<unknown>;

export function method(iface: ClientInterface, name: string): DynamicMethod {
	const fn = (iface as unknown as Record<string, DynamicMethod | undefined>)[name];
	if (typeof fn !== 'function') {
		throw new Error(`D-Bus method ${name} not found on interface`);
	}
	return fn.bind(iface);
}

export async function getConnectionPid(connectionName: string): Promise<number> {
	const bus = getSessionBus();
	const proxy = await bus.getProxyObject(
		'org.freedesktop.DBus',
		'/org/freedesktop/DBus',
	);
	const iface = proxy.getInterface('org.freedesktop.DBus');
	const result = await method(iface, 'GetConnectionUnixProcessID')(connectionName);
	return result as number;
}
