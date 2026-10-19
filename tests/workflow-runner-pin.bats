#!/usr/bin/env bats
#
# workflow-runner-pin.bats
# Every job runs on an explicitly versioned runner image.
#
# GitHub moves `ubuntu-latest` from 24.04 to 26.04 over several weeks
# starting 2026-10-19 (actions/runner-images#14748). While a label is
# mid-migration, two runs of one workflow can land on different images,
# so a release could build its deb on one OS and its AppImage on the
# other. Pinning makes the image a property of the repo: moving to a new
# one is a deliberate edit to every runs-on, and the "one x64 image"
# test below reds on a bump that misses a job.
#
# Like the other workflow suites, this reads the YAML with grep and sed
# rather than a YAML library, and the shape test fails loudly if the
# parser stops seeing the runs-on lines it expects.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
WORKFLOWS="${SCRIPT_DIR}/../.github/workflows"

# Every runs-on value as `<file>: <value>`. The leading-whitespace
# anchor skips commented-out runs-on lines. A trailing ` # comment` and
# quotes around a bare label are stripped, so `'ubuntu-24.04'` and
# `ubuntu-24.04 # pin` read as the label they are.
runs_on_values() {
	grep -H -E '^[[:space:]]*runs-on:' "$WORKFLOWS"/*.yml \
		| sed -E \
			-e 's|^.*/([^/]+):[[:space:]]*runs-on:[[:space:]]*|\1: |' \
			-e 's|[[:space:]]+#.*$||' \
			-e "s|: (['\"])([^'\"]*)\\1\$|: \\2|"
}

# The runner labels a runs-on value can resolve to: the value itself
# when it is a bare label, or each `&& '<label>'` / `|| '<label>'`
# result of an expression. Quoted operands of `==` are compared
# values, not labels, so they are skipped.
labels_of() {
	if [[ $1 == *'${{'* ]]; then
		grep -oE "(&&|\|\|)[[:space:]]*'[^']+'" <<< "$1" \
			| grep -oE "'[^']+'" | tr -d "'"
	else
		printf '%s\n' "$1"
	fi
}

@test "the parser sees the expected runs-on lines" {
	# If this reds, the indentation or key it keys on has drifted and
	# every assertion below is reading nothing.
	local count
	count=$(runs_on_values | wc -l)
	[[ $count -ge 19 ]]
}

@test "no workflow runs on a floating -latest label" {
	local hits
	hits=$(grep -n -E '^[^#]*[a-z]+-latest' "$WORKFLOWS"/*.yml || true)
	[[ -z $hits ]] || { echo "floating label: $hits"; return 1; }
}

@test "every runs-on resolves to an explicitly versioned Ubuntu image" {
	# An expression with no literal label (`${{ matrix.os }}`) yields
	# no labels at all, so it is flagged here rather than passing by
	# default.
	local line file value label labels bad=''
	while IFS= read -r line; do
		file=${line%%: *}
		value=${line#*: }
		labels=$(labels_of "$value")
		if [[ -z $labels ]]; then
			bad+="${file}: ${value} (no literal label)"$'\n'
			continue
		fi
		while IFS= read -r label; do
			[[ $label =~ ^ubuntu-[0-9]{2}\.[0-9]{2}(-arm)?$ ]] \
				|| bad+="${file}: ${label}"$'\n'
		done <<< "$labels"
	done < <(runs_on_values)
	[[ -z $bad ]] || { printf 'unpinned runner:\n%s' "$bad"; return 1; }
}

@test "every x64 job pins the same image" {
	# A half-done bump would split one release across two OSes, the
	# very thing pinning exists to prevent.
	local images
	images=$(runs_on_values | while IFS= read -r line; do
		labels_of "${line#*: }"
	done | grep -v -- '-arm$' | sort -u)
	[[ -n $images ]]
	[[ $(wc -l <<< "$images") -eq 1 ]] \
		|| { printf 'x64 images differ:\n%s\n' "$images"; return 1; }
}
