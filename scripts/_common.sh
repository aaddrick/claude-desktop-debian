#===============================================================================
# Common shell utilities: logging, command checks, checksum verification,
# asar resolution.
#
# Sourced by: build.sh, tools/patch-necessity-audit.sh,
#             tests/test-patch-stage.sh, tests/test-artifact-common.sh
# Sourced globals: (none)
# Modifies globals: asar_exec (via _resolve_asar)
#===============================================================================

check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 not found"
		return 1
	else
		echo "$1 found"
		return 0
	fi
}

section_header() {
	echo -e "\033[1;36m--- $1 ---\033[0m"
}

section_footer() {
	echo -e "\033[1;36m--- End $1 ---\033[0m"
}

verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-256 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")

	if [[ $actual_hash != "$expected_hash" ]]; then
		echo "SHA-256 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-256 verified: ${label}"
}

# Resolve a runnable asar into $asar_exec, or fail loud.
#
# Callers invoke "$asar_exec" as a single word, so a bare
# `npx --yes @electron/asar` fallback silently turns the next argument
# into a PACKAGE name: npx fetches an unrelated `extract` from the
# registry, nothing lands in the destination, and the caller then fails
# on whatever it read out of the empty tree rather than on anything
# real. Resolve a genuine asar or stop.
#
# Two traps this closes, both of which surfaced as the phantom
# "desktopName is missing/empty" WM_CLASS failure in #839:
#
#   - @electron/asar 4.x declares engines.node >=22.12.0 and refuses to
#     start below it. npm reports that as an EBADENGINE *warning*, not
#     an error, so the wrapper installs, lands on disk, and fails on
#     every invocation. Whether an unpinned install even lands on 4.x
#     depends on the npm version (npm 9 takes `latest`; npm 10's
#     manifest picker skips engine-incompatible versions), so the
#     symptom is host-dependent — pin the major explicitly instead of
#     trusting resolution.
#   - `-x` only proves a file exists. A 4.x wrapper under Node 20 is
#     executable and still cannot run, so probe --version and stop with
#     a message that names the Node requirement.
#
# The probe has two arms, judged separately, for the reason spelled out
# over setup_asar in scripts/setup/dependencies.sh: 4.3.0 under Node 20
# exits 1 with an empty stdout, so the exit code catches the shape that
# ships today, and the stdout-shape arm covers a future release that
# answers through --version and exits zero. The reply cannot be judged
# from a merged stream because the refusal text quotes the offending
# Node version and so contains a version number itself — so judge the
# shape of stdout, report the merged output, and anchor the match at
# the start of the reply.
#
# Args:
#   $1  directory to install into when no asar is on PATH (a caller's
#       $work_dir or an equivalent scratch dir — never hardcoded here)
#   $2  @electron/asar major to pin, default 3. 3.4.1 is the last
#       release that runs on the Node 20 stable distros still ship;
#       callers that only read an asar want 3 so they keep working
#       there. The build itself resolves asar through setup_asar, which
#       runs under the enforced NODE_MIN_VERSION floor instead.
# Sets: asar_exec
_resolve_asar() {
	local install_dir="$1"
	local major="${2:-3}"

	if [[ -z $install_dir ]]; then
		echo '_resolve_asar: no install directory given' >&2
		return 1
	fi
	# Checked here rather than left to the install subshell's `cd`,
	# which would report a missing directory as "failed to install".
	if [[ ! -d $install_dir ]]; then
		echo "_resolve_asar: not a directory: $install_dir" >&2
		return 1
	fi

	asar_exec=$(command -v asar)
	if [[ -z $asar_exec ]]; then
		echo "No asar on PATH; installing @electron/asar@$major into" \
			"$install_dir..."
		(
			cd "$install_dir" || exit 1
			if [[ ! -f package.json ]]; then
				echo '{"name":"asar-host","version":"0.0.1","private":true}' \
					> package.json || exit 1
			fi
			npm install --no-save --no-audit --no-fund \
				"@electron/asar@$major"
		) || {
			echo "Failed to install @electron/asar@$major." >&2
			return 1
		}
		asar_exec="$install_dir/node_modules/.bin/asar"
	fi

	if [[ ! -x $asar_exec ]]; then
		echo "asar is not executable: $asar_exec" >&2
		return 1
	fi

	local asar_report asar_probe_status asar_version
	asar_report=$("$asar_exec" --version 2>&1)
	asar_probe_status=$?
	asar_version=$("$asar_exec" --version 2>/dev/null)

	if (( asar_probe_status != 0 )) \
		|| [[ ! $asar_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
		echo "asar at '$asar_exec' will not run:" >&2
		echo "$asar_report" >&2
		echo '@electron/asar 4.x needs Node.js v22.12.0+; this host has' \
			"$(node --version 2>/dev/null || echo 'no node')." \
			'Use @electron/asar@3 on older Node, or a newer Node' \
			'(#839).' >&2
		return 1
	fi

	echo "Using asar executable: $asar_exec ($asar_version)"
}
