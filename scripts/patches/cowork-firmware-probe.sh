# shellcheck shell=bash
#===============================================================================
# Cowork firmware probe: add the edk2 layouts to the x86_64 OVMF list so
# Cowork finds firmware on Arch/CachyOS and EL without root links.
#
# The official client resolves OVMF from exactly two absolute paths
# (/usr/share/OVMF/OVMF_CODE_4M.fd, /usr/share/OVMF/OVMF_CODE.fd), takes
# the first readable one, and derives the VARS template from it with
# .replace("OVMF_CODE","OVMF_VARS"). There is no env override. Arch
# installs edk2-ovmf under /usr/share/edk2/x64/ and EL under
# /usr/share/edk2/ovmf/, so on those hosts firmwarePath stays null
# unless something links the files into /usr/share/OVMF (#884).
#
# The RPM's %post makes those links (#940), but the AppImage has no
# install step and the launcher can't write /usr/share without root,
# so an Arch or CachyOS AppImage user gets nothing. Appending the two
# edk2 CODE paths fixes every format in one place:
#
#   /usr/share/edk2/x64/OVMF_CODE.4m.fd   Arch, CachyOS, Manjaro
#   /usr/share/edk2/ovmf/OVMF_CODE.fd     RHEL, CentOS Stream, Alma,
#                                         Rocky 9/10. Fedora's edk2-ovmf
#                                         also ships /usr/share/OVMF/
#                                         OVMF_CODE.fd, so it resolves
#                                         unpatched.
#
# Both pair with the client's VARS derivation (OVMF_VARS.4m.fd and
# OVMF_VARS.fd ship beside them). The official paths stay first, so a
# Debian-layout or %post-linked host resolves exactly as before.
# openSUSE (ovmf-x86_64-4m-code.bin) is not added: its VARS name does
# not follow from the replace(), so it stays on the RPM's links. The
# aarch64 array is left alone.
#
# The edit lengthens the chunk, so V8 rejects the bundled
# compile-cache/*.jsc for it and compiles the patched source (V8 only
# reuses a cache whose source length matches; docs/learnings/nix.md).
#
# Sourced by: build.sh
# Sourced globals: (none — resolves its own file via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

patch_cowork_firmware_probe() {
	echo 'Patching Cowork firmware probe (edk2 layouts)...'

	# Resolve on the x86_64 array itself; the same path strings also
	# sit in the chunk's compile cache, which is not a .js file.
	local index_js
	index_js=$(_resolve_anchor_file 'OVMF probe array' \
		'\[\s*[`"'"'"']/usr/share/OVMF/OVMF_CODE_4M\.fd[`"'"'"']\s*,\s*[`"'"'"']/usr/share/OVMF/OVMF_CODE\.fd[`"'"'"']') \
		|| return 1

	if INDEX_JS="$index_js" node << 'FIRMWARE_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

const extra = [
    '/usr/share/edk2/x64/OVMF_CODE.4m.fd',
    '/usr/share/edk2/ovmf/OVMF_CODE.fd',
];

// The client's x86_64 probe array, whitespace-tolerant for beautified
// bundles, any delimiter (1.26832.0 used backticks, 2.42304.0 is back
// to double quotes):
//   ["/usr/share/OVMF/OVMF_CODE_4M.fd","/usr/share/OVMF/OVMF_CODE.fd"]
// The tail group captures any entries already appended, so a re-run
// can tell patched from pristine.
const Q = '([`"\'])';
const arrRe = new RegExp(
    '\\[\\s*' + Q + '\\/usr\\/share\\/OVMF\\/OVMF_CODE_4M\\.fd\\1\\s*,' +
    '\\s*\\1\\/usr\\/share\\/OVMF\\/OVMF_CODE\\.fd\\1' +
    '((?:\\s*,\\s*\\1[^`"\']*\\1)*)\\s*\\]', 'g');
const matches = [...code.matchAll(arrRe)];
if (matches.length !== 1) {
    console.log('  WARNING: expected exactly 1 OVMF probe-path array, ' +
        'found ' + matches.length);
    process.exit(1);
}

const m = matches[0];
const q = m[1];
const tail = m[2];
if (tail.trim() !== '') {
    const want = extra.map(p => ',' + q + p + q).join('');
    if (tail.replace(/\s+/g, '') === want) {
        console.log('  OVMF probe array already carries the edk2 paths');
        process.exit(0);
    }
    console.log('  WARNING: OVMF probe array has unexpected extra ' +
        'entries — upstream changed the list: ' + m[0]);
    process.exit(1);
}

const appended = extra.map(p => q + p + q).join(',');
const replacement = m[0].replace(/\s*\]$/, ',' + appended + ']');
code = code.substring(0, m.index) + replacement +
    code.substring(m.index + m[0].length);
fs.writeFileSync(indexJs, code);
console.log('  OVMF probe array: ' + replacement);
FIRMWARE_PATCH
	then
		echo 'Cowork firmware probe patch applied'
	else
		echo 'ERROR: Cowork firmware probe patch failed. Without it,' \
			'Cowork finds no firmware on Arch/CachyOS or EL' \
			'AppImage installs (#884). Update the anchor in' \
			'scripts/patches/cowork-firmware-probe.sh against the new' \
			'bundle before shipping.' >&2
		return 1
	fi
	echo '##############################################################'
}
