#===============================================================================
# Official Claude Desktop .deb acquisition: resolve, download, verify,
# extract. Replaced the Windows-installer download path in the v3.0.0
# official-Linux rebase.
#
# The official APT repository is plain HTTPS (no bot challenge), so both
# resolution and download are curl/wget-able. Extraction deliberately
# avoids dpkg-deb so rpm-family and Arch hosts can build: ar + tar handle
# every Debian archive member.
#
# Sourced by: build.sh, tools/patch-necessity-audit.sh
# Sourced globals:
#   work_dir, architecture, local_deb_path (optional), release_tag (optional)
# Modifies globals:
#   claude_extract_dir, version, official_deb_url, official_deb_sha256,
#   official_deb_filename, official_deb_depends, official_deb_recommends,
#   resolved_official_version, resolved_official_filename,
#   resolved_official_sha256, resolved_official_size
#===============================================================================

OFFICIAL_APT_BASE='https://downloads.claude.ai/claude-desktop/apt/stable'

# Pinned artifact per architecture, seeded from the Packages indexes on
# 2026-07-04. Bumped by check-claude-version after the rebase lands.
OFFICIAL_DEB_VERSION='1.18286.0'
OFFICIAL_DEB_POOL_AMD64='pool/main/c/claude-desktop/claude-desktop_1.18286.0_amd64.deb'
OFFICIAL_DEB_SHA256_AMD64='8f314ad1a80aab52711a8eaabc06aae48fb341f0adea4a0d7264db5cab9d0536'
OFFICIAL_DEB_POOL_ARM64='pool/main/c/claude-desktop/claude-desktop_1.18286.0_arm64.deb'
OFFICIAL_DEB_SHA256_ARM64='4820b989a9e4333956b6cbeaee2732dd2b49904fba540b472963c8003c8086c7'

# Set official_deb_url/sha256/filename from the pinned block for the
# current (or given) architecture.
official_deb_pin() {
	local arch="${1:-$architecture}"
	local pool_path

	case "$arch" in
		amd64)
			pool_path="$OFFICIAL_DEB_POOL_AMD64"
			official_deb_sha256="$OFFICIAL_DEB_SHA256_AMD64"
			;;
		arm64)
			pool_path="$OFFICIAL_DEB_POOL_ARM64"
			official_deb_sha256="$OFFICIAL_DEB_SHA256_ARM64"
			;;
		*)
			echo "Unsupported architecture for official .deb: $arch" >&2
			return 1
			;;
	esac

	official_deb_url="$OFFICIAL_APT_BASE/$pool_path"
	official_deb_filename="${pool_path##*/}"
}

# Query the official Packages index for the newest claude-desktop entry.
# Used by CI (check-claude-version) and the doctor drift check, never by
# the pinned build itself. Sets resolved_official_{version,filename,
# sha256,size}.
#
# sort -V is sufficient for the upstream scheme (dotted numerics, no
# epochs or tildes observed); revisit if upstream ever ships either.
resolve_official_deb() {
	local arch="${1:-$architecture}"
	local index_url="$OFFICIAL_APT_BASE/dists/stable/main/binary-${arch}/Packages"
	local newest

	newest=$(curl -fsS --max-time 30 "$index_url" | awk -v RS='' '
		/^Package: claude-desktop\n/ || $1 == "Package:" {
			v = f = s = z = ""
			n = split($0, lines, "\n")
			for (i = 1; i <= n; i++) {
				if (lines[i] ~ /^Version: /) v = substr(lines[i], 10)
				else if (lines[i] ~ /^Filename: /) f = substr(lines[i], 11)
				else if (lines[i] ~ /^SHA256: /) s = substr(lines[i], 9)
				else if (lines[i] ~ /^Size: /) z = substr(lines[i], 7)
			}
			if (v != "" && f != "" && s != "")
				printf "%s\t%s\t%s\t%s\n", v, f, s, z
		}' | sort -V -k1,1 | tail -1)

	if [[ -z $newest ]]; then
		echo "Could not resolve claude-desktop from $index_url" >&2
		return 1
	fi

	IFS=$'\t' read -r resolved_official_version resolved_official_filename \
		resolved_official_sha256 resolved_official_size <<< "$newest"

	echo "Newest official $arch package: $resolved_official_version" \
		"($resolved_official_filename)"
}

# Extract one member family (data.tar.* or control.tar.*) of a Debian
# archive into a directory, without dpkg. Handles zst/xz/gz/uncompressed.
_extract_deb_member() {
	local deb_path="$1"
	local member_prefix="$2"
	local dest_dir="$3"
	local member tar_flag

	member=$(ar t "$deb_path" | grep "^${member_prefix}\.tar" | head -1)
	if [[ -z $member ]]; then
		echo "No ${member_prefix}.tar member in $deb_path" >&2
		return 1
	fi

	case "$member" in
		*.tar.zst)	tar_flag='--zstd' ;;
		*.tar.xz)	tar_flag='-J' ;;
		*.tar.gz)	tar_flag='-z' ;;
		*.tar)		tar_flag='' ;;
		*)
			echo "Unsupported compression on $member" >&2
			return 1
			;;
	esac

	mkdir -p "$dest_dir" || return 1
	# tar_flag is intentionally unquoted: empty for plain .tar, one
	# decompression flag otherwise.
	# shellcheck disable=SC2086
	ar p "$deb_path" "$member" | tar $tar_flag -x -C "$dest_dir"
}

