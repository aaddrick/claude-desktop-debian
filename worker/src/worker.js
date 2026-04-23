// APT/DNF binary distribution Worker.
//
// Pass-through requests for repo metadata (dists/, KEY.gpg, repodata/, etc.)
// to the gh-pages origin. 302-redirect requests for binary packages
// (pool/.../*.deb, rpm/*/*.rpm) to GitHub Release assets, which CI publishes
// for every tagged release.
//
// The Worker only emits redirect responses; binary bytes flow directly from
// objects.githubusercontent.com to the user, never crossing Cloudflare.
//
// See docs/worker-apt-plan.md for the full architecture.

const ORIGIN = 'https://aaddrick.github.io/claude-desktop-debian';
const RELEASES =
	'https://github.com/aaddrick/claude-desktop-debian/releases/download';

// claude-desktop_<claudeVer>-<repoVer>_<arch>.deb
const DEB_RE = new RegExp(
	'^/pool/main/c/claude-desktop/(?<asset>claude-desktop_' +
		'(?<claudeVer>[^-]+)-(?<repoVer>[^_]+)_(?:amd64|arm64)\\.deb)$'
);

// claude-desktop-<claudeVer>-<repoVer>-<rpmRelease>.<arch>.rpm
const RPM_RE = new RegExp(
	'^/rpm/(?:x86_64|aarch64)/(?<asset>claude-desktop-' +
		'(?<claudeVer>[\\d.]+)-(?<repoVer>[\\d.]+)-\\d+\\.[^.]+\\.rpm)$'
);

export default {
	async fetch(request) {
		const url = new URL(request.url);
		const m = DEB_RE.exec(url.pathname) || RPM_RE.exec(url.pathname);
		if (m) {
			const { asset, claudeVer, repoVer } = m.groups;
			const tag = `v${repoVer}+claude${claudeVer}`;
			return Response.redirect(`${RELEASES}/${tag}/${asset}`, 302);
		}
		return fetch(ORIGIN + url.pathname + url.search, request);
	},
};
