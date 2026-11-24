#!/usr/bin/env bats
#
# AppStream catalog for the APT/DNF repos (#708):
# scripts/repo/appstream-catalog.sh and the reprepro export hook
# scripts/repo/reprepro-dep11-hook.sh.
#
# The hook's contract is reprepro's: every path it writes to fd 3 is
# hashed into the signed Release, `.new` names are renamed into place.
# A path missing from fd 3 is a file APT will never fetch, so these
# tests pin the fd-3 listing exactly, not just the files on disk.
# (bats uses fd 3 itself; each hook run redirects it to a file.)
#
# End-to-end (compose -> reprepro -> apt/PackageKit client) needs
# reprepro, appstream-compose and a real package, so it is verified in
# containers rather than here; see the PR for the recipe.

setup() {
	repo_root="$BATS_TEST_DIRNAME/.."
	hook="$repo_root/scripts/repo/reprepro-dep11-hook.sh"
	ci="$repo_root/.github/workflows/ci.yml"
	# shellcheck source=scripts/repo/appstream-catalog.sh
	source "$repo_root/scripts/repo/appstream-catalog.sh"

	dist="$BATS_TEST_TMPDIR/dists/stable"
	staging="$BATS_TEST_TMPDIR/staging"
	listing="$BATS_TEST_TMPDIR/fd3"
	mkdir -p "$dist" "$staging"
	local f
	for f in Components.yml icons-48x48.tar icons-64x64.tar \
		icons-128x128.tar; do
		printf '%s\n' "$f" > "$staging/$f"
		printf '%s.gz\n' "$f" > "$staging/$f.gz"
	done
}

# Run the hook the way reprepro does for one binary Packages index.
# The local must not be called `status`: it would shadow the $status
# that `run` sets, and every `[[ $status -eq 0 ]]` would then pass on
# an empty string whatever the hook returned.
_run_hook() {
	local arch=$1 index_state=${2:-new}
	run bash "$hook" "$dist" "main/binary-$arch/Packages.new" \
		"main/binary-$arch/Packages" "$index_state" 3> "$listing"
}

@test "hook: amd64 export lists Components and every icon tarball" {
	DEP11_STAGING=$staging _run_hook amd64
	[[ $status -eq 0 ]]
	diff -u - "$listing" << 'EOF'
main/dep11/Components-amd64.yml.new
main/dep11/icons-48x48.tar.new
main/dep11/icons-64x64.tar.new
main/dep11/icons-128x128.tar.new
main/dep11/Components-amd64.yml.gz.new
main/dep11/icons-48x48.tar.gz.new
main/dep11/icons-64x64.tar.gz.new
main/dep11/icons-128x128.tar.gz.new
EOF
	cmp "$staging/Components.yml.gz" \
		"$dist/main/dep11/Components-amd64.yml.gz.new"
}

@test "hook: other arches list only their Components, not the icons" {
	# Icons are arch-independent; listing them per arch would put the
	# same path in the Release twice.
	DEP11_STAGING=$staging _run_hook arm64
	[[ $status -eq 0 ]]
	diff -u - "$listing" << 'EOF'
main/dep11/Components-arm64.yml.new
main/dep11/Components-arm64.yml.gz.new
EOF
}

@test "hook: lists the uncompressed form of every gzip it lists" {
	# APT verifies a .gz against its decompressed hash and treats a
	# target with no uncompressed entry as absent from the Release.
	DEP11_STAGING=$staging _run_hook amd64
	local line
	while read -r line; do
		[[ $line == *.gz.new ]] || continue
		grep -qxF "${line%.gz.new}.new" "$listing"
	done < "$listing"
}

@test "hook: without staging, re-lists the published catalog unchanged" {
	mkdir -p "$dist/main/dep11"
	touch "$dist/main/dep11/Components-amd64.yml" \
		"$dist/main/dep11/Components-amd64.yml.gz" \
		"$dist/main/dep11/icons-64x64.tar.gz"
	DEP11_STAGING='' _run_hook amd64 old
	[[ $status -eq 0 ]]
	diff -u - "$listing" << 'EOF'
main/dep11/Components-amd64.yml
main/dep11/Components-amd64.yml.gz
main/dep11/icons-64x64.tar.gz
EOF
	[[ -z $(find "$dist" -name '*.new') ]]
}

@test "hook: staging dir set but empty falls back to the published copy" {
	mkdir -p "$dist/main/dep11"
	touch "$dist/main/dep11/Components-amd64.yml.gz"
	DEP11_STAGING="$BATS_TEST_TMPDIR/missing" _run_hook amd64
	[[ $status -eq 0 ]]
	[[ $(cat "$listing") == 'main/dep11/Components-amd64.yml.gz' ]]
}

@test "hook: nothing staged or published lists nothing and succeeds" {
	DEP11_STAGING='' _run_hook amd64
	[[ $status -eq 0 ]]
	[[ ! -s $listing ]]
}

@test "hook: unwritable dep11 dir keeps the published catalog, exit 0" {
	# A catalog write failure must not fail the APT publish (review
	# note on #990): warn, then re-list what is already published.
	[[ $EUID -ne 0 ]] || skip 'root ignores directory permissions'
	mkdir -p "$dist/main/dep11"
	touch "$dist/main/dep11/Components-amd64.yml" \
		"$dist/main/dep11/Components-amd64.yml.gz"
	chmod a-w "$dist/main/dep11"
	DEP11_STAGING=$staging _run_hook amd64
	chmod u+w "$dist/main/dep11"
	[[ $status -eq 0 ]]
	[[ $output == *'keeping the published catalog'* ]]
	[[ $(cat "$listing") == $'main/dep11/Components-amd64.yml\nmain/dep11/Components-amd64.yml.gz' ]]
}

