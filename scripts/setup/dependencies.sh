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

	# Command-to-package mappings per distro family
	declare -A debian_pkgs=(
		[p7zip]='p7zip-full' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='imagemagick'
		[dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
	)
	declare -A rpm_pkgs=(
		[p7zip]='p7zip p7zip-plugins' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='ImageMagick'
		[dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
	)

	local cmd
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			case "$distro_family" in
				debian)
					deps_to_install="$deps_to_install ${debian_pkgs[$cmd]}"
					;;
				rpm)
					deps_to_install="$deps_to_install ${rpm_pkgs[$cmd]}"
					;;
				*)
					echo "Warning: Cannot auto-install '$cmd' on unknown distro. Please install manually." >&2
					;;
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
		echo "Installing Electron and Asar locally into $work_dir..."
		# Pin to electron 41.x: electron@42.0.0 (2026-05-06) dropped the
		# postinstall that fetches the prebuilt binary into dist/, leaving
		# node_modules/electron/dist absent and the build aborting (#584).
		# A durable fix using @electron/get is tracked separately.
		if ! npm install --no-save 'electron@^41' @electron/asar; then
			echo 'Failed to install Electron and/or Asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'Electron and Asar installation command finished.'
	else
		echo 'Local Electron distribution and Asar binary already present.'
	fi

	if [[ -d $electron_dist_path ]]; then
		echo "Found Electron distribution directory at $electron_dist_path."
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
