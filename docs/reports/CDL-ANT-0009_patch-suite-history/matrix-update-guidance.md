# Matrix update guidance (next session)

> **Status: DONE (Rev B, 2026-07-04).** The matrix update this doc describes
> has shipped, and the open checks it names were settled on live hardware
> (see §21 of the report and the learnings doc's open-items section).
> References below to `verdict-verification-tracking.md` point at the live
> checklist that captured those runs; it was a working journal and is **not
> committed** — its settled conclusions live in
> [`../../learnings/official-deb-rebase-verification.md`](../../learnings/official-deb-rebase-verification.md).
> This file is retained as a record of the update procedure.

Update the patch-necessity matrix in
[`../../learnings/official-deb-rebase-verification.md`](../../learnings/official-deb-rebase-verification.md)
to reflect the accessibility reassessment and its ground-truth
verification, without reversing already-shipped code. Everything below is
grounded in two sibling docs and pristine official bytes; read them first.

## Pickup prompt

> Update the patch-necessity matrix in
> `docs/learnings/official-deb-rebase-verification.md`. Read, in order:
> this file (`matrix-update-guidance.md`),
> `verdict-verification-tracking.md` (the live checklist with per-verdict
> status), and `verdict-reassessment-accessibility.md` (the reasoning).
> The reassessment re-ran the matrix under an accessibility-maximizing lens
> and the verification pass ground-truthed every verdict against a pristine
> official **1.18286.0** `.deb` (sha256 `8f314ad1…0536`) via
> `tools/patch-necessity-audit.sh`. Apply the edits in "Exact matrix edits"
> below. Every changed cell must cite pristine-byte evidence (audit verdict,
> file anchor, or issue number) — do not hand-wave. Hedge live-hardware
> claims ("static analysis says", "pending repro"). Do NOT read a verdict
> flip as "re-add the patch": frame-fix and wco-shim are already deleted and
> shipped; the flip to `verify` records that the deletion carries an
> unverified accessibility risk pending a live check, not that code must
> change. Run a contrarian gate (Agent tool, `contrarian` agentType) on the
> rewritten matrix section against the two sibling docs before declaring
> done. We are on `rebase/official-deb`: do NOT touch main, do NOT tag, do
> NOT hand-bump the pin (`check-claude-version`'s job). `docs/reports/` and
> `docs/learnings/official-deb-rebase-verification.md` are both editable on
> this branch. Update `verdict-verification-tracking.md`'s status column as
> you land each edit.

## What changed and why (one paragraph)

The matrix was authored against pinned **1.17377.2** bytes on a patch-zero
objective (default verdict = delete). The reassessment re-scored it for
accessibility (widest reported-environment coverage), and verification
confirmed all three flips on fresh **1.18286.0** bytes. The flips all move
`delete`/`survivor-candidate` → `verify`, because their load-bearing
evidence lives where `.deb` bytes cannot reach: Electron-runtime WM
behavior (frame-fix), the remote claude.ai bundle (wco-shim), or the
Electron `isFocused()` implementation (quick-window). Nothing that was
byte-provable changed direction. Two survivors firmed. One reassessment
claim (password-store) was overstated and must NOT be copied into the
matrix — the matrix is already silent on it, keep it that way.

## Exact matrix edits

Table rows are the current matrix's first column. "New verdict" replaces the
Verdict cell; append the evidence to the Evidence cell.

| Row | Current | New verdict | Evidence to cite |
|---|---|---|---|
| `frame-fix-wrapper.js` | delete | **delete (byte-moot slice) / verify (accreted fixes)** | Audit `check` on 1.18286.0 ("frame:!1 occurs 3x"). Frame-core / titlebar-mode / wco-pairing / autoUpdater-no-op are byte-moot (delete stands). The ~18 accreted Electron-runtime fixes (#416, #605, #128, #623) track *unfixed upstream Electron* issues → **open check FF-1** before relying on the deletion. |
| `wco-shim.sh` | delete | **delete (local WCO half) / verify (remote UA gate)** | Audit `not-needed` is explicitly "(mainView refs: 0)" — local bundle only. The load-bearing `isWindows()` UA regex is in server-delivered claude.ai JS, unknowable from bytes → **open check WCO-1** (same item as the topbar open-item). |
| `quick-window.sh KDE blur/focus` | survivor candidate | **verify (keep-pending-repro)** | Pristine var `ms`: `\|\|hide()` present, no `blur()` on 1.18286.0 — survivor signal intact. Bug is in Electron `isFocused()`, not app bytes → **open check QW-1** decides keep-vs-drop. Stays in `active_patches` until QW-1 runs. |
| `org-plugins.sh` | survivor candidate | **survivor** | Byte-confirmed on pristine 1.18286.0: switch `...org-plugins");default:return null`, no linux case (count 0). Firm the verdict; keep-cost ~0, self-defusing anchor. (Earlier "native linux case" reading was a *patched-tree* false positive — note it so it is not re-introduced.) |
| all other rows | (unchanged) | (unchanged) | Append "re-confirmed pristine 1.18286.0" where the audit re-ran clean (tray, menubar, claude-code, native-stub, node-pty, autoupdater, asar-guards, config `needed?`, cowork `diverges`). |

## Also update these sections of the learnings doc

- **Install-layout facts** — add: (a) the layout is bare co-located with
  **no `node_modules/electron/dist`** (this is what breaks the artifact
  tests, SB-1); (b) compression changed `zst` (1.17377.2) → `xz`
  (1.18286.0), handled by `_extract_deb_member`; (c) `chrome-sandbox`
  recorded `-rwsr-xr-x root/root`, stripped by non-root extract, re-asserted
  by postinst.
- **Open items** — replace/extend with the verification tracking's live
  checklist: FF-1, WCO-1, QW-1, LD-1 (kwallet6 cookie persistence), config
  #400. Each carries its reported-environment population (see
  `verdict-verification-tracking.md`).

## Decision to make this session

**Extend the learnings matrix to the full 18 units, or keep it app.asar
focused?** The reassessment and `affects-lines.md` cover five packaging
units the learnings matrix omits (sandbox-shims survivor, ssh-helpers
delete, icons delete, launcher-doctor rework, acquisition rework). Options:
(a) add five rows so the learnings matrix matches the report; (b) keep the
learnings doc scoped to app.asar patches and cross-link the report for the
packaging layer. Recommend (b) with a one-line pointer — the learnings doc
is the *patch* audit; packaging fate belongs to the report and the rebase
tracking file. Confirm with aaddrick if unsure.

## Follow-on code fixes (NOT part of the matrix edit — separate PRs)

These came out of the verification pass and are tracked in
`.tmp/plans/official-deb-rebase-tracking.md`; list them in the matrix's Open
items only as pointers, do not implement them in the same change:

1. **ACQ-1** — `nix/claude-desktop.nix:18` hard `throw`; largest single
   accessibility win (Nix = biggest install channel). Owner @typedrat.
2. **SB-1** — repoint `test-artifact-{deb,rpm,appimage}.sh` +
   `launcher-common.bats` off the dead `node_modules/electron/dist` prefix
   to the bare layout. CI-gating. Coordinate with @sabiut.
3. **LD-2** — add `CLAUDE_QUIT_ON_CLOSE` to `doctor.sh` `_check_legacy_env`
   (currently omits it).
4. **AU-1 / MB-1** — build tripwires on `apt_channel_pending` and
   `menuBarEnabled:!0` so a future upstream flip is caught at build time.

## Guardrails

- **A verdict flip is an annotation, not a code reversal.** frame-fix and
  wco-shim are deleted and shipped; the `verify` tag documents residual
  risk + the open check. Only quick-window/org-plugins actually sit in
  `active_patches` (`scripts/patches/app-asar.sh:26-29`).
- **Do not import the password-store "regression" framing.** It was a
  deliberate, documented rework (`launcher-common.sh:202-211`, #593); the
  live kwallet6 risk (LD-1) is the only open part.
- **Live-hardware checks cannot be closed from source.** FF-1/WCO-1/QW-1/
  LD-1 stay open; the matrix records them, it does not resolve them.
- Branch discipline: no main, no tag, no hand-bump; contrarian-gate the
  rewritten section; public-facing prose through the aaddrick-voice agent.
