export const meta = {
  name: 'patch-suite-dossier',
  description: 'Research every patch on main (mechanism, history, issues/PRs, fate under the official-deb rebase) with per-unit contrarian gates',
  phases: [
    { title: 'Research', detail: 'one historian agent per patch unit' },
    { title: 'Gate', detail: 'contrarian verification of each dossier' },
    { title: 'Revise', detail: 'fix gated dossiers, then re-gate' },
    { title: 'Completeness', detail: 'cross-cutting critic over the full set' },
  ],
}

const DOSSIER_DIR = '/home/aaddrick/source/claude-desktop-debian/docs/reports/CDL-ANT-0009_patch-suite-history/dossiers'
const REPO = '/home/aaddrick/source/claude-desktop-debian'

const UNITS = [
  {
    key: 'frame-fix-wrapper',
    title: 'Frame-fix wrapper (frame-fix-wrapper.js + frame-fix-entry.js, incl. autoUpdater no-op Proxy and titlebar modes)',
    files: 'scripts/frame-fix-wrapper.js, scripts/frame-fix-entry.js, injection code in scripts/patches/app-asar.sh (package.json main swap)',
    hints: 'Runtime Proxy on require("electron") that forces frame:true on the main window, popup detection, CLAUDE_TITLEBAR_STYLE / ELECTRON_USE_SYSTEM_TITLE_BAR machinery, autoUpdater no-op. Related learning: docs/learnings/test-harness-electron-hooks.md (the Proxy silently bypasses constructor-level wraps). Verdict per matrix: delete (upstream main window omits frame; only intentionally frameless popups use frame:!1; updater early-returns apt_channel_pending).',
  },
  {
    key: 'claude-native-stub',
    title: 'Native module stub (claude-native-stub.js replacing @ant/claude-native)',
    files: 'scripts/claude-native-stub.js, injection in scripts/patches/app-asar.sh',
    hints: 'JS stub standing in for the Windows-only native binding (keyboard key codes, window effects, notifications no-ops). Verdict: delete — official .deb ships a real Rust NAPI ELF at app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node with genuine X11 input injection.',
  },
  {
    key: 'node-pty',
    title: 'node-pty provisioning (install_node_pty + nix/node-pty.nix + package.json optionalDependency)',
    files: 'install_node_pty() in scripts/patches/cowork.sh (~line 1003 on main), nix/node-pty.nix, the optionalDependencies edit in scripts/patches/app-asar.sh',
    hints: 'The Windows app.asar.unpacked shipped no Linux pty.node, so the build compiled/fetched one for Code-tab shells. Verdict: delete — official .deb ships prebuilds/linux-x64/pty.node in app.asar.unpacked. On the branch, the repack derives its --unpack glob from the shipped tree and verifies set equality.',
  },
  {
    key: 'tray',
    title: 'Tray patches (menu handler, icon selection, in-place update fast-path) + fix_native_theme_references',
    files: 'scripts/patches/tray.sh (patch_tray_menu_handler, patch_tray_icon_selection, patch_tray_inplace_update), fix_native_theme_references + extract_electron_variable in scripts/patches/_common.sh',
    hints: 'KDE Plasma duplicate-SNI race on destroy+recreate; issues #679 and #680 are known refs; docs/learnings/tray-rebuild-race.md. Multiple re-derivations as upstream re-minified (e.g. commits 6091615, eb12ad8). Verdict: delete — official build natively takes an in-place setImage branch and only destroys the tray when the user disables it, plus ships purpose-made TrayIconLinux(-Dark).png.',
  },
  {
    key: 'menubar-default',
    title: 'menuBarEnabled default-to-true patch',
    files: 'patch_menu_bar_default() in scripts/patches/tray.sh (~line 277 on main)',
    hints: 'Defaults the menu bar on when the setting is unset, so Linux users are not stranded without window controls. Verdict: delete — official defaults map ships menuBarEnabled:!0.',
  },
  {
    key: 'quick-window',
    title: 'Quick Entry window focus/blur patch (KDE stale-focus)',
    files: 'scripts/patches/quick-window.sh (patch_quick_window)',
    hints: 'Electron-on-KDE stale-focus bug around the Quick Entry popup: ||hide() anchor, blur handling, show() sites. SURVIVOR CANDIDATE: still in active_patches on the rebase branch; anchors (Ns/ex/ree + both show() sites) verified present in official 1.17377.2 bytes; pending a KDE Plasma repro to decide if it stays. Also related: docs/learnings/wayland-global-shortcuts-portal.md (hotkey side) and the quick-entry test runner docs.',
  },
  {
    key: 'claude-code',
    title: 'Linux Claude Code support patch (getHostPlatform)',
    files: 'scripts/patches/claude-code.sh (patch_linux_claude_code)',
    hints: 'Adds linux cases to the host-platform switch so the Code tab / agent binary resolution works on Linux. Verdict: delete — official getHostPlatform has native linux-x64/linux-arm64 branches.',
  },
  {
    key: 'asar-guards',
    title: 'asar-path guards in Cowork dispatch (path filter + argv file-drop guard)',
    files: 'patch_asar_path_filter() and patch_asar_argv_file_drop_guard() in scripts/patches/cowork.sh',
    hints: 'Issues #383, #622, #632: Electron ASAR VFS shim misidentifies app.asar as a folder/file when the repackaged launcher passes the asar path on argv, causing false Cowork dispatch and permission prompts on window reopen. Verdict: delete — upstream helpers still lack a .asar guard, but the official launcher is a bare ELF symlink so no app.asar argv ever reaches them; the guards existed only because the repackage passed the asar on argv.',
  },
  {
    key: 'cowork',
    title: 'Cowork Linux reroute (patch_cowork_linux + cowork-vm-service.js bwrap daemon)',
    files: 'patch_cowork_linux() in scripts/patches/cowork.sh, scripts/cowork-vm-service.js',
    hints: 'Reroutes Cowork from the macOS/Windows VM helper to a hand-written Node daemon, default backend bwrap (bubblewrap), optional KVM via COWORK_VM_BACKEND; disables the rootfs download; second AppArmor profile for bwrap. docs/learnings/cowork-vm-daemon.md. Subsystem owner @RayCharlizard. Verdict: PARK — official Cowork is coworkd (Go) + QEMU/KVM over a SO_PEERCRED Unix socket; impersonating that protocol is off the 3.0.0 critical path. On the branch the whole stack moved to scripts/cowork-fallback/ (daemon + reroute patch + 3 bats suites + README); 3.0.0 ships KVM-only with doctor guidance; bwrap fallback is a 3.1 investigation.',
  },
  {
    key: 'org-plugins',
    title: 'org-plugins Linux path patch (MDM-managed plugin marketplace)',
    files: 'scripts/patches/org-plugins.sh (patch_org_plugins_path)',
    hints: 'Injects a linux case into the org-plugins path switch (/etc/claude/org-plugins) so MDM-managed marketplaces work. docs/learnings/plugin-install.md. SURVIVOR: official switch still has darwin+win32 cases and default:return null (no linux case) — MDM org plugins are dead on Linux upstream. Still in active_patches on the branch; upstream report planned.',
  },
  {
    key: 'wco-shim',
    title: 'WCO/topbar shim (UA spoof so claude.ai renders its desktop topbar)',
    files: 'scripts/patches/wco-shim.sh (patch_wco_shim)',
    hints: 'Injects a shim into the BrowserView preload spoofing the remote bundle isWindows() UA check (load-bearing) plus matchMedia + windowControlsOverlay (defensive) so the hamburger/search/nav topbar renders. docs/learnings/linux-topbar-shim.md documents the four gates and hybrid mode. Verdict: delete — official build is never frameless and mainView.js has no WCO/isWindows gating; BUT there is an open verification item: the remote claude.ai bundle may still Windows-gate the topbar, in which case v3.0.0 loses it and it becomes an upstream report, not a shim revival.',
  },
  {
    key: 'config',
    title: 'Config-write patches (#400 mcpServers merge, #400 trusted-folder guard, #649 additional-dirs guard)',
    files: 'scripts/patches/config.sh (patch_config_write_merge, patch_asar_trusted_folder_guard, patch_asar_additional_dirs_guard)',
    hints: 'Issue #400: stale-cache config overwrite wiping externally-added mcpServers; #649 (and #640): corrupted sessions crashing local agent mode via .asar paths in --add-dir dispatch. Split verdicts: merge patch = verify behaviorally (kept UNWIRED on the branch pending a repro against a live official install, file upstream either way); the two .asar guards = delete (same no-asar-argv reasoning as the cowork guards).',
  },
  {
    key: 'shared-machinery',
    title: 'Shared patch machinery and asar repack scaffolding (_common.sh, app-asar.sh orchestration, i18n/tray-icon copies, WM_CLASS guard)',
    files: 'scripts/patches/_common.sh (extract_electron_variable), scripts/patches/app-asar.sh (orchestration: package.json main/desktopName edits, productName vs WM_CLASS fail-fast, i18n JSON copy, tray-icon copy into asar, asar repack)',
    hints: 'Not a behavior patch but the chassis every patch runs on: dynamic identifier extraction because upstream re-minifies between releases (docs/learnings/patching-minified-js.md — still applicable, governs the survivor suite). On the branch app-asar.sh became a thin orchestrator with active_patches=(patch_quick_window patch_org_plugins_path); empty array means byte-identical repack; repack preserves the upstream unpacked set via a derived brace glob + equality check. i18n/tray copies die because the official tree already has correct Linux resources.',
  },
]

