#===============================================================================
# Dependency installation and work-directory/Node/Electron bootstrap.
#
# Sourced by: build.sh
# Sourced globals:
#   build_format, distro_family, work_dir, app_staging_dir, project_root,
#   architecture
# Modifies globals:
#   chosen_electron_module_path, asar_exec (via setup_electron_asar);
#   PATH is exported (via setup_nodejs)
#===============================================================================

check_dependencies() {
	echo 'Checking dependencies...'
	local deps_to_install=''
	local common_deps='p7zip wget wrestool icotool convert'
	local all_deps="$common_deps"

	# Add format-specific dependencies
	case "$build_format" in
		deb) all_deps="$all_deps dpkg-deb" ;;
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# node-pty has a native C++ module compiled via node-gyp during
	# `npm install`. Without gcc/g++/make/python3 the install silently
	# emits a warning, leaves pty_src_dir empty, and the build ends up
	# shipping the upstream Windows binaries (the #401 failure mode).
	# Skip when --node-pty-dir is set (Nix and explicit overrides bring
	# their own pre-built node-pty).
	if [[ -z ${node_pty_dir:-} ]]; then
		all_deps="$all_deps gcc g++ make python3"
	fi

	# Command-to-package mappings per distro family
	declare -A debian_pkgs=(
		[p7zip]='p7zip-full' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='imagemagick'
		[dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
		[gcc]='build-essential' [g++]='build-essential'
		[make]='build-essential' [python3]='python3'
	)
	declare -A rpm_pkgs=(
		[p7zip]='p7zip p7zip-plugins' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='ImageMagick'
		[dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
		[gcc]='gcc' [g++]='gcc-c++'
		[make]='make' [python3]='python3'
	)

	local cmd pkg
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			case "$distro_family" in
				debian) pkg="${debian_pkgs[$cmd]}" ;;
				rpm)    pkg="${rpm_pkgs[$cmd]}" ;;
				*)
					echo "Warning: Cannot auto-install '$cmd' on unknown distro. Please install manually." >&2
					continue
					;;
			esac
			# Several commands map to the same package (gcc/g++/make
			# -> build-essential, wrestool/icotool -> icoutils). Skip
			# if the package is already queued so the log line stays
			# readable.
			case " $deps_to_install " in
				*" $pkg "*) ;;
				*) deps_to_install="$deps_to_install $pkg" ;;
			esac
		fi
	done

	if [[ -n $deps_to_install ]]; then
		echo "System dependencies needed:$deps_to_install"

		# Determine if we need sudo (skip if already root)
		local sudo_cmd='sudo'
		if (( EUID == 0 )); then
			sudo_cmd=''
			echo 'Installing as root (no sudo needed)...'
		else
			echo 'Attempting to install using sudo...'
			# Check if we can sudo without a password first
			if sudo -n true 2>/dev/null; then
				echo 'Passwordless sudo detected.'
			elif ! sudo -v; then
				echo 'Failed to validate sudo credentials. Please ensure you can run sudo.' >&2
				exit 1
			fi
		fi

		case "$distro_family" in
			debian)
				if ! $sudo_cmd apt update; then
					echo "Failed to run 'apt update'." >&2
					exit 1
				fi
				# shellcheck disable=SC2086
				if ! $sudo_cmd apt install -y $deps_to_install; then
					echo "Failed to install dependencies using 'apt install'." >&2
					exit 1
				fi
				;;
			rpm)
				# shellcheck disable=SC2086
				if ! $sudo_cmd dnf install -y $deps_to_install; then
					echo "Failed to install dependencies using 'dnf install'." >&2
					exit 1
				fi
				;;
			*)
				echo "Cannot auto-install dependencies on unknown distro." >&2
				echo "Please install these packages manually: $deps_to_install" >&2
				exit 1
				;;
		esac
		echo 'System dependencies installed successfully.'
	fi
}

setup_work_directory() {
	rm -rf "$work_dir"
	mkdir -p "$work_dir" || exit 1
	mkdir -p "$app_staging_dir" || exit 1
}

