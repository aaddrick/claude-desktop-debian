# Process stand-ins shared by doctor.bats and launcher-common.bats.
#
# Loaded with `load 'test_helper'`. Every spawner closes fd 3 on the
# child (`3>&-`): fd 3 is bats' run-coordination pipe, and a child that
# inherits it keeps the whole run waiting after the test ends. Callers'
# teardown must run _kill_stand_ins.

# Spawn a process whose executable path passes _pid_is_claude_desktop:
# a copy of bash at $TEST_TMP/<relpath>, default the 3.x layout's bare
# `claude-desktop`, blocking on a fifo until killed. bash rather than
# sleep because uutils coreutils (Ubuntu 26.04) is a multi-call binary
# that refuses to run under any other name. Sets $claude_pid.
_spawn_claude_desktop_stand_in() {
	local exe="$TEST_TMP/${1:-claude-desktop}"
	local fifo="$TEST_TMP/claude-block"
	mkdir -p "${exe%/*}"
	cp /bin/bash "$exe"
	[[ -p $fifo ]] || mkfifo "$fifo"
	# shellcheck disable=SC2016  # inner shell expands $1
	"$exe" -c 'read -r _ < "$1"' _ "$fifo" 3>&- &
	claude_pid=$!
	_await_exe "$claude_pid" "$(readlink -f "$exe")"
}

# Spawn a plain sleep: alive for kill -0, not a Claude Desktop
# executable. Stands in for a recycled PID (#784). Sets $plain_pid.
_spawn_plain_sleep() {
	sleep 300 3>&- &
	plain_pid=$!
	_await_exe "$plain_pid" "$(readlink -f "$(command -v sleep)")"
}

# Write the body the cowork stand-ins run: a bash script named
# cowork-vm-service.js in $TEST_TMP/<1>/ that blocks on a fifo until
# signalled. <2> is prepended to the body (the "trap" disposition).
# Running it as `bash <script> args…` gives the process the argv
# [bash, <script>, args…], and exec -a then swaps argv[0]: that is how
# the stand-ins get a real positional argv, not one packed string.
_cowork_stand_in_script() {
	local dir="$TEST_TMP/$1" fifo="$TEST_TMP/cowork-block"
	mkdir -p "$dir"
	[[ -p $fifo ]] || mkfifo "$fifo"
	printf '%sread -r _ < %q\n' "${2:-}" "$fifo" \
		> "$dir/cowork-vm-service.js"
}

# Spawn a REAL process standing in for the cowork-vm-service fallback
# daemon, with the argv cowork-bwrap.sh spawn swap B gives the real one:
#   [node, <resources>/cowork-vm-service.js, -socket, <sock>]
# No --class, so the UI scan skips it. Pass "trap" to make it ignore
# SIGTERM (stands in for a stuck daemon, forcing the reaper's SIGKILL
# escalation). Appends to $cowork_pids and sets $cowork_pid to the new
# one. Unlike the stubbed pgrep/kill tests, this exercises the real
# signals against a real process — a `kill`->`kill -0` regression the
# stubs would wave through fails here (#369, the end-to-end reap leg
# #857 conceded). Reaped in _kill_stand_ins.
_spawn_cowork_daemon_stand_in() {
	local disp=''
	[[ ${1:-} == trap ]] && disp='trap "" TERM; '
	_cowork_stand_in_script resources "$disp"
	# shellcheck disable=SC2016  # inner shell expands $@
	bash -c 'exec -a node bash "$@"' _ \
		"$TEST_TMP/resources/cowork-vm-service.js" \
		-socket "$TEST_TMP/cowork.sock" 3>&- &
	cowork_pid=$!
	cowork_pids+=("$cowork_pid")
	_await_argv0 "$cowork_pid" node
}