const RESEARCH_SCHEMA = {
  type: 'object',
  required: ['unit', 'dossierPath', 'headline', 'issueRefs', 'verdict', 'newHandling', 'gaps'],
  properties: {
    unit: { type: 'string' },
    dossierPath: { type: 'string' },
    headline: { type: 'string', description: 'One-sentence summary of the patch story' },
    issueRefs: {
      type: 'array',
      items: {
        type: 'object',
        required: ['number', 'kind', 'title', 'role'],
        properties: {
          number: { type: 'integer' },
          kind: { type: 'string', enum: ['issue', 'pr'] },
          title: { type: 'string' },
          role: { type: 'string' },
        },
      },
    },
    originCommit: { type: 'string' },
    originDate: { type: 'string' },
    revisionCount: { type: 'integer' },
    verdict: { type: 'string', description: 'Fate under the rebase, quoting the matrix' },
    newHandling: { type: 'string', description: 'How the rebase branch build handles this now' },
    gaps: { type: 'array', items: { type: 'string' } },
  },
}

const GATE_SCHEMA = {
  type: 'object',
  required: ['pass', 'blockers', 'corrections', 'notes'],
  properties: {
    pass: { type: 'boolean' },
    blockers: { type: 'array', items: { type: 'string' } },
    corrections: { type: 'array', items: { type: 'string' }, description: 'The fix for each blocker, with evidence' },
    notes: { type: 'array', items: { type: 'string' } },
  },
}

