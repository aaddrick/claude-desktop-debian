#!/usr/bin/env bats
#
# ci-tag-failure-job.bats
# Structural invariants for the "Report tag build failure" job in
# .github/workflows/ci.yml and the pool-readiness gate in
# .github/workflows/check-claude-version.yml.
#
# The v3.2.4+claude2.2553.0 tag build died on a pool-lag 404 and nobody
# saw it until the next day's bump superseded it (#859). Two things now
# stand between that and a repeat: the checker refuses to tag a version
# whose .deb isn't fetchable, and a failed tag chain opens an issue.
# Both are YAML, so the only way a regression shows is structurally — a
# dropped `needs` entry, a lost `always()`, a gate that no longer
# sources the probe — and this suite reads the shape back the same awk
# way ci-release-job.bats does.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CI_YML="${SCRIPT_DIR}/../.github/workflows/ci.yml"
CHECK_YML="${SCRIPT_DIR}/../.github/workflows/check-claude-version.yml"

# The job's region: from its header to the next job header at the same
# indent (or EOF).
job_region() {
	awk -v job="  $1:" '
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
			inj = ($0 == job)
			next
		}
		inj { print }
	' "$CI_YML"
}

# The `needs:` list of the job, one name per line.
job_needs() {
	job_region "$1" | awk '
		/^    needs:/ { innd = 1; next }
		innd && /^      - / { sub(/^      - /, ""); print; next }
		innd { innd = 0 }
	'
}

# The `if:` expression of the job, folded to one line.
job_if() {
	job_region "$1" | awk '
		/^    if: >-/ { inif = 1; next }
		inif && /^      / { printf "%s ", $0; next }
		inif { inif = 0 }
	'
}

# Every job header in ci.yml that carries a tag gate.
tag_gated_jobs() {
	awk '
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
			job = $0
			sub(/^  /, "", job)
			sub(/:.*/, "", job)
		}
		/startsWith\(github\.ref, .refs\/tags\/v.\)/ &&
			job != "report-tag-failure" { print job }
	' "$CI_YML" | sort -u
}

@test "parser sees the report-tag-failure job" {
	[[ -n $(job_region report-tag-failure) ]]
}

@test "report job needs every job of the tag chain" {
	# The chain is: every job gated on the tag (release + the four
	# publishers) plus everything release itself needs. A job missing
	# here is a failure the reporter can't see.
	local needs expected
	needs=$(job_needs report-tag-failure | sort)
	expected=$(printf '%s\n' test-flags build test-artifacts \
		test-artifacts-arm64 release mirror-official-deb \
		update-apt-repo update-dnf-repo update-aur-repo | sort)
	[[ $needs == "$expected" ]]
}

@test "report job's needs cover every tag-gated job in ci.yml" {
	# Derived, not hardcoded: adding a fifth publisher without adding it
	# to the reporter's needs reds this one.
	local missing job
	missing=''
	for job in $(tag_gated_jobs); do
		job_needs report-tag-failure | grep -qx "$job" || missing+=" $job"
	done
	[[ -z $missing ]] || { echo "not in needs:$missing"; return 1; }
}

@test "report job runs with always() and only when a needed job failed" {
	local cond
	cond=$(job_if report-tag-failure)
	[[ $cond == *'always()'* ]]
	[[ $cond == *"startsWith(github.ref, 'refs/tags/v')"* ]]
	[[ $cond == *"contains(needs.*.result, 'failure')"* ]]
}

@test "report job can write issues and nothing more" {
	local perms
	perms=$(job_region report-tag-failure | awk '
		/^    permissions:/ { inp = 1; next }
		inp && /^      / { print; next }
		inp { inp = 0 }
	')
	[[ $perms == '      issues: write' ]]
}

@test "report job labels the issue release-failure and titles it by tag" {
	local region
	region=$(job_region report-tag-failure)
	[[ $region == *"const label = 'release-failure';"* ]]
	[[ $region == *'Tag build failed: ${tag}'* ]]
	# Re-runs append to the open issue instead of opening a second one.
	[[ $region == *'issues.createComment'* ]]
	[[ $region == *'issues.create('* ]]
}

@test "report job hands the failed job names to the issue" {
	local region
	region=$(job_region report-tag-failure)
	[[ $region == *'NEEDS: ${{ toJSON(needs) }}'* ]]
	[[ $region == *"job.result === 'failure'"* ]]
}

@test "mirror job downloads through the retrying helper, not bare wget" {
	# The second bare-wget site the #859 triage found: the post-release
	# mirror fetches the same pool files and had the same one-shot
	# exposure. It sources official-deb.sh already, so the helper is in
	# scope; a revert to `wget -q -O` here would fail the mirror on the
	# first 404 while the build leg retries.
	local region
	region=$(job_region mirror-official-deb)
	[[ -n $region ]]
	[[ $region == *'_download_official_deb "$official_deb_url"'* ]]
	[[ $region != *'wget '* ]]
}

@test "checker probes both pool files before tagging" {
	# The gate must (a) source the probe, (b) probe both arches, and
	# (c) sit inside the update_needed branch so a no-op run never
	# spends two HEADs.
	local step
	step=$(awk '
		/id: check_update/ { ins = 1 }
		ins && /^      - name:/ && !/Check if update needed/ { ins = 0 }
		ins { print }
	' "$CHECK_YML")
	[[ $step == *'source scripts/setup/official-deb.sh'* ]]
	[[ $step == *'official_deb_pool_ready "$pool_path"'* ]]
	[[ $step == *'steps.resolve.outputs.amd64_filename'* ]]
	[[ $step == *'steps.resolve.outputs.arm64_filename'* ]]
	# Ordering: the probe comes after UPDATE_NEEDED is decided and
	# before NEW_TAG is composed.
	local decided probe tagged
	decided=$(grep -n 'if \[\[ "\$UPDATE_NEEDED" == "true" \]\]' "$CHECK_YML" | head -1 | cut -d: -f1)
	probe=$(grep -n 'official_deb_pool_ready "\$pool_path"' "$CHECK_YML" | cut -d: -f1)
	tagged=$(grep -n 'NEW_TAG="v\${REPO_VERSION}+claude\${VER}"' "$CHECK_YML" | cut -d: -f1)
	[[ -n $decided && -n $probe && -n $tagged ]]
	(( decided < probe && probe < tagged ))
}

@test "checker skips the run (update_needed=false) on a pool miss" {
	local step
	step=$(awk '
		/official_deb_pool_ready "\$pool_path"/ { ins = 1 }
		ins { print }
		ins && /done/ { exit }
	' "$CHECK_YML")
	[[ $step == *'echo "update_needed=false" >> "$GITHUB_OUTPUT"'* ]]
	[[ $step == *'exit 0'* ]]
}
