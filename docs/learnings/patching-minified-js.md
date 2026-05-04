# Patching minified JavaScript

Hard-won lessons from maintaining a long-lived patch suite against an
actively re-minified upstream. Each section names a failure mode and
the fix.

The verification recipes below use claude-desktop-debian-specific
incantations (Claude-Setup.exe, nupkg extraction, `build.sh
--build appimage`); substitute your own project's fetch/extract/build
commands as needed.

## Capturing identifiers: `\w` doesn't match `$`

JS identifiers allow `$` and `_`; minifiers freely emit names like
`$e`, `C$i`, `g$x`. The character class `\w` is `[A-Za-z0-9_]` — it
does not match `$`. A `(\w+)` against `$e` captures the suffix `e`
and returns a name that doesn't exist in the file. The failure is
silent: regex matches, downstream sed runs against a truncated name,
asar ships broken JS. Three recurrences (PRs #253, #421, #555) before
the convention stuck.

Use `[$\w]+` (repo convention; `[\w$]+` is equivalent). Strict
superset of `\w+`, so pre-`$` versions still match. Live at
`cowork.sh:484-502`:

```bash
const fsMatch = region.match(/([$\w]+)\.existsSync\(/);
```

## The beautified false-negative trap

Testing a regex against `build-reference/` is not verification. The
beautified copy has whitespace the regex doesn't account for.

During PR #555, both `\w+` and `[\w$]+` tested false against the
beautified file. Shipped minified bytes:

```js
await new Promise(n=>setTimeout(n,g$x))
```

Beautified copy:

```js
await new Promise((n) => setTimeout(n, g$x))
```

`await new Promise\(([\w$]+)=>\s*setTimeout\(\1,\s*([\w$]+)\)\)` fails
the beautified version on the parens and spaces around `=>`. Always
close the loop against shipped bytes.

## Whitespace tolerance: `\s*` vs `[ \t]*`

`\s` matches newlines. A `\s*`-padded pattern is a license to span
across structural boundaries the original line layout meant to
keep apart — usually fine on minified bytes (no newlines to span),
much looser on beautified.

Use `[ \t]*` when the intent is "spaces but stay on this line."
Reserve `\s*` for crossing structural boundaries on purpose. The
existing `cowork.sh` patches mix both — `\s*` where the surrounding
context is bounded enough that newline-spanning is harmless, and
literal token sequences (`",b:` etc.) when stricter adjacency is
required.

## Replacement-string escaping: `\1`, `&`, `$1`

A regex can match correctly and still produce corrupted output
because the *replacement string* has its own metacharacters. Match
debugging shows green; the asar still ships broken bytes. Three
flavors:

**sed `&`** — the entire match. `sed 's/foo/&_suffix/'` is fine
(`foo_suffix`). `sed 's/foo/literal_&_dollar/'` accidentally
interpolates the match (`literal_foo_dollar`). Escape with `\&` if
you want a literal ampersand:

```bash
sed 's/foo/literal_\&_dollar/'   # → literal_&_dollar
```

**sed `\1`** — backreferences in the replacement. These work as
expected in BRE/ERE. The footgun is the *pattern* side: in BRE, `$`
is the end-of-line anchor, so a literal `$` in the search pattern
needs `\$`. `_common.sh:25` does exactly this for `electron_var`,
which can be `$e` on newer upstream:

```bash
electron_var_re="${electron_var//\$/\\$}"
```

That escaping is for the sed *pattern*, not its replacement.

**JS `String.prototype.replace`: `$1`, `$&`, `$$`** — the JS
replacement DSL is its own thing. `$&` is the whole match; `$1..$9`
are capture groups; `$$` is a literal `$`. Plain `$` followed by an
unrelated char is left alone, but `$&` and `$N` get interpolated:

```js
code.replace(/foo/g, '$cost')   // → '$cost' (safe, no special)
code.replace(/foo/g, '$&_x')    // → 'foo_x' ($& = match)
code.replace(/foo/g, '$$cost')  // → '$cost' (escaped)
```

If the replacement is an injected JS snippet that happens to
contain `$1` or `$&` (template literals, jQuery, regex source), JS
will eat them. Use `$$` to escape, or build the string with
concatenation so `$` never sits next to a digit or `&`.

## Idempotency: a re-run must be byte-identical

Without it, CI re-runs and partial builds layer mutations until
something breaks visibly. Three patterns:

**Re-key the guard to post-rename names.** `tray.sh:174-180` keys its
fast-path guard on the post-rename
`${tray_var}.setImage(${electron_var}.nativeImage.createFromPath(${path_var}))`
sequence, so the second run recognizes its own first-run output.

**Negative lookbehind, inline.** `cowork.sh:102-106` — the
`(?<!...)` prevents a second match against text the first run
already wrapped:

```js
const logRe = new RegExp(
    '(?<!\\|\\|process\\.platform==="linux"\\))' +
    win32Var.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
    '(\\s*\\?\\s*"vmClient \\(TypeScript\\)")'
);
```

**Explicit `code.includes(...)` check.** `cowork.sh:227-230`
separates "anchor missing" from "already applied" in the build log:

```js
} else if (code.includes(
    'getDownloadStatus(){return process.platform==="linux"?'
)) {
    console.log('  Cowork auto-nav suppression already applied');
}
```

PR #436 verified by running the patch twice and diffing the output.

## Anchor selection: prefer literals over identifiers

The above sections cover making a patch work on first run. This one
covers keeping it working release after release. A patch can apply
cleanly today and silently no-op next month.

Minified identifiers churn every release. Developer strings —
property names, log messages, IPC channel names — survive
minification untouched (true for the upstream bundler used here; a
`--mangle-props` build would invalidate property-name anchors).
Anchor on those. A hardcoded minified name silently no-ops the next
release; the build log still says "patched."

Three patterns from the suite:

- **Quick-window (PR #390, fixing #144).** Original patch:
  `s/e.hide()/e.blur(),e.hide()/`. When `e` became `Sa`, it no-oped.
  The rewrite anchors on `"pop-up-menu"` (`quick-window.sh:17`), the
  `isWindowFocused` property name (`quick-window.sh:60`), and the
  `[QuickEntry]` log strings (`quick-window.sh:88-91`).
- **Cowork spawn (PR #436).** Anchored on `,VAR.mountConda)`
  (`cowork.sh:741`) — unique to the 12-arg call path, absent from the
  10-arg one-shot. Asserts match count is exactly 1 and bails
  otherwise (`cowork.sh:744`), so a future second caller surfaces
  immediately.
- **Tray (PR #515).** `tray.sh:16` uses the literal `"menuBarEnabled"`
  as a *position anchor*, then captures the surrounding minified
  identifier (`\K\w+(?=\(\)\})`) as the actual patch target. Two
  stages: stable literal → derived identifier. Every other tray name
  chains off that single dynamic extraction.

The lesson is about finding stable points to anchor on, not about
what gets patched. The patch target is usually a minified identifier;
the *anchor* should be a developer string nearby.

## Multi-site coordinated patches: surface partial application

Site 1 patches, site 2 misses, the asar ships half-wired. The
pattern: each sub-patch sets a per-site boolean flag on success,
then a single named WARNING fires if any flag is false:

```js
if (!siteADone || !siteBDone) {
    console.log('  WARNING: <ticket> partial — siteA=' + siteADone +
        ' siteB=' + siteBDone + '; <fallback consequence>');
}
```

CI greps the build log for `WARNING:` and fails the build. That
catches the half-patched state even when individual sub-patches each
log "applied." See `cowork.sh:759-763` for a real instance —
three-site `sharedCwdPath` forwarding, daemon fallback if any site
misses.

## Disambiguating non-unique anchors: lastIndexOf over indexOf

A string anchor can appear in source maps, dead exports, or
chunk-merged duplicates alongside the live code. `indexOf` returns
the first; that may be wrong.

`cowork.sh:264` uses `lastIndexOf(serviceErrorStr)` to bias toward
appended code. On 1.5354.0 the string occurs once, so the change is
a no-op there — the defense is for a future upstream that
reintroduces the string in onboarding text or sample data far from
the live retry-loop site.

When neither side is reliable, narrow the search region first.
`cowork.sh:269-276` does this for the ENOENT check, scanning only a
300-character window before the error string.

## Verifying a hypothesis before shipping a fix

Pull the pinned URL and SHA from `scripts/setup/detect-host.sh`,
download, verify hash, extract without beautifying, and test the
regex against the minified bytes:

```bash
url=$(grep -oP "claude_download_url='\K[^']+" \
    scripts/setup/detect-host.sh | head -1)
expected=$(grep -oP "claude_exe_sha256='\K[^']+" \
    scripts/setup/detect-host.sh | head -1)
mkdir -p /tmp/verify && cd /tmp/verify
wget -q -O Claude-Setup.exe "$url"
echo "$expected  Claude-Setup.exe" | sha256sum -c -

7z x -y Claude-Setup.exe -o exe
nupkg=$(find exe -name 'AnthropicClaude-*.nupkg' | head -1)
7z x -y "$nupkg" -o nupkg
npx asar extract nupkg/lib/net45/resources/app.asar app

node -e '
  const fs = require("fs");
  const code = fs.readFileSync(
    "app/.vite/build/index.js", "utf8");
  const re = /await new Promise\(([\w$]+)=>\s*setTimeout\(\1,\s*([\w$]+)\)\)/;
  const m = code.match(re);
  console.log(m ? `MATCH: ${m[0]}` : "NO MATCH");
'
```

`NO MATCH` means the regex is wrong. Verifying the SHA defends against
stale URL pinning or server-side binary swap.

## End-to-end verification (post-build)

Four layers: build log, syntactic validity, asar markers, runtime.

1. Check the patch-count line:

   ```bash
   ./build.sh --build appimage --clean no 2>&1 | tee build.log
   grep -E 'Applied [0-9]+ cowork patches' build.log
   ```

   Healthy 1.5354.0 build: `Applied 12 cowork patches`. A lower
   number, or any `WARNING:` in the cowork section, is a half-patched
   asar.

2. `node --check` on the patched `index.js` — catches malformed
   replacements that serialize but don't parse (PR #436 used this in
   dry-run validation):

   ```bash
   node --check test-build/.../app.asar.contents/.vite/build/index.js
   ```

3. Static-grep the shipped asar for the 9 cowork markers from PR
   #555. A `verify-cowork-patches.sh` helper that automates this is
   planned (issue #559 D6); prefer it once it lands.

4. Launch the AppImage and check runtime state:

   ```bash
   tail -20 ~/.config/Claude/logs/cowork_vm_daemon.log
   ls -la "${XDG_RUNTIME_DIR}/cowork-vm-service.sock"
   ss -lpx | grep cowork-vm-service.sock
   ```

   Daemon log should have `lifecycle startup` and `lifecycle
   listening`; socket should exist and be owned by the
   `cowork-vm-service.js` process listed by `ss`.

## Cross-references

- `tray-rebuild-race.md` "Resilience to minifier churn" — prior art
  for dynamic extraction across a six-variable patch site and the
  post-rename idempotency-guard pattern.
- `plugin-install.md` "Getting the Minified Source for Any Shipped
  Version" — the `reference-source.tar.gz` release asset gives
  beautified asar contents of any prior version for diffing. Useful
  for spotting when an identifier renamed and which version did it.