const COMPLETENESS_SCHEMA = {
  type: 'object',
  required: ['missingCoverage', 'inconsistencies', 'suggestions'],
  properties: {
    missingCoverage: { type: 'array', items: { type: 'string' } },
    inconsistencies: { type: 'array', items: { type: 'string' } },
    suggestions: { type: 'array', items: { type: 'string' } },
  },
}

const CONTEXT = `Repo: ${REPO} (GitHub: aaddrick/claude-desktop-debian). This project repackages Claude Desktop for Linux. On branch \`main\`, a patch suite modifies the upstream minified Electron app, which was historically extracted from the WINDOWS installer. Anthropic shipped an official Linux .deb on 2026-06-30 (teardown: report CDL-ANT-0008 in .tmp/reports/linux-official-teardown/). The CURRENTLY CHECKED-OUT branch is \`rebase/official-deb\`, a v3.0.0 rebase onto that official .deb which deletes most patches. The patch-necessity matrix and byte-level evidence live in docs/learnings/official-deb-rebase-verification.md — read that file.

CRITICAL: the working tree is the rebase branch, NOT main. Read main-state code via \`git show main:<path>\` and history via \`git log ... main -- <path>\`. The working tree shows how the NEW build handles things. Never modify any repo file.

History-tracing tips: patch logic often predates its current file. build.sh was split into scripts/patches/ modules in commit ff4821e ("refactor: split build.sh into topical modules") and organized into functions in 29173e9. Use pickaxe (\`git log --oneline --reverse -S '<function-or-anchor>' main\`) to find true origins across those moves, and \`git log --date=short --format='%h %ad %s' main -- <files>\` for the revision stream. Commit subjects reference issues/PRs as #NNN.

GitHub linkage: for each #NNN, try \`gh -R aaddrick/claude-desktop-debian pr view NNN --json number,title,state,mergedAt,author\` first; if it is not a PR, \`gh issue view NNN --json number,title,state,createdAt,author\`. You may also \`gh search issues --repo aaddrick/claude-desktop-debian '<keywords>' --limit 10\` to find reports that commits never referenced.`

