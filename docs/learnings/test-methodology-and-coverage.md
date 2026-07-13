[< Back to docs index](../index.md)

# Test methodology and coverage

How the automated test suite is written so a green run actually means something. This is the accumulated methodology from [@sabiut](https://github.com/sabiut)'s test/CI/doctor PRs (the tests/doctor subsystem owner — see [`.github/CODEOWNERS`](../../.github/CODEOWNERS)), both in his own test suites and in what he demands when reviewing others' fixes. The through-line is one claim: **a passing test proves nothing until you prove it fails when the code it guards is broken.** Most of the traps below are tests that shipped green while pinning nothing.

**Source files:**
- [`tests/doctor.bats`](../../tests/doctor.bats) — 88 unit tests for `scripts/doctor.sh` helpers; the `setup()` sandbox is the canonical host-isolation template
- [`tests/launcher-common.bats`](../../tests/launcher-common.bats) — 97 unit tests for `scripts/launcher-common.sh`
- [`tests/launcher-xrdp-detection.bats`](../../tests/launcher-xrdp-detection.bats) — the PATH-shim mocking pattern for command-substitution calls
- [`tests/test-artifact-common.sh`](../../tests/test-artifact-common.sh) — `run_launch_smoke_test` / `_launch_smoke_cleanup`, the shared headless launch harness
- [`tests/test-artifact-{deb,rpm,appimage}.sh`](../../tests/) — per-format structural + launch smoke tests
- [`.github/workflows/tests.yml`](../../.github/workflows/tests.yml) — runs `bats tests/*.bats` on push/PR
- [`.github/workflows/test-artifacts.yml`](../../.github/workflows/test-artifacts.yml) — the arch × format artifact-test matrix that gates the release job

## Overview

There are three test surfaces:

| Surface | Runs | Covers |
|---|---|---|
| **BATS unit tests** (`tests/*.bats`) | seconds, on every push/PR via `tests.yml` | pure shell helpers in `launcher-common.sh` and `doctor.sh` |
| **Artifact smoke tests** (`tests/test-artifact-*.sh`) | per built package, `test-artifacts.yml` matrix | deb/rpm/AppImage structure, `--doctor` dispatch, headless launch-to-ready |
| **Manual test plan** ([`docs/testing/`](../testing/README.md)) | human sweeps across the VM fleet | GUI behavior BATS can't reach (tray, WCO, IME) |

The unit suite is fast and standalone on purpose ([#520](https://github.com/aaddrick/claude-desktop-debian/pull/520)): a red "BATS Tests" check means *your code broke a test*, not *the build fell over before tests ran*. The artifact matrix gates the release job, so a launch regression can't ship.

The rest of this page is the methodology that keeps those green checks honest. The [half-pinned-test failure class](#the-half-pinned-test-failure-class) is the most important section — read it before adding or reviewing any shell test.

## The half-pinned-test failure class

Every trap here produced a **green test that did not pin the behavior it claimed.** The fix is always the same discipline — the [mutation check](#the-mutation-check): break the code by hand and confirm a test goes red. If nothing does, the test is decoration.

### `run helper` subshells away every variable mutation

This is the single most repeated bug in the suite ([#774](https://github.com/aaddrick/claude-desktop-debian/pull/774), [#744](https://github.com/aaddrick/claude-desktop-debian/pull/744), [#781](https://github.com/aaddrick/claude-desktop-debian/pull/781)). BATS' `run` executes its argument in a **subshell**, so any counter or flag the helper mutates is thrown away — the assertion after `run` only sees `$status` and `$output`. A doctor check's whole contribution to the exit code is `_doctor_failures=$((_doctor_failures + 1))` ([`doctor.sh`](../../scripts/doctor.sh)), and `run_doctor` ends with `return "$_doctor_failures"`. Assert on `$output` alone and you never pin whether the FAIL branch actually counted.

```bash
# WRONG — the increment happens in a subshell and vanishes; a mutation
# that stops the check from failing still passes this test.
run _doctor_check_display_server
[[ $output == *'[FAIL]'* ]]

# RIGHT — call it directly, redirect output to a file, assert BOTH the
# counter and the emitted line.
_doctor_failures=0
_doctor_check_display_server > "$TEST_TMP/out"
[[ $_doctor_failures -eq 1 ]]
grep -q '\[FAIL\]' "$TEST_TMP/out"
```

> [!WARNING]
> Use `run` only when you genuinely need `$status`/`$output` isolation (e.g. a helper whose internal `((_wait++))` would trip BATS' errexit — see [SC2314](#negative-assertions-that-dont-fail-sc2314) below). Any test asserting a side effect on `_doctor_failures`, `_cowork_incomplete`, or similar must call the helper directly.

### Anchor tests need a near-miss fixture

A `grep` anchor is only pinned if a fixture sits one character away from matching. In [#782](https://github.com/aaddrick/claude-desktop-debian/pull/782), `_doctor_check_userns_apparmor` matched `^claude-desktop-unofficial ` against the loaded AppArmor profile set, and the test passed — but so did *every* weakening of it (dropping `-unofficial`, dropping the `^`, dropping the trailing space), because the WARN fixture's loaded set was just `firefox (enforce)`. The real state the anchor disambiguates — the **official** `claude-desktop` profile present while **ours** is absent, the exact co-install collision — was never in a fixture. Adding one near-miss line (`claude-desktop (unconfined)`) turned a permissive weakening from "survives all 7 tests" into "fails 3."

**Rule:** an anchor/regex test needs a fixture line one character short of matching, or the anchor isn't pinned. Prove it by loosening the anchor and watching a test go red.

### A stub that mirrors the production call can't catch a change to that call

In [#745](https://github.com/aaddrick/claude-desktop-debian/pull/745) the `stat` stub keyed on `$2 == '%a'`. A production typo like `stat -c '%a'` → `stat -f '%a'` (where GNU `-f` reinterprets `%a` as free-block count) still passed all 90 tests, because the stub answered `%a` regardless of the flags around it. The fix runs **one** FAIL-branch test against real `stat` on a real `0644` file — no stub, so the actual flags and parse are exercised — while keeping the stub only for the un-fakeable `4755`+root PASS case. If a stub imitates the production invocation, at least one branch must run the real tool.

### `[PASS]` must mean "read and verified," never "failed to read"

A recurring false-green class ([#692](https://github.com/aaddrick/claude-desktop-debian/pull/692), [#740](https://github.com/aaddrick/claude-desktop-debian/pull/740)): a check emits `[PASS]` over a value it never actually parsed.

- **Blank presented as success** — `_doctor_check_password_store` did `_pass "Password store: $store"` even when detection returned empty → `[PASS] Password store: `. Fixed to `_warn` + early-return on empty.
- **Non-numeric falls through to PASS** — the disk check guarded only for *empty* `df` output (`[[ -n ]]`), so `avail="N/A"` cleared the guard, the `(( avail < 100 ))` arithmetic errored, and execution reached the PASS branch → `[PASS] Disk space: N/AMB free`. Fixed with `[[ $avail =~ ^[0-9]+$ ]] || return 0`.
- **Octal death, same landing** — `avail="0099"` passes that regex but `(( ))` dies with "value too great for base." Closed with `avail=$((10#$avail))`.
- **Unhandled file type** — `_doctor_check_singleton_lock` only handled the symlink case, so a regular-file `SingletonLock` (left by an unclean update, which still hard-blocks Electron's single-instance lock) fell through to `[PASS] SingletonLock: no lock file (OK)`. Fixed with an explicit `elif [[ -e $lock_file ]]` → WARN.

The maxim from those threads: **better no line than a green PASS on data we couldn't read.**

### A poll predicate must be *identical* to the production predicate

[#781](https://github.com/aaddrick/claude-desktop-debian/pull/781) added a flake-fix poll that grepped the child's cmdline for `--class=Claude` *without* a trailing space, while the reaper's own [`_claude_desktop_ui_cmdline_matches`](../../scripts/launcher-common.sh) requires `--class=Claude ` *with* the space. In the pre-`exec -a` bash window, `/proc/$pid/cmdline` reads `bash -c exec -a "--class=Claude" sleep 300` — the loose poll matches inside the quotes, the strict reaper does not. So the poll could green-light the reaper while the reaper still couldn't see the child, reproducing the exact starvation the poll existed to kill (5/5 by freezing the child in that state). The fix calls the reaper's own predicate — `_claude_desktop_ui_cmdline_matches "$(tr '\0' ' ' < /proc/$ui_pid/cmdline)"` — so drift is impossible by construction, plus a loud named failure after the ceiling (a silent fall-through would reproduce the very flake signature).

### Negative assertions that don't fail (SC2314)

A bare `! grep …` that isn't the **last** command in a BATS test does not fail the test — the negation is silently a no-op mid-body ([#693](https://github.com/aaddrick/claude-desktop-debian/pull/693); the same trap bites `[[ "$status" -eq 0 ]]` on bash 3.2, the macOS default). Write negative assertions so their exit status is what BATS checks:

```bash
# "no SIGKILL was sent" — the honest form
run grep -qF -- '-KILL' "$TEST_TMP/kills"
[[ $status -ne 0 ]]
```

## Host-state isolation

Unit tests must read *their* fixtures, never the developer's live machine. The [`setup()` in `doctor.bats`](../../tests/doctor.bats) is the template: redirect `HOME`/`XDG_CACHE_HOME`/`XDG_CONFIG_HOME` to a `mktemp -d`, then `unset` every ambient var the production code might consult.

- **Sandboxing `HOME` alone is not enough.** `_doctor_check_bwrap_mounts` resolves config via `${XDG_CONFIG_HOME:-$HOME/.config}/Claude`. GitHub runners export `XDG_CONFIG_HOME` ambient, so a test that sandboxed only `HOME` read the runner's *real* config dir and asserted against empty output — a latent failure that surfaced the instant [#520](https://github.com/aaddrick/claude-desktop-debian/pull/520) first ran BATS in CI. Unset every `XDG_*` and `_DOCTOR_*` override that has a `$HOME`- or system-path fallback ([#520](https://github.com/aaddrick/claude-desktop-debian/pull/520), [#782](https://github.com/aaddrick/claude-desktop-debian/pull/782)).

### Stub vs. shim — pick by where the call runs

Two ways to intercept an external command, and the choice is not stylistic:

| Technique | Use when | Why |
|---|---|---|
| **Function stub** (`pgrep() { return 1; }`) | the call runs **in the test shell** | bash function lookup beats `PATH`; `export -f` is a no-op here since it's the same shell |
| **PATH shim** (a script in `$TEST_TMP/bin`, prepended to `PATH`) | the call runs in a **subshell / command substitution** | `$(loginctl …)` forks a child where an un-exported function never reaches |

[#534](https://github.com/aaddrick/claude-desktop-debian/pull/534) fixed a test that used real `pgrep`: on any box running Claude Desktop, `cleanup_stale_cowork_socket` saw the developer's live `cowork-vm-service.js`, took its correct early-return, and skipped the `rm -f` the test expected — so it failed on maintainers' machines and passed in CI. The fix is a function stub. Contrast [`launcher-xrdp-detection.bats`](../../tests/launcher-xrdp-detection.bats), which needs a PATH shim because `loginctl` is called via `$(…)`.

### `pkill` sweeps must match the real exec path — and only in CI

The AppImage launch-smoke `pkill` sweep ([#691](https://github.com/aaddrick/claude-desktop-debian/pull/691)) was handed the `.AppImage` artifact path, which matched only the already-reaped top-level launcher — real strays exec from `/tmp/.mount_claude*`. It was fixed to match `mount_claude`, then guarded behind `[[ -n ${CI:-} ]]`: a bare `pkill -KILL -f mount_claude` on a developer's Ctrl-C would also kill their live local AppImage. Local runs fall back to the process-group kill alone.

## Artifact launch-smoke methodology

Structural asserts ("the files exist") are not enough — [#666](https://github.com/aaddrick/claude-desktop-debian/issues/666) shipped a Fedora `SyntaxError` from a bad patch anchor that killed the app on launch while the rpm test stayed green. `run_launch_smoke_test` in [`test-artifact-common.sh`](../../tests/test-artifact-common.sh) actually boots the artifact and waits for it to reach ready:

- **Reap the whole process group.** Boot via `setsid xvfb-run dbus-run-session -- …` in a fresh process group, then reap with `kill -- -PGID`. `setsid` is load-bearing: `xvfb-run`'s own EXIT trap leaves Xvfb behind when killed by signal, so only a fresh group reaps the entire tree (xvfb-run, Xvfb, dbus, AppRun, electron, zygotes) ([#592](https://github.com/aaddrick/claude-desktop-debian/pull/592), [#671](https://github.com/aaddrick/claude-desktop-debian/pull/671)).
- **Poll a readiness marker, not a flat sleep.** The original `sleep 10` was the worst of both worlds — 10s wasted on healthy runs, still flaky on slow ones. Replaced ([#646](https://github.com/aaddrick/claude-desktop-debian/pull/646)) with a 30s-ceiling / 0.5s-tick poll of `launcher.log` for a literal marker (currently `Executing: `, the launcher's pre-exec line; it was `[Frame Fix] Patches built successfully` until the frame-fix wrapper was deleted in the patch-zero rebase). Each tick checks the marker *first*, then liveness via `kill -0`, so a marker written just before exit still passes. Failure output distinguishes "did not reach ready state within Ns" (alive, no marker) from "exited before reaching ready state (exit: N)" (died early).
- **Drop privileges for rpm.** Electron hard-aborts as root without `--no-sandbox`, so the Fedora container drops to a throwaway unprivileged user — which also exercises the real setuid `chrome-sandbox` path ([#671](https://github.com/aaddrick/claude-desktop-debian/pull/671)).
- **Test the real arch on a native runner.** The arm64 leg runs on `ubuntu-*-arm` so the launch smoke executes the actual arm64 binary instead of dying on foreign-arch exec; the artifact-name contract (`package-{arch}-{format}`) is asserted exactly, and the release gate waits on both arches ([#691](https://github.com/aaddrick/claude-desktop-debian/pull/691)).
- **One shared cleanup trap, not one per block.** Bash keeps a single handler per signal, so a trap set *inside* the smoke block silently overrides a script-scope one and leaks whatever it forgot (a ~190MB `squashfs-root` in [#592](https://github.com/aaddrick/claude-desktop-debian/pull/592)). Use one script-scope `_cleanup`, each branch defensively guarded (`[[ -n ${var:-} ]] && …`) so it's safe however far the script got.

> [!NOTE]
> Known residual gaps are flagged, not hidden: rpm launch stays SKIP-not-PASS where the container denies the sandbox; GPU/renderer [#583](https://github.com/aaddrick/claude-desktop-debian/issues/583)-class crashes leave the main process alive and pass under Xvfb's SwiftShader fallback. Silent truncation of coverage reads as "we tested everything" when we didn't — say what was skipped.

## The doctor-check testability refactor

The pattern behind [#740](https://github.com/aaddrick/claude-desktop-debian/pull/740)/[#744](https://github.com/aaddrick/claude-desktop-debian/pull/744)/[#745](https://github.com/aaddrick/claude-desktop-debian/pull/745)/[#782](https://github.com/aaddrick/claude-desktop-debian/pull/782): lift an inline block out of `run_doctor` into a named `_doctor_check_*` helper so it's independently unit-testable, prove the move is byte-identical, and add path-injection hooks (`_DOCTOR_*`) that default to the real system paths. The review discipline attached to each is the reusable part:

1. **Diff the extracted helper against the inline original** and assert byte-identical behavior before trusting any new test.
2. **Mutation-test every new test** — "swap the Wayland/X11 precedence," "`4755`→`0755` breaks exactly 3 tests," "delete the `break` and the double-report test fails."
3. **Demand FAIL-branch coverage and counter/flag asserts**, not just the PASS path (this is where the `run`-subshell trap keeps reappearing).
4. **Unset each new `_DOCTOR_*` hook in `setup()`** so an exported value from the invoking shell can't leak in.

A refactor framed for testability earns the test work: "since testability is this PR's stated purpose, worth doing here." Coordination note — the three extractions insert at the same anchor (after `_doctor_check_bwrap_fallback()`), so they conflict in `doctor.sh` while the BATS side auto-merges; land them in sequence with trivial keep-both rebases.

## Review heuristics

What to demand when reviewing a fix, distilled from [@sabiut](https://github.com/sabiut)'s reviews on others' PRs.

- **The mutation check is mandatory.** Revert or weaken the fix by hand; if the suite still passes, the test guards nothing. *"Dropping the gate fails the new test, so a revert can't sneak past CI"* ([#713](https://github.com/aaddrick/claude-desktop-debian/pull/713)). A green suite over a *known* defect proves the coverage hole, not correctness ([#752](https://github.com/aaddrick/claude-desktop-debian/pull/752), [#776](https://github.com/aaddrick/claude-desktop-debian/pull/776)).
- **Claimed verification must ship as a committed test.** Methodology cited in the PR body but absent from the diff is CHANGES_REQUESTED; a manual `dash -n` / `shellcheck` run gets codified into the suite so the next edit can't regress it ([#776](https://github.com/aaddrick/claude-desktop-debian/pull/776), [#694](https://github.com/aaddrick/claude-desktop-debian/pull/694)).
- **Watch for hollow assertions.** A test that checks the fixture against itself (the sed never touches the branch the grep inspects) can't fail from a regression in the actual fix, and a test *name* that doesn't match what it validates hides an uncovered edge case ([#752](https://github.com/aaddrick/claude-desktop-debian/pull/752), [#732](https://github.com/aaddrick/claude-desktop-debian/pull/732)).
- **Name the verification level honestly.** State what was run live vs. read; treat "static-verified-only" as an open gap and add the cheap live/artifact assert that removes the qualifier (*"so the deb/rpm legs stop being static-verified-only"* — [#775](https://github.com/aaddrick/claude-desktop-debian/pull/775)). Leave external live confirmation (real-hardware GUI, eCryptfs box) as an explicit unchecked item rather than implying it's done — hedge untested paths ("should" / "static analysis says") instead of claiming coverage you don't have.
- **Doctor-vs-launch parity.** `--doctor` must observe the exact environment the launch will — same config load, same env, same runtime floor. A user with `COWORK_VM_BACKEND=bwrap` only in the config gets zero diagnostics because `--doctor` never reads the config file: that divergence is a real bug class ([#776](https://github.com/aaddrick/claude-desktop-debian/pull/776)).
- **Shared surfaces stay distro-agnostic; magic numbers get justified or overridable.** `doctor.sh` ships in every format, so ".deb auto-installs… reinstall the .deb" advice is wrong for AppImage/Nix/rpm users; a hard-coded crash threshold of 3 needs either a rationale comment or a `CLAUDE_DOCTOR_CRASH_THRESHOLD` override so the number isn't orphaned ([#694](https://github.com/aaddrick/claude-desktop-debian/pull/694), [#585](https://github.com/aaddrick/claude-desktop-debian/pull/585)).

## The mutation check

Before calling any shell test "merge-ready," neuter the code it guards and confirm a test goes red. If nothing does, the test is decoration regardless of how green CI is. Concretely, for a new or reviewed test ask:

1. Does it assert on a **side effect** (a counter, a flag)? Then it must call the helper directly, not via `run`.
2. Is there a fixture **one character** away from the anchor it claims to pin?
3. Does at least one branch run the **real** external tool, not only the stub?
4. Does `[PASS]` only fire on data the check actually **read and parsed**?
5. Does the negative assertion's exit status reach **BATS** (last command, or via `run` + `$status`)?
6. If you **revert the fix**, does a test fail?

Question 6 is the one that matters. The rest are the specific ways the answer to 6 comes out "no" while CI stays green.

## References

- Test-infra PRs: [#310](https://github.com/aaddrick/claude-desktop-debian/pull/310) (SHA-256 verify), [#338](https://github.com/aaddrick/claude-desktop-debian/pull/338) (artifact structure), [#520](https://github.com/aaddrick/claude-desktop-debian/pull/520) (wire BATS into CI), [#592](https://github.com/aaddrick/claude-desktop-debian/pull/592)/[#646](https://github.com/aaddrick/claude-desktop-debian/pull/646)/[#671](https://github.com/aaddrick/claude-desktop-debian/pull/671)/[#691](https://github.com/aaddrick/claude-desktop-debian/pull/691) (launch-smoke evolution), [#606](https://github.com/aaddrick/claude-desktop-debian/pull/606) (CI concurrency)
- Half-pinned-test fixes: [#534](https://github.com/aaddrick/claude-desktop-debian/pull/534), [#692](https://github.com/aaddrick/claude-desktop-debian/pull/692), [#693](https://github.com/aaddrick/claude-desktop-debian/pull/693), [#774](https://github.com/aaddrick/claude-desktop-debian/pull/774), [#740](https://github.com/aaddrick/claude-desktop-debian/pull/740), [#744](https://github.com/aaddrick/claude-desktop-debian/pull/744), [#745](https://github.com/aaddrick/claude-desktop-debian/pull/745), [#781](https://github.com/aaddrick/claude-desktop-debian/pull/781), [#782](https://github.com/aaddrick/claude-desktop-debian/pull/782)
- Review-heuristic threads: [#713](https://github.com/aaddrick/claude-desktop-debian/pull/713), [#752](https://github.com/aaddrick/claude-desktop-debian/pull/752), [#775](https://github.com/aaddrick/claude-desktop-debian/pull/775), [#776](https://github.com/aaddrick/claude-desktop-debian/pull/776)
- Related learnings: [`patching-minified-js.md`](patching-minified-js.md) (the same anchor/mutation discipline for patch scripts — exactly-1 assertions, idempotent re-runs, verify against real bytes), [`cross-build-host-vs-target.md`](cross-build-host-vs-target.md) (why the arch matrix runs on native runners), [`docs/testing/`](../testing/README.md) (the manual GUI test plan BATS can't reach)
