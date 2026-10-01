# shellcheck shell=bash
#===============================================================================
# virtiofsd resolution: un-gate the bundled fallback so Cowork's KVM
# stack resolves virtiofsd on every distro, not just Ubuntu 22.x.
#
# The official client resolves virtiofsd from exactly two absolute
# paths (/usr/libexec/virtiofsd, /usr/bin/virtiofsd) and only falls
# back to its own bundled copy (resources/virtiofsd) when
# /etc/os-release says ID=ubuntu with VERSION_ID 22.x. Arch installs
# virtiofsd at /usr/lib/virtiofsd, Debian at /usr/lib/qemu/virtiofsd,
# and Ubuntu derivatives (ID=pop, ID=linuxmint) fail the os-release
# check — on all of them virtiofsdPath resolves null and the support
# evaluator reports "Cowork requires QEMU" with everything installed
# (#771, #772; filed upstream, docs/upstream-reports/).
#
# The minimal fix is to drop the os-release condition on the bundled
# fallback: system paths stay preferred, and the version-matched
# binary Anthropic already ships covers everyone else. The probe
# array is deliberately NOT extended with the Arch/Debian paths —
# on qemu <8 hosts /usr/lib/qemu/virtiofsd can be the legacy C
# implementation, whose CLI is incompatible with how the client
# spawns the Rust virtiofsd (the likely reason upstream gates the
# list this tightly).
#
# Sourced by: build.sh
# Sourced globals: (none — resolves its own file via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

patch_virtiofsd_probe() {
	echo 'Patching virtiofsd resolution (bundled fallback un-gate)...'

	# Resolve on the probe-path array itself: `virtiofsd` alone also
	# appears in a second 1.26832.0 chunk that has no array to rewrite.
	local index_js
	index_js=$(_resolve_anchor_file 'virtiofsd probe array' \
		'\[\s*[`"'"'"']/usr/libexec/virtiofsd[`"'"'"']\s*,\s*[`"'"'"']/usr/bin/virtiofsd[`"'"'"']\s*\]') \
		|| return 1

	# Anchored on the probe-path array literal (path strings survive
	# minification); the gate rewrite happens in a bounded window after
	# it so the shape-matched expression can't hit an unrelated site.
	# Unlike the survivor cosmetic patches, an anchor miss here fails
	# the build: shipping without this patch silently re-opens #771.
	if INDEX_JS="$index_js" node << 'VIRTIOFSD_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');

// q(): match a literal under any delimiter. 1.26832.0 swapped the
// minifier and re-emitted nearly every string as a backtick template, so
// a bare " here matches nothing (#820).
const q = s => '[`"\']' + s + '[`"\']';

// The client's virtiofsd probe-path array, whitespace-tolerant for
// beautified bundles:
//   [`/usr/libexec/virtiofsd`,`/usr/bin/virtiofsd`]
const arrRe = new RegExp(
    '\\[\\s*' + q('\\/usr\\/libexec\\/virtiofsd') + '\\s*,\\s*' +
    q('\\/usr\\/bin\\/virtiofsd') + '\\s*\\]', 'g');
const arrMatches = [...code.matchAll(arrRe)];
if (arrMatches.length !== 1) {
    console.log('  WARNING: expected exactly 1 virtiofsd probe-path ' +
        'array, found ' + arrMatches.length);
    process.exit(1);
}

// Window after the array: the Ubuntu-detect helper sits between the
// array and the resolver (~230 chars minified, ~400 beautified).
const start = arrMatches[0].index + arrMatches[0][0].length;
const region = code.substring(start, start + 1200);

// Gated resolver tail (minified):
//   1.24012.11: return e||(A?d3A(igi,bA.constants.X_OK):null)
//   1.26832.0:  return await FT(kT)||(e?IT(TT,N.constants.X_OK):null)
// The left operand is the system-path hit. It used to be a bare
// identifier holding an already-awaited result; 1.26832.0 inlined the
// call, so it is now an `await F(x)` expression. Accept either shape --
// anything else here would be a different code path, not a re-minified
// one. The middle operand is "is Ubuntu 22.x" and the captured call is
// the bundled copy at process.resourcesPath. Identifiers are captured,
// not hardcoded, since they change every release.
const lhs = String.raw`(await\s+[\w$]+\(\s*[\w$]*\s*\)|[\w$]+)`;
const bundled =
    String.raw`([\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\))`;
const gatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*\\(\\s*[\\w$]+\\s*\\?\\s*` +
    `${bundled}\\s*:\\s*null\\s*\\)`);
// Already-ungated form, for idempotency (re-run, or upstream fix):
const ungatedRe = new RegExp(
    `return\\s+${lhs}\\s*\\|\\|\\s*` +
    String.raw`[\w$]+\(\s*[\w$]+\s*,\s*[\w$]+\.constants\.X_OK\s*\)`);

const gated = region.match(gatedRe);
if (gated) {
    const abs = start + gated.index;
    const replacement = 'return ' + gated[1] + '||' + gated[2];
    code = code.substring(0, abs) + replacement +
        code.substring(abs + gated[0].length);
    fs.writeFileSync(indexJs, code);
    console.log('  Un-gated bundled virtiofsd fallback: ' + gated[2]);
} else if (ungatedRe.test(region)) {
    console.log('  Bundled virtiofsd fallback already un-gated');
} else {
    console.log('  WARNING: bundled-fallback gate not found near the ' +
        'probe array — upstream reshaped the resolver');
    process.exit(1);
}
VIRTIOFSD_PATCH
	then
		echo 'virtiofsd probe patch applied'
	else
		echo 'ERROR: virtiofsd probe patch failed. Without it, Cowork' \
			'reports "requires QEMU" on Arch/Debian/Ubuntu-derivative' \
			'hosts with a complete KVM stack (#771, #772). Update the' \
			'anchors in scripts/patches/virtiofsd-probe.sh against the' \
			'new bundle before shipping.' >&2
		return 1
	fi
	echo '##############################################################'
}
