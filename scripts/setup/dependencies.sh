#===============================================================================
# Dependency installation and work-directory/Node/asar bootstrap.
#
# Sourced by: build.sh
# Sourced globals:
#   build_format, distro_family, work_dir, project_root
# Modifies globals:
#   asar_exec (via setup_asar); PATH is exported (via setup_nodejs)
#===============================================================================

check_dependencies() {
	echo 'Checking dependencies...'
	local deps_to_install=''
	# ar (binutils) plus tar with xz/zstd support unpack the official
	# .deb without dpkg, so rpm-family and Arch hosts can build too.
	local all_deps='wget ar tar xz zstd'

	# Add format-specific dependencies
	case "$build_format" in
		deb) all_deps="$all_deps dpkg-deb" ;;
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# Command-to-package mappings per distro family
	declare -A debian_pkgs=(
		[wget]='wget' [ar]='binutils' [tar]='tar'
		[xz]='xz-utils' [zstd]='zstd'
		[dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
	)
	declare -A rpm_pkgs=(
		[wget]='wget' [ar]='binutils' [tar]='tar'
		[xz]='xz' [zstd]='zstd'
		[dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
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
			# Several commands can map to the same package. Skip if the
			# package is already queued so the log line stays readable.
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

	# Node is build-host tooling: it runs asar here and never ships in
	# the package, so it is keyed to uname -m, NOT to $architecture —
	# which --arch can override to the cross-build target (an arm64
	# node on an amd64 runner dies with an exec-format error).
	local node_arch host_arch
	host_arch=$(uname -m)
	case "$host_arch" in
		x86_64)  node_arch='x64' ;;
		aarch64) node_arch='arm64' ;;
		*)
			echo "Unsupported host architecture for Node.js: $host_arch" >&2
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

setup_asar() {
	section_header 'Asar Tooling'

	# @electron/asar is only needed while at least one asar patch is
	# active (see active_patches in scripts/patches/app-asar.sh);
	# patch_app_asar also uses it to read package.json fields without a
	# full extract. No Electron install: the official tree ships its own
	# runtime, so the old pinned-Electron staging is gone.
	echo "Ensuring local asar installation in $work_dir..."
	cd "$work_dir" || exit 1

	if [[ ! -f package.json ]]; then
		echo "Creating temporary package.json in $work_dir for local install..."
		echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
	fi

	local asar_bin_path="$work_dir/node_modules/.bin/asar"

	if [[ ! -f $asar_bin_path ]]; then
		echo "Installing @electron/asar locally into $work_dir..."
		if ! npm install --no-save @electron/asar; then
			echo 'Failed to install @electron/asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
	else
		echo 'Local asar binary already present.'
	fi

	if [[ -f $asar_bin_path ]]; then
		asar_exec="$(realpath "$asar_bin_path")"
		echo "Using asar executable: $asar_exec"
	else
		echo "Failed to find asar binary at '$asar_bin_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$project_root" || exit 1
	section_footer 'Asar Tooling'
}