setup_nodejs() {
	section_header 'Node.js Setup'
	echo 'Checking Node.js version...'

	local node_version_ok=false
	if command -v node &> /dev/null; then
		local node_version node_major
		node_version=$(node --version | cut -d'v' -f2)
		node_major="${node_version%%.*}"
		echo "System Node.js version: v$node_version"

		if (( node_major >= 20 )); then
			echo "System Node.js version is adequate (v$node_version)"
			node_version_ok=true
		else
			echo "System Node.js version is too old (v$node_version). Need v20+"
		fi
	else
		echo 'Node.js not found in system'
	fi

	if [[ $node_version_ok == true ]]; then
		section_footer 'Node.js Setup'
		return 0
	fi

	# Node.js version inadequate - install locally
	echo 'Installing Node.js v20 locally in build directory...'

	local node_arch
	case "$architecture" in
		amd64) node_arch='x64' ;;
		arm64) node_arch='arm64' ;;
		*)
			echo "Unsupported architecture for Node.js: $architecture" >&2
			exit 1
			;;
	esac

	local node_version_to_install='20.18.1'
	local node_tarball="node-v${node_version_to_install}-linux-${node_arch}.tar.xz"
	local node_url="https://nodejs.org/dist/v${node_version_to_install}/${node_tarball}"
	local node_install_dir="$work_dir/node"

	echo "Downloading Node.js v${node_version_to_install} for ${node_arch}..."
	cd "$work_dir" || exit 1
	if ! wget -O "$node_tarball" "$node_url"; then
		echo "Failed to download Node.js from $node_url" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# Verify against official Node.js checksums
	local shasums_url node_expected_sha256
	shasums_url="https://nodejs.org/dist/v${node_version_to_install}/SHASUMS256.txt"
	node_expected_sha256=$(
		wget -qO- "$shasums_url" \
			| grep -F "$node_tarball" \
			| awk '{print $1}'
	) || true

	if ! verify_sha256 "$work_dir/$node_tarball" \
		"$node_expected_sha256" 'Node.js tarball'; then
		cd "$project_root" || exit 1
		exit 1
	fi

	echo 'Extracting Node.js...'
	if ! tar -xf "$node_tarball"; then
		echo 'Failed to extract Node.js tarball' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	mv "node-v${node_version_to_install}-linux-${node_arch}" "$node_install_dir" || exit 1
	export PATH="$node_install_dir/bin:$PATH"

	if command -v node &> /dev/null; then
		echo "Local Node.js installed successfully: $(node --version)"
	else
		echo 'Failed to install local Node.js' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	rm -f "$node_tarball"
	cd "$project_root" || exit 1
	section_footer 'Node.js Setup'
}

