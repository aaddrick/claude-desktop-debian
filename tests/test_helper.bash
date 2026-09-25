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

# Spawn a REAL process standing in for the cowork-vm-service fallback
# daemon: its argv carries the `cowork-vm-service.js` fingerprint the
# reaper greps for (pgrep -f), but no --class, so the UI scan skips it
# and only cleanup_orphaned_cowork_daemon matches. exec -a overrides
# argv[0] with the full fake command line. Blocks on a fifo until
# signalled. Pass "trap" to make it ignore SIGTERM (stands in for a
# stuck daemon, forcing the reaper's SIGKILL escalation). Sets
# $cowork_pid. Unlike the stubbed pgrep/kill tests, this exercises the
# real signals against a real process — a `kill`->`kill -0` regression
# the stubs would wave through fails here (#369, the end-to-end reap leg
# #857 conceded). Reaped in _kill_stand_ins.
_spawn_cowork_daemon_stand_in() {
	local disp=''
	[[ ${1:-} == trap ]] && disp='trap "" TERM; '
	local fifo="$TEST_TMP/cowork-block"
	[[ -p $fifo ]] || mkfifo "$fifo"
	bash -c "exec -a 'node cowork-vm-service.js -socket sock' \
		bash -c '${disp}read -r _ < \"\$1\"' _ '$fifo'" 3>&- &
	cowork_pid=$!
	_await_cowork_cmdline "$cowork_pid"
}

# Wait until /proc/PID/cmdline carries the daemon fingerprint: exec -a
# lands a moment after `&`, so matching straight away would be racy
# (mirrors _await_exe, but the daemon is matched by cmdline not exe).
_await_cowork_cmdline() {
	local pid="$1" i cmd
	for ((i = 0; i < 50; i++)); do
		cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
		[[ $cmd == *cowork-vm-service.js* ]] && return 0
		sleep 0.1
	done
	return 1
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
	for pid in "${claude_pid:-}" "${plain_pid:-}" "${cowork_pid:-}"; do
		[[ -n $pid ]] || continue
		kill -KILL "$pid" 2>/dev/null || true
	done
	unset claude_pid plain_pid cowork_pid
}
