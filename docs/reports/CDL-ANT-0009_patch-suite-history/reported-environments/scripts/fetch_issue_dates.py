"""Fetch creation/close/merge dates for every issue & PR number referenced
anywhere in catalog.json, via the GitHub GraphQL API (batched with aliases so
573 items cost ~12 requests instead of 573). Writes a separate JSON file
keyed by number -- catalog.json's provenance (item numbers) stays untouched.

Requires `gh` authenticated against the aaddrick/claude-desktop-debian repo.
Run:
  python3 scripts/fetch_issue_dates.py
"""
import json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OWNER, REPO = "aaddrick", "claude-desktop-debian"
BATCH_SIZE = 50

catalog = json.load(open(os.path.join(ROOT, "catalog.json")))
numbers = set()
for cat, entries in catalog.items():
    if cat == "notes":
        continue
    for e in entries:
        numbers.update(e["items"])
numbers = sorted(numbers)
print(f"{len(numbers)} unique issue/PR numbers referenced in catalog.json")

FIELDS = """
    __typename
    ... on Issue {
      number
      state
      createdAt
      closedAt
    }
    ... on PullRequest {
      number
      state
      createdAt
      closedAt
      merged
      mergedAt
    }
"""


def fetch_batch(nums, attempt=1):
    fields = "\n".join(f'n{n}: issueOrPullRequest(number: {n}) {{ {FIELDS} }}' for n in nums)
    query = f'query {{ repository(owner: "{OWNER}", name: "{REPO}") {{ {fields} }} }}'
    try:
        out = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                              capture_output=True, text=True, check=True, timeout=60)
        return json.loads(out.stdout)["data"]["repository"]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, KeyError, json.JSONDecodeError) as exc:
        if attempt >= 3:
            raise RuntimeError(f"batch starting at {nums[0]} failed after 3 attempts: {exc}\n{getattr(exc, 'stderr', '')}")
        wait = 2 ** attempt
        print(f"  batch {nums[0]}-{nums[-1]} failed ({exc}); retrying in {wait}s", file=sys.stderr)
        time.sleep(wait)
        return fetch_batch(nums, attempt + 1)


result = {}
missing = []
for i in range(0, len(numbers), BATCH_SIZE):
    batch = numbers[i:i + BATCH_SIZE]
    data = fetch_batch(batch)
    for n in batch:
        node = data.get(f"n{n}")
        if node is None:
            missing.append(n)
            continue
        result[str(n)] = {
            "type": "PullRequest" if node["__typename"] == "PullRequest" else "Issue",
            "state": node["state"],
            "createdAt": node["createdAt"],
            "closedAt": node.get("closedAt"),
            "merged": node.get("merged"),
            "mergedAt": node.get("mergedAt"),
        }
    print(f"  fetched {min(i + BATCH_SIZE, len(numbers))}/{len(numbers)}")

if missing:
    print(f"WARNING: {len(missing)} numbers returned no node (deleted/inaccessible): {missing}", file=sys.stderr)

os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
out_path = os.path.join(ROOT, "data", "issue_dates.json")
json.dump({"fetched": len(result), "missing": missing, "dates": result}, open(out_path, "w"), indent=2)
print(f"wrote {out_path} ({len(result)} resolved, {len(missing)} missing)")
