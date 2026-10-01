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

# Probe one asar candidate. Returns 0 only when the binary actually
# runs; sets $_asar_probe_report (merged streams, for the operator) and
# $_asar_probe_version (clean stdout, for the shape judgment).
#
# `-x` only proves a file exists. A 4.x wrapper under Node 20 is
# executable and still cannot run, so the exec bit is the first gate,
# not the only one.
#
# The run-check has two arms, judged separately, for the reason spelled
# out over setup_asar in scripts/setup/dependencies.sh: 4.3.0 under
# Node 20 exits 1 with an empty stdout, so the exit code catches the
# shape that ships today, and the stdout-shape arm covers a future
# release that answers through --version and exits zero. The reply
# cannot be judged from a merged stream because the refusal text quotes
# the offending Node version and so contains a version number itself —
# so judge the shape of stdout, report the merged output, and anchor
# the match at the start of the reply.
_asar_probe() {
	local candidate="$1"
	_asar_probe_report=''
	_asar_probe_version=''

	if [[ ! -x $candidate ]]; then
		_asar_probe_report="asar is not executable: $candidate"
		return 1
	fi

	local probe_status
	_asar_probe_report=$("$candidate" --version 2>&1)
	probe_status=$?
	_asar_probe_version=$("$candidate" --version 2>/dev/null)

	if (( probe_status != 0 )) \
		|| [[ ! $_asar_probe_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
		return 1
	fi
}

# The one line that has to survive every failure path. #839 is not "asar
# broke", it is "the operator could not tell it was a Node problem", so
# any exit that leaves the caller without an asar says this.
_asar_node_floor_hint() {
	echo '@electron/asar 4.x needs Node.js v22.12.0+; this host has' \
		"$(node --version 2>/dev/null || echo 'no node')." \
		'Use @electron/asar@3 on older Node, or a newer Node (#839).'
}

# npm install @electron/asar@<major> into a directory. Split out so the
# resolver reads as a sequence of decisions instead of carrying an
# install subshell inline; its no-asar and dead-asar paths both land
# here.
_asar_install() {
	local install_dir="$1" major="$2"
	(
		cd "$install_dir" || exit 1
		if [[ ! -f package.json ]]; then
			echo '{"name":"asar-host","version":"0.0.1","private":true}' \
				> package.json || exit 1
		fi
		npm install --no-save --no-audit --no-fund \
			"@electron/asar@$major"
	)
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
# @electron/asar 4.x declares engines.node >=22.12.0 and refuses to
# start below it. npm reports that as an EBADENGINE *warning*, not an
# error, so the wrapper installs, lands on disk, and fails on every
# invocation. Whether an unpinned install even lands on 4.x depends on
# the npm version (npm 9 takes `latest`; npm 10's manifest picker skips
# engine-incompatible versions), so the symptom is host-dependent — pin
# the major explicitly instead of trusting resolution.
#
# Order: a working asar on PATH wins outright (it may be deliberately
# staged, and it costs no network). A PATH asar that does NOT run falls
# through to the pinned install rather than stopping, because that
# install is very often the fix for that exact binary — a stale global
# 4.x left by an npm 9 that took `latest` is the #839 host plus one
# `npm i -g` (#849). Falling through is safe precisely because it is
# gated on the run-check: a tool that cannot run is not a staged tool
# being overridden, it is a dead one.
#
# Args:
#   $1  directory to install into (a caller's $work_dir or an
#       equivalent scratch dir — never hardcoded here)
#   $2  @electron/asar major to pin, default 3. 3.4.1 is the last
#       release that runs on the Node 20 stable distros still ship;
#       callers that only read an asar want 3 so they keep working
#       there. The build itself resolves asar through setup_asar, which
#       runs under the enforced NODE_MIN_VERSION floor instead.
# Sets: asar_exec
_resolve_asar() {
	local install_dir="$1"
	local major="${2:-3}"
	local path_asar path_refusal=''

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

	path_asar=$(command -v asar)
	if [[ -z $path_asar ]]; then
		echo "No asar on PATH; installing @electron/asar@$major into" \
			"$install_dir..."
	elif _asar_probe "$path_asar"; then
		asar_exec="$path_asar"
		echo "Using asar executable: $asar_exec ($_asar_probe_version)"
		return 0
	else
		# Held, not reported here. If the install below also fails
		# this refusal is the root cause and has to LEAD the final
		# report — an offline host would otherwise read only "failed
		# to install", which points at the network instead of at the
		# Node floor. Printing it here as well would only duplicate
		# it, and npm's own error spew in between is exactly what
		# buries it, so the detail is saved for the bottom where the
		# operator is looking. What goes out now is a two-line notice.
		path_refusal="asar at '$path_asar' will not run:"
		path_refusal+=$'\n'"$_asar_probe_report"
		echo "asar at '$path_asar' will not run." >&2
		echo "Falling back to @electron/asar@$major..." >&2
	fi

	if ! _asar_install "$install_dir" "$major"; then
		[[ -n $path_refusal ]] && echo "$path_refusal" >&2
		echo "Failed to install @electron/asar@$major into" \
			"$install_dir." >&2
		_asar_node_floor_hint >&2
		return 1
	fi

	asar_exec="$install_dir/node_modules/.bin/asar"
	if ! _asar_probe "$asar_exec"; then
		[[ -n $path_refusal ]] && echo "$path_refusal" >&2
		echo "asar at '$asar_exec' will not run:" >&2
		echo "$_asar_probe_report" >&2
		_asar_node_floor_hint >&2
		return 1
	fi

	echo "Using asar executable: $asar_exec ($_asar_probe_version)"
}
