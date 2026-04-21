#!/usr/bin/env python3
"""Extract the first balanced JSON object from stdin.

Used by the Investigate step in .github/workflows/issue-triage-v2.yml
to parse Claude CLI output that may contain leading or trailing prose
around the JSON body — a failure mode that fence-strip + jq-presence
did not handle (PR #459 review item 6). Uses `json.JSONDecoder.raw_decode`,
which stops at the first complete JSON value and ignores trailing text.

Exit codes:
  0 — JSON object found and written to stdout
  1 — no opening brace in input
  2 — content starting at the first brace was not valid JSON
"""

import json
import sys


def main() -> int:
    text = sys.stdin.read()
    start = text.find("{")
    if start < 0:
        return 1
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError:
        return 2
    json.dump(obj, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
