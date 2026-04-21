[< Back to README](../README.md)

# Decision Log

This log captures direction-level decisions that shape what this project does and — just as importantly — what it explicitly does not do. Each entry records the decision, the rationale at the time it was made, and the trade-offs accepted.

Decisions are not deleted. If a decision is revisited, the entry is marked `Superseded` and a new entry links back to it. This preserves the reasoning so future contributors don't have to relitigate settled questions without context.

**Format.** Each decision has a stable ID (`D-NNN`), a status, a decision date, an owner, and a short list of affected stakeholders. Decisions do not need to be long — they need to be clear about what was chosen and what was refused.

**Adding a new decision.** Append a new H2 section with the next `D-NNN` ID, add a row to the index, and keep the entry tightly scoped to one direction call. If a decision touches multiple areas, split it.

**Revisiting a decision.** Open an issue that cites the decision ID and describes what's materially changed since the original call. Don't open a PR that violates a recorded decision without first getting the decision reopened.

## Index

| ID | Date | Status | Title |
| --- | --- | --- | --- |
| [D-001](#d-001--auto-update-stays-in-the-package-manager-lane) | 2026-04-21 | Accepted | Auto-update stays in the package-manager lane |

---

## D-001 — Auto-update stays in the package-manager lane

- **Status:** Accepted
- **Decided:** 2026-04-21
- **Owner:** @aaddrick
- **Stakeholders:** Users on deb / rpm / AUR; AppImage users; external contributors proposing auto-update features

### Context

A contributor submitted a proposal (PR #320) that added roughly 550 lines of nightly cron-driven update scripts covering both Claude Desktop (rebuild-and-reinstall from source) and the Claude Code CLI (via `claude update`). The same PR contained an unrelated fix for GPU compositing on XRDP sessions (#319).

The XRDP portion was salvaged into PR #475 and merged. This entry records why the auto-update portion was declined at the direction level — not as a rework request, but as a "this is not a shape we'll ship."

### Decision

**This project does not ship an in-tree auto-updater.** Updates are delivered exclusively through:

1. The **APT repository** for Debian and Ubuntu users
2. The **DNF repository** for Fedora and RHEL users
3. The **AUR package** for Arch users
4. **AppImageUpdate / embedded zsync info** as the sanctioned direction if and when AppImage auto-update is prioritized

No cron-driven, systemd-timer-driven, or in-app rebuild-and-reinstall flows will be merged.

### Rationale

- **The platforms that matter already have the right answer.** Users on distributions where this project publishes a package repository get updates through their OS's package manager. That's the correct shape: the OS's update stack is the thing users configure, audit, and trust. Standing up a parallel path inside this project fragments the experience and duplicates machinery that already works.
- **The DE-neutral answer for AppImage is AppImageUpdate, not a bespoke updater.** A parallel AppImage update path would mean owning process detection, session-aware safety checks, and sudo escalation across every desktop environment, session manager, notification system, and sandboxing model (Flatpak, Snap, Wayland, X11, systemd-inhibit, screen locks). AppImage already has a sanctioned update mechanism; if we ever close that gap, we close it by embedding zsync info in the release artifact.
- **Security surface.** An unattended updater running from cron with broad `apt install` privileges in a user's git clone is a large ambient capability for the project to own. APT pre-invoke hooks and `.deb` maintainer scripts mean that `NOPASSWD: /usr/bin/apt install *` is effectively passwordless root for anyone who can place a file on disk — a surface that does not exist when the user runs `apt upgrade` through the OS's package manager directly.
- **Upstream parity.** The Windows and Mac builds of Claude Desktop do not auto-update via cron. They use platform-native mechanisms. A Linux-specific cron updater would make this project's update behavior diverge from the expectations users carry in from the upstream product.
- **Maintenance tail.** Every session manager, notification system, sandboxing runtime, and "is the user actively using the app" heuristic becomes this project's problem to keep working across distros, indefinitely. The blast radius of a broken updater is "the app stops working cleanly for a fraction of users until they figure out how to intervene" — and we would own that 24/7.

### Consequences

- **Accepted trade-off.** AppImage users who do not install from a supported distro's repo have no first-party auto-update path. Their options are: re-download the AppImage manually, use AppImageLauncher or Gear Lever, or switch to a supported package format.
- **Future work.** If AppImage auto-update becomes a priority, the sanctioned path is integrating zsync metadata into the release artifact and documenting `AppImageUpdate` usage — not a new cron script.
- **Contributor guidance.** PRs proposing in-tree auto-update mechanisms should reference this decision and are expected to be declined by default. Requests to reopen should be filed as issues that cite `D-001` and describe what's materially changed — e.g., AppImage becomes the dominant distribution channel for this project, upstream changes its update strategy, or the package repos stop being viable.

### Alternatives Considered

- **Cron-driven auto-updater (the PR #320 shape).** Rejected — rationale above.
- **Systemd-timer variant of the same.** Same concerns; the scheduling mechanism is not the hard part.
- **Watch-mode "update when idle" daemon.** Worse on balance — owning an always-on daemon that decides when the user is "idle enough" for an update is a larger maintenance surface than the cron approach and carries the same security footprint.
- **AppImageUpdate / zsync integration.** Accepted as the sanctioned direction if AppImage auto-update is ever prioritized. Not implemented today; recorded here so future contributors know which direction is open.

### References

- PR #320 — original auto-update proposal (closed, superseded by PR #475 for the salvageable XRDP portion): <https://github.com/aaddrick/claude-desktop-debian/pull/320>
- PR #475 — XRDP fix salvaged from PR #320: <https://github.com/aaddrick/claude-desktop-debian/pull/475>
- Issue #319 — the XRDP bug that motivated PR #320: <https://github.com/aaddrick/claude-desktop-debian/issues/319>
- Close comment on PR #320 articulating the direction: <https://github.com/aaddrick/claude-desktop-debian/pull/320#issuecomment-4288390494>
