#!/usr/bin/env bats
#
# launcher-prelaunch-calls.bats
# The generated launchers still call the pre-launch hygiene helpers.
#
# Every one of those helpers is unit-tested against its definition in
# scripts/launcher-common.sh, and nothing asserted that a launcher ever
# calls it. Deleting the whole block from all three of
# scripts/packaging/{deb,rpm,appimage}.sh left the suite green (#857).
# `backup_user_config` is the one that matters most: it is the
# patch-zero-clean primary fix for the config-wipe class (see
# docs/learnings/config-wipe-guard.md), and losing its call is silent
# until a user needs a backup that was never taken.
#
# Verification tier: this is the cheap static one. It reads the
# packaging scripts, not a built package, so it pins that the launcher
# *source* makes the calls in the right region — not that the shipped
# launcher executes them against real stale state. That end-to-end leg
# (one fixture per helper: a stale lock, an orphaned daemon, a dead
# socket) is the gap #857 concedes in its own Out-of-scope section.
# `cleanup_replaced_desktop_ui` is the only one with such a leg today,
# via `run_replaced_ui_cleanup_test` for deb and rpm.
#
# Search scope is the three packaging scripts alone, deliberately.
# `cleanup_after_electron_exit` in scripts/launcher-common.sh re-runs
# four of these same names *after* Electron exits, so a repo-wide grep
# for the names is satisfied without any launcher calling anything.
# There is no fourth launcher: nix/claude-desktop.nix and nix/fhs.nix
# contain none of these calls.
#
# No YAML/bash parser is pulled in — awk splits each script on its
# heredoc boundaries, the same shape tests/ci-release-job.bats uses on
# ci.yml. A parser that silently matched nothing would pass every
# assertion below, so the first test asserts the parse's own shape.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
PACKAGING_DIR="${SCRIPT_DIR}/../scripts/packaging"

readonly PACKAGING_SCRIPTS=(
	deb.sh
	rpm.sh
	appimage.sh
)

# The pre-launch block, in the order the launchers run it. One array for
# all three formats on purpose: a call added to one launcher and missed
# in the others reds here, which is the regression #856 would have been
# one bad merge away from. Copying this list per format would pin only
# that each format matches its own copy.
#
# Eight entries, where #857 as filed listed six. Its table also covers
# `cleanup_replaced_desktop_ui` (which its sed reproducer omits, because
# deb and rpm have an artifact-test leg for it — AppImage has none, so
# the static pin is its only coverage), and #856 landed
# `cleanup_stale_vm_bundle_images` in all three launchers after the
# issue was written.
readonly PRELAUNCH_CALLS=(
	cleanup_replaced_desktop_ui
	cleanup_orphaned_cowork_daemon
	cleanup_stale_desktop_helpers
	cleanup_stale_lock
	cleanup_stale_cowork_socket
	cleanup_stale_vm_bundle_images
	heal_autostart_entry
	backup_user_config
)

# The launcher heredoc body of packaging script <1>, as `<lineno>:<text>`
# rows (grep -n's own shape, so `cut -d: -f1` reads the number back).
#
# Keyed on a column-0 `cat > … << EOF` opener and its bare `EOF`
# terminator, then narrowed to the single region containing the
# launcher's `setup_logging` call. Each script writes several heredocs —
# the .desktop entry, the AppStream metainfo, deb's postinst/postrm —
# and only the launcher one is in scope. rpm's `<< SPECEOF` and deb's
# nested `<<'APPARMOR_EOF'` are not openers here and their terminators
# are not `^EOF$`, so neither splices a region.
launcher_heredoc() {
	awk -v q="'" '
		!inhd && $0 ~ ("^cat > .*<<[[:space:]]*" q "?EOF" q \
			"?[[:space:]]*$") {
			inhd = 1
			body = ""
			next
		}
		inhd && /^EOF[[:space:]]*$/ {
			inhd = 0
			if (body ~ /setup_logging/) printf "%s", body
			next
		}
		inhd { body = body NR ":" $0 "\n" }
	' "${PACKAGING_DIR}/$1"
}

