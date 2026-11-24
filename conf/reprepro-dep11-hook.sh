#!/usr/bin/env bash
#===============================================================================
# reprepro export hook: publish DEP-11 (AppStream) metadata (#708).
#
# APT only fetches index files that the signed Release lists, so DEP-11
# files dropped into dists/ by hand are ignored. reprepro lets an export
# hook add files to the Release instead: it runs the hook once per
# generated index with
#   $1 dist dir   (e.g. ./dists/stable)
#   $2 new name   (e.g. main/binary-amd64/Packages.new)
#   $3 old name   (e.g. main/binary-amd64/Packages)
#   $4 status     (new | change | old)
# and every path the hook writes to fd 3 (relative to $1) is hashed into
# the Release. A `.new` suffix tells reprepro to rename the file into
# place first. See reprepro's examples/xz.example for the protocol.
#
# Wired up in conf/distributions as
#   DebIndices: Packages Release . .gz reprepro-dep11-hook.sh
# with this file copied to conf/ (the update-apt-repo CI job does both).
#
# Content comes from $DEP11_STAGING (Components.yml, icons-<size>.tar
# and their .gz), written by
# `appstream-catalog.sh dep11`. On an export without staging (a manual
# reprepro run, or a failed compose) the files already in dists/ are
# re-listed unchanged, so a release never drops the catalog it had.
# The same fallback applies when staging is set but the files can't be
# written into dists/: the hook warns and exits 0, because the catalog
# is optional and must never fail the APT publish.
#
# Icon tarballs are architecture-independent; they are listed from the
# $DEP11_ICONS_ARCH (default amd64) invocation only, so each lands in
# the Release once.
#
# Sourced by: tests/appstream-catalog.bats (executed, not sourced)
#===============================================================================

dist_dir=$1
old_name=$3

# Only the per-architecture binary Packages index carries DEP-11.
[[ $old_name =~ ^(.+)/binary-([^/]+)/Packages$ ]] || exit 0
component=${BASH_REMATCH[1]}
arch=${BASH_REMATCH[2]}
dep11_rel="$component/dep11"
dep11_dir="$dist_dir/$dep11_rel"
icons_arch=${DEP11_ICONS_ARCH:-amd64}
staging=${DEP11_STAGING:-}

# Published name -> staging name, for this index. Each is listed
# uncompressed and as .gz: clients fetch the .gz but verify it against
# the hash of the decompressed form, and treat a target whose
# uncompressed hash is absent as missing from the Release.
names=() sources=()
for ext in '' .gz; do
	names+=("Components-$arch.yml$ext") sources+=("Components.yml$ext")
	if [[ $arch == "$icons_arch" ]]; then
		for size in 48x48 64x64 128x128; do
			names+=("icons-$size.tar$ext") sources+=("icons-$size.tar$ext")
		done
	fi
done

# Stage every file that has a staged source as <name>.new. All or
# nothing for this index: if any copy fails, drop the .new files
# written so far, so this index never mixes new and previously
# published catalog files. reprepro runs the hook once per
# architecture, so the guarantee is per index, not per release: when
# an icon (listed only for $DEP11_ICONS_ARCH) fails to copy, that arch
# keeps its old catalog while the others still get the new
# Components. The Release is valid either way.
# cp -T: if a directory already sits at a .new target, fail the copy
# instead of copying into it (reprepro would then reject the listing).
staged=()
stage_all() {
	local i src
	for i in "${!names[@]}"; do
		src="$staging/${sources[$i]}"
		[[ -f $src ]] || continue
		mkdir -p "$dep11_dir" && cp -T "$src" "$dep11_dir/${names[$i]}.new" \
			|| return 1
		staged[i]=1
	done
}

use_staging=false
if [[ -n $staging ]]; then
	if stage_all; then
		use_staging=true
	else
		# Every name, not just the staged ones: the copy that failed may
		# have left a partial file behind.
		for i in "${!names[@]}"; do
			rm -f "$dep11_dir/${names[$i]}.new"
		done
		staged=()
		# The catalog is optional: warn and fall back to the published
		# copy, like a failed compose, rather than fail the export.
		echo "reprepro-dep11-hook: could not stage DEP-11 files into" \
			"$dep11_dir; keeping the published catalog" >&2
	fi
fi

# List each file: the staged .new if there is one, otherwise an existing
# published copy so the Release keeps it. A failed write to reprepro's
# fd 3 is the one error left fatal: reprepro would get a partial list.
for i in "${!names[@]}"; do
	if $use_staging && [[ -n ${staged[$i]:-} ]]; then
		echo "$dep11_rel/${names[$i]}.new" >&3 || exit 1
	elif [[ -f $dep11_dir/${names[$i]} ]]; then
		echo "$dep11_rel/${names[$i]}" >&3 || exit 1
	fi
done
exit 0
