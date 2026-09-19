#!/usr/bin/env bats
#
# official-deb-download.bats
# The official pool's index runs ahead of its CDN: a .deb can be listed
# in Packages minutes before a GET stops answering 404. Two guards in
# scripts/setup/official-deb.sh absorb that lag, and these tests pin
# them:
#
#   _download_official_deb   retries with a doubling delay instead of
#                            failing the build on the first miss, and
#                            never leaves a partial file behind
#   official_deb_pool_ready  HEAD-probes a pool path so the version
#                            checker can refuse to tag an unfetchable
#                            pair
#
# wget and curl are shimmed on PATH; a counter file in the test tmpdir
# records how many times each was invoked, so the assertions are on
# attempts made, not on output that could pass vacuously.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

setup() {
	TEST_TMP="$(mktemp -d)"
	SHIM_DIR="$TEST_TMP/bin"
	mkdir -p "$SHIM_DIR"
	export PATH="$SHIM_DIR:$PATH"
	export COUNTER="$TEST_TMP/calls"
	: > "$COUNTER"

	# No real sleeping: the delay is env-tunable for exactly this.
	export OFFICIAL_DEB_DL_DELAY=0

	# shellcheck source=scripts/_common.sh
	source "$PROJECT_ROOT/scripts/_common.sh"
	# shellcheck source=scripts/setup/official-deb.sh
	source "$PROJECT_ROOT/scripts/setup/official-deb.sh"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Install a wget shim that fails the first FAIL_N calls and then writes
# DEST on success. Each call appends a line to $COUNTER. The heredocs
# below are quoted, so the shims read as plain bash; what varies per
# test travels in the environment they already inherit.
shim_wget() {
	export WGET_FAIL_N="$1"
	cat > "$SHIM_DIR/wget" <<'EOF'
#!/usr/bin/env bash
echo wget >> "$COUNTER"
n=$(grep -c wget "$COUNTER")
dest=''
while [[ $# -gt 0 ]]; do
	if [[ $1 == -O ]]; then dest=$2; shift; fi
	shift
done
if (( n <= WGET_FAIL_N )); then
	# Mimic a 404: wget leaves an empty output file behind.
	: > "$dest"
	exit 8
fi
echo payload > "$dest"
exit 0
EOF
	chmod +x "$SHIM_DIR/wget"
}

# Install a curl shim answering EXIT for every call; records argv.
shim_curl() {
	export CURL_EXIT="$1"
	cat > "$SHIM_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$COUNTER"
exit "$CURL_EXIT"
EOF
	chmod +x "$SHIM_DIR/curl"
}

wget_calls() {
	grep -c wget "$COUNTER"
}

# ---------------------------------------------------------------------------
# _download_official_deb
# ---------------------------------------------------------------------------

@test "download: succeeds first time - one attempt, file written" {
	shim_wget 0
	run _download_official_deb 'https://example.invalid/x.deb' \
		"$TEST_TMP/x.deb"
	[[ $status -eq 0 ]]
	[[ $(wget_calls) -eq 1 ]]
	[[ $(cat "$TEST_TMP/x.deb") == payload ]]
}

@test "download: two misses then a hit - three attempts, file written" {
	shim_wget 2
	run _download_official_deb 'https://example.invalid/x.deb' \
		"$TEST_TMP/x.deb"
	[[ $status -eq 0 ]]
	[[ $(wget_calls) -eq 3 ]]
	[[ $(cat "$TEST_TMP/x.deb") == payload ]]
	[[ $output == *'attempt 1/5 failed'* ]]
	[[ $output == *'attempt 2/5 failed'* ]]
}

@test "download: every attempt misses - gives up after OFFICIAL_DEB_DL_ATTEMPTS" {
	shim_wget 99
	OFFICIAL_DEB_DL_ATTEMPTS=3
	run _download_official_deb 'https://example.invalid/x.deb' \
		"$TEST_TMP/x.deb"
	[[ $status -ne 0 ]]
	[[ $(wget_calls) -eq 3 ]]
	[[ $output == *'Failed to download https://example.invalid/x.deb after 3 attempts'* ]]
}

@test "download: a failed attempt's partial file is removed" {
	# The shim leaves an empty file on failure, as wget -O does on a
	# 404. It must not survive to be sha256-checked as a .deb.
	shim_wget 99
	OFFICIAL_DEB_DL_ATTEMPTS=2
	run _download_official_deb 'https://example.invalid/x.deb' \
		"$TEST_TMP/x.deb"
	[[ $status -ne 0 ]]
	[[ ! -e "$TEST_TMP/x.deb" ]]
}

@test "download: the delay doubles between attempts" {
	shim_wget 99
	OFFICIAL_DEB_DL_ATTEMPTS=4
	# Shim sleep to record the requested delays instead of waiting.
	cat > "$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $1" >> "$COUNTER"
EOF
	chmod +x "$SHIM_DIR/sleep"
	OFFICIAL_DEB_DL_DELAY=15
	run _download_official_deb 'https://example.invalid/x.deb' \
		"$TEST_TMP/x.deb"
	[[ $status -ne 0 ]]
	[[ $(grep -c '^sleep' "$COUNTER") -eq 3 ]]
	[[ $(grep '^sleep' "$COUNTER" | tr '\n' ' ') == 'sleep 15 sleep 30 sleep 60 ' ]]
}

@test "download: fetch_official_deb goes through the retrying helper" {
	# Pin the call site, not just the helper: a revert to a bare wget in
	# fetch_official_deb would leave every helper test green. One miss
	# then a hit must still let the fetch reach the sha256 check, which
	# is where this stub deliberately stops it.
	shim_wget 1
	work_dir="$TEST_TMP"
	architecture=amd64
	unset local_deb_path
	verify_sha256() { echo 'reached sha256 check'; return 1; }
	run fetch_official_deb
	[[ $status -ne 0 ]]
	[[ $(wget_calls) -eq 2 ]]
	[[ $output == *'reached sha256 check'* ]]
}

# ---------------------------------------------------------------------------
# official_deb_pool_ready
# ---------------------------------------------------------------------------

@test "pool_ready: HEAD 200 - returns 0, probes the pool URL with -I" {
	shim_curl 0
	run official_deb_pool_ready 'pool/main/c/claude-desktop/x_amd64.deb'
	[[ $status -eq 0 ]]
	grep -q -- "-fsSI" "$COUNTER"
	grep -q "$OFFICIAL_APT_BASE/pool/main/c/claude-desktop/x_amd64.deb" \
		"$COUNTER"
}

@test "pool_ready: HEAD fails (404) - returns non-zero" {
	shim_curl 22
	run official_deb_pool_ready 'pool/main/c/claude-desktop/x_arm64.deb'
	[[ $status -ne 0 ]]
}

@test "pool_ready: empty pool path - returns non-zero without probing" {
	# An unresolved arch hands the checker an empty filename; probing
	# the bare base URL would answer 200 and wave the tag through.
	shim_curl 0
	run official_deb_pool_ready ''
	[[ $status -ne 0 ]]
	[[ ! -s "$COUNTER" ]]
}