function researchPrompt(u) {
  return `${CONTEXT}

You are the historian for ONE patch unit of the legacy suite. Write a dossier markdown file at ${DOSSIER_DIR}/${u.key}.md (create it with the Write tool; overwrite if present).

UNIT: ${u.title}
FILES/FUNCTIONS ON MAIN: ${u.files}
BACKGROUND HINTS (verify before trusting — these are leads, not facts): ${u.hints}

The dossier must cover, with evidence for EVERY claim (commit SHA, file path + anchor/function name, or issue/PR number):

## Mechanism
What the patch does concretely on main: which minified-bundle anchors it greps/seds, what runtime behavior changes, idempotency guards, dynamic identifier extraction. Read the actual code via \`git show main:<file>\`. Quote the load-bearing anchors/regexes briefly.

## Origin
Why it was created: the first commit introducing the logic (pickaxe across file moves), its date, the motivating issue(s)/bug report(s), and the situation at the time (what upstream version, what broke without it).

## Revision history
Each SUBSTANTIVE change (skip formatting/lint-only), in date order: commit SHA, date, what changed, and WHY (upstream re-minification breaking anchors, review findings, follow-up bug, style-guide migration). Causal stories must cite the commit message or issue that states the cause; otherwise mark them as inference.

## Related issues and PRs
Every related GitHub issue/PR with number, kind, title, state, and its ROLE (motivated the patch / regression it caused / fixed by a revision / review / duplicate report). Include ones found via search, not just commit refs.

## Learnings
Related docs/learnings/*.md entries and what they record about this unit.

## Fate under the official-deb rebase
The verdict per docs/learnings/official-deb-rebase-verification.md (quote the matrix row verbatim), the byte-level evidence behind it, and how the NEW build on the working tree handles it — check scripts/patches/app-asar.sh (active_patches array), scripts/setup/official-deb.sh, scripts/cowork-fallback/, scripts/launcher-common.sh, scripts/doctor.sh as relevant, and cite what you actually find. Note open verification items if the verdict is conditional.

## Gaps
Anything you could not verify. NO speculation presented as fact anywhere in the dossier.

Return the JSON summary per the schema. 'issueRefs' must list every issue/PR that appears in the dossier. 'verdict' quotes the matrix verdict. 'newHandling' is 1-3 sentences.`
}

function gatePrompt(u, round) {
  return `You are the contrarian gate for a patch-history dossier (round ${round}). Read the dossier at ${DOSSIER_DIR}/${u.key}.md.

${CONTEXT}

UNIT: ${u.title}
FILES/FUNCTIONS ON MAIN: ${u.files}

This dossier feeds a formal typeset report (CDL-ANT-0009). A wrong claim that survives you ends up in a PDF with the project's name on it. Try to BREAK the dossier:

1. ISSUE/PR LINKAGE — for EVERY #NNN cited, verify with \`gh -R aaddrick/claude-desktop-debian pr view NNN --json number,title,state\` / \`gh issue view NNN --json number,title,state\`. Wrong number, wrong title paraphrase, or a role the issue/PR does not actually support = blocker.
2. VERDICT FIDELITY — compare the Fate section against the actual matrix row in docs/learnings/official-deb-rebase-verification.md and against the working tree (rebase branch is checked out). Misquoted verdict or wrong new-build handling = blocker.
3. CODE CLAIMS — spot-check Mechanism claims against \`git show main:<file>\`. A fabricated anchor, function, or behavior = blocker.
4. HISTORY COMPLETENESS — run your own \`git log --date=short --format='%h %ad %s' main -- <files>\` plus pickaxe for the key function names. A missed substantive revision, or an origin commit that is actually a file move rather than the true introduction = blocker.
5. UNSUPPORTED NARRATIVE — any causal story not backed by a cited commit message/issue and not marked as inference = blocker.

Do NOT modify the dossier or any other file. pass=true ONLY if there are zero blockers. Every blocker needs a matching entry in 'corrections' stating the fix with evidence. Minor style/emphasis points go in 'notes', never 'blockers'.`
}

