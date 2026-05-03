#!/usr/bin/env python3
"""Apply structured credit entries from the post-merge attribution
LLM call to README.md's Acknowledgments section.

Input: a JSON file matching schemas/credit.json.
Output: README.md is modified in place.

The script handles three operations:

  add      Append a new one-liner to the bottom of the Acknowledgments
           list, just before the next ## heading.

  promote  Convert an existing one-liner for `username` into a
           multi-bullet block. The original prose (with any leading
           "for " stripped) becomes the first bullet; the new
           description becomes the second bullet.

  append   Append a new bullet to an existing multi-bullet block for
           `username`.

Usernames are matched case-insensitively against the bracketed link
text in entries of the form:

  - **[handle](https://github.com/handle)** for ...
  - **[handle](https://github.com/handle)**
    - first bullet
    - second bullet

Mismatches (e.g. "promote" requested for a user who is already
multi-bullet, or "add" requested for a user who already has an entry)
are auto-corrected to the correct operation with a warning printed
to stderr. Unknown usernames in promote/append are auto-corrected to
add.

The script is idempotent in the sense that running it twice with the
same input is safe — the second run will detect that the new
bullet/line already exists and skip it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ACK_HEADING = "## Acknowledgments"
NEXT_SECTION_RE = re.compile(r"^## ", re.MULTILINE)
ENTRY_LINE_RE = re.compile(
    r"^- \*\*\[(?P<handle>[^\]]+)\]\(https://github\.com/[^)]+\)\*\*"
    r"(?P<rest>.*)$"
)
BULLET_RE = re.compile(r"^  - (?P<text>.*)$")


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def find_section(lines: list[str]) -> tuple[int, int]:
    """Return (start, end) line indices for the Acknowledgments
    section content. `start` is the line AFTER the heading; `end` is
    the line INDEX of the next ## heading (exclusive). Lines in
    [start, end) include the section's body.
    """

    start = None
    for i, line in enumerate(lines):
        if line.strip() == ACK_HEADING:
            start = i + 1
            break
    if start is None:
        raise SystemExit(
            f"FATAL: '{ACK_HEADING}' heading not found in README.md"
        )

    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break

    return start, end


def find_entry(
    lines: list[str], start: int, end: int, username: str
) -> tuple[int, int] | None:
    """Find an existing entry for `username`. Returns (entry_start,
    entry_end) — entry_start points to the `- **[handle]...` line,
    entry_end is exclusive. For one-liners, entry_end == entry_start
    + 1. For multi-bullet entries, entry_end is the index after the
    last `  - ` bullet line.

    Returns None if no entry exists.
    """

    target = username.lower()
    for i in range(start, end):
        m = ENTRY_LINE_RE.match(lines[i])
        if m and m.group("handle").lower() == target:
            entry_end = i + 1
            while entry_end < end and BULLET_RE.match(lines[entry_end]):
                entry_end += 1
            return i, entry_end
    return None


def is_multibullet(lines: list[str], entry_start: int, entry_end: int) -> bool:
    return entry_end - entry_start > 1


def get_oneliner_rest(line: str) -> str:
    """Extract the prose after the bold-link prefix on a one-liner.

    For `- **[foo](https://github.com/foo)** for the bar fix`, returns
    "for the bar fix". For `- **[foo](https://github.com/foo)** for
    the bar fix`, the leading space before "for" is preserved as part
    of `rest` from the regex; we strip it.
    """

    m = ENTRY_LINE_RE.match(line)
    if not m:
        raise ValueError(f"not an entry line: {line!r}")
    return m.group("rest").lstrip()


def strip_for_prefix(prose: str) -> str:
    """Strip a leading 'for ' (case-insensitive) so that one-liner
    prose can be reused as a bullet. Multi-bullet bullets don't begin
    with 'for ' (per existing README convention), so promotions need
    this normalization.
    """

    if prose.lower().startswith("for "):
        return prose[4:]
    return prose


def make_oneliner(username: str, description: str) -> str:
    """Build a one-line entry. `description` should already begin with
    'for ' or whatever prefix matches the project convention. We
    accept either form and prepend 'for ' if missing, since the LLM
    output is unstructured prose.
    """

    desc = description.strip()
    # Most existing entries start with 'for ' or 'for the '; if the
    # model omitted it, add it. If the model wrote a full sentence
    # that doesn't fit the template (e.g. starting with a verb), let
    # it through unchanged.
    lower = desc.lower()
    if not (
        lower.startswith("for ")
        or lower.startswith("contributing ")
        or lower.startswith("contributed ")
    ):
        desc = "for " + desc[0].lower() + desc[1:]
    return (
        f"- **[{username}](https://github.com/{username})** {desc}"
    )


def make_block_header(username: str) -> str:
    return f"- **[{username}](https://github.com/{username})**"


def make_bullet(text: str) -> str:
    text = text.strip()
    # Strip a leading "- " or "  - " in case the LLM included it
    # despite the prompt instructions.
    text = re.sub(r"^\s*-\s+", "", text)
    return f"  - {text}"


def trim_trailing_blank(lines: list[str], end: int) -> int:
    """If the line just before `end` (i.e. the line that separates
    Acknowledgments from the next ## heading) is blank, return
    end-1; else return end. Used to find the right insertion point
    for new one-liners.
    """

    while end > 0 and lines[end - 1].strip() == "":
        end -= 1
    return end


def already_has_bullet(
    lines: list[str], entry_start: int, entry_end: int, bullet_text: str
) -> bool:
    target = bullet_text.strip().lower()
    for i in range(entry_start + 1, entry_end):
        m = BULLET_RE.match(lines[i])
        if m and m.group("text").strip().lower() == target:
            return True
    return False


def already_has_oneliner(
    lines: list[str], start: int, end: int, username: str, description: str
) -> bool:
    target = username.lower()
    desc = description.strip().lower()
    if desc.startswith("for "):
        desc = desc[4:]
    for i in range(start, end):
        m = ENTRY_LINE_RE.match(lines[i])
        if not m or m.group("handle").lower() != target:
            continue
        rest = m.group("rest").strip().lower()
        if rest.startswith("for "):
            rest = rest[4:]
        if rest == desc:
            return True
    return False


def apply_add(
    lines: list[str],
    section_start: int,
    section_end: int,
    username: str,
    description: str,
) -> tuple[list[str], int, int]:
    """Append a new one-liner to the bottom of the section. If the
    user already exists, fall through to promote semantics."""

    existing = find_entry(lines, section_start, section_end, username)
    if existing is not None:
        entry_start, entry_end = existing
        if is_multibullet(lines, entry_start, entry_end):
            sys.stderr.write(
                f"WARN: action=add for {username} but they already "
                f"have a multi-bullet block; converting to append\n"
            )
            return apply_append(
                lines,
                section_start,
                section_end,
                username,
                description,
            )
        sys.stderr.write(
            f"WARN: action=add for {username} but they already have "
            f"a one-liner; converting to promote\n"
        )
        return apply_promote(
            lines,
            section_start,
            section_end,
            username,
            description,
        )

    if already_has_oneliner(
        lines, section_start, section_end, username, description
    ):
        sys.stderr.write(
            f"WARN: identical one-liner for {username} already "
            f"present; skipping\n"
        )
        return lines, section_start, section_end

    insert_at = trim_trailing_blank(lines, section_end)
    new_line = make_oneliner(username, description)
    new_lines = lines[:insert_at] + [new_line] + lines[insert_at:]
    return new_lines, section_start, section_end + 1


def apply_promote(
    lines: list[str],
    section_start: int,
    section_end: int,
    username: str,
    description: str,
) -> tuple[list[str], int, int]:
    """Promote an existing one-liner to a multi-bullet block."""

    existing = find_entry(lines, section_start, section_end, username)
    if existing is None:
        sys.stderr.write(
            f"WARN: action=promote for {username} but no existing "
            f"entry found; converting to add\n"
        )
        return apply_add(
            lines, section_start, section_end, username, description
        )

    entry_start, entry_end = existing
    if is_multibullet(lines, entry_start, entry_end):
        sys.stderr.write(
            f"WARN: action=promote for {username} but they are "
            f"already multi-bullet; converting to append\n"
        )
        return apply_append(
            lines,
            section_start,
            section_end,
            username,
            description,
        )

    old_line = lines[entry_start]
    old_prose = strip_for_prefix(get_oneliner_rest(old_line))
    new_prose = strip_for_prefix(description.strip())

    if old_prose.strip().lower() == new_prose.strip().lower():
        sys.stderr.write(
            f"WARN: promote for {username} would duplicate the "
            f"existing prose; skipping\n"
        )
        return lines, section_start, section_end

    new_block = [
        make_block_header(username),
        make_bullet(old_prose),
        make_bullet(new_prose),
    ]
    new_lines = (
        lines[:entry_start] + new_block + lines[entry_end:]
    )
    delta = len(new_block) - (entry_end - entry_start)
    return new_lines, section_start, section_end + delta


def apply_append(
    lines: list[str],
    section_start: int,
    section_end: int,
    username: str,
    description: str,
) -> tuple[list[str], int, int]:
    """Append a new bullet to an existing multi-bullet block."""

    existing = find_entry(lines, section_start, section_end, username)
    if existing is None:
        sys.stderr.write(
            f"WARN: action=append for {username} but no existing "
            f"entry found; converting to add\n"
        )
        return apply_add(
            lines, section_start, section_end, username, description
        )

    entry_start, entry_end = existing
    if not is_multibullet(lines, entry_start, entry_end):
        sys.stderr.write(
            f"WARN: action=append for {username} but they are "
            f"a one-liner; converting to promote\n"
        )
        return apply_promote(
            lines,
            section_start,
            section_end,
            username,
            description,
        )

    new_prose = strip_for_prefix(description.strip())
    if already_has_bullet(lines, entry_start, entry_end, new_prose):
        sys.stderr.write(
            f"WARN: identical bullet for {username} already present; "
            f"skipping\n"
        )
        return lines, section_start, section_end

    new_bullet = make_bullet(new_prose)
    new_lines = (
        lines[:entry_end] + [new_bullet] + lines[entry_end:]
    )
    return new_lines, section_start, section_end + 1


ACTION_DISPATCH = {
    "add": apply_add,
    "promote": apply_promote,
    "append": apply_append,
}


def apply_entries(readme_text: str, entries: list[dict]) -> str:
    lines = readme_text.split("\n")
    section_start, section_end = find_section(lines)

    for entry in entries:
        action = entry["action"]
        username = entry["username"]
        description = entry["description"]
        fn = ACTION_DISPATCH[action]
        lines, section_start, section_end = fn(
            lines, section_start, section_end, username, description
        )

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Apply structured credit entries to README.md"
    )
    parser.add_argument(
        "--decision",
        type=Path,
        required=True,
        help="Path to LLM decision JSON (matches schemas/credit.json)",
    )
    parser.add_argument(
        "--readme",
        type=Path,
        required=True,
        help="Path to README.md to modify in place",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the updated README to stdout without writing",
    )
    args = parser.parse_args()

    decision = load_json(args.decision)
    if not decision.get("should_update"):
        print("decision: should_update=false, no changes")
        return 0

    entries = decision.get("entries") or []
    if not entries:
        print("decision: should_update=true but entries=[], no changes")
        return 0

    original = args.readme.read_text(encoding="utf-8")
    updated = apply_entries(original, entries)

    if updated == original:
        print("apply: no effective changes (idempotent skip)")
        return 0

    if args.dry_run:
        sys.stdout.write(updated)
        return 0

    args.readme.write_text(updated, encoding="utf-8")
    print(f"apply: README.md updated with {len(entries)} entr"
          f"{'y' if len(entries) == 1 else 'ies'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
