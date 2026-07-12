# Upstream report (investigation): "getAppInfoForFile is not a function" (issue #720)

**Status: NOT FILED — investigation, thesis falsified against pinned bytes, one open question pending a first-party 3.x `main.log`.** The narrow "the official Rust binding lacks `getAppInfoForFile` on Linux" hypothesis is falsified on the pinned `1.18286.2` bytes. No upstream filing until a real 3.x stack trace pins the one remaining live throw path (runtime module shadowing). This is the D-002 escape valve: nothing here is an `app.asar` patch.

This draft covers [#720](https://github.com/aaddrick/claude-desktop-debian/issues/720), reopened after [#780](https://github.com/aaddrick/claude-desktop-debian/issues/780) reported the same error string against `claude-desktop-unofficial` 3.0.1 (upstream `1.18286.2`, the official Linux build with the real Rust binding). Filing target, if it ever files, is `anthropics/claude-code` GitHub Issues.

## Symptom

`TypeError: o.getAppInfoForFile is not a function` surfacing when the file/folder picker is exercised on Linux. Originally reported on `1.11847.5-2.0.19` (#720); re-reported present-tense on `1.18286.2-3.0.1` (#780).

## Repro

Not first-party reproducible on stock `1.18286.2` bytes. Every probe below was run against the pinned artifacts; none produces the reported error. The error is only reproducible if a truthy-but-incomplete `@ant/claude-native` module shadows the packaged binding on the module resolution path (see root cause, candidate B) — which our packaging cannot produce and which requires the reporter's own `main.log` to confirm.

## Root cause with byte evidence

### What was actually run

Both `1.18286.2` debs were fetched from the official APT pool and sha-verified against the pins in `scripts/setup/official-deb.sh`:

| Artifact | Observed sha256 | Pin | Match |
|---|---|---|---|
| `claude-desktop_1.18286.2_amd64.deb` | `56fa5de0…512f1` | `OFFICIAL_DEB_SHA256_AMD64` | yes |
| `claude-desktop_1.18286.2_arm64.deb` | `38c65a12…29ba3` | `OFFICIAL_DEB_SHA256_ARM64` | yes |

The native binding, extracted from each `app.asar.unpacked`:

| Binding | Observed sha256 | Note |
|---|---|---|
| `.2` amd64 `claude-native-binding.node` | `369514aa00adc164bf34c0ca7353f4820df4a22209228d1db9af2802d6605b3f` | **byte-identical to the `.0` build-reference binding** |
| `.2` arm64 `claude-native-binding.node` | `c4c0466e38451ae135d8315346eff5687afdd7cd50669a9da085b8fdd5405460` | ELF aarch64, stripped |
| `.0` build-reference amd64 (on disk) | `369514aa…605b3f` | prior lane's confirmed value |

Because the `.2` amd64 binding is byte-identical to `.0`, the export analysis carries to the pinned version directly. The `.2` app.asar (`88fd2b93…`) is **not** identical to the `.0` build-reference app.asar (`b740b5b9…`), so the JS call site was re-verified against the freshly extracted `.2` bundle rather than reused.

### The `.2` amd64 binding exports `getAppInfoForFile` and it is a function

`node -e` require + `Object.keys` on the extracted `.2` amd64 binding (Node v22.22.0, x86_64 host):

- **45 top-level exports** (was asserted as 45 by the prior lane; observed = 45).
- `getAppInfoForFile` is present; `typeof binding.getAppInfoForFile === "function"`.
- Called with a real existing file (`/etc/hostname`), a directory (`$HOME`), and a non-existent path, it returns **`null`** every time — no throw. (Called with no argument it throws a NAPI arg-conversion `Error`, `Failed to convert JavaScript value Undefined into rust type String` — an argument-arity error, not the reported "is not a function".)

So on the pinned `.2` amd64 bytes, `getAppInfoForFile` is a callable Linux no-op returning `null`, not a missing method. The narrow hypothesis is falsified.

### The `.2` arm64 binding registers the same export set

The `.node` cannot be `require()`d on x86_64, so it was verified statically: NAPI export names are stored as string literals in the module. `getAppInfoForFile` appears as an exact-match string in the arm64 binary, and 43 of the 45 amd64 export names appear verbatim in the arm64 binary (the two that don't, `key` and `keys`, are generic short identifiers present as substrings, not standalone-terminated strings). Static analysis says the aarch64 binding registers the same export surface as amd64, including `getAppInfoForFile`.

### The `.2` call site uses a truthiness guard, not a method-existence guard

Grepped from the freshly extracted `.2` amd64 `index.js` (`app-extracted/.vite/build/index.js`, `"version": "1.18286.2"`). `getAppInfoForFile` appears exactly once, in the `whichApplication` FileSystem IPC method:

```js
whichApplication:async n=>{const o=wa();return o?o.getAppInfoForFile(n):null}
```

The accessor `wa()` is the cached native-module loader:

```js
let W6,Y_t;
function wa(){
  if(W6!==void 0)return W6;
  try{W6=require("@ant/claude-native")}
  catch(A){W6=null,Y_t=A,D.error("Failed to load Claude Native %o",A)}
  return W6
}
```

`W6` caches the module; `Y_t` caches the load error. The guard `o?` is **truthiness only** — it protects against `wa()` returning `null` (a hard load failure), but not against `wa()` returning a truthy object that lacks `getAppInfoForFile`. With the real binding loaded, `o` is truthy, `o.getAppInfoForFile` is a function, and the method returns `null`. No throw.

Note the same bundle already ships the stricter pattern elsewhere: `b$()` throws if `wa()` is `null` before touching safe-fs methods, and the cowork-socket path does `if(typeof e!="function")throw…` on `connectUnixSocketSameUid`. `whichApplication` simply does not use the strict form.

### The actual folder picker never touches the binding

`browseFolder` — the method behind the folder picker — is pure Electron:

```js
browseFolder:async(n,o,s)=>{…await aA.dialog.showOpenDialog(e,{properties:["openDirectory","createDirectory"],title:n,defaultPath:g??a})…}
```

It never calls `wa()` or `getAppInfoForFile`. `whichApplication` (the getAppInfoForFile caller) is a separate "which app opens this file" query, not the picker itself.

### Historical mechanism (2.x, byte-confirmed) — fixed by the rebase

The original 2.0.19 crash was our own deleted Linux stub, not a missing upstream export. `git show 295d71b:scripts/claude-native-stub.js` + `Object.keys`:

- **18 top-level exports**: 16 no-op methods (`getWindowsVersion`, `readRegistryValues`, `writeRegistryValue`, `writeRegistryDword`, `getWindowsElevationType`, `getCurrentPackageFamilyName`, `setWindowEffect`, `removeWindowEffect`, `getIsMaximized`, `flashFrame`, `clearFlashFrame`, `showNotification`, `setProgressBar`, `clearProgressBar`, `setOverlayIcon`, `clearOverlayIcon`) **plus** the `KeyboardKey` constant and the `AuthRequest` class.
- `grep -c getAppInfoForFile` on the stub = **0** — the method was absent.

The stub returned a truthy object with no `getAppInfoForFile` key, so the `o?` truthiness guard passed and `o.getAppInfoForFile(n)` threw exactly `… is not a function`. The v3.0.0 rebase deleted the stub (commit `d9cef9e`, `scripts/claude-native-stub.js` and its bats removed) and ships the real 45-export binding. That crash class cannot recur with the real binding in place.

### Root-cause ranking on 3.x

- **(A) Original 2.x stub crash** — fixed by the rebase; not live on 3.x.
- **(B) Runtime module shadowing** — the only live throw candidate. If a stale pre-3.0.0 `@ant/claude-native` (the old truthy-but-incomplete stub, or any partial module) resolves ahead of the packaged binding on the reporter's machine, `wa()` returns it, `o?` passes, and `o.getAppInfoForFile` is `undefined` → the reported error. Our packaging cannot produce this — `active_patches` never touch the binding, and the packaged module lives at a fixed path inside `app.asar.unpacked`. Confirming this needs the reporter's `main.log` (look for `Failed to load Claude Native` = a hard `wa()===null` load failure, whose absence alongside the throw would point at shadowing).
- **(C) Arch parity** — static analysis says the aarch64 binding registers `getAppInfoForFile` (export string present); no cross-arch live call was possible from the x86_64 host.

## Reconciliation — @JVrachnis's present-tense error on `.2` (#780)

@JVrachnis (human reporter, `1.18286.2-3.0.1` Fedora RPM) reports the exact error string present-tense, which directly contradicts the probe: stock `.2` bytes cannot throw "is not a function" because the method exists and returns `null`. Three explanations, in evidence order:

1. **Paraphrased / cited historical error (evidence favors this).** #780's phrasing — "the native folder picker is broken (`o.getAppInfoForFile is not a function`, #720)" — cites the issue number inline and quotes the error string verbatim from the #720 title. No stack trace, no `main.log` line, no version-specific detail accompanies it. This reads as a reporter attributing an observed "picker is broken" symptom to the known historical error string, not pasting a fresh `.2` log line. The probe makes a genuine fresh throw on stock bytes impossible, which is consistent with this being a citation rather than a capture.
2. **Runtime module shadowing (candidate B) — possible, unconfirmed.** A leftover pre-3.0.0 `@ant/claude-native` on his resolution path would make the error genuinely fire on his machine while stock bytes stay clean. This is the only mechanism that reconciles a *real* fresh throw with the falsified export hypothesis. It cannot be adjudicated from our bundle; it needs his `main.log`.
3. **A different `.2` throw path — ruled out.** `getAppInfoForFile` appears exactly once in the `.2` bundle (in `whichApplication`), and it returns `null` cleanly. There is no second call site or alternate path in the shipped bytes that throws this string. A "broken picker" he's seeing, if real and distinct, is more likely a `browseFolder`/`dialog.showOpenDialog` issue misattributed to the #720 error — a separate defect that would need its own repro.

**Verdict:** On the pinned `1.18286.2` bytes (amd64 binding `369514aa…`, byte-identical to `.0`), the missing-export hypothesis is **falsified** — `getAppInfoForFile` is exported, is a function, and returns `null` on Linux. #780's present-tense report is most consistent with a citation of the historical #720 error string (candidate 1) rather than a fresh throw; runtime module shadowing (candidate 2) is the only mechanism that could produce a genuine fresh throw on 3.x, and our packaging cannot cause it. #720 stays **OPEN as a tracking issue** — no upstream filing until a first-party 3.x `main.log` stack trace distinguishes candidate 1 from candidate 2.

## Suggested upstream fix (conditional — only if a real repro pins candidate B)

Harden the `whichApplication` guard from truthiness to method-existence, matching the strict pattern the same bundle already uses for `connectUnixSocketSameUid`:

```js
// current
whichApplication:async n=>{const o=wa();return o?o.getAppInfoForFile(n):null}
// suggested
whichApplication:async n=>{const o=wa();return typeof o?.getAppInfoForFile==="function"?o.getAppInfoForFile(n):null}
```

This is explicitly **not** something we patch (patch-zero / [D-002](../decisions.md)); it is the upstream ask, and only warranted if a first-party `main.log` confirms a truthy-but-incomplete module is reaching `wa()`. Absent that, the correct resolution is the reporter clearing a stale `@ant/claude-native` from their environment.

## Evidence needed before filing

- A first-party 3.x `main.log` line showing the throw with its stack (and whether `Failed to load Claude Native` precedes it).
- A require-probe of the reporter's *installed* `claude-native-binding.node` (see the #720 draft comment recipe).

## Voice and authorship

---
Written by Claude Fable 5 via [Claude Code](https://claude.ai/code)
