export interface DesktopEnv {
	desktop: string;
	sessionType: string;
	isWayland: boolean;
	isX11: boolean;
	isKDE: boolean;
	isGNOME: boolean;
	isSWAY: boolean;
	isHYPR: boolean;
	isNIRI: boolean;
	row: string;
}

export function getEnv(): DesktopEnv {
	const desktop = process.env.XDG_CURRENT_DESKTOP ?? '';
	const sessionType = process.env.XDG_SESSION_TYPE ?? '';
	const upper = desktop.toUpperCase();
	return {
		desktop,
		sessionType,
		isWayland: sessionType === 'wayland',
		isX11: sessionType === 'x11',
		isKDE: upper.includes('KDE'),
		isGNOME: upper.includes('GNOME'),
		isSWAY: upper.includes('SWAY'),
		isHYPR: upper.includes('HYPRLAND'),
		isNIRI: upper.includes('NIRI'),
		row: process.env.ROW ?? 'KDE-W',
	};
}
