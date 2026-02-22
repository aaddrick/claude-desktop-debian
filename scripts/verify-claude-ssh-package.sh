#!/usr/bin/env bash
set -euo pipefail

artifact_path="${1:?artifact path required}"
artifact_type="${2:?artifact type required (deb|rpm|appimage)}"

required_paths=(
	"node_modules/electron/dist/resources/claude-ssh/version.txt"
	"node_modules/electron/dist/resources/claude-ssh/claude-ssh-linux-amd64"
	"node_modules/electron/dist/resources/claude-ssh/claude-ssh-linux-arm64"
)

list_paths() {
	case "$artifact_type" in
		deb)
			dpkg-deb -c "$artifact_path" | awk '{print $6}' | sed 's#^./##'
			;;
		rpm)
			rpm -qpl "$artifact_path" | sed 's#^/usr/lib/claude-desktop/##'
			;;
		appimage)
			tmp_dir="$(mktemp -d)"
			(
				cd "$tmp_dir"
				"$artifact_path" --appimage-extract >/dev/null
				find squashfs-root/usr/lib/node_modules/electron/dist/resources \
					-type f | sed 's#^squashfs-root/usr/lib/##'
			)
			rm -rf "$tmp_dir"
			;;
		*)
			echo "Unsupported artifact type: $artifact_type" >&2
			exit 1
			;;
	esac
}

all_paths="$(list_paths)"
missing=0
for p in "${required_paths[@]}"; do
	if ! grep -qx "$p" <<< "$all_paths"; then
		echo "Missing required SSH asset: $p" >&2
		missing=1
	fi
done

if [[ $missing -ne 0 ]]; then
	exit 1
fi
