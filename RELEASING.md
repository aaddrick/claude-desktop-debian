# Releasing

This project ships through tag-driven CI. A tag of the form `v{REPO_VERSION}+claude{CLAUDE_DESKTOP_VERSION}` on `main` triggers the release job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which builds for both architectures, attaches the artifacts to a GitHub Release, and updates the APT and DNF repositories (and AUR, when the `AUR_PUBLISH_ENABLED` repo variable isn't `false`).

There are two flavors of release:

- **Upstream-tracking retag.** A `check-claude-version` workflow runs daily, detects new Claude Desktop releases, bumps the `CLAUDE_DESKTOP_VERSION` repo variable, seds the `OFFICIAL_DEB_*` pins (version, pool paths, SHA-256) in `scripts/setup/official-deb.sh` and the SRI hashes in `nix/claude-desktop.nix`, and pushes a new tag with the same `REPO_VERSION` and a new `+claude{X.Y.Z}` suffix. **No human action required.** These do not get CHANGELOG entries — they're tracked in the tag suffix.
- **Project release.** You bumped `REPO_VERSION` because you shipped project changes. Follow the checklist below.

## Pre-release checklist

1. **CI is green on `main`.** All required workflows (CI, tests, shellcheck) passed on the commit you're about to tag.

   ```bash
   gh run list --branch main --limit 5
   ```

2. **`CHANGELOG.md` is updated.** The `[Unreleased]` section now reflects what you're about to ship. Move it under a new `[v{REPO_VERSION}]` heading with today's date.

3. **Local tests pass.**

   ```bash
   bats tests/*.bats scripts/cowork-fallback/tests/*.bats
   git grep -l '^#\( *shellcheck \|!\(/bin/\|/usr/bin/env \)\(sh\|bash\|dash\|ksh\)\)' -- '*.sh' \
     | xargs shellcheck -x
   ```

   These are the commands `tests.yml` and `shellcheck.yml` run. The shellcheck selector picks files with a shebang or a `# shellcheck` directive; a bare `scripts/**/*.sh` glob only recurses with `shopt -s globstar`. See [`CLAUDE.md`](CLAUDE.md#linting).

4. **AppImage artifact boots on a clean system.** The `test-artifacts.yml` reusable workflow already runs a `--doctor` smoke test against each format in CI (#592), but if you've touched the launcher or patch surface, build locally and confirm:

   ```bash
   ./build.sh --build appimage --clean no
   ./test-build/claude-desktop-*.AppImage --doctor
   ```

5. **The version variables are in sync.**

   ```bash
   gh variable list | grep -E '^(REPO_VERSION|CLAUDE_DESKTOP_VERSION)\s'
   grep -oP "^OFFICIAL_DEB_VERSION='\K[^']+" scripts/setup/official-deb.sh
   ```

   The pinned `OFFICIAL_DEB_VERSION` should match the `CLAUDE_DESKTOP_VERSION` variable. If not, pull the latest pins from `main` — the `check-claude-version` workflow may have updated them on `main` without rebasing your branch ([`CLAUDE.md`](CLAUDE.md#common-gotchas) has the recipe). This uses `gh variable list` because older `gh` releases lack `gh variable get`.

## Bumping and tagging

```bash
# 1. Bump the project version (this is a GitHub Actions variable, not a file).
gh variable set REPO_VERSION --body "X.Y.Z"

# 2. Tag the release commit on main with both versions in the tag name.
claude_ver=$(grep -oP "^OFFICIAL_DEB_VERSION='\K[^']+" scripts/setup/official-deb.sh)
git tag "vX.Y.Z+claude$claude_ver"

# 3. Push the tag to the canonical repo — this is what kicks off the
#    release build. That remote is `origin` on a direct clone, but on a
#    fork checkout `origin` is your fork (use `upstream` there).
git push upstream "vX.Y.Z+claude$claude_ver"
```

The `REPO_VERSION` variable bump can happen before or after the tag push; CI reads neither directly. The variable exists so future workflow runs know the current project version.

## What CI does on tag push

The [`release`](.github/workflows/ci.yml) job in `ci.yml` is gated on `startsWith(github.ref, 'refs/tags/v')`. After `test-flags`, `build-amd64`, `build-arm64`, and `test-artifacts` pass:

1. Downloads the build artifacts: six packages (amd64 + arm64, each in deb/rpm/AppImage), two AppImage `.zsync` delta files, and the transitional `claude-desktop_1.16000.0-1_all.deb` the amd64 leg produces.
2. Generates release notes from the commit log since the previous tag. The [`aaddrick/claude-desktop-versions`](https://github.com/aaddrick/claude-desktop-versions) checkout that used to feed upstream diffs has failed since that repo went private on 2026-07-24, and the AI `compare-releases` step is `if: false`; the step is `continue-on-error`, so neither blocks the release.
3. Creates the GitHub Release with those nine files, then uploads `reference-source.tar.gz`.
4. `mirror-official-deb` attaches the pinned official `claude-desktop_<ver>_<arch>.deb` for both architectures, for twelve assets in all.
5. Hands off to `update-apt-repo`, `update-dnf-repo`, and `update-aur-repo` (skipped while `AUR_PUBLISH_ENABLED` is `false`), which publish to the Cloudflare-fronted package repos ([`docs/learnings/apt-worker-architecture.md`](docs/learnings/apt-worker-architecture.md) for the redirect chain).

## After the release lands

- **Verify the Release page.** Twelve assets attached, sizes look right, release notes rendered. Then check the package repos serve the new version: `curl -fsS https://pkg.claude-desktop-debian.dev/dists/stable/main/binary-amd64/Packages | grep -A1 'Package: claude-desktop-unofficial' | grep -oP 'Version: \K.*' | sort -V | tail -1` should print it, and the pool `Filename` should 302 to the release asset.
- **Smoke-test one artifact.** Download the AppImage and run `--doctor` against it.
- **Watch `apt-repo-heartbeat`.** The next daily run validates the redirect chain end-to-end. If it opens a tracking issue, walk the chain in [`docs/learnings/apt-worker-architecture.md`](docs/learnings/apt-worker-architecture.md#heartbeat-failure-runbook).

## If something goes wrong mid-release

- **A tag build fails.** See [A tag build fails](#a-tag-build-fails) below.
- **A bad release shipped.** Mark the GitHub Release as a pre-release / draft and ship a follow-up. Don't delete artifacts that may already be cached by the APT/DNF Worker.
- **The `check-claude-version` workflow conflicts with your local branch.** Pull pin changes from `main` before pushing your tag — the workflow autobumps `scripts/setup/official-deb.sh` between your work and your tag.

### A tag build fails

CI opens (or appends to) an issue labelled `release-failure` titled `Tag build failed: <tag>` whenever any job in the tag chain fails, with the failed job names and the run link. Nobody has to watch the Actions tab. Work the issue like this:

1. **Read the failed job's log through the API, not `gh run view --log-failed`.** The build legs are reusable-workflow jobs and `--log-failed` prints nothing for them. Use `gh api repos/aaddrick/claude-desktop-debian/actions/jobs/<job-id>/logs` (job ids from `gh api .../actions/runs/<run-id>/jobs`).
2. **`Failed to download …/claude-desktop_<ver>_<arch>.deb` is pool lag.** The official `Packages` index lists a file minutes before the CDN serves it. The build now retries for a few minutes and `check-claude-version` won't tag until both files answer a HEAD 200, so this should be rare; if it still happens, re-run the failed jobs from the Actions UI once `curl -sI <url>` returns 200. Re-running keeps the tag.
3. **Anything else:** push the fix to `main`, then re-tag with a new `+claude` suffix (or a `+rebuild.N` suffix if upstream hasn't moved). The original tag stays — releases are append-only, and tooling may already reference it.
4. **Upstream moved on before you got to it** (a `<ver+1>` tag built and released): close the issue noting it's superseded. The orphan tag stays for the same reason.

Close the issue by hand once the tag has a release; nothing auto-closes it.
