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

# Emit one file: from staging as <name>.new, otherwise re-list an
# existing published copy so the Release keeps it.
emit() {
	local name=$1 src
	src="$staging/$2"
	if [[ -n $staging && -f $src ]]; then
		mkdir -p "$dep11_dir" || return 1
		cp "$src" "$dep11_dir/$name.new" || return 1
		echo "$dep11_rel/$name.new" >&3
	elif [[ -f $dep11_dir/$name ]]; then
		echo "$dep11_rel/$name" >&3
	fi
}

# Each index is listed uncompressed and as .gz: clients fetch the .gz
# but verify it against the hash of the decompressed form, and treat a
# target whose uncompressed hash is absent as missing from the Release.
for ext in '' .gz; do
	emit "Components-$arch.yml$ext" "Components.yml$ext" || exit 1
	if [[ $arch == "$icons_arch" ]]; then
		for size in 48x48 64x64 128x128; do
			emit "icons-$size.tar$ext" "icons-$size.tar$ext" || exit 1
		done
	fi
done
exit 0
