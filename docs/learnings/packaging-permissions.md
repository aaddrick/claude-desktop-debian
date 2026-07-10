[< Back to learnings](./)

# Packaging permissions

The build host's umask and uid leak into shipped artifacts unless every
packager normalizes the staged tree first — this page covers how each
format records modes and ownership, the silent-vs-loud runtime symptoms,
and the normalization blocks in this repo that close the hole.

**Source files:**

- [`scripts/packaging/deb.sh`](../../scripts/packaging/deb.sh) —
  normalization pass + `dpkg-deb --root-owner-group` (the block above
  the `dpkg-deb` call)
- [`scripts/packaging/rpm.sh`](../../scripts/packaging/rpm.sh) —
  `%install` file-mode normalization + buildroot `chmod 4755` on
  `chrome-sandbox`
- [`scripts/packaging/appimage.sh`](../../scripts/packaging/appimage.sh) —
  AppDir normalization before `appimagetool` runs `mksquashfs`
- [`scripts/setup/official-deb.sh`](../../scripts/setup/official-deb.sh) —
  the non-root `ar` + `tar` extraction that strips upstream's SUID bit
  in the first place

## The trap

All three packagers stage the extracted official tree with `cp -a`,
which preserves source modes. Under a restrictive umask (`umask 077`)
the extracted tree has `0700` directories and `0600` files, and every
container format records what it sees:

| Format | What it records verbatim |
|---|---|
| deb | file modes always; **ownership** too, unless built under fakeroot or with `--root-owner-group` |
| rpm | *file* modes — `%defattr(-, root, root, 0755)` forces only **directory** modes via its fourth field; the `-` first field ships buildroot file modes as-is |
| AppImage | everything — `mksquashfs` snapshots AppDir modes exactly |

The desktop user is a different uid from the build uid, so the
installed tree can be unreadable or untraversable at runtime.

Two symptom shapes, depending on which modes leaked:

- **Loud — EACCES.** Unreadable `app.asar`, non-executable electron
  binary. This is the rpm shape: `%defattr`'s forced `0755` keeps
  directories traversable, so broken *file* modes fail with an explicit
  error.
- **Silent — feature just missing.** `fs.existsSync()` returns
  **false** on a path inside a directory the user can't traverse, not
  only when the file is absent, and existence-guarded code skips its
  feature with zero log output. This is how the 2.x Cowork daemon
  auto-launch died under a `0700` `app.asar.unpacked/`: no daemon log,
  no error line, an endless `connect ENOENT` — the diagnosis record is
  in [`cowork-vm-daemon.md`](cowork-vm-daemon.md).

Confirm what the run-time user sees, not what root sees:

```bash
test -r /usr/lib/claude-desktop-unofficial/resources/app.asar && echo OK || echo BLOCKED
stat -c '%A %U:%G' /usr/lib/claude-desktop-unofficial   # 0700 + foreign uid == broken
```

## The fix: normalize at the packaging boundary

Canonical modes: directories and already-executable files `755`, every
other file `644`. `u=rwX,go=rX` does this in one pass — capital `X`
keeps the executable bit only where it already exists. Each packager
runs the same normalization immediately before its container step:

`deb.sh` (before `dpkg-deb`):

```bash
find "$install_dir" -type d -exec chmod 755 {} + || exit 1
find "$install_dir" -type f -exec chmod u=rwX,go=rX {} + || exit 1

# --root-owner-group forces root:root in the archive so a leaked build
# uid can't deny access on the installed system (the build does not run
# under fakeroot).
dpkg-deb --root-owner-group --build "$package_root" "$deb_file"
```

`rpm.sh` (inside `%install`, so the `%files` directory walk records the
fixed modes — and *before* the `chrome-sandbox` chmod, so `4755`
survives):

```bash
find %{buildroot}/usr/lib/$package_name -type f -exec chmod u=rwX,go=rX {} +
chmod 4755 %{buildroot}/usr/lib/$package_name/chrome-sandbox
```

`appimage.sh` (before invoking `appimagetool`):

```bash
find "$appdir_path" -type d -exec chmod 755 {} + || exit 1
find "$appdir_path" -type f -exec chmod u=rwX,go=rX {} + || exit 1
```

## SUID interaction: chrome-sandbox

The official `data.tar` records `chrome-sandbox` as SUID `4755`, but
the build's non-root `ar | tar` extraction
(`_extract_deb_member` in `scripts/setup/official-deb.sh`) strips the
bit, and the blanket `u=rwX,go=rX` pass would clear it anyway. Each
format re-asserts it where its model allows:

- **deb** — postinst runs `chown root:root` + `chmod 4755` at install
  time (a build-time bit set by a non-root build would be meaningless
  ownership-wise).
- **rpm** — `%install` sets `4755` in the buildroot *after* the
  normalization pass, so the payload records it directly.
- **AppImage** — no SUID: FUSE mounts are `nosuid`, which is why the
  AppRun launcher passes `--no-sandbox`.

## Unsticking an installed system

For a package that already shipped broken modes, without rebuilding:

```bash
sudo chmod -R o+rX /usr/lib/claude-desktop-unofficial
```

`o+rX` adds world read/traverse only; it leaves the setuid
`chrome-sandbox` bit alone.

## See also

- [`cowork-vm-daemon.md`](cowork-vm-daemon.md) — the bug that surfaced
  all of this (silent `existsSync` failure under `0700` packaging)
- [`official-deb-rebase-verification.md`](official-deb-rebase-verification.md) —
  install-layout facts of the official `.deb`, including SUID recording
  in `data.tar.xz`
