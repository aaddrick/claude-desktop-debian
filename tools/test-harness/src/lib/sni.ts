import { getSessionBus, getConnectionPid, method } from './dbus.js';
import type { Variant } from 'dbus-next';

const WATCHER_DEST = 'org.kde.StatusNotifierWatcher';
const WATCHER_PATH = '/StatusNotifierWatcher';
const ITEM_IFACE = 'org.kde.StatusNotifierItem';

export interface SniItem {
	service: string;
	objectPath: string;
}

export async function listRegisteredItems(): Promise<SniItem[]> {
	const bus = getSessionBus();
	const proxy = await bus.getProxyObject(WATCHER_DEST, WATCHER_PATH);
	const props = proxy.getInterface('org.freedesktop.DBus.Properties');
	const result = await method(props, 'Get')(
		WATCHER_DEST,
		'RegisteredStatusNotifierItems',
	);
	const variant = result as Variant<string[]>;
	return variant.value.map(parseItemAddress);
}

export async function findItemByPid(pid: number): Promise<SniItem | null> {
	const items = await listRegisteredItems();
	for (const item of items) {
		try {
			const itemPid = await getConnectionPid(item.service);
			if (itemPid === pid) {
				return item;
			}
		} catch {
			// connection may have gone away mid-iteration; skip
		}
	}
	return null;
}

export async function activateItem(item: SniItem): Promise<void> {
	const bus = getSessionBus();
	const proxy = await bus.getProxyObject(item.service, item.objectPath);
	const iface = proxy.getInterface(ITEM_IFACE);
	await method(iface, 'Activate')(0, 0);
}

function parseItemAddress(raw: string): SniItem {
	const slash = raw.indexOf('/');
	if (slash === -1) {
		return { service: raw, objectPath: '/StatusNotifierItem' };
	}
	return { service: raw.slice(0, slash), objectPath: raw.slice(slash) };
}
