# Bug Report: DNS resolver not configured in Claude Code on the web environment

## Summary

The `/etc/resolv.conf` file is empty in Claude Code on the web sessions, causing DNS resolution to fail. This prevents `apt-get` from installing packages even though the required domains (e.g., `archive.ubuntu.com`) are on the allowlist.

## Environment

- Platform: Claude Code on the web (research preview)
- Session type: Remote (`CLAUDE_CODE_REMOTE=true`)
- Date: 2026-01-26

## Expected Behavior

DNS resolution should work for allowlisted domains. According to the documentation, these domains are allowed by default:
- `archive.ubuntu.com`
- `security.ubuntu.com`
- `*.ubuntu.com`
- `ppa.launchpad.net`

Package installation via `apt-get` should succeed for these domains.

## Actual Behavior

DNS resolution fails because `/etc/resolv.conf` is empty:

```bash
$ cat /etc/resolv.conf
# (empty - 0 bytes)

$ file /etc/resolv.conf
/etc/resolv.conf: empty

$ getent hosts archive.ubuntu.com
# (fails silently)
```

This causes `apt-get update` and `apt-get install` to fail:

```
W: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease  Temporary failure resolving 'archive.ubuntu.com'
E: Failed to fetch http://archive.ubuntu.com/ubuntu/pool/universe/s/shellcheck/shellcheck_0.9.0-1_amd64.deb  Temporary failure resolving 'archive.ubuntu.com'
```

## Impact

- **SessionStart hooks** that use `apt-get` to install dependencies fail
- Users cannot install additional packages via apt
- Tools like `shellcheck`, `gh` (GitHub CLI), and other apt packages cannot be installed
- Workarounds exist for some tools (direct binary downloads), but not for all

## Workaround

Tools that can be installed via direct binary download (like `actionlint` from GitHub releases) work because `curl` appears to use a different resolution path or has cached DNS results.

## Steps to Reproduce

1. Start a Claude Code on the web session
2. Run: `cat /etc/resolv.conf` (observe it's empty)
3. Run: `getent hosts archive.ubuntu.com` (observe it fails)
4. Run: `sudo apt-get update` (observe DNS resolution errors)

## Additional Context

- Network connectivity works when using direct IPs: `curl --resolve archive.ubuntu.com:80:91.189.91.82 http://archive.ubuntu.com/` succeeds
- The issue is specifically DNS resolution, not network connectivity or domain blocking
- The security proxy documentation states "All outbound internet traffic passes through this proxy" but doesn't mention DNS handling

## Suggested Fix

Ensure `/etc/resolv.conf` is properly configured with DNS nameservers before the session starts, or configure the system to use the proxy for DNS resolution.

---
Written by Claude Opus 4.5 via [Claude Code](https://claude.ai/code)
