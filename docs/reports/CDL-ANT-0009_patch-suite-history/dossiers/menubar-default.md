# Dossier: menuBarEnabled default-to-true patch

Unit: `patch_menu_bar_default()` in `scripts/patches/tray.sh` (main, ~line 277).
Purpose: make the tray/menu bar default ON when the `menuBarEnabled` config key
is missing, instead of the minified bundle's `!!undefined` → `false` coercion.

## Mechanism

Source read via `git show main:scripts/patches/tray.sh` (function
`patch_menu_bar_default`, lines ~277–312 on main). It operates on
`app.asar.contents/.vite/build/index.js` and works in two stages:

1. **Dynamic identifier extraction.** The minified variable holding the
   preference is captured off the stable string literal `"menuBarEnabled"`
   (literal-as-position-anchor, per `docs/learnings/patching-minified-js.md`):

   ```
   menu_bar_var=$(grep -oP \
       'const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))' \
       "$index_js" | head -1)
   ```

   If extraction fails it prints `Could not extract menuBarEnabled variable
   name` and `return`s (warn-and-continue, not a build failure).

2. **The rewrite.** In the upstream bundle the tray gate was
   `const t = Vn("menuBarEnabled"); if(!!t){ new Tray(...) }` (bundle bytes
   quoted in issue #218). `!!undefined` is `false`, so a missing key disabled
   the tray. The patch flips the coercion so only an explicit `false` disables:

   ```
   if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
       sed -i -E \
           "s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
           "$index_js"
   ```

3. **Three-branch outcome ladder** (final main shape, added in 6091615 and
   eb12ad8):
   - legacy `,!!VAR)` anchor present → rewrite to `VAR!==false`;
   - `elif grep -qP 'menuBarEnabled:[ \t]*!0\b'` → upstream defaults map
     already ships `menuBarEnabled:!0` (true); patch is a no-op **by design**
     and says so (`menuBarEnabled already defaults to true upstream`);
   - neither shape → loud `WARNING: ... the tray may default OFF on a fresh
     install; the default shape likely changed` to stderr, so a future default
     flip back to false surfaces instead of hiding.

   **Idempotency** is by anchor consumption: after the rewrite the `,!!VAR)`
   anchor no longer exists, so a re-run falls through to branch 2 or 3 rather
   than double-patching. The three branches are covered by
   `tests/tray-patches.bats` on main (cases at lines 136, 144, 157:
   "recognizes the upstream defaults map as already-true", "still rewrites the
   legacy !!var shape", "warns when neither legacy anchor nor upstream default
   exists").

Runtime behavior change (legacy bundles only): fresh installs and
post-update configs where the updater dropped the key get the tray/menu bar
ON instead of silently OFF.

## Origin

- **First commit:** `7bd2f38`, 2026-02-08, "fix: use regex extraction for
  electron variable in tray patches" (author aaddrick, Co-Authored-By
  Claude). The commit body lists "Patch menuBarEnabled to default to true
  when config key is missing" as one of five bullets and carries
  `Fixes #218` / `Fixes #219`. It added `patch_menu_bar_default()` to
  `build.sh` (build.sh had already been organized into functions by
  `29173e9`, 2026-01-22, so the unit was born as a named function — no
  earlier pre-function form exists; pickaxe `-S '!==false'` and
  `-S 'patch_menu_bar_default'` both bottom out at 7bd2f38).
- **Motivating report:** issue #218 (Voork1144, 2026-02-07, "Tray icon
  missing — Anthropic's app.asar has oe/Ae minifier bug + menuBarEnabled
  config reset on update"). Its "Bug 2: menuBarEnabled config reset
  (upstream)" section quotes the gate
  `const t = Vn("menuBarEnabled"); if(!!t) { Ds = new Ae.Tray(...) }` from
  upstream **1.1.2321** and reports that updates removed the key from
  `~/.config/Claude/config.json`, silently disabling the tray; the manual
  workaround was adding `"menuBarEnabled": true` by hand. The issue itself
  proposed the build-time fix ("ensure menuBarEnabled defaults to true").
- Issue #219 (dlepold, 2026-02-08, "Tray icon patch uses wrong variable name
  (oe vs Ae) in v1.1.2321") was closed by the same commit but concerns the
  sibling electron-variable bug, not the default itself (its body has no
  `menuBarEnabled` mention).

## Revision history

Substantive changes only, from `git log -L :patch_menu_bar_default:` across
the build.sh → tray.sh move:

- **7bd2f38** (2026-02-08) — created, in `build.sh`. Fixes #218/#219 (cause
  stated in commit message). Original else-branch message: "pattern not
  found or already patched".
