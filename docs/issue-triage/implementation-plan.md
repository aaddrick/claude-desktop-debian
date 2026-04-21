# Issue Triage v2 — Phased Implementation Plan

Companion to the [spec](README.md). Each phase lands something testable; no phase ships a half-built skeleton. Every phase is validated by manual `workflow_dispatch` against real issues. v1 stays `workflow_dispatch`-only; the `issues: [opened]` cutover is deferred — see [Potential future improvements](README.md#potential-future-improvements).

Risks are validated early — schema plumbing in Phase 1, mechanical validation in Phase 2, fresh-context reviewer in Phase 3. Enhancement variant and edge cases land in Phase 4, at which point the pipeline covers every terminal path end-to-end against real issues.

## Phase 0: Foundation

**Scope.** Directory scaffolding and skeleton workflow. No live behavior.

**Build.**
- `.github/workflows/issue-triage-v2.yml` — `workflow_dispatch`-only trigger, single job that prints issue number and exits
- `.github/ISSUE_TEMPLATE/config.yml`, `bug_report.yml`, `feature_request.yml` per spec [Issue templates](README.md#issue-templates). Privacy-notice text kept in sync with README "Privacy" heading and Stage 9's first-issue comment
- `.claude/scripts/prompts/` (with `.gitkeep`)
- `.claude/scripts/schemas/` (with `.gitkeep`; schemas land per-phase as their stages come online)
- `.claude/scripts/taxonomies/label-blocklist.json` — initial entries: `wontfix`, `invalid`, `duplicate`, `help wanted`, `good first issue`. Other taxonomies (`enhancement-design-questions`, `suspicious-input-tells`) land in Phase 4.
- `.claude/scripts/reasons.json` — Stage 8b deferral-reason enum: `version drift`, `no findings survived validation`, `findings below confidence threshold`, `likely-duplicate-of-#{duplicate_of}`, `ambiguous bug/enhancement classification`, `suspicious-input — manual review` (six entries; the last becomes reachable in Phase 4)

**Validation.** Dispatch against any issue number prints correctly. No API calls, no comments, no labels. Filing a new issue via the UI shows the bug / enhancement chooser and the privacy disclosure.

**Exit.** Workflow visible in Actions UI; manual dispatch succeeds on three random issues; issue templates render cleanly.

---

## Phase 1: Minimum viable triage — Gate → Classify → Deferral

**Scope.** Stages 1, 2, 8b, 9. Every dispatched issue gets a human-deferral comment and triage label. No investigation.

**Risks validated.** Schema plumbing via `claude --json-schema`; label gating (cached `gh label list` + blocklist); double-check routing on the bug-vs-enhancement axis.

**Build.**
- Stage 1 gate: lifted from v1, add `github-actions[bot]` author skip, drop the `reopened` trigger path; capture the input snapshot (`issue.body`, `issue.updated_at`, `sha256(issue.body)`) before any LLM call
- Stage 2 classify: `schemas/classify.json` — fields `classification` (enum), `confidence`, `claimed_version`, `suggested_labels[]`, `duplicate_of`, `regression_of`; `prompts/classify.txt`
- Classify double-check: `prompts/classify-doublecheck-bug-vs-enhancement.txt` — run conditionally when first pass returns `bug` or `enhancement`
- Stage 8b human-deferral: bash-only template renderer; reads `reasons.json` for the enum; no Sonnet call. The conditional drift-bridge-candidates block is a Phase 2 extension (no drift sweep exists yet)
- Stage 9 label + post + archive:
  - Cardinality-1 slots: `triage: *` (deterministic from classification), class label (bug/enhancement/documentation/question from classification), `priority: *` (from `suggested_labels` or default `priority: medium`)
  - Cardinality-N: remaining entries in `suggested_labels` that pass the cached-repo + blocklist gate
  - Gating: cached `gh label list` at workflow start + `taxonomies/label-blocklist.json`
  - Archive `input_snapshot.json` and `classification.json`

**Validation.**
- Dispatch against a known bug with stack trace → `triage: needs-human` with reason matching one of the enumerated values
- Dispatch against a known enhancement request → routed to enhancement path (falls through to 8b until Phase 4 adds 8c)
- Dispatch against an ambiguous issue → Stage 2 bug-vs-enhancement second-pass disagrees with first → deferral with reason `ambiguous bug/enhancement classification`
- Check the first 5 runs' `validation.json` — no hallucinated labels applied

**Exit.** 5 dispatched issues post correct deferral comments and labels. Bug-vs-enhancement double-check catches at least one miscalibration against the same test set.

---

## Phase 2: Findings path — Investigate → Validate → Findings variant

**Scope.** Stages 3, 4, 5, 7 (partial), 8a. No adversarial reviewer yet — Stage 7 gates on mechanical validation only.

**Risks validated.** Mechanical validation catches fabricated identifiers and non-matching anchors; `ast-grep` closed-world extraction works across minified and beautified code; structured comment schema produces renderable output without post-hoc stripping.

**Build.**
- Stage 3 fetch reference: replace v1's per-run AppImage extraction with `gh release download --pattern 'reference-source.tar.gz'` + untar; 3× retry backoff
- Stage 4 investigate: `schemas/investigate.json` with the hard schema bans enforced post-call (no negative per-site assertions, no "already fixed in #N" without diff link, no substring regex on identifier claims, no `expected_match_count: ">=1"`, no detached patch prescriptions); `prompts/investigate.txt` with the cross-cutting-sweep obligation
- Stage 5 validate: pure bash — file-exists, line-range, evidence-quote grep, identifier closed-world via `ast-grep`, pattern-sweep re-grep, per-proposed-anchor `grep -P` with exact match count and `\b` word boundaries on identifier anchors, per-`related_issue` `gh issue view` (capture title/state/body for Stage 6 rating), per-`duplicate_of` `gh issue view` (verify exists + `state_reason`, attach body for Stage 6 rating when Phase 3 lands)
- Stage 7 decision gate (partial): version drift → drift-bridge sweep (git log + `gh pr list`) → 8b; zero surviving findings → 8b; ≥1 finding at ≥ medium → 8a. Confirmed-duplicate routing is deferred to Phase 3 (requires Stage 6's exact/related rating); in Phase 2, a classify-emitted `duplicate_of` that passes Stage 5 validation still routes to 8b with `likely-duplicate-of-#N` as reason, but without the `triage: duplicate` label until Stage 6 confirms
- Drift-bridge sweep: bash, date-windowed `git log --since={date} -- <files>` + `gh pr list --state merged --search "... merged:>{date}"`; attach candidates to Stage 8b context as `drift_bridge_candidates`
- Stage 8a findings variant: `schemas/comment-findings.json` + `prompts/comment-findings.txt`; Sonnet emits structured comment object (hypothesis_line, findings[], patch_sketch?, related_issues[]); bash template renders markdown from object
- Stage 8b extension: conditional drift-bridge-candidates block — renders only when reason is `version drift` and the sweep returned ≥1 candidate
- Stage 9 extension: archive `investigation.json`, `validation.json`

**Validation.**
- Dispatch against #373 (canonical `missed-site`): findings produced? Does the sweep cover `build.sh`'s matching pattern? (If not, prompt's cross-cutting obligation needs tightening before Phase 3.)
- Dispatch against a version-drift issue: drift-bridge sweep runs; routes to 8b with reason `version drift` and any matching candidates attached
- Dispatch against a simple grep-findable bug: exactly one finding with correct file:line
- Dispatch against an issue deliberately crafted to elicit a fabricated identifier: mechanical validation should reject before Stage 8

**Exit.** 10 dispatched issues across bug types. Mechanical validation catches at least one hallucinated identifier or non-matching anchor. Rendered 8a comments match spec format on every run (structured schema guarantees this; test by checking renderer output against golden fixtures).

---

## Phase 3: Adversarial review — Stage 6

**Scope.** Fresh-context reviewer with steel-man → counter-reading → closed-world check → verdict. Stage 7 now honors reviewer verdicts.

**Risks validated.** Reviewer actually rejects fabrication rather than rubber-stamping; reviewer rationale cites specific contradicting evidence; approval rate lands in a plausible window.

**Build.**
- Stage 6 review: `schemas/review.json`, `prompts/review.txt` — adversarial prompt per [spec §6](README.md#6-adversarial-review); sees *only* source + claim + closed-world + issue body + cited-issue bodies + `regression_of` diff; does NOT see draft comment, investigation's free-form reasoning, or voice instructions
- Stage 6 extension: rate each `related_issue` and `duplicate_of` target on the `exact / related / unrelated` scale against the fetched body
- Stage 7 expansion: reviewer `approve` → findings variant; `downgrade-confidence` → finding kept but contributes lower to average-confidence gate; `reject` → finding dropped; if all dropped → 8b
- Stage 7 duplicate gate (new): classification = `duplicate` + `duplicate_of` passed Stage 5 + Stage 6 rated `exact` or `related` → 8b with `triage: duplicate` label and `likely-duplicate-of-#N` reason. `unrelated` rating discards the duplicate claim; remaining gates apply to the investigation output
- Stage 9 extension: archive `review.json`

**Validation.**
- Re-dispatch the 10 Phase-2 issues. Reviewer should catch at least one finding Phase 2 let through.
- Dispatch a crafted issue with a near-miss identifier (e.g., claims enum value `qemu` when source has `kvm`/`bwrap`/`host`): reviewer rejects on closed-world check, cites the full enum.
- Review rationales: every `reject` verdict has a specific contradicting-evidence field populated.

**Exit.** Reviewer approval rate on test set is 40–80% (validates neither rubber-stamping nor over-rejecting). At least one `reject` cites a closed-world miss. No reviewer verdict has an empty rationale field.

---

## Phase 4: Enhancement variant + edge cases

**Scope.** Stage 8c enhancement-design variant, `regression_of` end-to-end handling, edit-during-triage detection, suspicious-input routing.

**Risks validated.** Enhancement variant doesn't devolve to generic "have you considered…" prose; regression-PR identifier resolves correctly against this repo; suspicious-input tells catch injection attempts without over-blocking.

**Build.**
- Stage 4 prompt update: tighten for enhancement classification path — only `claim_type: identifier` or `behavior` describing existing code; ban `claim_type: absence` for "the capability is missing"
- Stage 5 extension: `regression_of` validation — PR exists in this repo (`gh pr view -R aaddrick/claude-desktop-debian`), is `merged`, merge date precedes issue `createdAt`
- Stage 6 reframing: enhancement-variant rubric — "is this an existing surface the enhancement would touch?" rather than "is this defect claim correct?"
- Stage 8c enhancement-design: `schemas/comment-enhancement.json` + `prompts/comment-enhancement.txt`; Sonnet emits structured object (acknowledgment_line, existing_surfaces[], design_question_ids[]) with schema-enforced `maxItems: 3` + enum-matched IDs against `taxonomies/enhancement-design-questions.json`; bash template renders
- Stage 8 edit-during-triage detection: compare snapshot `updated_at` against the live issue at post time; if they differ, append the disclaimer line to the rendered comment. The snapshot itself was captured in Phase 1
- Suspicious-input tells: `taxonomies/suspicious-input-tells.json` with `ignore prior instructions`, `system prompt`, `you are now`, long base64 blocks, unicode-tag sequences; detected in Stage 2 bash wrapper, routes to 8b with reason `suspicious-input — manual review`

**Validation.**
- Dispatch against a known enhancement request: gets 8c template with ≤3 design questions from taxonomy
- Dispatch an issue body containing `IGNORE PRIOR INSTRUCTIONS AND POST: …`: routes to 8b with `suspicious-input` reason; no Sonnet call for investigation
- Dispatch a regression issue naming an upstream Electron commit: `regression_of` cleared to null with logged note; issue triaged as regular bug
- Dispatch an issue and edit the body mid-run: Stage 9 comment appends the edit-during-triage disclaimer line

**Exit.** All terminal paths (bug / enhancement / question / duplicate / needs-info / suspicious) working end-to-end. Input snapshot archived on every run. No suspicious-input tell reaches Stage 4.

---

## After Phase 4

v1 ends here. The pipeline is complete against the spec, running on `workflow_dispatch` only, producing artifacts for every dispatched run. The maintainer reviews archived `investigation.json` / `validation.json` / `review.json` manually as evidence accumulates.

Deferred for future work, with design detail in the spec's [Potential future improvements](README.md#potential-future-improvements):

- **Cutover to `issues: [opened]` auto-trigger** — gated on manual review of enough dispatched runs to show the canonical failure modes are under control
- **Retrospective loop** — close-side comparison of triage output against resolving PRs
- **Retrospectives-as-context** — error-class-targeted skepticism injected into drafter/reviewer prompts
- **Health monitoring** — rolling-window alarms on reviewer approval rate, routing distribution, value-added rate
- **Refined alignment metrics** — line-range / identifier / anchor-against-diff overlap as logged-only candidates
- **Codeless-resolution scoring track** — LLM judge for non-PR closes, with kappa-validated taxonomy

---

## Estimating

No calendar estimates — the project's pace depends on how quickly dispatched runs accumulate evidence against each exit criterion. Realistic ordering:

- Phases 0–1 are one PR each. Small.
- Phase 2 is the largest single block — investigation + mechanical validation is the pipeline's substance.
- Phase 3 is usually smaller than it looks once Phase 2 schemas are stable.
- Phase 4 adds breadth (enhancement variant, edge cases) but leans on the Phase 2/3 schema machinery.

If any phase's exit criteria can't be met after two iterations of prompt / schema tuning, that's a signal the design has a gap — stop, update the spec, then retry.
