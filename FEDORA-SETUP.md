# Fedora Fork Setup Guide

This document provides comprehensive instructions for setting up the Claude Desktop Fedora fork with automated builds and releases.

## Repository Configuration

### Required Secrets

The following secrets must be configured in your GitHub repository (`Settings > Secrets and variables > Actions`):

#### Essential Secrets

1. **`GH_PAT`** (Personal Access Token)
   - **Required for**: Version monitoring, automated releases, variable updates
   - **Scopes needed**: `repo`, `workflow`
   - **How to create**:
     1. Go to GitHub Settings > Developer settings > Personal access tokens > Tokens (classic)
     2. Click "Generate new token (classic)"
     3. Select scopes: `repo` (full control) and `workflow`
     4. Copy the token and add it as `GH_PAT` secret in your repository

### Required Variables

Configure these in `Settings > Secrets and variables > Actions > Variables`:

1. **`REPO_VERSION`**
   - **Purpose**: Base version number for your fork
   - **Suggested value**: `1.0.0` (increment when you make significant changes)
   - **Usage**: Combined with Claude version to create release tags

2. **`CLAUDE_DESKTOP_VERSION`**
   - **Purpose**: Tracks the latest Claude Desktop version that was built
   - **Initial value**: Leave empty (will be set automatically by the version check workflow)
   - **Usage**: Prevents duplicate builds when Claude version hasn't changed

## Workflow Overview

### 1. Main CI Workflow (`ci-fedora.yml`)
- **Triggers**: Push to main/dev, PRs, manual dispatch, version tags
- **Purpose**: Orchestrates builds for both architectures and package formats
- **Outputs**: RPM and AppImage packages for amd64/arm64

### 2. Version Monitoring (`check-claude-version-fedora.yml`)
- **Triggers**: Daily at 1 AM UTC, manual dispatch
- **Purpose**: Automatically detects new Claude Desktop releases
- **Actions**: Creates new release tags and GitHub releases when updates are found

### 3. Architecture-Specific Builds
- **`build-amd64-fedora.yml`**: Builds packages on standard GitHub runners
- **`build-arm64-fedora.yml`**: Uses Docker with ARM64 emulation for cross-compilation
- **Both support**: RPM and AppImage output formats

### 4. Quality Assurance
- **`test-flags-fedora.yml`**: Tests build script argument parsing
- **`shellcheck.yml`**: Shell script linting (inherited from original)
- **`codespell.yml`**: Spelling check (inherited from original)

## Package Formats

### RPM Packages
- **Target systems**: Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux, openSUSE
- **Installation**: `sudo dnf install ./claude-desktop-*.rpm`
- **Dependencies**: Automatically managed by RPM
- **Architecture**: `x86_64` (amd64) and `aarch64` (arm64)

### AppImage Packages
- **Target systems**: Universal Linux compatibility
- **Installation**: Make executable and run, or integrate with Gear Lever
- **Dependencies**: Self-contained (includes Electron)
- **Updates**: Automatic via GitHub releases (when integrated with Gear Lever)

## Local Development

### Building Locally

1. **Clone the repository**:
   ```bash
   git clone https://github.com/Frost26/Claude-Linux-Desktop.git
   cd Claude-Linux-Desktop
   ```

2. **Install dependencies** (Fedora/RHEL):
   ```bash
   sudo dnf install rpm-build p7zip p7zip-plugins wget icoutils ImageMagick nodejs npm
   ```

3. **Build RPM package**:
   ```bash
   chmod +x build-fedora.sh
   ./build-fedora.sh --build rpm
   ```

4. **Build AppImage**:
   ```bash
   ./build-fedora.sh --build appimage
   ```

### Testing Workflows Locally

1. **Test flag parsing**:
   ```bash
   ./build-fedora.sh --test-flags
   ```

2. **Test different build options**:
   ```bash
   ./build-fedora.sh --build rpm --clean no
   ./build-fedora.sh --build appimage --clean yes
   ```

## Release Process

### Automatic Releases
1. The version check workflow runs daily and detects new Claude Desktop versions
2. When a new version is found:
   - Repository variables are updated
   - A new tag is created (format: `v{REPO_VERSION}+claude{CLAUDE_VERSION}-fedora`)
   - CI workflows are triggered to build packages
   - A GitHub release is created with all built packages

### Manual Releases
1. **Create a version tag**:
   ```bash
   git tag -a v1.0.0+claude0.12.112-fedora -m "Manual release"
   git push origin v1.0.0+claude0.12.112-fedora
   ```

2. **Trigger workflows**: Tag push automatically triggers CI workflows

## Troubleshooting

### Common Issues

1. **"GH_PAT secret is not configured"**
   - Solution: Create and configure Personal Access Token as described above

2. **RPM build fails on ARM64**
   - Solution: Check Docker setup in `build-arm64-fedora.yml`
   - Alternative: Consider using self-hosted ARM64 runners

3. **Missing dependencies during build**
   - Solution: Update dependency lists in workflow files
   - For RPM builds: Update `build-amd64-fedora.yml` and `build-arm64-fedora.yml`

4. **AppImage update information not working**
   - Ensure repository name matches exactly in `scripts/build-appimage.sh`
   - Update URLs point to correct repository: `Frost26/Claude-Linux-Desktop`

### Build Logs
- Check GitHub Actions tab for detailed build logs
- Local builds log to `~/claude-desktop-launcher.log`

## Customization

### Changing Package Names
1. Update `PACKAGE_NAME` in `build-fedora.sh`
2. Update artifact names in workflow files
3. Update desktop entry files

### Modifying Build Options
1. Edit `build-fedora.sh` for build logic changes
2. Update `scripts/build-rpm-package.sh` for RPM-specific changes
3. Modify workflow matrices in `ci-fedora.yml` for different build combinations

### Adding New Distributions
1. Update dependency installation logic in `build-fedora.sh`
2. Add new package manager support (zypper, pacman, etc.)
3. Test on target distributions

## Maintenance

### Regular Tasks
1. **Monitor Claude Desktop releases**: Automatic via version check workflow
2. **Update dependencies**: Periodically review and update package dependencies
3. **Test on new Fedora versions**: When new Fedora releases are available
4. **Security updates**: Keep build environment and dependencies updated

### Version Management
- **REPO_VERSION**: Increment when making significant changes to the packaging or scripts
- **Claude versions**: Automatically tracked and updated
- **Tag format**: Maintains clear relationship between fork version and Claude version

## Support

### Getting Help
1. **Check existing issues**: Look for similar problems in the repository issues
2. **Create new issue**: Provide build logs and system information
3. **Discussions**: Use GitHub Discussions for questions and feature requests

### Contributing
1. **Fork the repository**: Create your own fork for development
2. **Test thoroughly**: Test on multiple Fedora/RHEL versions
3. **Submit pull requests**: Include detailed description of changes
4. **Follow conventions**: Match existing code style and documentation format