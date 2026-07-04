export const meta = {
  name: 'issue-env-catalog',
  description: 'Extract distros, compositors/DEs, package formats, and versions mentioned across all 712 issues & PRs',
  phases: [
    { title: 'Extract', detail: '24 agents, one per shard of ~30 items' },
    { title: 'Synthesize', detail: 'merge + normalize into one catalog' },
  ],
}

const DUMP = '/tmp/claude-1000/-home-aaddrick-source-claude-desktop-debian/16016114-d9bd-4058-9daf-7d210e5ac404/scratchpad/gh-dump'
const LINES = [764, 1266, 2023, 1538, 1488, 1414, 1512, 3396, 2565, 2112, 2735, 2586, 2883, 4567, 1861, 2467, 2152, 2233, 2716, 2175, 2888, 2655, 2646, 1557]
const ITEMS = [30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 22]
const shards = LINES.map((ln, i) => ({
  path: `${DUMP}/shards/shard-${String(i).padStart(2, '0')}.txt`,
  lines: ln,
  items: ITEMS[i],
}))

const GROUP = {
  type: 'array',
  items: {
    type: 'object',
    additionalProperties: false,
    required: ['name', 'items'],
    properties: {
      name: { type: 'string' },
      items: { type: 'array', items: { type: 'integer' } },
    },
  },
}

const EXTRACT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['distros', 'desktopEnvironments', 'compositors', 'sessionTypes', 'packageFormats', 'claudeVersions'],
  properties: {
    distros: GROUP,
    desktopEnvironments: GROUP,
    compositors: GROUP,
    sessionTypes: GROUP,
    packageFormats: GROUP,
    claudeVersions: GROUP,
  },
}

phase('Extract')
const perShard = await parallel(shards.map((s, idx) => () =>
  agent(
    `You are mining GitHub issue/PR text from the "aaddrick/claude-desktop-debian" project (repackages Claude Desktop for Linux). ` +
    `Your shard file is at:\n  ${s.path}\n` +
    `It contains ${s.items} items and about ${s.lines} lines. Items are delimited by lines like "========== ITEM #<number> ==========". ` +
    `Each item begins with "#<number> [ISSUE|PR] <title>", then STATE, LABELS, "---BODY---", then "---COMMENT by <user>---" blocks.\n\n` +
    `READ THE WHOLE FILE. Because it may exceed the 2000-line Read cap, call Read repeatedly: offset 1 (limit 2000), then offset 2001, then 4001, and so on until you pass line ${s.lines}. Do not skip any chunk. Alternatively use grep via Bash to locate mentions, but you MUST cover the entire file.\n\n` +
    `Extract EVERY explicit mention of the following, tagging each with the item number(s) it appears in. Scan bodies AND comments (a commenter saying "same on Arch" counts). Capture what is literally stated — do not infer an OS from a file path unless the path unambiguously names it. Include version numbers whenever the text gives them.\n\n` +
    `1. distros — Linux distributions. Examples: Ubuntu 24.04, Debian 12, Fedora 41, Arch Linux, Manjaro, EndeavourOS, CachyOS, Garuda, Pop!_OS, Linux Mint 21, openSUSE Tumbleweed, NixOS, Gentoo, Kali, Zorin, elementary OS, Nobara, Bazzite, Solus, MX Linux, Devuan, Raspberry Pi OS, SteamOS, Tuxedo OS, Void, etc. Keep the version attached to the name when stated (e.g. "Ubuntu 24.04"). Also record WSL/WSL2 and any Debian/Ubuntu derivative named.\n` +
    `2. desktopEnvironments — GNOME, KDE Plasma, XFCE, Cinnamon, MATE, LXQt, LXDE, Budgie, Deepin, Pantheon, COSMIC, Enlightenment, etc. Attach version if stated (e.g. "KDE Plasma 6.1", "GNOME 47").\n` +
    `3. compositors — Wayland compositors or X11 window managers explicitly named: Mutter, KWin, Sway, Hyprland, Niri, wlroots, Weston, River, Wayfire, labwc, Mir, cosmic-comp, i3, bspwm, awesome, dwm, xmonad, Qtile, etc. (Only when literally named — do NOT auto-derive Mutter from "GNOME".)\n` +
    `4. sessionTypes — the display server / session protocol: "Wayland", "X11" (or "Xorg"), "XWayland". Record whichever are mentioned.\n` +
    `5. packageFormats — the packaging / install method discussed: deb, AppImage, RPM, Flatpak, Snap, Nix/flake, AUR, pacman, source/manual build, tarball, .desktop, etc.\n` +
    `6. claudeVersions — Claude Desktop UPSTREAM version strings (e.g. 1.1.381, 1.1.8629, 1.17377.1) and this project's repo version strings (e.g. v1.3.23). Capture the raw version token.\n\n` +
    `For each value, "items" is the deduplicated list of item numbers (integers) where it appears. Merge trivial variants WITHIN your shard (e.g. "Plasma 6" and "KDE Plasma 6" -> one entry "KDE Plasma 6"), but keep distinct versions separate. If a category has no mentions in your shard, return an empty array for it. Be exhaustive and precise — this feeds a catalog.`,
    { label: `extract:shard-${String(idx).padStart(2, '0')}`, phase: 'Extract', schema: EXTRACT_SCHEMA }
  )
))

const valid = perShard.filter(Boolean)
log(`Extracted from ${valid.length}/${shards.length} shards`)

phase('Synthesize')
const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['distros', 'desktopEnvironments', 'compositors', 'sessionTypes', 'packageFormats', 'claudeVersions', 'notes'],
  properties: {
    distros: GROUP,
    desktopEnvironments: GROUP,
    compositors: GROUP,
    sessionTypes: GROUP,
    packageFormats: GROUP,
    claudeVersions: GROUP,
    notes: { type: 'string' },
  },
}

const merged = await agent(
  `You are merging ${valid.length} per-shard extraction results from the "aaddrick/claude-desktop-debian" issue tracker into ONE normalized catalog. ` +
  `Each shard result is a JSON object with keys: distros, desktopEnvironments, compositors, sessionTypes, packageFormats, claudeVersions — each an array of {name, items:[int]}.\n\n` +
  `Here is the array of shard results as JSON:\n\n${JSON.stringify(valid)}\n\n` +
  `Merge them into a single catalog per category. Rules:\n` +
  `- Union the "items" arrays across shards for the same value, then DEDUPLICATE and sort ascending.\n` +
  `- Normalize naming across shards so the same thing collapses to one entry: e.g. "Plasma 6" / "KDE Plasma 6" / "KDE6" -> "KDE Plasma 6"; "Arch" / "Arch Linux" -> "Arch Linux"; "Xorg" / "X11" -> "X11".\n` +
  `- IMPORTANT for distros & DEs: keep versioned and unversioned as SEPARATE entries when the version is meaningful (e.g. keep "Ubuntu 22.04", "Ubuntu 24.04", and a generic "Ubuntu" if some mentions had no version). Do NOT collapse different versions together. This preserves the "different versions" the user wants.\n` +
  `- For claudeVersions, keep every distinct version token separate; sort them.\n` +
  `- Sort each category's entries by descending number of items (most-mentioned first).\n` +
  `- Do not invent entries; only merge what the shards reported.\n` +
  `In "notes", briefly flag any ambiguities (e.g. GNOME/Mutter overlap, whether "frontend" likely maps to packageFormats) and give the total distinct count per category. Return the merged catalog.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' }
)

return { shardCount: valid.length, catalog: merged }