# The `<lineno>:<text>` rows on stdin that are a call to <1>: the name at
# column 0 of the launcher line, followed by end-of-line or whitespace.
# Emits the line numbers.
#
# The block is flat by construction, so an indented line is not accepted
# as a call either — see the near-miss test, which mutation-checks each
# piece of the anchor.
#
# Comment rows are dropped first as a second layer, and honestly: with
# the `^<lineno>:` anchor in place the drop is redundant, because a `#`
# already occupies column 0 of any commented-out call. Removing it is
# the one mutation of this matcher the suite does not catch. It stays
# because it is what makes the anchor safe to relax — appimage.sh
# carries a real comment directly above its `heal_autostart_entry`, and
# scripts/launcher-common.sh names these helpers in prose, so a future
# looser match would walk straight into both.
call_lines() {
	grep -vE '^[0-9]+:[[:space:]]*#' \
		| grep -E "^[0-9]+:$1([[:space:]]|\$)" \
		| cut -d: -f1
}

# The launcher heredoc of <1> with comment rows dropped and the line
# numbers stripped, for assertions that match a whole source line.
uncommented_launcher() {
	launcher_heredoc "$1" | grep -vE '^[0-9]+:[[:space:]]*#' \
		| cut -d: -f2- || true
}

# Count of column-0, uncommented calls to <2> anywhere in script <1>,
# heredoc or not. Compared against the in-heredoc count to prove no
# asserted call sits outside the launcher.
file_calls() {
	grep -vE '^[[:space:]]*#' "${PACKAGING_DIR}/$1" \
		| grep -cE "^$2([[:space:]]|\$)" || true
}

# The `heal_autostart_entry` argument each format must carry, verbatim as
# the packaging script spells it.
#
# deb and rpm open their launcher heredoc unquoted, so `$package_name`
# expands at build time and the source line holds it literally. The
# AppImage heredoc is quoted (`<< 'EOF'`), so `${APPIMAGE:-}` is literal
# in the source *and* in the shipped AppRun, where the AppImage runtime
# fills it in. A grep for one format's line therefore cannot match
# another's, which is the point of the cross-format negative below.
heal_call() {
	case "$1" in
	deb.sh | rpm.sh)
		printf '%s' 'heal_autostart_entry "/usr/bin/$package_name"'
		;;
	appimage.sh)
		printf '%s' 'heal_autostart_entry "${APPIMAGE:-}"'
		;;
	*)
		return 1
		;;
	esac
}

