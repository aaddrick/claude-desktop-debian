[< Back to docs index](../index.md)

# Docs Style Guide

How docs are organized and written in this repo. The patterns here come from a survey of well-organized open-source docs (Spatie, Filament, laravel-docs, earendil-works/pi) plus what's worked in this project's own `docs/` tree. If you're adding a page, read the **Page anatomy** section before you start.

## Structure

- **Flat `docs/`**, **lowercase kebab-case** filenames (`troubleshooting.md`, not `TROUBLESHOOTING.md`; `building.md`, not `BUILDING.md`). Order belongs in this index, not filenames.
- One entry point: **[`docs/index.md`](../index.md)**. It's the GitHub-browsable landing page and the link target from every other doc.
- **Subdirectories only when a topic grows past ~5 pages.** Current subdirs:
  - [`docs/learnings/`](../learnings/) — subsystem deep-dives. Promoted out of the top level once there were >3.
  - [`docs/testing/`](../testing/) — test harness docs.
  - [`docs/issue-triage/`](../issue-triage/) — the issue-triage bot config and prompts.
  - [`docs/upstream-reports/`](../upstream-reports/) — bug reports filed against upstream that we keep alongside the patch.
  - `docs/styleguides/` — meta-docs about how to write docs and shell scripts.
- **`docs/images/`** for screenshots and diagrams. Never scatter `.png`s next to `.md`s.
- **Repo-root auxiliary files stay at the root** so GitHub auto-detects them: `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE-*`, `RELEASING.md`, `CLAUDE.md`, `AGENTS.md`. Don't move them under `docs/`.

## Page anatomy

Three skeletons recur across well-organized docs in this project. Pick one before starting a page.

### Setup / how-to page

Used for: `building.md`, `configuration.md`, `releasing.md` (in the root).

```
<one declarative sentence: what this page is for>
<one code block showing the minimum working command>
## Prerequisites          -> short list; assume Linux + git unless stated
## <Step 1>               -> one short paragraph + code block
## <Step 2>
## Common variations      -> distro-specific or flag-specific quirks
## Troubleshooting        -> link out to troubleshooting.md, don't duplicate
```

Open with the minimum command, not the prerequisites table. Readers skim to the code block first.

### Troubleshooting / FAQ page

Used for: `troubleshooting.md`.

```
<one declarative sentence: what kind of problem this page solves>
## <Symptom or error message verbatim>    -> one ### Fix per symptom, with a code block
## <Next symptom>
```

The headings are **the symptom users type into search.** Don't editorialize ("Troubles with Wayland" is wrong — `## Black screen on Fedora KDE under Wayland` is right). One `### Fix` per `##`. If a symptom needs explanation, prose goes under the fix, not in the heading.

### Subsystem deep-dive (a "learning")

Used for: everything in `docs/learnings/`.

```
<one paragraph: what subsystem this covers, when it runs, why it's non-obvious>
**Source files:** bullet list of GitHub links to the relevant source
## Overview                -> 2–3 paragraphs of context
## <Mechanic>              -> for each non-trivial mechanic, prose + diagram only when state transitions need one
## <Failure mode>          -> for each known failure, repro + diagnosis + fix path
## References              -> issues, PRs, upstream bugs, useful commits
```

Deep-dives can be long — `apt-worker-architecture.md` and `patching-minified-js.md` are >10 kB and that's fine. They serve repeat readers (future you, future contributors) hunting for a specific fact, not first-timers.

### Decision record (ADR)

Used for: entries in `docs/decisions.md`.

```
## D-NNN — <short title>
- **Status:** Accepted / Superseded / Proposed
- **Decided:** YYYY-MM-DD
- **Owner:** @handle
- **Stakeholders:** ...
### Context        -> what triggered the decision
### Decision       -> the call in one or two sentences
### Rationale      -> bullets
### Consequences   -> what was accepted, what's now out of bounds
### Alternatives Considered
### References
```

See [`decisions.md`](../decisions.md) for the live record. Don't delete superseded decisions — mark them and link forward.

## Content rules

