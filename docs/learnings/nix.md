# NixOS / Nix Flake Learnings

The Nix derivation is a deliberate `throw` stub on the v3.0.0
official-deb branch — every `nix build .#claude-desktop` (and the
default `.#claude-desktop-fhs`) fails at eval until the official-deb
rework lands (owner @typedrat). The stub's comment block carries the
target design; this page expands it and preserves the resource-path
knowledge from the deleted Windows-pipeline derivation so nobody
re-introduces the hack it needed.

**Source files:**

- [`nix/claude-desktop.nix`](../../nix/claude-desktop.nix) — the stub;
  its comment block is the design contract
- [`nix/fhs.nix`](../../nix/fhs.nix) — `buildFHSEnv` wrapper, still the
  flake's default output
- [`flake.nix`](../../flake.nix) — outputs and overlay wiring
- [`scripts/setup/official-deb.sh`](../../scripts/setup/official-deb.sh)
  — the pinned URL + SHA-256 the derivation will mirror
- [`.github/workflows/check-claude-version.yml`](../../.github/workflows/check-claude-version.yml)
  — the stub-guarded SRI auto-bump step

## Current state (v3.0.0 branch)

- `nix/claude-desktop.nix` is `{ lib }: throw ...`. The throw message
  is the user-facing error; it points at the recovery command below.
- The Windows-installer derivation (7z-extract the exe, stock nixpkgs
  Electron, hand-built co-located resources tree, node-pty build) was
  deleted in the acquisition swap. Recover it from history:

  ```bash
  git log --oneline -- nix/claude-desktop.nix
  ```

- `flake.nix` is decoupled from node-pty; `nix/node-pty.nix` was
  deleted. The official `.deb` ships its own native bindings, so
  nothing in the flake compiles node modules anymore.
- The flake outputs and overlay are still wired (`claude-desktop`,
  `claude-desktop-fhs`, default = FHS env), so replacing the stub with
  a real derivation needs no `flake.nix` changes.
- `check-claude-version` has an "Update Nix SRI hashes" step that is
  **stub-guarded**: it skips cleanly while the file has no
  `version = "..."` line, and starts auto-bumping the moment the real
  derivation lands (see below).

## Target design for the rework

Per the stub comment and
[`official-deb-rebase-verification.md`](official-deb-rebase-verification.md):

- **`fetchurl` the official `.deb`** from the official APT pool
  (`https://downloads.claude.ai/claude-desktop/apt/stable/pool/...`).
  The SRI hash comes from the APT `Packages` index — authoritative, no
  download needed to compute it. The pins in
  `scripts/setup/official-deb.sh` (`OFFICIAL_DEB_POOL_*`,
  `OFFICIAL_DEB_SHA256_*`) are the same values in hex form.
- **Unpack and `autoPatchelfHook` the official co-located tree.**
  nixpkgs precedent: `signal-desktop`, `slack` — both repackage a
  vendor `.deb` around a bundled Electron/Chromium ELF. The official
  tree is bare co-located
  (`/usr/lib/claude-desktop/{claude-desktop, chrome-sandbox,
  resources/app.asar}`), so the derivation patches the shipped ELF
  instead of marrying the app to a nixpkgs `electron`.
- **No resourcesPath hack.** The official ELF already sits next to its
  `resources/` directory; `/proc/self/exe` resolves inside the app's
  own store path. See the retained section below for why this used to
  be the hard part.
- **`buildFHSEnv` (`nix/fhs.nix`) stays the default output.** MCP
  servers spawned by the app expect an FHS world (`nodejs`, `uv`,
  `docker`, ...); that rationale is unchanged from the Windows era.
- **The FHS env must bind-provide OVMF firmware at the probed path.**
  Cowork's firmware probe list is hardcoded with no env override:
  x86_64 → `/usr/share/OVMF/OVMF_CODE_4M.fd`,
  `/usr/share/OVMF/OVMF_CODE.fd`; arm64 →
  `/usr/share/AAVMF/AAVMF_CODE.fd`. The RPM grew compat symlinks for
  this (CW-1); the Nix-side fix rides this derivation rework.
  `nix/fhs.nix` does not provide OVMF today — whether the right shape
  is an edk2 package in `targetPkgs` (if buildFHSEnv surfaces its
  `share/` at the probed path) or explicit symlinks, the spike will
  decide.

Open questions the spike will settle: whether `autoPatchelfHook`
covers the full dependency surface of the official Electron ELF plus
the bundled helpers (`virtiofsd`, `chrome-native-host`; `coworkd` is
static Go and needs nothing), and whether `chrome-sandbox` SUID is
handled via the FHS env or dropped in favor of user namespaces.

### The SRI auto-bump contract

