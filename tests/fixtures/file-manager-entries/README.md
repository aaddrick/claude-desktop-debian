# File-manager entry fixtures

The four file-manager entries the official Claude Desktop 3.6556.2 wrote
on a real host (Fedora 44, KDE, AppImage launch), byte for byte, with one
substitution: the user's data home is replaced by `@@DATA_HOME@@`. The
`/tmp/.mount_claudeOHhjmk` execPath is upstream's own output and is kept.

- `Send to Claude`, `Open in Claude Code` — written to
  `$XDG_DATA_HOME/nautilus/scripts/` (names are localized).
- `com.anthropic.Claude.SendTo.desktop`,
  `com.anthropic.Claude.OpenInCode.desktop` — written identically to
  `$XDG_DATA_HOME/kio/servicemenus/` and
  `$XDG_DATA_HOME/kservices5/ServiceMenus/`.

Used by the `heal_file_manager_entries` (FM-1) tests in
`tests/launcher-common.bats` and the doctor tests in `tests/doctor.bats`.
Refresh them from a new upstream version when its writer changes.
