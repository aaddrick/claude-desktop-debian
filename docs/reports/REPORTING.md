# Reporting Standard

The single convention for every analysis report this project publishes under `docs/reports/`. This
page defines the scheme; the index of released reports lives in [`REPORTS.md`](./REPORTS.md).

## Document ID

```
CDL-ANT-0009-A
│   │   │    └── rev: A, B, C … (material re-issues; carried in the file name)
│   │   └─────── sequence: zero-padded, assigned in order, never reused
│   └─────────── series: ANT — analyses of Anthropic's upstream Claude Desktop
└─────────────── project: CDL (Claude Desktop on Linux)
```

The series' first published report is CDL-ANT-0008; numbers below 0008 are unpublished and stay
unused. Claim the *Next available* number from [`REPORTS.md`](./REPORTS.md) before starting a
report, and increment the pointer.

## Folder and file naming

- **Report folder:** `CDL-ANT-NNNN_<kebab-slug>` — the folder slug carries **no** rev.
  (e.g. `CDL-ANT-0009_patch-suite-history`)
- **Report file:** `CDL-ANT-NNNN-<REV>_<Descriptive_Name>.<ext>` — the rev is part of the file
  name so re-issues sit side by side. (e.g. `CDL-ANT-0009-A_The_Legacy_Patch_Suite.pdf`)
- **Supporting files** (dossiers, data, build scripts) keep plain descriptive names and live inside
  the report's folder, so the deliverable and the evidence that produced it never drift apart.
- CDL-ANT-0008's files predate this convention and keep their published names
  (`claude-desktop-linux-teardown.{tex,pdf}`); links to them already exist in public issues.

## Revisions

Start at rev `A`. Bump to `B`, `C`, … only for **material** re-issues of the same report. A rev
bump means a **new file** (`…-B_…`) beside the old one; never an overwrite.

## Lifecycle (Status)

```
DRAFT ──▶ FINAL ──▶ SUPERSEDED   (replaced by a newer rev/report)
              └──▶ ARCHIVED     (retired, no replacement)
```

Keep the status in sync between the [`REPORTS.md`](./REPORTS.md) row and the report's own cover
title block and footer.

## Authoring

Reports are built from the XeLaTeX template in [`templates/latex/`](./templates/latex/), the one
CDL-ANT-0008 and CDL-ANT-0009 use, in the Graphite + Copper visual language. Fonts: Public Sans
(body), IBM Plex Mono (labels), DejaVu Sans (symbols). Two XeLaTeX passes for stable layout; see
`templates/latex/build/`.

## House style

Prose avoids **em dashes**. Replace them with a comma, period, colon, semicolon, or parentheses,
whichever fits the grammar. En dashes in numeric ranges (`2024-2025`, `0-100`) are fine. Both
templates restate this rule in their headers.

## Issuing a report

1. **Claim the number.** Take *Next available* from [`REPORTS.md`](./REPORTS.md) and increment it.
2. **Create the folder** `CDL-ANT-NNNN_<slug>` and author the report as rev `A` from a template.
3. **Record it** as a row in [`REPORTS.md`](./REPORTS.md) with status DRAFT.
4. **Maintain status** as the report moves DRAFT → FINAL → SUPERSEDED/ARCHIVED.
