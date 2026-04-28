#!/usr/bin/env bash
# recolor-icon.sh — generate a tinted Claude Desktop icon for a side profile.
#
# Usage:
#   ./recolor-icon.sh <profile-N> [brightness] [saturation] [hue]
#
# Defaults: brightness=100, saturation=100, hue=100 (no change).
# ImageMagick's -modulate semantics: 100 = unchanged, 200 = +180° (hue) or
# +100% (b/s), 0 = the opposite extreme.
#
# Examples:
#   ./recolor-icon.sh 2 100 100 47      # purple/lavender (hue -95°)
#   ./recolor-icon.sh 3 100 100 167     # green           (hue +120°)
#   ./recolor-icon.sh 4 110 160 30      # boosted indigo  (perceptually purple)
#
# Output: 6 PNGs at standard hicolor sizes under
# ~/.local/share/icons/hicolor/<size>/apps/claude-desktop-<N>.png
#
# After running, refresh the icon cache:
#   gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor

profile="${1:?profile number required (e.g. 2, 3, 4)}"
brightness="${2:-100}"
saturation="${3:-100}"
hue="${4:-100}"

src_base='/usr/share/icons/hicolor'
dst_base="${HOME}/.local/share/icons/hicolor"
sizes=(16 24 32 48 64 256)

if ! command -v magick >/dev/null && ! command -v convert >/dev/null; then
	echo 'ImageMagick not found. Install it (e.g. `apt install imagemagick`).' >&2
	exit 1
fi

magick_cmd='magick'
command -v magick >/dev/null || magick_cmd='convert'

for size in "${sizes[@]}"; do
	src="${src_base}/${size}x${size}/apps/claude-desktop.png"
	dst_dir="${dst_base}/${size}x${size}/apps"
	dst="${dst_dir}/claude-desktop-${profile}.png"

	if [[ ! -f "$src" ]]; then
		echo "  [skip] ${size}x${size}: source not found ($src)"
		continue
	fi

	mkdir -p "$dst_dir"
	"$magick_cmd" "$src" \
		-modulate "${brightness},${saturation},${hue}" \
		"$dst"
	echo "  [ok] ${size}x${size} -> ${dst}"
done

echo
echo "Done. Refresh icon cache:"
echo "  gtk-update-icon-cache -f -t ${dst_base}"