@test "the launcher-heredoc parser sees the expected shape" {
	# Guards every test below. A renamed packaging script, a reindented
	# heredoc opener or a launcher that stops being a heredoc would
	# otherwise let the rest pass on empty input.
	local script body rows
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		[[ -s "${PACKAGING_DIR}/${script}" ]]

		body=$(launcher_heredoc "$script")
		[[ -n "$body" ]]

		rows=$(grep -c '' <<<"$body")
		[[ "$rows" -ge 30 ]]

		# Exactly one launcher region was kept, not two spliced
		# together, and it carries both ordering landmarks.
		[[ $(grep -cE '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body") -eq 1 ]]
		[[ $(grep -cE '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body") -eq 1 ]]

		# The region stops at its own EOF instead of bleeding into
		# the .desktop heredoc that follows it in all three scripts.
		[[ "$body" != *'[Desktop Entry]'* ]]
	done
}

@test "the call anchor rejects comments, prefixes and prose mentions" {
	# The near-miss fixture: rows one character short of matching, which
	# is what makes the anchor pinned rather than merely present.
	# Dropping the `^<lineno>:` prefix admits the prose mention,
	# dropping the trailing-boundary group admits the prefixed name, and
	# allowing leading whitespace admits the indented row — each
	# loosening reds this test on its own.
	local fixture hits
	fixture=$(cat <<-'FIXTURE'
		10:# cleanup_stale_lock
		11:  # cleanup_stale_lock
		12:cleanup_stale_lock_extra
		13:log_message 'ran cleanup_stale_lock'
		14:  cleanup_stale_lock
		15:cleanup_stale_lock
		16:# heal_autostart_entry "${APPIMAGE:-}"
		17:heal_autostart_entry "${APPIMAGE:-}"
	FIXTURE
	)

	hits=$(call_lines cleanup_stale_lock <<<"$fixture")
	[[ "$hits" == '15' ]]

	hits=$(call_lines heal_autostart_entry <<<"$fixture")
	[[ "$hits" == '17' ]]
}

@test "every pre-launch call appears exactly once in every launcher" {
	local script body call count offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			count=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			[[ "$count" -eq 1 ]] && continue
			offenders+="${script}: ${call}:"
			offenders+=" ${count} call site(s), want 1"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call missing or duplicated:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "every pre-launch call runs after setup_logging, before the exec" {
	# A cleanup that runs after the exec is not a cleanup, and
	# log_message needs setup_logging to have run first.
	local script body start end call line offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		start=$(grep -E '^[0-9]+:setup_logging \|\| exit 1$' \
			<<<"$body" | head -1 | cut -d: -f1)
		end=$(grep -E '^[0-9]+:run_electron_and_cleanup ' \
			<<<"$body" | head -1 | cut -d: -f1)

		[[ -n "$start" && -n "$end" ]] || {
			offenders+="${script}: no setup_logging/exec landmark"
			offenders+=$'\n'
			continue
		}

		for call in "${PRELAUNCH_CALLS[@]}"; do
			line=$(call_lines "$call" <<<"$body" | head -1)
			[[ -n "$line" ]] || {
				offenders+="${script}: ${call}: no call site"$'\n'
				continue
			}
			[[ "$line" -gt "$start" && "$line" -lt "$end" ]] \
				&& continue
			offenders+="${script}: ${call}: line ${line} outside"
			offenders+=" (${start}, ${end})"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call outside the launch window:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "no pre-launch call site sits outside the launcher heredoc" {
	# Presence alone is satisfied by a call written next to the `cat >`
	# in the packaging script's own body, where it would run at build
	# time instead of at launch. Counting the whole file and the
	# heredoc separately makes the two disagree in that case.
	local script body call inside in_file offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(launcher_heredoc "$script")
		for call in "${PRELAUNCH_CALLS[@]}"; do
			inside=$(call_lines "$call" <<<"$body" \
				| grep -c . || true)
			in_file=$(file_calls "$script" "$call")
			[[ "$inside" -eq "$in_file" ]] && continue
			offenders+="${script}: ${call}: ${in_file} in file,"
			offenders+=" ${inside} in the launcher"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'pre-launch call outside the launcher heredoc:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "each launcher carries only its own heal_autostart_entry argument" {
	# The argument is the one line of the block that differs per format,
	# so it is the easiest to copy wrong. Foreign arguments are derived
	# from the same heal_call() the positive assertion uses, so adding a
	# fourth format cannot leave a stale expectation behind.
	local script other body want foreign offenders=''
	for script in "${PACKAGING_SCRIPTS[@]}"; do
		body=$(uncommented_launcher "$script")
		want=$(heal_call "$script")

		[[ $(grep -cFx -- "$want" <<<"$body" || true) -eq 1 ]] || {
			offenders+="${script}: want exactly one: ${want}"$'\n'
		}

		for other in "${PACKAGING_SCRIPTS[@]}"; do
			foreign=$(heal_call "$other")
			[[ "$foreign" == "$want" ]] && continue
			grep -qFx -- "$foreign" <<<"$body" || continue
			offenders+="${script}: carries ${other}'s argument:"
			offenders+=" ${foreign}"$'\n'
		done
	done

	[[ -z "$offenders" ]] || {
		printf 'wrong heal_autostart_entry argument:\n%s' \
			"$offenders" >&2
		false
	}
}