# Cowork bwrap fallback (parked)

Reference code for a non-KVM Cowork backend, unwired from the build since
the v3.0.0 rebase onto Anthropic's official Linux `.deb`.

v3.0.0 ships Cowork exactly as upstream does: coworkd (Go) + QEMU/KVM over
a `SO_PEERCRED` Unix socket, with doctor checks explaining missing-KVM
hosts. Reviving a bubblewrap fallback against the official client means
impersonating coworkd's undocumented socket protocol, which is a separate
3.1 investigation (owner @RayCharlizard) behind a binary-dispatcher design
— no asar patching. See
[`docs/learnings/official-deb-rebase-verification.md`](../../docs/learnings/official-deb-rebase-verification.md)
and the rebase ADR for the decision trail.

Contents:

- `cowork-vm-service.js` — the bwrap-backed VM-service daemon that
  impersonated the Windows VM service for the repackaged client.
- `cowork.sh` — the asar patch (`patch_cowork_linux`) that rerouted the
  app's TypeScript VM client to the daemon socket. Anchors were written
  against the Windows-repackage bundle and need re-verification against
  official bytes.
- `tests/` — the bats suites for the daemon (backend detection, bwrap
  config, guest-path translation). Run from the repo root:
  `bats scripts/cowork-fallback/tests/`.

Nothing here is executed, installed, or patched into any artifact.
