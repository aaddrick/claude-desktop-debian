#===============================================================================
# Host detection and argument parsing: architecture, distro, requirements,
# CLI flag processing.
#
# Sourced by: build.sh
# Sourced globals: (none read on entry)
# Modifies globals:
#   architecture, claude_download_url, claude_exe_sha256, claude_exe_filename,
#   distro_family, original_user, original_home, project_root, work_dir,
#   app_staging_dir, build_format, cleanup_action, perform_cleanup,
#   test_flags_mode, local_exe_path, release_tag, source_dir, node_pty_dir
#===============================================================================

detect_architecture() {
	section_header 'Architecture Detection'
	echo 'Detecting system architecture...'

	local raw_arch
	raw_arch=$(uname -m) || {
		echo 'Failed to detect architecture' >&2
		exit 1
	}
	echo "Detected machine architecture: $raw_arch"

	case "$raw_arch" in
		x86_64)
			claude_download_url='https://downloads.claude.ai/releases/win32/x64/1.5354.0/Claude-9a9e3d5a4a368f0f49a80dc303b0ed1a18bfedad.exe'
			claude_exe_sha256='e619c7bd3b6746a7307ebefe509bfe447a143aed97e6c7f666677b36a6b6ba54'
			architecture='amd64'
			claude_exe_filename='Claude-Setup-x64.exe'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64)
			claude_download_url='https://downloads.claude.ai/releases/win32/arm64/1.5354.0/Claude-9a9e3d5a4a368f0f49a80dc303b0ed1a18bfedad.exe'
			claude_exe_sha256='bf7de5d6c012542feadf7d5caa77a72dfcea1b24512e9a6d28e004ba4ae2a11d'
			architecture='arm64'
			claude_exe_filename='Claude-Setup-arm64.exe'
			echo 'Configured for arm64 (aarch64) build.'
			;;
		*)
			echo "Unsupported architecture: $raw_arch. This script supports x86_64 (amd64) and aarch64 (arm64)." >&2
			exit 1
			;;
	esac

	echo "Target Architecture: $architecture"
	section_footer 'Architecture Detection'
}

detect_distro() {
	section_header 'Distribution Detection'
	echo 'Detecting Linux distribution family...'

	if [[ -f /etc/debian_version ]]; then
		distro_family='debian'
		echo "Detected Debian-based distribution"
		echo "  Debian version: $(cat /etc/debian_version)"
	elif [[ -f /etc/fedora-release ]]; then
		distro_family='rpm'
		echo "Detected Fedora"
		echo "  $(cat /etc/fedora-release)"
	elif [[ -f /etc/redhat-release ]]; then
		distro_family='rpm'
		echo "Detected Red Hat-based distribution"
		echo "  $(cat /etc/redhat-release)"
	elif [[ -f /etc/NIXOS ]]; then
		distro_family='nix'
		echo "Detected NixOS"
	else
		distro_family='unknown'
		echo "Warning: Could not detect distribution family"
		echo "  AppImage build will still work, but native packages (deb/rpm) may not"
	fi

	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	section_footer 'Distribution Detection'
}

check_system_requirements() {
	# Allow running as root in CI/container environments
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			echo 'This script should not be run using sudo or as the root user.' >&2
			echo 'It will use sudo when needed for specific actions (may prompt for password).' >&2
			echo 'Please run as a normal user.' >&2
			exit 1
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	if [[ -z $original_home ]]; then
		echo "Could not determine home directory for user $original_user." >&2
		exit 1
	fi
	echo "Running as user: $original_user (Home: $original_home)"

	# Check for NVM and source it if found
	if [[ -d $original_home/.nvm ]]; then
		echo "Found NVM installation for user $original_user, checking for Node.js 20+..."
		export NVM_DIR="$original_home/.nvm"
		if [[ -s $NVM_DIR/nvm.sh ]]; then
			# shellcheck disable=SC1091
			\. "$NVM_DIR/nvm.sh"
			local node_bin_path=''
			node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || \
				find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

			if [[ -n $node_bin_path && -d $node_bin_path ]]; then
				echo "Adding NVM Node bin path to PATH: $node_bin_path"
				export PATH="$node_bin_path:$PATH"
			else
				echo 'Warning: Could not determine NVM Node bin path.'
			fi
		else
			echo 'Warning: nvm.sh script not found or not sourceable.'
		fi
	fi

	echo 'System Information:'
	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	echo "Target Architecture: $architecture"
}

