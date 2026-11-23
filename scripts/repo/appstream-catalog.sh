#!/usr/bin/env bash
#===============================================================================
# AppStream catalog metadata for the APT and DNF repositories (#708).
#
# The packages already ship a metainfo file (#633), which makes the app
# show up in GNOME Software / App Center / Discover once it is installed.
# Store search on a system that has never installed it reads the repo's
# own catalog instead: DEP-11 Components files in the APT dists tree, and
# `appstream` / `appstream-icons` records in DNF repodata. This script
# builds those from a published package:
#
#   appstream-catalog.sh dep11 <deb> <staging-dir>
#       Writes <staging-dir>/Components.yml.gz and icons-<size>.tar.gz.
#       The reprepro export hook (reprepro-dep11-hook.sh) moves them into
#       dists/<suite>/main/dep11/ so they land in the signed Release.
#
#   appstream-catalog.sh rpm <rpm> <repo-arch-dir>
#       Adds appstream + appstream-icons records to
#       <repo-arch-dir>/repodata with modifyrepo_c. Run after
#       createrepo_c and before repomd.xml is signed.
#
# The catalog is composed from the package's own files with
# `appstreamcli compose` (metainfo, desktop entry, hicolor icons), so it
# can never drift from what the package installs. compose only sees a
# directory tree, so <pkgname> (the store's link from component to
# installable package) and the catalog origin are added afterwards.
#
# Requires: appstreamcli with compose (Ubuntu: appstream +
#   appstream-compose), dpkg-deb for dep11, rpm, rpm2cpio + cpio and
#   modifyrepo_c (createrepo-c) for rpm.
# Sourced by: tests/appstream-catalog.bats (functions only; the CLI
#   dispatch at the bottom runs only when executed)
# Modifies globals: (none)
#===============================================================================

appstream_origin_default='claude-desktop-unofficial'
appstream_icon_sizes=(48x48 64x64 128x128)

# Unpack the three trees compose reads from a .deb or .rpm into <dest>.
# Everything else in the package (the ~200 MB app) is skipped.
appstream_extract_pkg() {
	local pkg dest=$2
	# Absolute, because the rpm branch reads it after a cd.
	pkg=$(readlink -f -- "$1") || return 1
	mkdir -p "$dest" || return 1
	case $pkg in
		*.deb)
			dpkg-deb --fsys-tarfile "$pkg" \
				| tar -x -C "$dest" --wildcards \
					'./usr/share/applications/*' \
					'./usr/share/metainfo/*' \
					'./usr/share/icons/*' \
				|| return 1
			;;
		*.rpm)
			# rpm2cpio streams the whole payload; cpio keeps only the
			# matching paths. Subshell so the cd stays local.
			(
				cd "$dest" || exit 1
				rpm2cpio "$pkg" | cpio -idm --quiet \
					'./usr/share/applications/*' \
					'./usr/share/metainfo/*' \
					'./usr/share/icons/*'
			) || return 1
			;;
		*)
			echo "Unsupported package type: $pkg" >&2
			return 1
			;;
	esac
	if ! compgen -G "$dest/usr/share/metainfo/*.xml" > /dev/null; then
		echo "No metainfo found in $pkg" >&2
		return 1
	fi
}

# Add <pkgname> after each component <id> and an origin attribute on the
# <components> root. Text-level edit of compose's own output, whose shape
# is fixed: one <id> per component on its own line, one root element.
# Usage: appstream_annotate_catalog <pkgname> <origin> < in > out
appstream_annotate_catalog() {
	local pkgname=$1 origin=$2
	sed -e "s|^\([[:space:]]*\)<id>.*</id>\$|&\n\1<pkgname>$pkgname</pkgname>|" \
		-e "s|<components version=\"\([^\"]*\)\">|<components version=\"\1\" origin=\"$origin\">|"
}

# The package's own name, so the catalog names what the file installs.
appstream_pkg_name() {
	local pkg=$1
	case $pkg in
		*.deb) dpkg-deb -f "$pkg" Package ;;
		*.rpm) rpm -qp --qf '%{NAME}' "$pkg" 2> /dev/null ;;
		*) return 1 ;;
	esac
}

# Compose <pkg> into <work>/catalog.xml plus <work>/icons/<size>/*.png.
appstream_compose_pkg() {
	local pkg=$1 work=$2 origin=$3
	local pkgname root="$work/root" out="$work/compose"

	pkgname=$(appstream_pkg_name "$pkg") || return 1
	if [[ -z $pkgname ]]; then
		echo "Could not read the package name of $pkg" >&2
		return 1
	fi
	appstream_extract_pkg "$pkg" "$root" || return 1

	appstreamcli compose --no-net --origin="$origin" \
		--result-root="$out" --data-dir="$out/data" \
		--icons-dir="$work/icons" --hints-dir="$out/hints" \
		"$root" || return 1

	local data="$out/data/$origin.xml.gz"
	if [[ ! -s $data ]]; then
		echo "appstreamcli compose produced no catalog for $pkg" >&2
		return 1
	fi
	gzip -dc "$data" \
		| appstream_annotate_catalog "$pkgname" "$origin" \
		> "$work/catalog.xml" || return 1
	if ! grep -qF "<pkgname>$pkgname</pkgname>" "$work/catalog.xml"; then
		echo 'Failed to add <pkgname> to the composed catalog' >&2
		return 1
	fi
}

