// APT/DNF binary distribution Worker.
//
// Pass-through requests for repo metadata (dists/, KEY.gpg, repodata/, etc.)
// to the gh-pages origin. 302-redirect requests for binary packages
// (pool/.../*.deb, rpm/*/*.rpm) to GitHub Release assets, which CI publishes
// for every tagged release.
//
// The Worker only emits redirect responses; binary bytes flow directly from
// release-assets.githubusercontent.com to the user, never crossing Cloudflare.

// Raw gh-pages content, bypassing the Pages routing layer. Fetching
// via aaddrick.github.io auto-301s back to pkg.<domain> once the CNAME
// is in place (Pages' custom-domain redirect), creating a loop through
// this Worker. raw.githubusercontent.com serves the same branch content
// directly and is unaffected by the custom-domain config.
const ORIGIN =
	'https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/gh-pages';
const RELEASES =
	'https://github.com/aaddrick/claude-desktop-debian/releases/download';
// GitHub resolves /releases/latest/download/<asset> to the newest
// non-prerelease tag with its own 302 — used for assets whose
// filenames don't encode a release tag (the transitional deb below).
const RELEASES_LATEST =
	'https://github.com/aaddrick/claude-desktop-debian/releases/latest/download';

// Our renamed package:
// claude-desktop-unofficial_<claudeVer>-<repoVer>_<arch>.deb
const DEB_RE = new RegExp(
	'^/pool/main/c/claude-desktop-unofficial/(?<asset>claude-desktop-unofficial_' +
		'(?<claudeVer>[^-]+)-(?<repoVer>[^_]+)_(?:amd64|arm64)\\.deb)$'
);

// Transitional dummy package (Package: claude-desktop, Depends:
// claude-desktop-unofficial) that auto-migrates legacy apt installs
// to the renamed package. Its version is fixed at 1.16000.0-<rev>, so
// the filename encodes no release tag; CI uploads the asset to every
// release and requests redirect via releases/latest instead.
const TRANSITIONAL_DEB_RE = new RegExp(
	'^/pool/main/c/claude-desktop/(?<asset>claude-desktop_' +
		'1\\.16000\\.0-\\d+_all\\.deb)$'
);

// claude-desktop-unofficial-<claudeVer>-<repoVer>-<rpmRelease>.<arch>.rpm
const RPM_RE = new RegExp(
	'^/rpm/(?:x86_64|aarch64)/(?<asset>claude-desktop-unofficial-' +
		'(?<claudeVer>[\\d.]+)-(?<repoVer>[\\d.]+)-\\d+\\.[^.]+\\.rpm)$'
);

// Pre-rename (v2.x-era) pool paths and asset names. The Worker deploys
// on merge to main, but gh-pages metadata keeps pointing at these until
// the first renamed release regenerates the repo — and apt/dnf clients
// with cached metadata point at them for a while after. The old assets
// live on their releases forever, so keep these routes permanently.
const LEGACY_DEB_RE = new RegExp(
	'^/pool/main/c/claude-desktop/(?<asset>claude-desktop_' +
		'(?<claudeVer>[^-]+)-(?<repoVer>[^_]+)_(?:amd64|arm64)\\.deb)$'
);
const LEGACY_RPM_RE = new RegExp(
	'^/rpm/(?:x86_64|aarch64)/(?<asset>claude-desktop-' +
		'(?<claudeVer>[\\d.]+)-(?<repoVer>[\\d.]+)-\\d+\\.[^.]+\\.rpm)$'
);

export default {
	async fetch(request) {
		const url = new URL(request.url);
		const m =
			DEB_RE.exec(url.pathname) ||
			RPM_RE.exec(url.pathname) ||
			LEGACY_DEB_RE.exec(url.pathname) ||
			LEGACY_RPM_RE.exec(url.pathname);
		if (m) {
			const { asset, claudeVer, repoVer } = m.groups;
			const tag = `v${repoVer}+claude${claudeVer}`;
			return Response.redirect(`${RELEASES}/${tag}/${asset}`, 302);
		}
		const t = TRANSITIONAL_DEB_RE.exec(url.pathname);
		if (t) {
			return Response.redirect(
				`${RELEASES_LATEST}/${t.groups.asset}`,
				302
			);
		}
		return fetch(ORIGIN + url.pathname + url.search, request);
	},
};