- **4043474** (2026-02-08) — readability refactor: introduced the
  `local index_js=` variable, reflowed the grep/sed. No behavior change
  (cosmetic; noted for completeness).
- **ff4821e** (2026-04-20) — "refactor: split build.sh into topical modules
  under scripts/": function moved verbatim into `scripts/patches/tray.sh`.
- **b40441c** (2026-05-24, merged as PR #644 2026-05-25) — "fix(patches):
  harden regex patterns for minified JS identifiers": extraction pattern
  widened from `\w+` to `[$\w]+` on both the declared variable and the
  getter name (`const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))`), so
  `$`-containing minified identifiers resolve. Cause stated in the PR/commit
  title; follows the `$`-identifier recurrences first hit in PR #627
  (fixing issue #625) / #559 territory (the `\w` vs `$` trap recorded in
  `docs/learnings/patching-minified-js.md`).
- **6091615** (2026-06-26) — "fix(tray): re-derive in-place fast-path for the
  1.13576+ rebuild refactor". Fixed the 1.13576+ breakage; issue #750 was
  filed 39 seconds **after** this commit (commit 2026-06-26T10:54:37Z vs
  issue createdAt 2026-06-26T10:55:16Z), from the same review session — its
  "## Fix" section opens "On branch `claude/review-open-issues-prs-d4cjs6`
  (commit `6091615`)". The issue records the breakage analysis and the
  already-existing fix; it did not trigger the commit (the commit body
  contains no #750 reference). Upstream 1.13576+ moved
  the preference behind a settings getter (`Di("menuBarEnabled")`) backed by
  a defaults map that already ships `menuBarEnabled:!0`; the legacy `,!!VAR)`
  anchor vanished. The commit added the `elif` defaults-map probe so the
  no-op-by-design case is distinguished from a genuine miss, downgraded
  nothing silently, upgraded the else-branch to a loud stderr WARNING, and
  added `tests/tray-patches.bats` covering all three branches (commit body:
  "the three menu-bar-default branches. Full suite 329/329", verified
  against the real 1.15962.0 app.asar). Issue #750's section "Not a
  regression: `patch_menu_bar_default`" records the bundle bytes:
  `Di=A=>{const e=tg().preferences??{}; …; return {...Bpt,...e,...A}[A]}`
  with `Bpt={menuBarEnabled:!0, …}`.
- **eb12ad8** (2026-06-26) — "fix(tray): assert single TRAY.destroy() anchor;
  tighten default probe": the defaults-map probe tightened from
  `menuBarEnabled:\s*!0\b` to `menuBarEnabled:[ \t]*!0\b` so the same-line
  match cannot span a newline on a beautified bundle (cause stated in commit
  body: hardening per docs/learnings/patching-minified-js.md review).

Not revisions of this unit but adjacent: `cf2b0fc` (#515) reused the same
`const X = fn("menuBarEnabled")` anchor for `patch_tray_inplace_update`'s
`enabled_var` extraction — same anchor family, different function.

## Related issues and PRs

- **#218** — issue, CLOSED, "Tray icon missing — Anthropic's app.asar has
  oe/Ae minifier bug + menuBarEnabled config reset on update". **Motivated
  the patch**; documents the upstream `if(!!t)` gate and the config-key
  reset on update; proposed the build-time default. Closed by 7bd2f38.
- **#219** — issue, CLOSED, "Tray icon patch uses wrong variable name (oe vs
  Ae) in v1.1.2321". **Sibling report** closed by the same origin commit;
  concerns the electron-variable bug, not the default.
- **#644** — PR, MERGED (2026-05-25), "fix(patches): harden regex patterns
  for minified JS identifiers". **Revision**: widened this unit's extraction
  regex to `[$\w]+` (commit b40441c).
- **#750** — issue, OPEN, "tray.sh in-place fast-path silently broken on
  1.13576+ (yukonSilver rebuild refactor) → #515 duplicate-icon race
  re-arms". **Documents the breakage 6091615 fixed** (filed alongside the
  commit — 39 seconds after it, from the same review session; its body cites
  the commit hash and branch). Explicitly records that
  `patch_menu_bar_default` becoming a no-op on 1.13576+ is not a regression
  because upstream's defaults map ships `menuBarEnabled:!0`.
- **#515** — PR (merged; commit cf2b0fc 2026-04-27), "fix: update Linux tray
  icon in place on OS theme change". **Adjacent**: reuses the
  `"menuBarEnabled"` literal anchor for its own extraction; cited in
  `patching-minified-js.md` as the tray anchor exemplar.
- **#680** — PR, MERGED (2026-06-04), "fix(tray): startup icon stuck black —
  make rebuild mutex trailing-edge (#679)" (author LiukScot; commits
  e13e331, 55bc328, a5b54dd, 2ad33d3, 9505574). Its constituent commit
  2ad33d3 ("fix(tray): warn loudly when menu-function resolution fails
  (#680)") upgraded `patch_tray_inplace_update`'s silent skip to a loud
  stderr WARNING — the warning that #750 (body: "the #680
  `WARNING: could not resolve tray menu function`") and 6091615's commit
  body ("#680 WARNING fired") both reference, i.e. the guard that exposed
  the 1.13576+ breakage. **Adjacent tray context**; does not modify this
  unit.
- **#627** — PR, MERGED (2026-05-21), "fix(tray): support $-containing
  identifiers in 1.8089.1 minified bundle (#625)" (author typedrat;
  squash-merged as commit 6219d5a), fixing issue #625. **Background** for
  the `[$\w]+` hardening line that #644 extended to this unit; 6219d5a's
  diff touches only `patch_tray_menu_handler` and
  `patch_tray_inplace_update`, not `patch_menu_bar_default` (its commit
  body does record `patch_menu_bar_default: e!==false defaulting applied`
  as part of its 1.8089.1 end-to-end verification).
- **#625** — issue, CLOSED, "[bug]: nix build failure on decb512" (fdnt7,
  2026-05-20). **Motivating issue for PR #627**: the nix build aborted
  because `\w+` extraction missed the `i$A` menu handler and
  `patch_tray_menu_handler` exits 1, taking every downstream patch —
  including this unit — with it. Closed by 6219d5a ("Fixes #625").

Search (`gh search issues 'menuBarEnabled'`) surfaced no additional direct
reports beyond #218 and #750; other hits are the same tray family or
unrelated (nix build failures citing logs).

## Learnings

- `docs/learnings/official-deb-rebase-verification.md` — the
  patch-necessity matrix row for this unit (quoted below); the deciding
  document for its fate.
- `docs/learnings/patching-minified-js.md:170` — "**Tray (PR #515).**
  `tray.sh:16` uses the literal `"menuBarEnabled"` as a *position anchor*,
  then captures the surrounding minified identifier ... Two stages: stable
  literal → derived identifier." This unit uses the identical
  literal-anchor/derived-identifier technique on the same literal.
- `docs/learnings/tray-rebuild-race.md:70,80,85` — records that disabling
  the tray "via `menuBarEnabled` setting" drives the destroy path, and lists
  `enabled_var` extraction `const X = fn("menuBarEnabled")` in its anchor
  table — the same anchor family this unit greps.

## Fate under the official-deb rebase

Matrix row, quoted verbatim from
`docs/learnings/official-deb-rebase-verification.md:20`:

> | menuBarEnabled default | **delete** | Defaults map ships `menuBarEnabled:!0`. |

**Byte-level evidence.** The doc header states the matrix was verified
against the official Linux `.deb` **1.17377.2**, audited 2026-07-02, and
that any row is reproducible with `tools/patch-necessity-audit.sh`. That
tool's `probe_menu_bar_default()` (working tree,
`tools/patch-necessity-audit.sh:157-165`) greps the extracted official
bundle for exactly the eb12ad8-era anchor:

```
if LC_ALL=C grep -qP 'menuBarEnabled:[ \t]*!0\b' "$index_js"; then
    report 'menuBarEnabled default' 'not-needed' \
        'defaults map ships menuBarEnabled:!0'
```

The same defaults-map bytes were first captured (on the pre-official
1.15962.0 Windows-derived bundle) in issue #750:
`Bpt={menuBarEnabled:!0, …}` behind the `Di("menuBarEnabled")` getter — the
official deb inherits that shape, so an unset preference already resolves to
`true` upstream with no patch at all.

**How the new build handles it.** On the working tree
(`rebase/official-deb`):

- `scripts/patches/tray.sh` is deleted entirely; the whole tray family
  (mutex/delay/in-place, icon selection, and this default) is gone.
- `scripts/patches/app-asar.sh` defines
  `active_patches=(patch_quick_window patch_org_plugins_path)` — the only
  two survivor candidates. `patch_menu_bar_default` is not sourced or
  invoked anywhere; `grep -rn 'menuBarEnabled' scripts/` on the working tree
  returns nothing.
- `patch_app_asar` carries the patch-zero contract in its header comment:
  the default verdict for any patch is delete, and with an empty array the
  official app.asar ships byte-identical.
- `tests/tray-patches.bats` is deleted along with the function (working-tree
  `tests/` contains only doctor/launcher bats and artifact tests).
- Nothing in `scripts/setup/official-deb.sh`, `scripts/launcher-common.sh`,
  or `scripts/doctor.sh` compensates for this unit — none needed, since the
  default lives in upstream's own bundle.

The verdict is unconditional (not one of the two "survivor candidate" or
"verify behaviorally" rows). The only forward-looking guard the legacy suite
had — the loud WARNING if upstream ever flips the default back to `!1` — is
retired with the file; the audit tool's `probe_menu_bar_default` `check`
branch ("defaults-map anchor absent — read the settings getter") is now the
sole detector for a future default flip.

## Gaps

- The teardown report directory `.tmp/reports/linux-official-teardown/`
  contains no `menuBarEnabled` mention; the 1.17377.2 byte evidence rests on
  the matrix row plus the reproducible audit-tool probe, not on a preserved
  grep transcript. I did not download the official .deb to re-run the probe
  myself.
- I could not determine whether commits 6091615/eb12ad8 landed via a
  reviewed PR; #750 names the working branch
  `claude/review-open-issues-prs-d4cjs6`, but no PR number for that merge
  surfaced in commit messages or search.
- #515 was verified as a merged change via commit cf2b0fc's subject; I did
  not separately confirm its PR metadata via `gh` (the number appears as a
  PR in `patching-minified-js.md` and as the referenced race in #750).
- Whether any end user was ever bitten by the warn-and-continue extraction
  miss (branch 1 failing silently pre-6091615) is not recorded anywhere I
  found; no issue reports a tray defaulting OFF between 1.13576 and the
  6091615 fix — consistent with #750's "no-op by design, not a regression"
  analysis, but absence of reports is not proof (inference).
