# Upstream report draft: Cowork OVMF firmware probe (issue #884)

**Not filed yet.** This draft is for the upstream bug report covering the firmware half of [#884](https://github.com/aaddrick/claude-desktop-debian/issues/884), checked against the official 2.42304.0 bytes. File it in `anthropics/claude-code` using the template-mismatch workaround described in [`771-cowork-virtiofsd-probe.md`](771-cowork-virtiofsd-probe.md). The downstream fix until then is the `cowork-firmware-probe` asar patch. Its `patch_retirement` row points here.

## Title

```
[BUG] Claude Desktop for Linux: Cowork finds no OVMF firmware on Arch or RHEL-family distros — probe list is two hardcoded /usr/share/OVMF paths with no override
```

## Form fields

### What's Wrong?

Cowork's support evaluator resolves x86_64 firmware from exactly two absolute paths, and nothing else:

```js
["/usr/share/OVMF/OVMF_CODE_4M.fd","/usr/share/OVMF/OVMF_CODE.fd"]
```

It takes the first path that's readable and derives the VARS template from it with `.replace("OVMF_CODE","OVMF_VARS")`. You can't override it with an env var or a setting. That layout is Debian's. Other major distros put edk2 somewhere else:

- **Arch / CachyOS / Manjaro** (`edk2-ovmf`): `/usr/share/edk2/x64/OVMF_CODE.4m.fd` and `OVMF_VARS.4m.fd`
- **RHEL / CentOS Stream / Alma / Rocky 9 and 10** (`edk2-ovmf`): `/usr/share/edk2/ovmf/OVMF_CODE.fd` and `OVMF_VARS.fd`. EL ships `/usr/share/OVMF/OVMF_VARS.fd` but no `OVMF_CODE.fd` next to it.

Fedora isn't affected: its `edk2-ovmf` also ships `/usr/share/OVMF/OVMF_CODE.fd` and `OVMF_VARS.fd`, so the existing probe finds them.

On these hosts, `firmwarePath` ends up null even though the firmware is installed. To work around it, the user has to root-link files into `/usr/share/OVMF/` and pick names that make the derived VARS path come out right. If they link the CODE file as `OVMF_CODE_4M.fd` on EL, the client derives `OVMF_VARS_4M.fd`, and that file doesn't exist.

### What Should Happen?

When firmware from the distro's own `edk2-ovmf` package is installed, Cowork should find it. Either of these would do it:

1. Add `/usr/share/edk2/x64/OVMF_CODE.4m.fd` and `/usr/share/edk2/ovmf/OVMF_CODE.fd` to the probe list, after the existing paths. Both pair with the existing `replace()`.
2. Add an env override for the firmware path, like the one qemu effectively has through `PATH`.

### Steps to Reproduce

1. On Arch (or RHEL, CentOS Stream, Alma or Rocky 9/10), install `qemu` and `edk2-ovmf`, with a working `/dev/kvm` and `/dev/vhost-vsock`.
2. Install Claude Desktop and open Cowork.

Expected: the VM is supported. Actual: the firmware probe resolves nothing, so Cowork isn't available. Linking the edk2 CODE and VARS files into `/usr/share/OVMF/` under the probed names, then restarting, fixes it.