@test "hook: unwritable dist with nothing published lists nothing, exit 0" {
	[[ $EUID -ne 0 ]] || skip 'root ignores directory permissions'
	chmod a-w "$dist"
	DEP11_STAGING=$staging _run_hook amd64
	chmod u+w "$dist"
	[[ $status -eq 0 ]]
	[[ $output == *'keeping the published catalog'* ]]
	[[ ! -s $listing ]]
}

@test "hook: a copy failing midway leaves no .new files behind" {
	# Components copies fine, then an icon source can't be read: the
	# staged Components.new must be removed too, so the Release lists
	# the published set only, never a mix of new and old. The stale
	# icons .new stands in for a partial file the failed copy left: the
	# cleanup has to cover every name, not only the copies that worked.
	[[ $EUID -ne 0 ]] || skip 'root ignores file permissions'
	mkdir -p "$dist/main/dep11"
	touch "$dist/main/dep11/Components-amd64.yml" \
		"$dist/main/dep11/icons-64x64.tar.new"
	chmod a-r "$staging/icons-64x64.tar"
	DEP11_STAGING=$staging _run_hook amd64
	chmod u+r "$staging/icons-64x64.tar"
	[[ $status -eq 0 ]]
	[[ $output == *'keeping the published catalog'* ]]
	[[ -z $(find "$dist/main/dep11" -name '*.new') ]]
	[[ $(cat "$listing") == 'main/dep11/Components-amd64.yml' ]]
}

@test "hook: a directory at a .new target is a copy failure, not a listing" {
	# Without cp -T, cp copies into the directory and succeeds, the hook
	# lists the directory, and reprepro export fails (rc 235).
	mkdir -p "$dist/main/dep11/Components-amd64.yml.new"
	touch "$dist/main/dep11/Components-amd64.yml"
	DEP11_STAGING=$staging _run_hook amd64
	[[ $status -eq 0 ]]
	[[ $output == *'keeping the published catalog'* ]]
	[[ $(cat "$listing") == 'main/dep11/Components-amd64.yml' ]]
}

@test "hook: ignores indices that are not binary Packages" {
	run bash "$hook" "$dist" 'main/source/Sources.new' \
		'main/source/Sources' new 3> "$listing"
	[[ $status -eq 0 ]]
	[[ ! -s $listing ]]
}

@test "annotate: adds pkgname after the id and origin on the root" {
	local out
	out=$(appstream_annotate_catalog claude-desktop-unofficial test-origin \
		<< 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<components version="1.0">
  <component type="desktop-application">
    <id>io.github.example.app</id>
    <name>App</name>
  </component>
</components>
EOF
	)
	[[ $out == *'<components version="1.0" origin="test-origin">'* ]]
	[[ $out == *$'<id>io.github.example.app</id>\n    <pkgname>claude-desktop-unofficial</pkgname>\n    <name>'* ]]
}

@test "annotate: leaves an id inside other elements alone" {
	# Only a whole-line <id> is the component id; e.g. a <provides>
	# child on the same line as other markup must not gain a pkgname.
	local out
	out=$(printf '%s\n' '  <provides><id>x</id></provides>' \
		| appstream_annotate_catalog p o)
	[[ $out != *pkgname* ]]
}

@test "dep11 origin: added after Version when convert dropped it" {
	local yml="$BATS_TEST_TMPDIR/Components.yml"
	printf '%s\n' '---' 'File: DEP-11' 'Version: '"'1.0'" \
		'MediaBaseUrl: x' '---' 'Type: desktop-application' > "$yml"
	appstream_dep11_ensure_origin "$yml" test-origin
	[[ $(grep -c '^Origin: ' "$yml") -eq 1 ]]
	[[ $(sed -n 4p "$yml") == 'Origin: test-origin' ]]
}

@test "dep11 origin: kept single when convert already emitted it" {
	# appstream 1.0.2 (Ubuntu 24.04 runner) keeps the root origin, so an
	# unconditional insert produced a duplicate YAML key.
	local yml="$BATS_TEST_TMPDIR/Components.yml"
	printf '%s\n' '---' 'File: DEP-11' 'Version: '"'1.0'" \
		'Origin: test-origin' '---' 'Type: desktop-application' > "$yml"
	cp "$yml" "$BATS_TEST_TMPDIR/before.yml"
	appstream_dep11_ensure_origin "$yml" test-origin
	[[ $(grep -c '^Origin: ' "$yml") -eq 1 ]]
	cmp "$yml" "$BATS_TEST_TMPDIR/before.yml"
}

@test "ci: DEP-11 hook name in conf/distributions matches the script" {
	grep -qF 'DebIndices: Packages Release . .gz reprepro-dep11-hook.sh' "$ci"
	grep -qF 'conf/reprepro-dep11-hook.sh' "$ci"
	[[ -x $hook ]]
}

@test "ci: the reprepro step exports with DEP11_STAGING set" {
	# Without the env var the hook can only re-list old files, so a new
	# release would never refresh the catalog.
	awk '/- name: Add packages to repository/{f=1} f&&/DEP11_STAGING:/{print; exit}' \
		"$ci" | grep -q 'runner.temp }}/dep11'
}

@test "ci: catalog generation can never fail a release" {
	# The DEP-11 stage step is continue-on-error and the DNF inject is
	# wrapped in an if/else that only warns.
	awk '/- name: Stage DEP-11/{f=1} f&&/continue-on-error:/{print; exit}' \
		"$ci" | grep -q 'true'
	grep -qF 'AppStream compose failed for $arch; repodata published without it' "$ci"
}