function revisePrompt(u, gate) {
  return `${CONTEXT}

You are revising the dossier at ${DOSSIER_DIR}/${u.key}.md (unit: ${u.title}) after a contrarian gate rejected it.

BLOCKERS:
${gate.blockers.map((b, i) => `${i + 1}. ${b}`).join('\n')}

CORRECTIONS SUGGESTED BY THE GATE (verify them yourself before applying — the gate can also be wrong):
${gate.corrections.map((c, i) => `${i + 1}. ${c}`).join('\n')}

Fix every blocker in the dossier file (Edit/Write). Independently re-verify each correction against git/gh/files before applying it. If a blocker is itself factually wrong, keep the original claim but add the evidence that settles it. Do not modify any other file. Return the updated JSON summary per the schema.`
}

phase('Research')
log(`Researching ${UNITS.length} patch units with contrarian gates...`)

const results = await pipeline(
  UNITS,
  u => agent(researchPrompt(u), { label: `research:${u.key}`, phase: 'Research', schema: RESEARCH_SCHEMA }),
  async (dossier, u) => {
    if (!dossier) return { unit: u.key, status: 'research-error', summary: null, gate: null }
    let summary = dossier
    let lastGate = null
    for (let round = 1; round <= 3; round++) {
      lastGate = await agent(gatePrompt(u, round), {
        label: `gate:${u.key}(r${round})`,
        phase: 'Gate',
        agentType: 'contrarian',
        schema: GATE_SCHEMA,
      })
      if (!lastGate) return { unit: u.key, status: 'gate-error', summary, gate: null }
      if (lastGate.pass) {
        log(`${u.key}: passed contrarian gate (round ${round})`)
        return { unit: u.key, status: 'passed', rounds: round, summary, gate: lastGate }
      }
      if (round === 3) break
      log(`${u.key}: gate round ${round} found ${lastGate.blockers.length} blocker(s), revising`)
      const revised = await agent(revisePrompt(u, lastGate), {
        label: `revise:${u.key}(r${round})`,
        phase: 'Revise',
        schema: RESEARCH_SCHEMA,
      })
      if (revised) summary = revised
      else return { unit: u.key, status: 'revise-error', summary, gate: lastGate }
    }
    return { unit: u.key, status: 'failed-gate', rounds: 3, summary, gate: lastGate }
  }
)

const done = results.filter(Boolean)
const passed = done.filter(r => r.status === 'passed')
log(`${passed.length}/${UNITS.length} dossiers passed gates; running completeness critic`)

phase('Completeness')
const critic = await agent(`${CONTEXT}

You are the completeness critic for a set of ${done.length} patch-history dossiers in ${DOSSIER_DIR}/ (files: ${UNITS.map(x => x.key + '.md').join(', ')}). They feed report CDL-ANT-0009, which must detail ALL the patches on main.

1. MISSING COVERAGE: read \`git show main:build.sh\`, \`git ls-tree main scripts/\` and \`git ls-tree main scripts/patches/\`. Is there any patch machinery on main (app.asar mutation, injected file, minified-bundle sed, packaging-time behavior shim) that NO dossier covers? Launcher/doctor runtime flags are out of scope unless a dossier already claims them.
2. INCONSISTENCIES: read all dossiers. Flag cross-dossier contradictions (different dates for the same commit, conflicting descriptions of the same shared machinery, conflicting verdict quotes).
3. SUGGESTIONS: material that appears in multiple dossiers and should be told once in the report (e.g. the build.sh split, the re-minification arms race), plus any load-bearing fact you believe is missing entirely.

Read-only: do not modify anything.`, { label: 'completeness-critic', phase: 'Completeness', agentType: 'contrarian', schema: COMPLETENESS_SCHEMA })

return {
  dossierDir: DOSSIER_DIR,
  units: done.map(r => ({
    unit: r.unit,
    status: r.status,
    rounds: r.rounds || 0,
    headline: r.summary ? r.summary.headline : null,
    verdict: r.summary ? r.summary.verdict : null,
    issueRefs: r.summary ? r.summary.issueRefs : [],
    gaps: r.summary ? r.summary.gaps : [],
    outstandingBlockers: r.status === 'failed-gate' && r.gate ? r.gate.blockers : [],
  })),
  completeness: critic,
}