# Spawn a REAL same-user process whose command line names
# cowork-vm-service.js without being the daemon (#882): the reaper
# must leave it alone. <1> picks the shape:
#   editor   [less, <dir>/cowork-vm-service.js] — a pager/editor on
#            the file; argv[2] is not -socket (default)
#   relative [node, cowork-vm-service.js, -socket, <sock>] — a
#            developer running the daemon by hand from the source dir;
#            argv[2] is -socket but argv[1] is not the absolute path
#            path.join(process.resourcesPath, …) always gives
#   packed   whole command line in argv[0], the shape #881's daemon
#            stand-in used; argv[1] is -c
# Appends to $bystander_pids. Reaped in _kill_stand_ins.
_spawn_cowork_bystander_stand_in() {
	local dir="$TEST_TMP/bystander" argv0
	_cowork_stand_in_script bystander
	# shellcheck disable=SC2016  # inner shells expand $@ / $1
	case ${1:-editor} in
		editor)
			argv0=less
			bash -c 'exec -a less bash "$@"' _ \
				"$dir/cowork-vm-service.js" 3>&- &
			;;
		relative)
			argv0=node
			bash -c 'cd "$1" && shift && exec -a node bash "$@"' _ \
				"$dir" cowork-vm-service.js \
				-socket "$TEST_TMP/dev.sock" 3>&- &
			;;
		packed)
			argv0='node cowork-vm-service.js -socket sock'
			bash -c 'exec -a "$1" bash -c "read -r _ < \"\$1\"" _ "$2"' \
				_ "$argv0" "$TEST_TMP/cowork-block" 3>&- &
			;;
	esac
	bystander_pids+=("$!")
	_await_argv0 "$!" "$argv0"
}

# Wait until /proc/PID/cmdline argv[0] is <2>: exec -a lands a moment
# after `&`, and until then the process still carries the spawning
# `bash -c …` argv — which names cowork-vm-service.js too, so a
# substring poll would pass before the real argv is in place.
_await_argv0() {
	local pid="$1" want="$2" i
	local -a argv
	for ((i = 0; i < 50; i++)); do
		mapfile -d '' argv 2>/dev/null < "/proc/$pid/cmdline"
		[[ ${argv[0]:-} == "$want" ]] && return 0
		sleep 0.1
	done
	return 1
}

# Restrict pgrep's results to the cowork stand-ins this test spawned.
# The real pgrep still runs with the caller's own flags (so -u and the
# pattern are exercised); only PIDs outside the test are dropped. The
# reaper's candidates are host-wide, so leaving it unscoped would
# SIGTERM/SIGKILL a developer's live fallback daemon (the #534 trap,
# destructive here). Bystanders are included on purpose: they must be
# spared by the argv check, not by this filter, or a bystander test
# pins nothing.
_scope_pgrep_to_stand_ins() {
	# shellcheck disable=SC2329  # called by the code under test
	pgrep() {
		local pid ours
		command pgrep "$@" | while read -r pid; do
			for ours in "${cowork_pids[@]}" "${bystander_pids[@]}"; do
				[[ $pid == "$ours" ]] && printf '%s\n' "$pid"
			done
		done
	}
}

# Wait until /proc/PID/exe shows the exec'd binary: the fork carries
# the parent's exe until exec lands, so asserting straight after `&`
# would be racy.
_await_exe() {
	local pid="$1" exe="$2" seen i
	for ((i = 0; i < 50; i++)); do
		seen=$(readlink "/proc/$pid/exe" 2>/dev/null)
		[[ $seen == "$exe" ]] && return 0
		sleep 0.1
	done
	return 1
}

# Reap whatever the spawners above started. Call from teardown.
# SIGKILL (not SIGTERM) so the trap-TERM cowork stand-in dies too.
_kill_stand_ins() {
	local pid
	for pid in "${claude_pid:-}" "${plain_pid:-}" \
		"${cowork_pids[@]}" "${bystander_pids[@]}"; do
		[[ -n $pid ]] || continue
		kill -KILL "$pid" 2>/dev/null || true
	done
	unset claude_pid plain_pid cowork_pid cowork_pids bystander_pids
}