# Read a single field from an extracted Debian control file. Multi-line
# fields (continuation lines) are not needed for the fields we read.
_control_field() {
	local control_path="$1"
	local field="$2"

	LC_ALL=C grep -oP "^${field}: \K.*" "$control_path"
}

# Download (or copy) the pinned official .deb, verify it, and extract it
# into work_dir/claude-extract. The app tree lands at
# claude-extract/usr/lib/claude-desktop; package metadata at
# claude-extract/DEBIAN-meta/control.
fetch_official_deb() {
	section_header 'Download the official Claude Desktop .deb'

	official_deb_pin || exit 1
	local claude_deb_path="$work_dir/$official_deb_filename"

	if [[ -n ${local_deb_path:-} ]]; then
		echo "Using local official .deb: $local_deb_path"
		if [[ ! -f $local_deb_path ]]; then
			echo "Local .deb file not found: $local_deb_path" >&2
			exit 1
		fi
		cp "$local_deb_path" "$claude_deb_path" || exit 1
		echo 'Local .deb copied to build directory'
	else
		echo "Downloading official Claude Desktop $OFFICIAL_DEB_VERSION" \
			"for $architecture..."
		if ! wget -q --show-progress -O "$claude_deb_path" \
			"$official_deb_url"; then
			echo "Failed to download $official_deb_url" >&2
			exit 1
		fi
		echo "Download complete: $official_deb_filename"

		if ! verify_sha256 "$claude_deb_path" "$official_deb_sha256" \
			'official Claude Desktop .deb'; then
			exit 1
		fi
	fi

	echo 'Extracting the official .deb...'
	claude_extract_dir="$work_dir/claude-extract"
	mkdir -p "$claude_extract_dir" || exit 1

	_extract_deb_member "$claude_deb_path" data "$claude_extract_dir" || {
		echo 'Failed to extract data archive from .deb' >&2
		exit 1
	}
	_extract_deb_member "$claude_deb_path" control \
		"$claude_extract_dir/DEBIAN-meta" || {
		echo 'Failed to extract control archive from .deb' >&2
		exit 1
	}

	local control_path="$claude_extract_dir/DEBIAN-meta/control"
	version=$(_control_field "$control_path" Version)
	if [[ -z $version ]]; then
		echo "Could not read Version from $control_path" >&2
		exit 1
	fi
	echo "Detected Claude version: $version"

	if [[ -z ${local_deb_path:-} && $version != "$OFFICIAL_DEB_VERSION" ]]; then
		echo "Warning: control Version ($version) differs from pinned" \
			"OFFICIAL_DEB_VERSION ($OFFICIAL_DEB_VERSION)" >&2
	fi

	# The dependency contract differs per arch (e.g. qemu-system-x86 vs
	# qemu-system-arm); packaging re-emits it verbatim rather than
	# hardcoding a copy.
	official_deb_depends=$(_control_field "$control_path" Depends)
	official_deb_recommends=$(_control_field "$control_path" Recommends)

	if [[ ! -d "$claude_extract_dir/usr/lib/claude-desktop" ]]; then
		echo 'Extracted tree missing usr/lib/claude-desktop —' \
			'upstream layout changed?' >&2
		exit 1
	fi

	# Extract wrapper version from release tag if provided
	# (e.g., v3.0.0+claude1.17377.2 -> 3.0.0; v3.0.0-rc1+claude1.17377.2
	# -> 3.0.0-rc1). Deb versions may contain hyphens; rpm.sh sanitizes
	# the RC suffix (hyphens -> dots) for the RPM Release field.
	if [[ -n ${release_tag:-} ]]; then
		local wrapper_version
		wrapper_version=$(echo "$release_tag" | \
			LC_ALL=C grep -oP \
				'^v\K[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?(?=\+claude)')
		if [[ -n $wrapper_version ]]; then
			version="${version}-${wrapper_version}"
			echo "Package version with wrapper suffix: $version"
		else
			echo 'Warning: Could not extract wrapper version from' \
				"release tag: $release_tag" >&2
		fi
	fi

	section_footer 'Download the official Claude Desktop .deb'
}
