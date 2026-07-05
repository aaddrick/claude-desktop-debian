# Upstream report draft: Cowork virtiofsd probe (issues #771/#772)

This is the upstream bug report covering [#771](https://github.com/aaddrick/claude-desktop-debian/issues/771) and [#772](https://github.com/aaddrick/claude-desktop-debian/issues/772). **FILED 2026-07-05 as [anthropics/claude-code#74605](https://github.com/anthropics/claude-code/issues/74605)** (Claude Desktop has no in-app engineering report path — see the filing-path note in [`README.md`](README.md)).

## Template mismatch note

The `anthropics/claude-code` bug template is built for the Claude Code CLI, not Claude Desktop. Fields like "Claude Code Version" and "Terminal/Shell" don't apply cleanly. Other Claude Desktop reports in the same repo work around this by putting `N/A — Claude Desktop <version>` in the version field and selecting `Other` for terminal (see #43705, #36319, #14807).

## Title

```
[BUG] Claude Desktop for Linux 1.18286.0: Cowork "requires QEMU" on hosts where the full KVM stack is installed — virtiofsd probe checks two paths and gates the bundled fallback to Ubuntu 22 only
```

## Form fields

### Preflight Checklist

- [x] I have searched existing issues and this hasn't been reported yet
- [x] This is a single bug report
- [x] I am using the latest version of Claude Code

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian), which repackages the official Linux `.deb` into RPM/AppImage/Nix/AUR formats. Two of our users hit the same Cowork failure on machines with a complete, healthy KVM stack, so I read the bundle to find the cause.

Cowork's support evaluator resolves `virtiofsd` from exactly two absolute paths: `/usr/libexec/virtiofsd`, then `/usr/bin/virtiofsd`. It checks each with `fs.access` for read access. There's no PATH search. When neither resolves, it falls back to the bundled copy at `process.resourcesPath/virtiofsd` **only** when `/etc/os-release` reports `ID=ubuntu` and `VERSION_ID` starting with `22.`. On anything else, `virtiofsdPath` stays null.

With a null `virtiofsdPath`, the evaluator (feature key `yukonSilver`) returns `unsupported` / `virtualization_tools_missing` and the UI shows: "Cowork requires QEMU. Install it with 'sudo apt install qemu-system-x86 ovmf virtiofsd', then restart Claude." That message fires even when qemu, ovmf, and virtiofsd are all installed and working. The install command just puts the binary back where the probe already isn't looking.

The distros this breaks on, all with working KVM:

- **Arch / CachyOS** ship virtiofsd at `/usr/lib/virtiofsd`. Not probed. (our [#771](https://github.com/aaddrick/claude-desktop-debian/issues/771))
- **Debian Bookworm** ships it at `/usr/lib/qemu/virtiofsd` (Rust 1.13.2). Not probed. (our [#772](https://github.com/aaddrick/claude-desktop-debian/issues/772))
- **Pop!_OS 22.04** reports `ID=pop`, so a jammy base never qualifies for the bundled fallback. This one reproduced on Anthropic's own official `.deb` from your apt repo, so it isn't a repackaging artifact on our end.

The Linux VM bundle isn't the problem. The static manifest includes `unix/x64` and `unix/arm64` rootfs entries with checksums, and every install ships a working bundled `virtiofsd` (v1.13.2, ~2.6 MB) at `resources/virtiofsd`. Linux Cowork is fully built. It's gated off by the path resolution alone.

Two things compound it. The `startVM` path logs `[startVM] VM not supported (linux/x64), skipping` for **any** unsupported status. The platform/arch interpolation makes it read like an architecture gate when it's actually the tools gate, which sent our triage bot down the wrong path (`unsupported_architecture`). And `cleanupVMBundleIfUnsupported` deletes the downloaded VM bundle whenever status ≠ supported, so an affected user's bundle gets repeatedly cleaned out.

### What Should Happen?

On a host with a working KVM stack and a virtiofsd binary present, Cowork should evaluate as supported and start the VM. The user shouldn't be told to install packages that are already installed.

Two fixes, either or both:

1. **Drop the Ubuntu-22-only condition on the bundled fallback.** You already ship the binary in every install. System paths can stay preferred; the bundled copy just becomes the universal last resort instead of a jammy-only one. This is the smaller, safer change.
2. **Widen the probe list** to include `/usr/lib/virtiofsd` and `/usr/lib/qemu/virtiofsd`. One caveat: `/usr/lib/qemu/virtiofsd` on qemu < 8 hosts (e.g. Ubuntu 22.04 jammy) can be the legacy C implementation, whose CLI is incompatible with the Rust one. That's presumably why the current list is conservative. Un-gating the bundled copy avoids that trap entirely, which is why I'd lean on (1).

### Error Messages/Logs

UI prompt:

```
Cowork requires QEMU. Install it with 'sudo apt install qemu-system-x86 ovmf virtiofsd', then restart Claude.
```

Misleading main-process log line (reads like an arch gate; it's the tools gate):

```
[startVM] VM not supported (linux/x64), skipping
```

The gate reason lands in `~/.config/Claude/logs/cowork_vm_node.log`. Grep there for `virtualization_tools_missing`.

### Steps to Reproduce

1. Linux host with a working KVM stack: `qemu-system-x86_64`, OVMF, and `virtiofsd` all installed and functional.
2. Install virtiofsd anywhere other than `/usr/libexec/virtiofsd` or `/usr/bin/virtiofsd` (Arch → `/usr/lib/virtiofsd`, Debian → `/usr/lib/qemu/virtiofsd`), or run on a non-Ubuntu / non-`22.x` distro so the bundled fallback is gated off.
3. Launch Claude Desktop and open Cowork.

Expected: Cowork starts. Actual: "Cowork requires QEMU" prompt for packages that are already installed.

Confirming workaround (proves it's the probe): `sudo ln -s <actual virtiofsd path> /usr/bin/virtiofsd`, then fully quit Claude (not just close the window) and relaunch. The probe runs once at module load and is memoized, so a restart is required. The client only needs read access to the binary.

I also verified the mechanism differentially on an Arch VM (virtiofsd only at `/usr/lib/virtiofsd`, otherwise a complete KVM stack — qemu on PATH, OVMF at the probed path, `/dev/kvm` and `/dev/vhost-vsock` present): 1.18286.0 as shipped logs `[cleanupVMBundleIfUnsupported] yukonSilver not supported (status=unsupported)` and deletes the VM bundle on every launch; the same build with only the bundled fallback un-gated evaluates as supported on the same machine and proceeds to bundle management (`[Bundle:status] rootfs.img missing`). The gate is the resolver, nothing else.

### Claude Model

Not sure / Multiple models

### Is this a regression?

I don't know

### Last Working Version

(leave blank)

### Claude Code Version

```
N/A — this is a Claude Desktop issue. Bundle version: 1.18286.0
```

### Platform

Anthropic API

### Operating System

Ubuntu/Debian Linux

### Terminal/Shell

Other

### Additional Information

Anchor table for 1.18286.0. Minified symbols rename between releases, so each row carries a stable string anchor. All line numbers are against the beautified bundle (`asar extract` + `prettier` on the official Linux `.deb`).

| Role | Symbol in 1.18286.0 | Stable anchor | Beautified loc |
|---|---|---|---|
| Probe path array | `sgi` | `["/usr/libexec/virtiofsd", "/usr/bin/virtiofsd"]` | index.js:156891 |
| Ubuntu-22 gate | `agi()` | `id === "ubuntu" && versionId.startsWith("22.")` | index.js:156892 |
| Resolver | `cgi(A)` | `TMt(sgi) \|\| (A ? bundled : null)` | index.js:156906 |
| Memoized probe | `Igi()` / `N2e` | probe runs once at module load | index.js:156963 |
| Tools gate | `Cen()` | `!e.qemuPath \|\| !e.firmwarePath \|\| !e.virtiofsdPath` → `virtualization_tools_missing` | index.js:281909 |
| Misleading log | `startVM` | `VM not supported (linux/x64), skipping` | index.js:283787 |
| Bundle cleanup | `cleanupVMBundleIfUnsupported` | deletes VM bundle when status ≠ supported | index.js:499016 |

The probe resolves to `TMt(sgi)` (first readable of the two system paths) OR — only when `agi()` is true — the bundled copy. Un-gate that second operand and every install with the shipped binary resolves.

Full downstream provenance: [aaddrick/claude-desktop-debian#771](https://github.com/aaddrick/claude-desktop-debian/issues/771) and [#772](https://github.com/aaddrick/claude-desktop-debian/issues/772). The Pop!_OS datapoint on the official `.deb` came from @mj-crabtree in the #771 thread.

One question where a one-line answer would help us route this downstream: is the Ubuntu-22-only gate on the bundled fallback deliberate (e.g. you only validated the bundled binary against a jammy glibc), or is it a leftover from an early Ubuntu-first rollout? If it's deliberate, we'll keep our downstream patch conservative.

---
Written by Claude Fable 5 via [Claude Code](https://claude.ai/code)

## Filing checklist

When you're ready to file:

1. Open https://github.com/anthropics/claude-code/issues/new?template=bug_report.yml
2. Paste each section above into the matching form field
3. Submit
4. Drop the GitHub issue URL as a comment on [#771](https://github.com/aaddrick/claude-desktop-debian/issues/771) and [#772](https://github.com/aaddrick/claude-desktop-debian/issues/772) so the trail is bidirectional, and replace the `<!-- LINK: upstream issue -->` placeholders in the downstream replies/PR
5. Per the survival playbook: author comment within 3 days, `has repro` phrasing is already in the body

## Voice and authorship

Drafted using the aaddrick-voice style profile against the form schema in `anthropics/claude-code/.github/ISSUE_TEMPLATE/bug_report.yml`, from static analysis verified against the beautified 1.18286.0 bundle in `build-reference/`.
