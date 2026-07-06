# Cowork bwrap fallback (opt-in)

A non-KVM Cowork backend for hosts that can't run the official KVM
microVM. Wired into the build as the `patch_cowork_bwrap` asar patch,
but dormant unless the user launches with `COWORK_VM_BACKEND=bwrap`.

The official v3.x client runs Cowork as coworkd (Go) + QEMU/KVM over a
`SO_PEERCRED` Unix socket, gated on `/dev/kvm` + `/dev/vhost-vsock`.
Hosts like ChromeOS Crostini block `vhost_vsock` at the kernel level and
can never pass that gate ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772)).
This backend impersonates the helper's socket protocol and backs it with
bubblewrap instead of QEMU.

## How it's wired

- **`cowork-vm-service.js`** — the daemon. Speaks the official helper's
  length-prefixed-JSON socket protocol (see [`PROTOCOL.md`](PROTOCOL.md))
  and dispatches to a bwrap/host/kvm backend. Shipped to `resources/`
  (next to `app.asar`, i.e. `process.resourcesPath`) by `patch_app_asar`
  when the patch is active — outside the asar because `child_process`
  can't exec from inside one, and outside `app.asar.unpacked` to keep
  the repack invariant pinned to upstream's set.
- **`../patches/cowork-bwrap.sh`** (`patch_cowork_bwrap`) — the asar
  patch. Three flag-gated injections: report the KVM support evaluator
  as `supported`, swap the native-helper spawn for
  `node cowork-vm-service.js -socket <path>`, and suppress the unused
  VM-image download. Every branch requires
  `process.env.COWORK_VM_BACKEND==="bwrap"`, so on unflagged launches
  every branch evaluates false and the official path runs unchanged.
- **launcher** (`setup_cowork_bwrap_env` in `launcher-common.sh`) —
  resolves a system `node`/`nodejs` and exports `COWORK_NODE_PATH` for
  the patched spawn, since the official Electron binary has the
  RunAsNode fuse off and can't run the daemon itself.
- **`tests/`** — bats suites for the daemon (backend detection, bwrap
  config, guest-path translation). Run from the repo root:
  `bats scripts/cowork-fallback/tests/`.

## Protocol note

`PROTOCOL.md` is the wire contract extracted from the official bundle
(`build-reference/app-extracted/.vite/build/index.js`). When upstream
reshapes the helper protocol, re-derive it there and re-verify the
daemon against it — the daemon's job is to be a drop-in for whatever the
current client dials.
