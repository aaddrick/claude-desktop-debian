# Plan: APT/DNF binary distribution via Cloudflare Worker → GitHub Releases

**Status:** Draft (post-contrarian-review revision 3)
**Issue:** [#493](https://github.com/aaddrick/claude-desktop-debian/issues/493)
**Trigger:** [run 24811974733](https://github.com/aaddrick/claude-desktop-debian/actions/runs/24811974733) — `update-apt-repo` push rejected because `.deb` exceeds GitHub's 100 MB per-file cap
**Relationship to #449:** This plan addresses the **forward** component of #449's gh-pages clone-bloat (no new `.deb` accumulation after Phase 4b). Backfill — shrinking the existing history — is a mandatory follow-up via one-time orphan-reset of `gh-pages`, not optional. The previously-drafted `gh-pages-split-plan.md` is deleted in this branch; the split-into-separate-repo machinery is no longer required.

## Problem

`apt update` users are pinned to v2.0.1+claude1.3561.0 because the v2.0.2+claude1.3883.0 `.deb` is 129.81 MB and `git push` to `gh-pages` is rejected by GitHub's 100 MB hard cap. Shrinking experiments on a throwaway branch got the `.deb` to ~113 MB compressed; the floor for a working build is ~110 MB given Electron + libs + ion-dist + smol-bin VHDX + app.asar are all individually irreducible. Shrinking is not a viable path under the cap.

## Approach

Front the existing GitHub Pages apt/dnf repo with a Cloudflare Worker on a custom domain. The Worker passes metadata through to gh-pages and 302-redirects pool requests to GitHub Release assets (which already exist — `Create Release` succeeds every tag). Existing user `sources.list` URLs keep working transparently via GitHub Pages' auto-301 from `*.github.io` to the configured custom domain.

**Architecturally important:** the Worker only emits redirect responses (a few hundred bytes). The `.deb` bytes themselves flow directly from `objects.githubusercontent.com` to the user, never crossing Cloudflare. This matters for both TOS posture (see Phase 0) and bandwidth economics.

Reference architecture: Cloudflare's own apt/yum repo at [`pkg.cloudflare.com`](https://pkg.cloudflare.com/) uses a related pattern (R2 + Worker) to ship `cloudflared` to Debian/Ubuntu/RHEL/CentOS users.

## Decisions

| Decision | Value |
|---|---|
| Custom domain | New domain, registered for this purpose (~$10–15/yr) |
| Cloudflare account | Free tier; new account if none exists, owned by a non-personal email |
| Worker route | `apt.<domain>/*` |
| Worker source | `worker/` directory in this repo, version-controlled, deployed via CI |
| Worker deploy creds | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` as repo secrets |
| RPM filename regex | Verify against actual CI-produced filename in Phase 1 |
| #449 follow-up | One-time orphan-reset of `gh-pages` after Phase 4b — separate, smaller PR, **mandatory** |
| Combine with `gh-pages-split` work | No — that complexity is no longer needed once `.deb` files stop accumulating |

## Architecture

```
existing user with old sources.list
       │
       ▼
github.io/.../foo.deb
   ↓ 301 (Pages auto-redirect from CNAME file)
apt.<domain>/.../foo.deb
   ↓ Worker route handler
   ├─ /dists/*, /KEY.gpg, /index.html, /repodata/*  →  fetch() from gh-pages origin (200)
   └─ /pool/.../*.deb, /rpm/*/*.rpm                  →  302 to github.com/.../releases/download/<tag>/<asset>
                                                           ↓ 302 to objects.githubusercontent.com
                                                              ↓ 200 (the binary, direct from GitHub CDN)
```

`apt`'s default redirect cap is 5; max chain length here is 3.

## Worker code (initial)

```js
const ORIGIN = 'https://aaddrick.github.io/claude-desktop-debian';
const RELEASES = 'https://github.com/aaddrick/claude-desktop-debian/releases/download';

const DEB_RE = /^\/pool\/main\/c\/claude-desktop\/(claude-desktop_(?<claudeVer>[^-]+)-(?<repoVer>[^_]+)_(?<arch>amd64|arm64)\.deb)$/;
const RPM_RE = /^\/rpm\/(?<arch>x86_64|aarch64)\/(claude-desktop-(?<claudeVer>[\d.]+)-(?<repoVer>[\d.]+)-\d+\.[^.]+\.rpm)$/;

function tagFor(claudeVer, repoVer) {
	return `v${repoVer}+claude${claudeVer}`;
}

export default {
	async fetch(request) {
		const url = new URL(request.url);
		const m = DEB_RE.exec(url.pathname) || RPM_RE.exec(url.pathname);
		if (m) {
			const { claudeVer, repoVer } = m.groups;
			return Response.redirect(
				`${RELEASES}/${tagFor(claudeVer, repoVer)}/${m[1]}`, 302
			);
		}
		return fetch(ORIGIN + url.pathname + url.search, request);
	}
};
```

RPM filename format confirmed against existing Release assets: `claude-desktop-1.3883.0-2.0.2-1.x86_64.rpm` (note the `-1` release number after the version).

## CI changes

Two surgical edits to `.github/workflows/ci.yml`. The first adds a step to both `update-apt-repo` and `update-dnf-repo` jobs to delete binary files from the working tree after metadata generation, before commit. The destructive action is **gated on a positive liveness probe** — it only fires if the production Worker is actually responding. This makes the gating self-protecting: a misconfigured env var, accidentally-true condition, or premature merge cannot strip binaries before the Worker is genuinely live.

```diff
       - name: Add packages to repository
         working-directory: apt-repo
         run: |
           # ... existing reprepro includedeb loop, unchanged ...

+      - name: Strip binaries from pool (gated on Worker liveness)
+        working-directory: apt-repo
+        env:
+          WORKER_DOMAIN: apt.<domain>
+        run: |
+          probe_url="https://${WORKER_DOMAIN}/dists/stable/InRelease"
+          if curl -fsI --max-time 10 "$probe_url" >/dev/null; then
+            echo "Worker live at ${WORKER_DOMAIN}; stripping binaries from pool"
+            find pool -type f -name '*.deb' -delete
+          else
+            echo "Worker not responding at ${WORKER_DOMAIN}; preserving .debs in pool"
+            echo "(this is expected before Phase 4a; an error after Phase 4a)"
+          fi

       - name: Commit and push changes
```

`dists/.../Packages` retains `Filename: pool/main/c/claude-desktop/foo.deb` — the Worker intercepts that path. Signed `InRelease` is unaffected because signatures are over content, not URL.

The second adds a smoke-test step at the end of each repo-update job that **walks the redirect chain hop-by-hop in expected order** and **asserts size match** against the GitHub Releases asset. Substring-grep on collected `Location:` headers is order-blind and would pass on a misconfigured Worker that 302'd straight to the wrong tag's asset; we walk the chain explicitly:

```yaml
      - name: Smoke test published deb (ordered chain + size)
        env:
          WORKER_DOMAIN: apt.<domain>  # the registered custom domain
          GH_TOKEN: ${{ github.token }}
        run: |
          deb_name="claude-desktop_${CLAUDE_VERSION}-${REPO_VERSION}_amd64.deb"
          deb_url="https://aaddrick.github.io/claude-desktop-debian/pool/main/c/claude-desktop/${deb_name}"

          # Wait for propagation; fail after 5 min instead of cargo-cult sleep
          deadline=$((SECONDS + 300))
          until curl -fsI --max-time 10 "$deb_url" -o /dev/null; do
            [[ $SECONDS -gt $deadline ]] \
              && { echo "::error::Reachability timeout"; exit 1; }
            sleep 10
          done

          # Walk the redirect chain hop-by-hop, asserting each hop's
          # Location matches the expected pattern in order.
          # Patterns are extended regex; '.' is literal here-and-there
          # because we anchor with full hostname matches.
          expected_hops=(
            "https://${WORKER_DOMAIN}/"
            "https://github\.com/aaddrick/claude-desktop-debian/releases/download/v${REPO_VERSION}\+claude${CLAUDE_VERSION}/"
            "https://objects\.githubusercontent\.com/"
          )
          url="$deb_url"
          for i in "${!expected_hops[@]}"; do
            hop_status=$(curl -s -o /dev/null -w '%{http_code}' "$url")
            redirect_url=$(curl -s -o /dev/null -w '%{redirect_url}' "$url")
            echo "Hop $i: ${hop_status} ${url} -> ${redirect_url}"
            [[ "$hop_status" =~ ^30[12]$ ]] \
              || { echo "::error::Hop $i expected 301/302, got ${hop_status}"; exit 1; }
            [[ "$redirect_url" =~ ^${expected_hops[$i]} ]] \
              || { echo "::error::Hop $i mismatch: expected ${expected_hops[$i]}, got ${redirect_url}"; exit 1; }
            url="$redirect_url"
          done

          # Fetch the file (now that we trust the chain)
          curl -fsSL -o /tmp/smoke.deb "$deb_url"
          file /tmp/smoke.deb | grep -q 'Debian binary package' \
            || { echo "::error::Not a valid Debian package"; exit 1; }

          # Size match against the Releases asset (catches truncation,
          # wrong-asset redirects, middleware that rewrites Content-Length)
          asset_size=$(gh release view "v${REPO_VERSION}+claude${CLAUDE_VERSION}" \
            --repo aaddrick/claude-desktop-debian \
            --json assets --jq ".assets[] | select(.name == \"${deb_name}\") | .size")
          local_size=$(stat -c %s /tmp/smoke.deb)
          [[ "$asset_size" == "$local_size" ]] \
            || { echo "::error::Size mismatch: ${local_size} vs ${asset_size}"; exit 1; }

          echo "Smoke test passed: ordered chain validated, file matches Releases asset"
```

The DNF smoke test is the same shape: same `expected_hops` ordering (Pages 301 → Worker 302 → `objects.githubusercontent.com`), but the URL uses the RPM pool path (`/rpm/x86_64/claude-desktop-${CLAUDE_VERSION}-${REPO_VERSION}-1.x86_64.rpm`), filename validation uses `rpm -qpi /tmp/smoke.rpm` instead of `file ... | grep Debian`, and the asset name in `gh release view` uses the RPM pattern.

## Phases

Each phase has a hard exit criterion. Don't progress until met.

### Phase 0 — Pre-work (manual, one-time)

**Infrastructure:**

- Register domain (~$10–15/yr) at a registrar that supports auto-renewal
- Configure auto-renewal with a payment method that won't expire in the next 5 years
- Create Cloudflare account (or audit existing one); add domain with proxied DNS

**Bus factor — accepted risk, with mitigations** (replacing the earlier "≥2 maintainers reachable" requirement, which was unrealistic for a solo-maintained project):

The honest reality: `@aaddrick` is the sole maintainer for everything outside cowork (`@RayCharlizard`) and nix (`@typedrat`). Neither collaborator is a candidate for shared Cloudflare or registrar credentials, and pretending otherwise is checklist theatre. So the bus factor is 1, and the mitigation strategy is to **make recovery from a future maintainer's loss tractable**, not to fictionally distribute credentials today:

- **Email forwarding:** Cloudflare account and registrar email both forward to a personal backup mailbox (e.g., a Gmail filter rule into a separate folder), so account-recovery emails don't land in a dead inbox if the primary mail provider becomes unreachable
- **Auto-renewal:** registrar configured with auto-renew on a credit card that doesn't expire in the next 5 years
- **CI-only deploys:** `wrangler` credentials live as repo secrets (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`), never on a single workstation. Deploys happen via CI from any pushed commit, not from `aaddrick`'s laptop. This eliminates the "lost workstation" failure mode without requiring a second human
- **Recovery runbook:** `docs/learnings/apt-worker-architecture.md` (created in Phase 5) documents which Cloudflare account and which registrar own what, plus exact steps for a future maintainer to take over (rotate API token, point registrar contact at new email, update DNS if migrating accounts)

**Cloudflare API token scopes** (for the `CLOUDFLARE_API_TOKEN` repo secret):

- `Account.Workers Scripts:Edit` — required to deploy Worker code
- `Zone.Workers Routes:Edit` — required to bind the Worker to `apt.<domain>/*`
- `Zone.Zone:Read` — required by `wrangler` to enumerate zones during deploy

A token missing `Workers Routes:Edit` will deploy the Worker successfully but fail silently to bind the route — the Worker will exist but receive no traffic. Phase 3's post-deploy probe catches this.

**`wrangler.toml` shape** (committed in `worker/`):

```toml
name = "claude-desktop-apt-redirect"
main = "src/worker.js"
compatibility_date = "2026-04-22"
account_id = "<from CLOUDFLARE_ACCOUNT_ID secret at deploy time>"

routes = [
  { pattern = "apt.<domain>/*", zone_name = "<domain>" }
]
```

**TOS review (completed during planning, no action needed):**

- Cloudflare's old "Section 2.8" (no non-HTML content on free plans) was removed [in October 2025](https://blog.cloudflare.com/updated-tos/)
- Our pattern only routes redirect responses through Cloudflare. Binary bytes flow directly from `objects.githubusercontent.com` to the user; Cloudflare never sees the `.deb` bytes
- Reselling / proxying-as-service restrictions don't apply (we're not providing service to third parties; we're routing our own users to our own binaries)
- **Conclusion:** no known TOS conflict for this use case. `pkg.cloudflare.com` is a Cloudflare-owned precedent and not a guarantee that third-party use is blessed; if Cloudflare ever suspends the account, the documented fallback (split-package or commercial CDN) is the recovery path

**GitHub Releases dependency review (completed during planning):**

- Release asset URL format `/releases/download/<tag>/<asset>` is documented as stable
- `Content-Disposition` headers are NOT guaranteed stable — irrelevant to us (we use the URL path)
- Auto-generated source code zip URLs are unstable — irrelevant (we don't use those)
- Unauthenticated per-IP rate limits on `*.githubusercontent.com` rolled out in 2025; users don't share a quota
- Per-account egress throttling can return 503 under unusual load — heartbeat (Phase 5) catches this

Exit: domain resolves through Cloudflare; auto-renewal configured; account email forwards to backup mailbox; `CLOUDFLARE_API_TOKEN` (with all three required scopes) + `CLOUDFLARE_ACCOUNT_ID` stored as repo secrets; `worker/wrangler.toml` drafted.

### Phase 1 — Worker dev (locally, no production traffic)

- Worker code in a new top-level `worker/` directory (will be CI-deployed in later phases)
- `wrangler dev` runs locally
- `curl localhost:8787/dists/stable/InRelease` returns gh-pages content unchanged
- `curl -L localhost:8787/pool/main/c/claude-desktop/claude-desktop_1.3561.0-2.0.1_amd64.deb` lands on the actual published `.deb` via the 302 chain
- `curl -L localhost:8787/rpm/x86_64/claude-desktop-1.3883.0-2.0.2-1.x86_64.rpm` lands on the actual published `.rpm` (the v2.0.2 release already has RPM assets, so this is verifiable today)

Exit: both `curl` checks succeed against the previously-published version; RPM regex confirmed against the real `-1` release-numbered filename format.

### Phase 2 — Test domain validation (broad container matrix)

- Deploy Worker to `apt-test.<domain>/*`, no production traffic
- Container matrix expanded beyond happy-path distros to catch real-world configurations:

| Container | Why |
|---|---|
| `debian:stable` | Baseline |
| `ubuntu:lts` | Baseline |
| `debian:testing` | Catches early apt regressions |
| `fedora:latest` | DNF baseline |
| `rockylinux:9` | RHEL-family compat |
| `debian:stable` + `apt-cacher-ng` | Caching proxy in front of apt — RFC says don't cache 302s, in practice some configs do |
| `debian:stable` --network with IPv6-only | Confirm `apt.<domain>` and `objects.githubusercontent.com` resolve AAAA |

For each container, drop a temporary `sources.list` pointing at `apt-test.<domain>`, run `apt update && apt install claude-desktop` (or DNF equivalent). Specifically validate a `.deb > 100 MB` install (use 1.3883.0).

**`apt-secure` origin-change check** — requires a **two-step run** because `apt` only emits the "changed its 'Origin'" warning when comparing against a previously-cached state. A fresh container has no prior origin recorded, so the warning never fires regardless of behavior. The check has to establish baseline first, then change URL, then re-update:

```bash
# Step 1: install with the original github.io URL (current state),
# capture the cached origin
echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg] https://aaddrick.github.io/claude-desktop-debian stable main" \
  > /etc/apt/sources.list.d/claude-desktop.list
apt-get update

# Step 2: switch sources.list to the test custom domain directly
echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg] https://apt-test.<domain> stable main" \
  > /etc/apt/sources.list.d/claude-desktop.list

# Step 3: re-update with debug; this is when the warning would surface
apt-get update -o Debug::Acquire::http=true 2>&1 \
  | tee /tmp/apt-debug.log
grep -iE "changed its '(Origin|Label|Suite|Codename)'|expected entry.*not found|not signed" /tmp/apt-debug.log \
  && { echo "FAIL: apt-secure surfacing warnings"; exit 1; }
```

In our specific case the `Origin:` field comes from reprepro's `conf/distributions` and is unchanged across the redirect (Worker passes metadata through). The warning is unlikely to fire — but worth verifying because *any* signed-metadata mismatch surfaces the same way and the cost of testing is low.

If origin-change warnings appear, the README must document the fix (typically: re-add the source with the new URL or refresh `signed-by=`). Do not proceed to Phase 3 with this unresolved.

Exit: all containers install successfully with the >100 MB `.deb`; no `apt-secure` warnings on stable / LTS distros after the two-step URL change.

### Phase 3 — CI plumbing PR (NOT YET ENABLING THE PRODUCTION DOMAIN)

- PR adds the Worker source under `worker/` with `wrangler.toml` (route bound to staging `apt-test.<domain>/*` initially), and a CI workflow `.github/workflows/deploy-worker.yml` that runs `wrangler deploy` on push to `main` when `worker/**` changes. Workflow needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` repo secrets
- PR adds the **liveness-probed** strip step (`curl -fsI` against `https://${WORKER_DOMAIN}/dists/stable/InRelease`) to both `update-apt-repo` and `update-dnf-repo`. Gating mechanism: the destructive `find ... -delete` runs only if the probe succeeds. Before Phase 4a, the production Worker doesn't exist, so the probe fails harmlessly and binaries stay in pool. After Phase 4a, the probe succeeds and binaries get stripped. **No env-var gating** — the gate is the actual reachability of the production endpoint
- PR adds smoke-test step (deb + rpm versions) to each repo-update job, also implicitly gated by Worker existence
- PR adds a **post-Worker-deploy probe** to `deploy-worker.yml` that confirms the Worker received the update and the route resolves: `curl -fsI https://apt-test.<domain>/dists/stable/InRelease` (against the staging route during this phase)

Manually trigger CI on a test tag (e.g., `v0.0.0-test+claude0.0.0`) to confirm:
- Worker deploys to staging route successfully
- Strip step *does not* fire (because production Worker isn't live yet)
- Push to gh-pages succeeds with `.debs` still in pool (current behavior, just adds the new probes/steps idempotently)

Exit: CI green on test tag; staging Worker deployed and reachable; strip step correctly skips because production probe fails; smoke test correctly skips or runs against staging successfully.

### Phase 4a — Production Worker provisioning (gh-pages binaries as cold standby)

The critical insight from contrarian review: **don't strip `.deb`s from gh-pages until the Worker path is proven live in production.** Otherwise there's a guaranteed user-visible outage between strip and Worker enable.

- Add `CNAME` file to `gh-pages` root containing `apt.<domain>` (Pages settings UI)
- Wait for Let's Encrypt cert provisioning. Typical: ~1h. Edge cases: 24h+ for DNS CAA records, registrar propagation delays, Let's Encrypt rate limits. Monitor in Pages settings UI
- Update `wrangler.toml` route from staging (`apt-test.<domain>/*`) to production (`apt.<domain>/*`) and merge — CI deploys the Worker to the production route
- **Important correction from earlier draft:** once the CNAME is live, GitHub Pages auto-301s **all** `aaddrick.github.io/claude-desktop-debian/...` traffic to `apt.<domain>/...`. So the "direct path" via github.io is no longer directly serving — the auto-301 makes the Worker the active path for all traffic. The `.deb`s remaining in gh-pages are not actively serving most users; they exist as a **cold standby for rollback only** (if we unbind the Worker route, gh-pages still has the binaries to serve directly via the github.io URL, since CNAME removal stops the auto-301)
- Validation, on each container in Phase 2's matrix: clean install with original `sources.list` succeeds via the Worker chain
- Validation: `curl -IL https://aaddrick.github.io/claude-desktop-debian/dists/stable/InRelease` shows the 301 chain landing on the custom domain

Exit: clean container installs succeed via the new Worker path with original `sources.list` URLs; cert is valid and stable for ≥24h; rollback path (unbind Worker → traffic flows direct to gh-pages binaries) verified by briefly toggling the Worker route off in a maintenance window and confirming a clean container still installs.

### Phase 4b — Atomic cutover

No PR-merge required for the gating flip — the strip step's liveness probe automatically activates once Phase 4a's production Worker is live. The cutover step is just **triggering a release that exercises the new path end-to-end**:

- Re-run the v2.0.2+claude1.3883.0 `update-apt-repo` and `update-dnf-repo` jobs (or tag a follow-on release)
- The strip step's liveness probe now succeeds (production Worker is live), so binaries get stripped from pool before commit
- The push to gh-pages succeeds with metadata-only tree
- Smoke test passes (ordered chain validation, size match against Releases asset)
- Container test on clean `debian:stable` with original `sources.list` runs `apt update && apt install` and gets v2.0.2

Exit: failed run from issue #493 succeeds; v2.0.2+claude1.3883.0 reaches apt users.

### Phase 5 — Documentation, monitoring, follow-up

- README install snippet still works as-is (no URL change required); mention the new domain as canonical going forward in a "preferred URL" note
- New `docs/learnings/apt-worker-architecture.md` describing:
  - The redirect chain
  - Worker config and deploy mechanism
  - Credential ownership map (which email owns Cloudflare, which owns the registrar, where `wrangler` token lives)
  - What to do when the heartbeat workflow fails
- CLAUDE.md mention under "CI/CD" or new "Distribution" section
- **Cloudflare Workers Analytics alert** (free, configured via dashboard): error rate >1% sustained for 15 min, request rate >80% of free tier
- **Heartbeat workflow** (`.github/workflows/apt-repo-heartbeat.yml`): daily cron walks **both** the `.deb` and `.rpm` chains (matrix strategy, parallel, independent failure tracking per format), **opens a tracking issue on failure** with a format-specific label (and auto-closes on next success). Pure cron-failure surfacing isn't enough — GitHub doesn't email-notify on scheduled workflow failures by default, and most maintainers have those notifications filtered. An open issue is visible from the repo's home page

Heartbeat sketch:

```yaml
name: APT/DNF Repo Heartbeat
on:
  schedule:
    - cron: '0 12 * * *'  # daily noon UTC
  workflow_dispatch:
permissions:
  contents: read
  issues: write  # required for issue creation/comment on failure
jobs:
  ping:
    strategy:
      fail-fast: false  # if deb fails, still test rpm
      matrix:
        format: [deb, rpm]
    runs-on: ubuntu-latest
    env:
      WORKER_DOMAIN: apt.<domain>
      GH_TOKEN: ${{ github.token }}
    steps:
      - name: Resolve latest release for ${{ matrix.format }}
        id: latest
        run: |
          tag=$(gh release list --limit 1 --json tagName --jq '.[0].tagName' \
                  --repo aaddrick/claude-desktop-debian)
          repoVer=${tag#v}; repoVer=${repoVer%+claude*}
          claudeVer=${tag#*+claude}
          if [[ "${{ matrix.format }}" == "deb" ]]; then
            asset="claude-desktop_${claudeVer}-${repoVer}_amd64.deb"
            url="https://aaddrick.github.io/claude-desktop-debian/pool/main/c/claude-desktop/${asset}"
          else
            asset="claude-desktop-${claudeVer}-${repoVer}-1.x86_64.rpm"
            url="https://aaddrick.github.io/claude-desktop-debian/rpm/x86_64/${asset}"
          fi
          {
            echo "tag=$tag"
            echo "repoVer=$repoVer"
            echo "claudeVer=$claudeVer"
            echo "asset=$asset"
            echo "url=$url"
          } >> "$GITHUB_OUTPUT"

      - name: Validate chain + fetch
        run: |
          # Same hop-by-hop walk as the smoke test in update-{apt,dnf}-repo,
          # asserts ordered chain (Pages 301 → Worker 302 → objects.githubusercontent.com)
          # + size match against the Releases asset for ${{ steps.latest.outputs.asset }}.
          # Validator differs by format:
          #   deb: file /tmp/x | grep -q 'Debian binary package'
          #   rpm: rpm -qpi /tmp/x

      - name: Open or update failure issue
        if: failure()
        uses: actions/github-script@v7
        env:
          FORMAT: ${{ matrix.format }}
        with:
          script: |
            const fmt = process.env.FORMAT;
            const label = `heartbeat-failure-${fmt}`;
            const title = `APT/DNF repo heartbeat failing (${fmt})`;
            const body_url = `${process.env.GITHUB_SERVER_URL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`;
            const open = await github.rest.issues.listForRepo({
              owner: context.repo.owner, repo: context.repo.repo,
              labels: label, state: 'open',
            });
            const body = `Heartbeat failed for \`${fmt}\` at ${new Date().toISOString()}.\nRun: ${body_url}`;
            if (open.data.length === 0) {
              await github.rest.issues.create({
                owner: context.repo.owner, repo: context.repo.repo,
                title, body, labels: [label],
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner, repo: context.repo.repo,
                issue_number: open.data[0].number, body,
              });
            }

      - name: Auto-close failure issue on recovery
        if: success()
        uses: actions/github-script@v7
        env:
          FORMAT: ${{ matrix.format }}
        with:
          script: |
            const fmt = process.env.FORMAT;
            const label = `heartbeat-failure-${fmt}`;
            const open = await github.rest.issues.listForRepo({
              owner: context.repo.owner, repo: context.repo.repo,
              labels: label, state: 'open',
            });
            for (const issue of open.data) {
              await github.rest.issues.createComment({
                owner: context.repo.owner, repo: context.repo.repo,
                issue_number: issue.number,
                body: `Heartbeat for \`${fmt}\` recovered at ${new Date().toISOString()}; auto-closing.`,
              });
              await github.rest.issues.update({
                owner: context.repo.owner, repo: context.repo.repo,
                issue_number: issue.number, state: 'closed',
              });
            }
```

Format-specific labels (`heartbeat-failure-deb`, `heartbeat-failure-rpm`) prevent a recovering format from auto-closing the other format's still-open failure issue.

- **Mandatory follow-up PR**: one-time orphan-reset of `gh-pages` to address #449's clone-bloat backfill. Now safe because nothing important lives in gh-pages history (metadata is regenerated by reprepro/createrepo on every release; no binaries to lose)

## Test plan

Repeat at every phase boundary, on each container in the matrix.

**Debian/Ubuntu side:**

```bash
docker run --rm -it debian:stable bash -c '
  apt-get update && apt-get install -y curl gnupg file
  curl -fsSL https://aaddrick.github.io/claude-desktop-debian/KEY.gpg \
    | gpg --dearmor > /usr/share/keyrings/claude-desktop.gpg
  echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg] https://aaddrick.github.io/claude-desktop-debian stable main" \
    > /etc/apt/sources.list.d/claude-desktop.list
  apt-get update -o Debug::Acquire::http=true 2>&1 | tee /tmp/apt-debug.log
  # Note: this single-step check captures only Origin/Suite/Codename/Label
  # warnings on first update; for the full apt-secure check after URL change,
  # see Phase 2 two-step procedure
  grep -iE "changed its .(Origin|Suite|Codename|Label)." /tmp/apt-debug.log && exit 1 || true
  apt-get install -y claude-desktop
  dpkg -l claude-desktop
  dpkg -L claude-desktop | head
'
```

Plus `apt-cache policy claude-desktop` to confirm the version resolved, and an `apt-cacher-ng`-fronted variant of the same.

**Fedora/RHEL side:**

```bash
docker run --rm -it fedora:latest bash -c '
  dnf install -y curl rpm-build
  curl -fsSL -o /etc/yum.repos.d/claude-desktop.repo \
    https://aaddrick.github.io/claude-desktop-debian/claude-desktop.repo
  rpm --import https://aaddrick.github.io/claude-desktop-debian/KEY.gpg
  dnf --setopt=debuglevel=10 makecache 2>&1 | tee /tmp/dnf-debug.log
  # Surface any signature or repo-metadata mismatches that would surface
  # after a URL change
  grep -iE "(GPG check FAILED|repomd\.xml signature|metadata is outdated)" /tmp/dnf-debug.log \
    && exit 1 || true
  dnf install -y claude-desktop
  rpm -qi claude-desktop
  rpm -ql claude-desktop | head
'
```

`rockylinux:9` runs the same flow; `dnf` semantics are equivalent across the RHEL family.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Worker regex breaks on filename/tag scheme change | CI smoke test catches first regression; chain assertion is explicit, not silent |
| Cloudflare outage → repo unreachable | Heartbeat workflow surfaces; fast rollback in Phase 4b reverts to direct gh-pages serving (binaries 404 but metadata works); accept this as cost of single-vendor dependency |
| Cloudflare account suspension | TOS reviewed; redirect-only architecture means no large bandwidth attributed to the account; documented fallback (split-package or commercial CDN) if account is suspended |
| Hardened apt clients with `Acquire::http::AllowRedirect=false` | Document in README that this must remain `true` (the default); link from heartbeat-failure runbook |
| Custom domain cert provisioning slow/fails | Phase 4a explicitly waits for stable cert before Phase 4b; if it fails, Phase 4a doesn't exit and nothing breaks — `.deb`s still on gh-pages |
| Filename regex divergence between deb and rpm | Phase 1 dev with both filename samples in hand; both smoke tests in CI |
| Apt-secure origin-change warnings | Phase 2 explicit check with `Debug::Acquire::http=true`; do not exit Phase 2 with this unresolved |
| `apt-cacher-ng` caches 302 incorrectly | Phase 2 matrix entry; if regression, document workaround or flag as known issue |
| IPv6-only network breaks chain | Phase 2 matrix entry; both `apt.<domain>` and `objects.githubusercontent.com` must have AAAA records |
| Domain registrar lapse | Auto-renewal + secondary contact email + heartbeat catches |
| GitHub Releases per-account egress throttle (503) | Heartbeat catches; if persistent, consider authenticated CDN (rare in practice for desktop-app traffic) |
| GitHub changes Releases asset URL format | Smoke test catches first failed release; documented mitigation: update Worker `RELEASES` constant |
| Bus factor (single maintainer with all credentials) | Accepted risk for a solo-maintained project; mitigated via email-forwarding to backup mailbox, registrar auto-renewal, CI-only Worker deploys (no workstation dependency), and recovery runbook in `docs/learnings/apt-worker-architecture.md` for a future maintainer to take over |
| Worker free tier exhausted | Cloudflare Analytics alert at 80% threshold; daily cron is ~30 reqs/day, real apt traffic dominated by metadata polls (most return 304); upgrading is $5/mo for 10M+ reqs/day |

## Rollback strategy

If Phase 4b cutover causes user-visible breakage:

1. **Cold-standby restore via CNAME removal** (Pages settings, ~5 min): remove the CNAME file from `gh-pages`. github.io URL stops 301-ing. Apt fetches directly from gh-pages — and because the strip step's liveness probe targets the *production* Worker URL (which now no longer 301s into existence), future CI runs will see the probe fail and stop stripping binaries. The pre-Phase-4a `.deb`s still in gh-pages history serve direct-from-Pages until the next release re-pushes binaries
2. **Fast Worker disable** (Cloudflare dashboard, <1 min): unbind the Worker from `apt.<domain>/*`. Custom domain still resolves but Cloudflare returns Pages content directly. Useful for isolating "is this a Worker bug?" — but if the most recent release already stripped `.deb`s from gh-pages (Phase 4b succeeded), binary fetches still 404. Combine with #1 if user impact is ongoing
3. **Recovery if architecture is fundamentally broken**: rollback via #1, then accept that the next upstream growth triggers the original cap problem, and pursue one of the documented fallbacks (split-package, R2, commercial CDN)

The critical invariant: Phase 4a completing successfully (cert + Worker live + container tests pass with original `sources.list`) means Phase 4b is a low-risk *release trigger* (no PR-merge required — the strip step's liveness probe activates automatically once the production Worker is up). Phases 2 + 4a must catch issues before Phase 4b. Once 4b ships and the smoke test passes, the path forward from a regression is forward (fix Worker bug, push new release) or backward via rollback #1.

## Documented fallbacks (not the chosen path, kept for if this fails)

- **Splitting the `.deb` into multiple smaller packages with `Depends:` chains** — pure in-tree change, no external dependencies, no recurring costs. More invasive packaging refactor. Buys 6–12 months until a half crosses 100 MB. Real fallback if Cloudflare/GitHub-Releases dependency proves untenable
- **Migrating storage to Cloudflare R2** (the variant `pkg.cloudflare.com` uses) — full hosting in R2 instead of Releases. Larger CI change for marginal benefit given GitHub Releases already works as backend for our scale. Reasonable if we ever hit GitHub egress throttling regularly
- **Commercial package CDN (Cloudsmith, Packagecloud, JFrog Artifactory)** — outsources the same architecture, monthly fees ($20–100+/mo for proprietary). Use if we want a fully managed answer

## Out of scope

- AUR / Nix / AppImage / Snap / Flathub. Unaffected by this plan.

## Sources

- [Cloudflare Workers — limits and free tier](https://developers.cloudflare.com/workers/platform/limits/)
- [Cloudflare Workers — pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Goodbye, section 2.8 and hello to Cloudflare's new terms of service (Oct 2025)](https://blog.cloudflare.com/updated-tos/)
- [pkg.cloudflare.com — Cloudflare's own apt/yum repo, reference architecture](https://pkg.cloudflare.com/)
- [Using Cloudflare R2 as an apt/yum repository (Cloudflare blog)](https://blog.cloudflare.com/using-cloudflare-r2-as-an-apt-yum-repository/)
- [kdrag0n/github-releases-proxy — Worker proxying GitHub Release assets](https://github.com/kdrag0n/github-releases-proxy)
- [GitHub Pages: managing a custom domain (auto-301 from `*.github.io`)](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)
- [GitHub Docs: linking to releases (asset URL format stability)](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub Changelog: updated rate limits for unauthenticated requests](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/)
- [apt-transport-http(1) — `Acquire::http::AllowRedirect`](https://manpages.debian.org/testing/apt/apt-transport-http.1.en.html)
