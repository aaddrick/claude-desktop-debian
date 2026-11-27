# shellcheck shell=bash
#===============================================================================
# Cowork firmware probe: add the edk2 and openSUSE layouts to the x86_64
# OVMF list so Cowork finds firmware on Arch/CachyOS, EL and openSUSE
# without root links.
#
# The official client resolves OVMF from exactly two absolute paths
# (/usr/share/OVMF/OVMF_CODE_4M.fd, /usr/share/OVMF/OVMF_CODE.fd), takes
# the first readable one, and derives the VARS template from it with
# .replace("OVMF_CODE","OVMF_VARS"). There is no env override. Arch
# installs edk2-ovmf under /usr/share/edk2/x64/, EL under
# /usr/share/edk2/ovmf/, and openSUSE's qemu-ovmf-x86_64 under
# /usr/share/qemu/ with its own names, so on those hosts firmwarePath
# stays null unless something links the files into /usr/share/OVMF
# (#884).
#
# The RPM's %post makes those links (#940), but the AppImage has no
# install step and the launcher can't write /usr/share without root,
# so an AppImage user on those distros gets nothing. Appending the
# CODE paths fixes every format in one place:
#
#   /usr/share/edk2/x64/OVMF_CODE.4m.fd   Arch, CachyOS, Manjaro
#   /usr/share/edk2/ovmf/OVMF_CODE.fd     RHEL, CentOS Stream, Alma,
#                                         Rocky 9/10. Fedora's edk2-ovmf
#                                         also ships /usr/share/OVMF/
#                                         OVMF_CODE.fd, so it resolves
#                                         unpatched.
#   /usr/share/qemu/ovmf-x86_64-4m-code.bin
#                                         openSUSE Leap, Tumbleweed and
#                                         the Micro variants
#
# The edk2 paths pair with the client's VARS derivation as shipped
# (OVMF_VARS.4m.fd and OVMF_VARS.fd sit beside them). openSUSE's VARS
# file is ovmf-x86_64-4m-vars.bin, which no OVMF_CODE swap reaches, so
# a second edit appends .replace("-code.bin","-vars.bin") to that
# derivation. No official or edk2 path contains "-code.bin", so the
# extra replace leaves their VARS paths alone. The official paths stay
# first, so a Debian-layout or %post-linked host resolves exactly as
# before. The aarch64 array is left alone.
#
# The edit lengthens the chunk, so V8 rejects the bundled
# compile-cache/*.jsc for it and compiles the patched source (V8 only
# reuses a cache whose source length matches; docs/learnings/nix.md).
#
# Sourced by: build.sh
# Sourced globals: (none — resolves its own files via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

patch_cowork_firmware_probe() {
	echo 'Patching Cowork firmware probe (edk2 and openSUSE layouts)...'

	if _patch_cowork_firmware_list && _patch_cowork_firmware_vars; then
		echo 'Cowork firmware probe patch applied'
	else
		echo 'ERROR: Cowork firmware probe patch failed. Without it,' \
			'Cowork finds no firmware on Arch/CachyOS, EL or openSUSE' \
			'AppImage installs (#884). Update the anchors in' \
			'scripts/patches/cowork-firmware-probe.sh against the new' \
			'bundle before shipping.' >&2
		return 1
	fi
	echo '##############################################################'
}

# Append the extra CODE paths to the x86_64 probe array.
_patch_cowork_firmware_list() {
	# Resolve on the x86_64 array itself; the same path strings also
	# sit in the chunk's compile cache, which is not a .js file.
	local index_js
	index_js=$(_resolve_anchor_file 'OVMF probe array' \
		'\[\s*[`"'"'"']/usr/share/OVMF/OVMF_CODE_4M\.fd[`"'"'"']\s*,\s*[`"'"'"']/usr/share/OVMF/OVMF_CODE\.fd[`"'"'"']') \
		|| return 1

	INDEX_JS="$index_js" node << 'FIRMWARE_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

const extra = [
    '/usr/share/edk2/x64/OVMF_CODE.4m.fd',
    '/usr/share/edk2/ovmf/OVMF_CODE.fd',
    '/usr/share/qemu/ovmf-x86_64-4m-code.bin',
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
        console.log('  OVMF probe array already carries the extra paths');
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
}

# Teach the VARS derivation openSUSE's -code.bin/-vars.bin pair.
_patch_cowork_firmware_vars() {
	local index_js
	index_js=$(_resolve_anchor_file 'OVMF VARS derivation' \
		'\.replace\(\s*[`"'"'"']OVMF_CODE[`"'"'"']\s*,\s*[`"'"'"']OVMF_VARS[`"'"'"']\s*\)\s*\.replace\(\s*[`"'"'"']AAVMF_CODE[`"'"'"']\s*,\s*[`"'"'"']AAVMF_VARS[`"'"'"']\s*\)') \
		|| return 1

	INDEX_JS="$index_js" node << 'FIRMWARE_VARS_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// Intent: .replace("OVMF_CODE","OVMF_VARS").replace("AAVMF_CODE","AAVMF_VARS")
// The optional tail group is our own replace, so a re-run can tell
// patched from pristine.
const Q = '([`"\'])';
const rep = (a, b) =>
    '\\.replace\\(\\s*\\1' + a + '\\1\\s*,\\s*\\1' + b + '\\1\\s*\\)';
const varsRe = new RegExp(
    '\\.replace\\(\\s*' + Q + 'OVMF_CODE\\1\\s*,\\s*\\1OVMF_VARS\\1\\s*\\)' +
    '\\s*' + rep('AAVMF_CODE', 'AAVMF_VARS') +
    '(\\s*' + rep('-code\\.bin', '-vars\\.bin') + ')?', 'g');
const matches = [...code.matchAll(varsRe)];
if (matches.length !== 1) {
    console.log('  WARNING: expected exactly 1 OVMF VARS derivation, ' +
        'found ' + matches.length);
    process.exit(1);
}

const m = matches[0];
if (m[2] !== undefined) {
    console.log('  OVMF VARS derivation already maps -code.bin');
    process.exit(0);
}

const q = m[1];
const replacement = m[0] + '.replace(' + q + '-code.bin' + q + ',' +
    q + '-vars.bin' + q + ')';
code = code.substring(0, m.index) + replacement +
    code.substring(m.index + m[0].length);
fs.writeFileSync(indexJs, code);
console.log('  OVMF VARS derivation: ' + replacement);
FIRMWARE_VARS_PATCH
}
