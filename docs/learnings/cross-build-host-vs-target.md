[< Back to learnings](./)

# Cross-builds: host tools vs. target artifacts

Anything that *runs during the build* keys on `uname -m` (the host);
anything *embedded in the artifact* keys on the `--arch` target —
conflating the two downloads a tool the runner cannot exec. This class
was caught three times during the v3.0.0 CI cutover: twice as loud
`Exec format error` (Phases 4+5), once as the silent variant below.

**Source files:**

- [`scripts/setup/dependencies.sh`](../../scripts/setup/dependencies.sh) —
  `setup_nodejs` host-arch selection
- [`scripts/packaging/appimage.sh`](../../scripts/packaging/appimage.sh) —
  appimagetool host-arch selection *and* target `ARCH` export in one
  script (the canonical worked example)
- [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) /
  [`.github/workflows/build.yml`](../../.github/workflows/build.yml) —
  the 6-leg cross-building matrix, all legs on `ubuntu-latest`

## Why every build is potentially a cross-build

Repackaging Anthropic's prebuilt official `.deb` is arch-independent —
nothing compiles — so CI runs all six legs
({amd64, arm64} × {deb, rpm, appimage}) on `ubuntu-latest` x86_64
runners. `ci.yml`'s matrix feeds `build.yml`, which just calls
`./build.sh --arch ${{ inputs.arch }}`. Every arm64 leg is therefore a
cross leg: target arm64, host x86_64.

## The failure mode

Both `setup_nodejs` and the appimagetool selection were originally
keyed to `$architecture` (the `--arch` target). On an arm64 leg they
downloaded arm64 binaries onto the x86_64 runner:

```
cannot execute binary file: Exec format error
```

Nothing about the *inputs* was wrong — the pinned official arm64 `.deb`
is exactly what should be fetched and repacked — only the build-host
tooling was mis-keyed.

## The rule

| Keys on | What | Examples in this repo |
|---|---|---|
| `uname -m` (host) | anything that **runs** during the build | Node (runs asar), appimagetool, `@electron/asar` itself |
| `--arch` / `$architecture` (target) | anything **embedded** in the artifact | AppImage runtime `ARCH` export, deb control `Architecture:`, `rpmbuild --target`, artifact/pool filenames, which official `.deb` gets fetched (`official_deb_pin`) |

## Worked example: both keys in `appimage.sh`

Host side — the tool that must execute on the runner:

```bash
# appimagetool is a native binary that must run on the HOST machine, not
# the package's target architecture: CI cross-builds (e.g. an arm64
# package on an ubuntu-latest/x86_64 runner) need the x86_64 tool even
# though $architecture says arm64. Select strictly by uname -m here;
# the target architecture is only used later for the embedded ARCH.
host_arch=$(uname -m)
case "$host_arch" in
	x86_64|aarch64) ;;
	*)
		echo "Unsupported host architecture for appimagetool: $host_arch" >&2
		exit 1
		;;
esac
```

Target side, later in the same script — the runtime that ships inside
the artifact:

```bash
case "$architecture" in
	amd64) export ARCH='x86_64' ;;
	arm64) export ARCH='aarch64' ;;
esac
```

One script, two arch variables, zero overlap.

## The silent variant: tools that embed host-arch bytes

The `ARCH` export above is NOT enough for the AppImage runtime. The
third instance of this class had no `Exec format error` at build time:
appimagetool always embeds the runtime stub bundled with the *tool
itself* (host-arch) — `ARCH` only covers arch naming/validation, and
the tool doesn't even accept `aarch64` as an env value (its internal
name is `arm_aarch64`; real AppDirs work because the arch is guessed
from payload ELFs). A cross-built arm64 AppImage therefore shipped an
x86_64 first-stage stub and could not start on any arm64 machine. The
build "succeeded"; only executing the artifact on target hardware
(the first native-arm64 `test-artifacts` run) exposed it.

The fix forces the target runtime explicitly — download
`runtime-${ARCH}` from the same AppImageKit release as the tool and
pass `--runtime-file "$runtime_path"` to every appimagetool
invocation (see `appimage.sh`).

The general lesson: a host-arch *tool* that writes bytes into the
artifact may default those bytes to its own arch. `readelf -h` the
shipped stub, don't trust the tool's arch flags — and prefer artifact
tests that *execute* the artifact on target-arch hardware over
build-time assertions. `setup_nodejs` in
`scripts/setup/dependencies.sh` follows the same host-side pattern for
its Node tarball ("Node is build-host tooling: it runs asar here and
never ships in the package").

## How to spot a new instance

Any `case "$architecture"` (or `$ARCH`/`--arch` plumbing) that ends in
a download URL or an exec is suspect: ask whether the bytes it selects
are *executed now* or *shipped later*. If executed now, rewrite it
against `uname -m` and keep an explicit unsupported-host bail-out, as
both fixed sites do.

## See also

- [`official-deb-rebase-verification.md`](official-deb-rebase-verification.md) —
  per-arch dependency contracts of the official `.deb` (target-side
  facts the packagers re-emit)