Once the stub is replaced, `check-claude-version` expects this shape
(from the workflow's sed anchors):

```nix
version = "1.18286.0";
# one hash per arch block, each closed by };
x86_64-linux = { url = "..."; hash = "sha256-..."; };
aarch64-linux = { url = "..."; hash = "sha256-..."; };
```

The workflow converts the Packages-index hex digest to SRI
(`xxd -r -p | base64`) and range-seds each arch block. Diverge from
this shape and the auto-bump silently rewrites the wrong hash — keep
exactly one `hash = "..."` per arch block.

## glibc floors the derivation inherits

From objdump on the official 1.18286.0 tree: the main Electron ELF
needs glibc **2.25**; `virtiofsd` and `chrome-native-host` need
**2.34** (matching the official `libc6 (>= 2.34)` Depends); `coworkd`
is static. On Nix this is mostly moot (nixpkgs glibc is well past
2.34), but it is the support boundary for anyone pinning an old
nixpkgs: the core app is more portable than the Depends line suggests,
and Cowork/browser-bridge are the 2.34-bound parts.

## Why the resourcesPath hack existed — and why it must not return

Kept from the Windows-pipeline era. The old derivation's central
problem is gone, but only because of how the official tree is laid
out — this section is the guard against reintroducing the hack (or
the failure it fixed) in the rework.

**The old problem:** the Windows-era derivation ran the app under the
nixpkgs `electron` package, so Electron and the app lived in separate
Nix store paths. Chromium computes `process.resourcesPath` from
`/proc/self/exe`, which resolved to `electron-unwrapped`'s store path;
the app's locale files, tray icons, and other resources lived
elsewhere and weren't found.

**`/proc/self/exe` resolves symlinks.** This is why `symlinkJoin` and
symlink-based trees don't work: the kernel follows symlinks to the
real binary, so `resourcesPath` always pointed at
`electron-unwrapped`'s directory. The only fix was a real copy of the
ELF into a tree that also contained the merged `resources/` (PR
[#368](https://github.com/aaddrick/claude-desktop-debian/pull/368)).

**The ENOENT was JS, not C++.** The `isPackaged=true` failure was
`readFileSync` loading `en-US.json` from `process.resourcesPath` at
module top-level in the minified bundle — before any wrapper could
correct the path. Claude Desktop is unusual among Electron apps in
loading locale JSONs from `resourcesPath` at module init with no
fallback, which is why the standard nixpkgs
`makeWrapper electron --add-flags app.asar` pattern (Signal, Obsidian,
Vesktop) was never enough here.

**There is no override.** No Electron env var or CLI flag overrides
`resourcesPath`; a `--resources-path` PR
([electron/electron#36114](https://github.com/electron/electron/pull/36114))
was closed in Nov 2025 over security concerns, and the property was
made read-only in Electron 28.2.1.

**Why it's moot now:** the official `.deb` ships its own Electron ELF
bare co-located with `resources/` in one tree. The derivation copies
that tree into a single store path and patches the ELF in place, so
`/proc/self/exe` resolves inside the app's own tree and
`resourcesPath` is correct by construction. No nixpkgs `electron`, no
ELF-copy-plus-symlink-merge, no wrapper surgery. If a future rework is
ever tempted to swap the bundled ELF for a nixpkgs `electron` (e.g.
for CVE turnaround), this whole section becomes load-bearing again —
that path requires the PR #368 tree-merge technique, and the locale
JSONs (shipped loose in the official tree) are the first thing to
break.

One related constraint survives unchanged: the Nix store is
read-only, so any file-layout fix (firmware symlinks, resource
merges) must happen at build time in the derivation or via the FHS
env's bind layer — never "at runtime, add a symlink into the store."

## Testing Nix changes without NixOS

Kept from the Windows-pipeline era; the technique is unchanged.

A Fedora distrobox with the Nix package manager (Determinate Systems
installer, `--init none` for no-systemd containers) can build and run
the flake. The derivation produces identical store paths whether built
on NixOS or standalone Nix. Start the daemon manually with
`sudo nix-daemon &` before building.

This validates build success and basic app startup, but is not a
substitute for real NixOS testing (system integration, desktop
environment, Cowork's KVM path). Note that until the @typedrat rework
lands, any `nix build` in any environment fails at eval with the
stub's throw message — that is the expected state, not a local setup
problem.

## References

- [`official-deb-rebase-verification.md`](official-deb-rebase-verification.md)
  — install-layout facts (bare co-located tree, OVMF probe list, glibc
  floors, per-arch dependency contract)
- [`cowork-vm-daemon.md`](cowork-vm-daemon.md) — the Cowork VM daemon
  that consumes the OVMF firmware
- [#368](https://github.com/aaddrick/claude-desktop-debian/pull/368) —
  the old ELF-copy resourcesPath fix (historical)
- [electron/electron#36114](https://github.com/electron/electron/pull/36114)
  — the rejected `--resources-path` override