# DEP-11 carries the origin in the header document, which stores use to
# locate the cached icons. Whether `appstreamcli convert` keeps the
# root origin attribute varies by appstream version (1.0.2 on the
# Ubuntu 24.04 runner keeps it), so add the header line only when it
# is missing: a second Origin: key is a duplicate YAML key that strict
# parsers reject.
appstream_dep11_ensure_origin() {
	local yml=$1 origin=$2
	if ! grep -q '^Origin: ' "$yml"; then
		sed -i "0,/^Version: .*/s//&\nOrigin: $origin/" "$yml"
	fi
}

# Deterministic tar of the files under <dir> (sorted, no ./ prefix,
# fixed owner and mtime) so an unchanged icon set hashes the same in
# every Release file.
appstream_tar() {
	local dir=$1 out=$2
	(
		cd "$dir" || exit 1
		find . -type f -printf '%P\n' | LC_ALL=C sort \
			| tar --create --no-recursion --owner=0 --group=0 \
				--numeric-owner --mtime='@0' --files-from=-
	) > "$out"
}

# APT: stage DEP-11 Components + per-size icon tarballs from one .deb.
# The content is identical across architectures (the metainfo is
# arch-independent), so one composed file serves every binary-<arch>.
appstream_dep11_stage() {
	local deb=$1 staging=$2 origin=${3:-$appstream_origin_default}
	local work size

	work=$(mktemp -d) || return 1
	mkdir -p "$staging" || return 1

	if ! appstream_compose_pkg "$deb" "$work" "$origin" \
		|| ! appstreamcli convert --format=yaml "$work/catalog.xml" \
			"$work/Components.yml"; then
		rm -rf "$work"
		return 1
	fi
	appstream_dep11_ensure_origin "$work/Components.yml" "$origin"
	if ! grep -q '^Package: ' "$work/Components.yml" \
		|| ! grep -q "^Origin: $origin\$" "$work/Components.yml"; then
		echo 'DEP-11 output is missing Package: or Origin:' >&2
		rm -rf "$work"
		return 1
	fi
	# Each file is staged uncompressed and gzip'd. Only the .gz is
	# fetched, but APT verifies a download against the hash of its
	# decompressed form, so the Release must list both (the same reason
	# reprepro lists the uncompressed Packages).
	cp "$work/Components.yml" "$staging/Components.yml"

	# DEP-11 icon tarballs hold the cached icons flat, named as the
	# Icon: cached: entries reference them.
	for size in "${appstream_icon_sizes[@]}"; do
		[[ -d $work/icons/$size ]] || continue
		if ! appstream_tar "$work/icons/$size" \
			"$staging/icons-$size.tar"; then
			rm -rf "$work"
			return 1
		fi
	done
	local f
	for f in "$staging"/Components.yml "$staging"/icons-*.tar; do
		gzip -9nkf "$f" || { rm -rf "$work"; return 1; }
	done

	rm -rf "$work"
	echo "DEP-11 metadata staged in $staging:"
	ls -l "$staging"
}

# DNF: add appstream + appstream-icons records to an existing repodata.
appstream_rpm_inject() {
	local rpm=$1 repo=$2 origin=${3:-$appstream_origin_default}
	local work

	if [[ ! -f $repo/repodata/repomd.xml ]]; then
		echo "No repodata in $repo (run createrepo_c first)" >&2
		return 1
	fi
	work=$(mktemp -d) || return 1

	if ! appstream_compose_pkg "$rpm" "$work" "$origin"; then
		rm -rf "$work"
		return 1
	fi

	mv "$work/catalog.xml" "$work/appstream.xml" || return 1
	# appstream-icons keeps the <size>/ directories, as Fedora's own
	# repos do; consumers unpack it under the catalog origin.
	if ! appstream_tar "$work/icons" "$work/appstream-icons.tar"; then
		rm -rf "$work"
		return 1
	fi

	# Hand modifyrepo_c the uncompressed files and let it gzip them: that
	# records both checksum and open-checksum and names them
	# <hash>-appstream.xml.gz / -appstream-icons.tar.gz like Fedora's
	# repos. (--no-compress on pre-gzipped input drops the .gz from the
	# published name.) modifyrepo_c replaces an existing record of the
	# same type, so re-runs stay idempotent.
	if ! modifyrepo_c --compress-type=gz --mdtype=appstream \
			"$work/appstream.xml" "$repo/repodata" \
		|| ! modifyrepo_c --compress-type=gz --mdtype=appstream-icons \
			"$work/appstream-icons.tar" "$repo/repodata"; then
		rm -rf "$work"
		return 1
	fi

	rm -rf "$work"
	echo "AppStream records added to $repo/repodata"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	case ${1:-} in
		dep11)
			if (($# < 3)); then
				echo "Usage: $0 dep11 <deb> <staging-dir> [origin]" >&2
				exit 2
			fi
			appstream_dep11_stage "$2" "$3" "${4:-}"
			;;
		rpm)
			if (($# < 3)); then
				echo "Usage: $0 rpm <rpm> <repo-arch-dir> [origin]" >&2
				exit 2
			fi
			appstream_rpm_inject "$2" "$3" "${4:-}"
			;;
		*)
			echo "Usage: $0 {dep11|rpm} <package> <dir> [origin]" >&2
			exit 2
			;;
	esac
fi