setup_electron_asar() {
	section_header 'Electron & Asar Handling'

	# Pin Electron to the exact version upstream Claude Desktop ships
	# (build-reference/app-extracted/package.json). The shipped app.asar
	# binds to specific V8/NAPI ABI, Chromium pairing, and node-pty
	# native surface — running a different Electron major against this
	# asar is unsupported. Bump when upstream bumps.
	local electron_version='41.5.0'

	echo "Ensuring local Electron and Asar installation in $work_dir..."
	cd "$work_dir" || exit 1

	if [[ ! -f package.json ]]; then
		echo "Creating temporary package.json in $work_dir for local install..."
		echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
	fi

	local electron_dist_path="$work_dir/node_modules/electron/dist"
	local asar_bin_path="$work_dir/node_modules/.bin/asar"
	local install_needed=false

	[[ ! -d $electron_dist_path ]] && echo 'Electron distribution not found.' && install_needed=true
	[[ ! -f $asar_bin_path ]] && echo 'Asar binary not found.' && install_needed=true

	if [[ $install_needed == true ]]; then
		echo "Installing electron@${electron_version} and Asar locally into $work_dir..."
		if ! npm install --no-save \
			"electron@${electron_version}" @electron/asar @electron/get extract-zip; then
			echo 'Failed to install Electron and/or Asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'Electron and Asar installation command finished.'

		# electron@42+ no longer ships a postinstall script that fetches
		# the prebuilt binary into dist/. If npm didn't populate it,
		# fetch the matching binary explicitly via @electron/get. See
		# #584. Retry once on transient CDN failures (503, network drops).
		#
		# Check for the binary itself (not just the dist/ directory),
		# because under Node 24 the extract-zip step in both the npm
		# postinstall (electron <42 path) and @electron/get can silently
		# no-op — leaving an empty dist/locales/ behind, which would pass
		# a bare `-d` check while no electron binary actually landed.
		if [[ ! -f $electron_dist_path/electron ]]; then
			echo 'Electron dist/electron missing; fetching binary explicitly...'
			local fetch_ok=false
			local fetch_attempts=0
			while ! node "$project_root/scripts/setup/fetch-electron-binary.js"; do
				fetch_attempts=$((fetch_attempts + 1))
				if (( fetch_attempts >= 2 )); then
					echo 'Failed to fetch Electron binary via @electron/get after 2 attempts.' >&2
					echo 'For air-gapped or mirrored builds set ELECTRON_MIRROR or ELECTRON_CUSTOM_DIR; see docs/building.md.' >&2
					break
				fi
				echo "Retrying Electron binary fetch (attempt $((fetch_attempts + 1))/2)..."
				sleep 2
			done
			if (( fetch_attempts < 2 )); then
				fetch_ok=true
			fi

			# Final fallback: even when @electron/get reports success,
			# extract-zip can leave dist/ empty under Node 24 (the
			# unzip stream resolves without writing files). If we still
			# have no binary, the cache zip was downloaded successfully
			# — unpack it with system `unzip`.
			if [[ ! -f $electron_dist_path/electron ]]; then
				if [[ $fetch_ok == false ]]; then
					echo 'Electron download failed; no cached zip to fall back on.' >&2
					cd "$project_root" || exit 1
					exit 1
				fi
				echo 'extract-zip path produced no binary; unpacking @electron/get cache with system unzip...'
				local electron_cache_dir="$HOME/.cache/electron"
				local electron_arch
				case $architecture in
					amd64) electron_arch='x64' ;;
					arm64) electron_arch='arm64' ;;
					*)     electron_arch='x64' ;;
				esac
				local cached_zip
				cached_zip=$(find "$electron_cache_dir" -name "electron-v${electron_version}-linux-${electron_arch}.zip" 2>/dev/null | head -1)
				if [[ -z $cached_zip ]]; then
					echo "No cached zip matching electron-v${electron_version}-linux-*.zip under $electron_cache_dir" >&2
					cd "$project_root" || exit 1
					exit 1
				fi
				if ! command -v unzip >/dev/null 2>&1; then
					echo "unzip not installed; cannot apply final fallback. Install unzip and retry, or upgrade extract-zip upstream." >&2
					cd "$project_root" || exit 1
					exit 1
				fi
				mkdir -p "$electron_dist_path"
				if ! unzip -oq "$cached_zip" -d "$electron_dist_path"; then
					echo 'unzip fallback failed.' >&2
					cd "$project_root" || exit 1
					exit 1
				fi
				printf 'v%s\n' "$electron_version" > "$electron_dist_path/version"
				printf 'electron\n' > "$work_dir/node_modules/electron/path.txt"
				echo "unzip fallback populated $electron_dist_path ($(du -sh "$electron_dist_path" | awk '{print $1}'))"
			fi
		fi
	else
		echo 'Local Electron distribution and Asar binary already present.'
	fi

	if [[ -f $electron_dist_path/electron ]]; then
		echo "Found Electron binary at $electron_dist_path."
		chosen_electron_module_path="$(realpath "$work_dir/node_modules/electron")"
		echo "Setting Electron module path for copying to $chosen_electron_module_path."
	else
		echo "Failed to find Electron distribution directory at '$electron_dist_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if [[ -f $asar_bin_path ]]; then
		asar_exec="$(realpath "$asar_bin_path")"
		echo "Found local Asar binary at $asar_exec."
	else
		echo "Failed to find Asar binary at '$asar_bin_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$project_root" || exit 1

	if [[ -z $chosen_electron_module_path || ! -d $chosen_electron_module_path ]]; then
		echo 'Critical error: Could not resolve a valid Electron module path to copy.' >&2
		exit 1
	fi

	echo "Using Electron module path: $chosen_electron_module_path"
	echo "Using asar executable: $asar_exec"
	section_footer 'Electron & Asar Handling'
}