1. **Open every page with one declarative sentence, then a code block or list.** No "In this guide we will explore…" preamble. If the page is in the root (not behind `[< Back to ...]`), the first line under the H1 is that sentence.
2. **Imperative, second-person, present tense.** "Run the build." Not "users may wish to consider running the build."
3. **Domain nouns.** This is a packaging project — use `patches`, `the launcher`, `the worker`, `app.asar`, `the minified bundle`, `the asar archive`. Don't say `foo`/`bar` in end-to-end recipes. Placeholders are tolerable in basic-usage; in walkthroughs they kill comprehension.
4. **Real PR / issue / commit references over hand-waving.** "Fixed in [#475](https://github.com/aaddrick/claude-desktop-debian/pull/475)" beats "fixed in a recent PR." `git log --grep` works on links; not on adjectives.
5. **Defaults first, then the override.** "The build auto-detects your distro. To force a format, pass `--build appimage`."
6. **Warnings in alert blocks**, not paragraphs: `> [!NOTE]`, `> [!WARNING]`, `> [!TIP]`. GitHub renders them; reading them isn't optional.
7. **Source-file blocks on deep-dives.** Bulleted GitHub links to the actual files. Don't bury source references in prose.
8. **Cross-link liberally.** Every page should link to 2–4 others. `docs/index.md` should link to every page in `docs/`.
9. **One file per topic.** Don't paste the same config block into three pages. Show it once in `configuration.md`; excerpt subsections elsewhere with a link back.
10. **Rationale lives in `decisions.md` or a learning**, not sprinkled through feature docs. If you find yourself writing "we did this because…" in a how-to page, that paragraph belongs in `learnings/<topic>.md` or `decisions.md`.

## Patterns worth stealing

- **Comparison tables for near-synonyms.** When something has overlapping siblings (deb vs. rpm vs. AppImage vs. nix; Wayland vs. XWayland; SUID sandbox vs. user namespaces), a `| feature | A | B | C |` table beats three prose paragraphs.
- **"Source files" block at the top of deep-dives.** See [`docs/learnings/apt-worker-architecture.md`](../learnings/apt-worker-architecture.md) for the canonical example.
- **`[< Back to <parent>]` link at the top of subpages.** GitHub doesn't render breadcrumbs; this is the manual equivalent. Use it on pages inside subdirectories.
- **Verbatim error messages as `##` headings in `troubleshooting.md`.** Users land via search; search hits the heading.

## Antipatterns

- **Duplicating quickstart in three places.** README is pitch + install one-liner + link to docs. Real install lives in `building.md`, and only there.
- **`docs/` without an `index.md`.** GitHub renders an alphabetical file list and contributors get lost.
- **Uppercase / SHOUTY filenames** (`TROUBLESHOOTING.md`). Hard to type, looks dated, inconsistent with `docs/learnings/*.md`. Lowercase kebab-case throughout.
- **Numbered prefixes** (`01-introduction.md`). Order belongs in `index.md`. Renumbering rots cross-links.
- **Free-form FAQ prose** ("Q: How do I…? A: Well, you might…"). Use `## <error message>` → `### Fix` → code instead. Search ranks headings, not paragraphs.
- **One page past ~30 kB that isn't a reference/deep-dive.** Promote to a subdirectory or split. CLAUDE.md is the exception — it's an archaeology document, not a how-to.
- **Inline "this changed in v2.0.7" annotations** scattered through current docs. Version notes belong in `CHANGELOG.md`.
- **Code blocks without a "when to use this" sentence above them.** Turns docs into a man-page dump.
- **Hiding `CONTRIBUTING.md` or `SECURITY.md` under `docs/`.** GitHub stops auto-detecting them.

## Page-size honesty

Length should track topic depth, not editorial consistency.

| Size | When |
|---|---|
| <500 B | Single config snippet + 2 sentences. Stub pages and redirects. |
| 1.5–3 kB | Platform notes, single-flag install variants |
| 3–8 kB | Standard how-to and setup pages |
| 10–17 kB | Major how-to pages, learnings |
| 17–25 kB | Deep-dive learnings with diagrams |
| >30 kB | Smell. Either it's a reference page (rare in this repo), or it should split. |

Pages can be five sentences. **Don't pad short topics.**

## What stays in README vs. moves into `docs/`

| In README | In `docs/` |
|---|---|
| Elevator pitch (1–3 sentences) | Full prose docs |
| Installation one-liners per package format | Complete build / configuration walkthroughs |
| Link to `docs/index.md` | Everything else |
| Acknowledgments (contributor credits) | — |
| License + sponsor links | — |

The README is the project's storefront. `docs/` is the manual. Once a topic exists in `docs/`, the README links out — don't duplicate.
