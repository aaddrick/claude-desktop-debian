# APT/DNF Worker Architecture

How binary distribution works since Phase 4a (April 2026, #493). Things
that aren't obvious from reading the code alone — read this before
debugging the repo chain or rotating credentials.

## The problem that drove it

The v2.0.2+claude1.3883.0 `.deb` grew to 129.81 MB and GitHub rejects
pushes containing any file over 100 MB. `apt update` users got stuck
on v2.0.1+claude1.3561.0 because `update-apt-repo` couldn't push.
Shrinking experiments got the `.deb` to ~113 MB but Electron + libs +
ion-dist + smol-bin VHDX + app.asar are each individually
irreducible — ~110 MB is the floor for a working build. Shrinking was
never going to be a viable path.

Splitting into multiple `.deb` packages with `Depends:` chains was the
alternative, but that's an invasive packaging refactor that buys
6-12 months until a half crosses 100 MB again.

## The shape of the fix

Front the existing GitHub Pages repo with a Cloudflare Worker on a
custom domain. The Worker passes metadata through (InRelease,
Packages, KEY.gpg, repodata/) to the `gh-pages` origin and 302-redirects
binary requests (`/pool/.../*.deb`, `/rpm/*/*.rpm`) to GitHub Release
assets. `.deb` / `.rpm` bytes never touch `gh-pages`, so the 100 MB
cap doesn't apply.

Binary bytes flow directly from `release-assets.githubusercontent.com`
to the user — never through Cloudflare. The Worker only emits redirect
responses (a few hundred bytes). This matters for Cloudflare TOS and
bandwidth economics.

## The chain (existing users, legacy URL)

```
apt/dnf with sources.list pointing at https://aaddrick.github.io/claude-desktop-debian
    │
    ▼ [301, Pages auto-redirect from CNAME file on gh-pages]
http://pkg.claude-desktop-debian.dev/...     ← note http://, see "Pages scheme" below
    │
    ▼ [302, Worker route]
    ├─ /dists/*, /KEY.gpg, /rpm/*/repodata/*  →  fetch() from raw.githubusercontent.com (200)
    └─ /pool/main/c/.../*.deb, /rpm/*/*.rpm   →  302 to github.com/.../releases/download/<tag>/<asset>
                                                     ↓ 302
                                                  https://release-assets.githubusercontent.com/...
                                                     ↓ 200
                                                  (the binary)
```

## The chain (new users, pkg.<domain> direct)

```
apt/dnf with sources.list pointing at https://pkg.claude-desktop-debian.dev
    │
    ▼ [Worker route, all HTTPS]
    ├─ metadata  →  200 from raw.githubusercontent.com
    └─ binaries  →  302 → 302 → 200 from release-assets
```

## Why raw.githubusercontent.com as origin (not github.io Pages)

The Worker's `ORIGIN` is `https://raw.githubusercontent.com/aaddrick/claude-desktop-debian/gh-pages`,
not `https://aaddrick.github.io/claude-desktop-debian`. Once the CNAME
file is in place on `gh-pages`, Pages auto-301s `aaddrick.github.io/...`
back to `pkg.<domain>`. The Worker fetching github.io would get that
301, pass it to the client, the client would follow it back to
`pkg.<domain>`, and the Worker would run again — infinite loop.

raw.githubusercontent.com serves the same branch content directly,
without Pages' routing layer, so it's loop-free.

## Pages scheme downgrade: why the Location is http://

Pages' auto-301 from github.io to `pkg.<domain>` uses `http://` in the
Location header, not `https://`. This is because `https_enforced` on
the Pages config can't be set to `true`:

```
$ gh api -X PUT repos/aaddrick/claude-desktop-debian/pages -F https_enforced=true
{"message":"The certificate does not exist yet", ...}
```

Pages would normally provision a Let's Encrypt cert via HTTP-01
challenge, which requires DNS for the custom domain to point at Pages'
IPs. But DNS for `pkg.claude-desktop-debian.dev` points at Cloudflare
(Workers' `custom_domain = true` takes over DNS), so Pages can never
verify domain ownership and never gets a cert. Without a cert, it
emits http:// in the Location header.

DNF follows the https→http scheme downgrade silently. `apt` refuses it
as a security policy (non-configurable) — "Redirection from https to
'http://pkg...' is forbidden". This is why new users are told to
configure sources.list with `https://pkg.claude-desktop-debian.dev`
directly in the README, skipping the Pages hop entirely.

Existing users hitting the legacy github.io URL see their apt break
on next `apt update` until they run the migration `sed` one-liner.

## Files in this repo

| Path | Role |
|---|---|
| `worker/src/worker.js` | Worker source. Matches `DEB_RE` / `RPM_RE` for binary paths, emits 302 to Releases; everything else passes through to `raw.githubusercontent.com`. |
| `worker/wrangler.toml` | Worker config. `custom_domain = true` binds DNS automatically; flipping the `pattern` between staging and production is how cutovers happen. |
| `.github/workflows/deploy-worker.yml` | Runs `wrangler deploy` on push to `main` when `worker/**` or the workflow itself changes. Post-deploy probe asserts `https://pkg.<domain>/dists/stable/InRelease` returns 2xx/3xx. |
| `.github/workflows/ci.yml` (`update-apt-repo`, `update-dnf-repo`) | Strip `.deb`/`.rpm` from the local pool tree before commit, **gated on a liveness probe against the Worker**. The probe's success is the cutover signal — misconfigured env vars can't accidentally strip. |
| `.github/workflows/apt-repo-heartbeat.yml` | Daily cron, matrix over `deb` + `rpm`, walks the full redirect chain and asserts size match against the Release asset. Opens a format-specific `heartbeat-failure-{deb,rpm}` tracking issue on failure; auto-closes on recovery. |

## Credentials and ownership

- **Cloudflare account**: created specifically for this project, email `cf-pkg@claude-desktop-debian.dev`, free tier. Aliased so registrar and account recovery emails land in @aaddrick's backup inbox
- **Domain registrar**: Cloudflare Registrar (same dashboard as the account). Auto-renewal enabled on a payment method with >5y expiry
- **DNS**: managed at Cloudflare. `pkg.claude-desktop-debian.dev` is a Workers-managed custom domain (auto-created by `custom_domain = true` on deploy). No manual DNS entry exists
- **API credentials**: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as repo secrets. The token is scoped to the "Edit Cloudflare Workers" template — Workers Scripts Edit, Account Settings Read, Workers Routes Edit. CI-only; no workstation dependency on @aaddrick's laptop

Recovery for a future maintainer: rotate the API token, update the
registrar contact email, and the whole Worker deploy pipeline works
from their fork via CI.

## Heartbeat failure runbook

If `apt-repo-heartbeat.yml` opens a `heartbeat-failure-deb` or
`heartbeat-failure-rpm` tracking issue, work through these in order:

1. **Is the Worker actually down?** Manually run the probe:
   ```
   curl -IsL https://pkg.claude-desktop-debian.dev/dists/stable/InRelease
   ```
   Should return HTTP 200 with `content-type: text/plain; charset=utf-8`
   and the InRelease content. If it 5xx's or times out, check Cloudflare
   dashboard → Workers → claude-desktop-debian-pkg-redirect for
   deployment state and error logs
2. **Is GitHub's Release asset CDN reachable?** Try fetching the latest
   release's `.deb` directly:
   ```
   gh release view --repo aaddrick/claude-desktop-debian --json assets \
     --jq '.assets[] | select(.name | endswith("_amd64.deb")) | .url'
   ```
   Curl that URL; should 302 through `release-assets.githubusercontent.com`
   to a 200. GitHub has had per-account egress throttling return 503
   under unusual load — rare but real
3. **Did GitHub rename the asset CDN again?** The smoke tests and
   heartbeat accept both `objects.githubusercontent.com` and
   `release-assets.githubusercontent.com`. If a third hostname shows up,
   widen the regex in `.github/workflows/ci.yml` and
   `.github/workflows/apt-repo-heartbeat.yml`
4. **Did the release filename format change?** The Worker's `DEB_RE` and
   `RPM_RE` have specific patterns. A build-script change that renames
   artifacts would miss the regex — the Worker would passthrough to raw
   (404) instead of 302 to Releases
5. **Is Pages' 301 scheme still http?** Expected. If it flips to https,
   that's a GitHub-side behavior change — relax the chain walker,
   don't panic

## Rollback

If the Worker chain misbehaves after a release:

1. **Fast disable** (Cloudflare dashboard, <1 min): unbind the Worker
   from `pkg.claude-desktop-debian.dev/*`. Domain still resolves but
   returns 521/523. Useful for "is this a Worker bug?" isolation
2. **Cold-standby restore** (Pages settings, ~5 min): remove the
   `CNAME` file from `gh-pages`. github.io URL stops 301-ing. Apt
   fetches from Pages directly — serves what's in `gh-pages` at the
   time, which after Phase 4a is metadata-only. **This doesn't restore
   binaries.** For any version that was pushed post-Phase-4a, binary
   fetches still 404 via the legacy path
3. **Full revert**: restore `.deb`s to `gh-pages` history from a local
   build (`reprepro includedeb` locally + push). Heavy — only if the
   Worker path is structurally broken and can't be fixed forward

The architecture's single-vendor dependency (Cloudflare) is accepted
risk. If Cloudflare suspends the account, the documented fallbacks are
(a) split the `.deb` into multiple packages with `Depends:` chains
(invasive packaging refactor, 6-12 months of runway), (b) migrate to
Cloudflare R2 as primary storage (larger CI change), (c) commercial
package CDN (Cloudsmith, Packagecloud — $20-100/mo).

## Known gotchas

- **apt's https→http redirect refusal** is non-configurable. Users on
  legacy github.io URLs must migrate sources.list. README documents
  the sed one-liner
- **Pages cert can't be provisioned** because DNS points at Cloudflare.
  Don't try to enable `https_enforced` via API — it'll 404
- **Fastly caching**: GitHub Pages is fronted by Fastly. After pushing
  a new release, `curl` directly to github.io may show stale content
  for up to a few minutes. The Worker fetches from `raw.githubusercontent.com`,
  which has its own (different) caching — generally stales faster
- **Smoke-test chain-starting URLs are intentionally at github.io**
  (`deb_url` / `rpm_url` in `ci.yml`). They test the full 3-hop chain
  via `curl` (which follows the downgrade). Don't "fix" them to point
  at `pkg.<domain>` — you'd break coverage of the Pages-301 path that
  DNF users actually traverse
- **`worker/.wrangler/`** is wrangler's local build cache, not in
  `.gitignore` yet. Ignore it; don't commit
