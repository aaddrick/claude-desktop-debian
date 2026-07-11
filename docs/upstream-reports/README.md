# Upstream reports — pending pile

Draft reports for bugs that belong upstream (Anthropic or Electron),
with per-report status. None of these block the v3.0.0 ship; filing is
tracked here so findings don't rot in learnings docs. Every filed text
goes through the voice workflow first.

| report | target | status | source |
|---|---|---|---|
| Cowork virtiofsd probe: two hardcoded paths + Ubuntu-22-only bundled fallback ("requires QEMU" with a full KVM stack) | anthropics/claude-code | **FILED** — [anthropics/claude-code#74605](https://github.com/anthropics/claude-code/issues/74605) (2026-07-05); reproduced on the official `.deb` (Pop!_OS datapoint in #771) and differentially on an Arch guest; needs the within-3-days author comment to survive the dupe bot; downstream `virtiofsd-probe` asar patch + doctor fix ship via [#773](https://github.com/aaddrick/claude-desktop-debian/pull/773) meanwhile | [`771-cowork-virtiofsd-probe.md`](771-cowork-virtiofsd-probe.md) |
| config + Cowork store stub-wipe | anthropics/claude-code | **FILED** — [anthropics/claude-code#74288](https://github.com/anthropics/claude-code/issues/74288) (2026-07-04); reopen case for #32345/#34359/#56296/#59640/#63651 with the mechanism traced to 1.18286.0 line numbers; needs the within-3-days author comment + upvotes to survive the dupe bot; launcher-side backup ships downstream meanwhile | [`../learnings/config-wipe-guard.md`](../learnings/config-wipe-guard.md) |
| stdio MCP double-spawn | anthropics/claude-code | **drafted** — [`546-mcp-double-spawn.md`](546-mcp-double-spawn.md); now first-party-reproducible on the official Linux build | [`../learnings/mcp-double-spawn.md`](../learnings/mcp-double-spawn.md) |
| WCO Linux bugs A/B/C (media query, BrowserView isolation, implicit drag region) | electron/electron | **drafted** — [`electron-wco-linux-bugs.md`](electron-wco-linux-bugs.md); needs Fiddle re-verification on current Electron first | [`../archive/linux-topbar-shim.md`](../archive/linux-topbar-shim.md) |
| Cowork device registry never links on Linux (no `@ant/claude-native` hardware-key backend; `hardwareKeyGetOrCreate` throws `linux-not-yet-supported`, so new cloud tasks stay "Not linked to a computer") | anthropics/claude-code | **drafted** — [`780-device-registry.md`](780-device-registry.md); pre-existing HostLoop sessions unaffected | [aaddrick/claude-desktop-debian#780](https://github.com/aaddrick/claude-desktop-debian/issues/780) |
| XWayland default defeats GlobalShortcutsPortal (no `Registry.Register` app-id handshake) | electron/electron | **not drafted** — upstream issue [electron#51875](https://github.com/electron/electron/issues/51875) already tracks the handshake gap; ours would add the GNOME 50 / portal ≥1.20 evidence | [`../learnings/wayland-global-shortcuts-portal.md`](../learnings/wayland-global-shortcuts-portal.md) |
| OVMF firmware probe list hardcoded, no env override (Cowork breaks on non-Debian layouts) | Anthropic | **not drafted** — packaging shims cover rpm (CW-1) and Nix FHS meanwhile | [`../learnings/official-deb-rebase-verification.md`](../learnings/official-deb-rebase-verification.md) |
| org-plugins platform switch has no `linux` case (MDM plugins dead on Linux) | Anthropic | **not drafted** — justifies the `org-plugins` survivor patch | [`../learnings/official-deb-rebase-verification.md`](../learnings/official-deb-rebase-verification.md) |
| official `.desktop` sets `StartupWMClass=claude-desktop` but productName is `Claude` | Anthropic | **not drafted** — window-matching mismatch; our packages ship `StartupWMClass=Claude` | [`../learnings/official-deb-rebase-verification.md`](../learnings/official-deb-rebase-verification.md) |
| `claude_desktop_config.json` hand-edits clobbered while app is running (#400, CF-1) | Anthropic | **not drafted** — patch deliberately retired (a naive merge would resurrect UI-deleted servers); doc workaround shipped (quit → edit → reopen) | tracking file + [`../learnings/official-deb-rebase-verification.md`](../learnings/official-deb-rebase-verification.md) |
| keep-awake inhibitor is a no-op on bare wlroots/i3 (no SessionManager/PowerManagement service) | Anthropic | **not drafted** — pre-existing upstream gap, not a rebase regression | CDL-ANT-0009 verification tracking (gitignored, local) |
| Quick Entry hotkey re-registration on KDE (SHORTCUT-1) | Anthropic | **not drafted** | CDL-ANT-0009 verification tracking (gitignored, local) |
| doubled titlebar on sway (SWAY-1) | Anthropic | **not drafted** — env-scoped | CDL-ANT-0009 verification tracking (gitignored, local) |
| Quick Entry square (untransparent) frame on niri/virtio-GPU (S10) | Anthropic | **not drafted** — niri/virtio-GL-scoped cosmetic; note, not a bug report per se | CDL-ANT-0009 verification tracking (gitignored, local) |

Filing-path note: Claude Desktop has no in-app engineering report path
(`/bug` and `/feedback` are inert; Help ▸ Get Support routes to the
support queue). Anthropic-targeted reports go to
`anthropics/claude-code` GitHub Issues with `N/A — Claude Desktop
<version>` in the CLI-specific fields, per the pattern in
[`546-mcp-double-spawn.md`](546-mcp-double-spawn.md).