parse_arguments() {
	section_header 'Argument Parsing'

	project_root="$(pwd)"
	work_dir="$project_root/build"
	app_staging_dir="$work_dir/electron-app"

	# Set default build format based on detected distro
	case "$distro_family" in
		debian) build_format='deb' ;;
		rpm) build_format='rpm' ;;
		nix) build_format='nix' ;;
		*) build_format='appimage' ;;
	esac

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-s|--source-dir|--node-pty-dir)
				if [[ -z ${2:-} || $2 == -* ]]; then
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				case "$1" in
					-b|--build) build_format="$2" ;;
					-c|--clean) cleanup_action="$2" ;;
					-e|--exe) local_exe_path="$2" ;;
					-r|--release-tag) release_tag="$2" ;;
					-s|--source-dir) source_dir="$2" ;;
					--node-pty-dir) node_pty_dir="$2" ;;
				esac
				shift 2
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
			-h|--help)
				echo "Usage: $0 [--build deb|rpm|appimage|nix] [--clean yes|no] [--exe /path/to/installer.exe] [--source-dir /path] [--release-tag TAG] [--test-flags]"
				echo '  --build: Specify the build format (deb, rpm, appimage, or nix).'
				echo "           Default: auto-detected based on distro (current: $build_format)"
				echo '  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes'
				echo '  --exe:   Use a local Claude installer exe instead of downloading'
				echo '  --source-dir: Path to repo root for scripts/ and assets (default: project root)'
				echo '  --node-pty-dir: Path to pre-built node-pty package (skips npm install)'
				echo '  --release-tag: Release tag (e.g., v1.3.2+claude1.1.799) to append wrapper version to package'
				echo '  --test-flags: Parse flags, print results, and exit without building.'
				exit 0
				;;
			*)
				echo "Unknown option: $1" >&2
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# source_dir is where scripts/assets live (default: project_root)
	source_dir="${source_dir:-$project_root}"

	# Validate arguments
	build_format="${build_format,,}"
	cleanup_action="${cleanup_action,,}"

	if [[ ! -d $source_dir ]]; then
		echo "Error: --source-dir path does not exist: $source_dir" >&2
		exit 1
	fi
	if [[ -n $node_pty_dir && ! -d $node_pty_dir ]]; then
		echo "Error: --node-pty-dir path does not exist: $node_pty_dir" >&2
		exit 1
	fi

	if [[ $build_format != 'deb' && $build_format != 'rpm' && $build_format != 'appimage' && $build_format != 'nix' ]]; then
		echo "Invalid build format specified: '$build_format'. Must be 'deb', 'rpm', 'appimage', or 'nix'." >&2
		exit 1
	fi

	# Warn if building native package for wrong distro
	if [[ $build_format == 'deb' && $distro_family != 'debian' ]]; then
		echo "Warning: Building .deb package on non-Debian system ($distro_family). This may fail." >&2
	elif [[ $build_format == 'rpm' && $distro_family != 'rpm' ]]; then
		echo "Warning: Building .rpm package on non-RPM system ($distro_family). This may fail." >&2
	fi
	if [[ $cleanup_action != 'yes' && $cleanup_action != 'no' ]]; then
		echo "Invalid cleanup option specified: '$cleanup_action'. Must be 'yes' or 'no'." >&2
		exit 1
	fi

	echo "Selected build format: $build_format"
	echo "Cleanup intermediate files: $cleanup_action"

	[[ $cleanup_action == 'yes' ]] && perform_cleanup=true

	section_footer 'Argument Parsing'
}
