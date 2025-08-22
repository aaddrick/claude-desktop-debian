#!/bin/bash
set -euo pipefail

# Security function: validate package names against whitelist
validate_package_name() {
    local package="$1"
    # Whitelist of allowed packages for this installation script
    local allowed_packages=(
        "p7zip" "p7zip-plugins" "rpm-build" "npm" "wget"
        "icoutils" "ImageMagick" "nodejs" "git" "curl"
    )
    
    for allowed in "${allowed_packages[@]}"; do
        if [[ "$package" == "$allowed" ]]; then
            return 0
        fi
    done
    
    echo "ERROR: Package '$package' is not in the allowed whitelist"
    return 1
}

# Security function: sanitize string for safe logging
sanitize_for_logging() {
    local input="$1"
    # Remove or escape potentially dangerous characters
    echo "$input" | sed 's/[^a-zA-Z0-9._/-]/***/g'
}

# Check if running as root (security risk)
if [ "$EUID" -eq 0 ]; then
    echo "WARNING: Running as root. This script should be run as a regular user."
    echo "WARNING: The script will use sudo when necessary."
fi

echo "Installing build dependencies for Claude Desktop..."

# Define packages to install
PACKAGES_TO_INSTALL=(
    "p7zip"
    "p7zip-plugins"
    "rpm-build"
    "npm"
    "wget"
    "icoutils"
    "ImageMagick"
    "nodejs"
)

# Validate all packages before installation
echo "Validating package names against security whitelist..."
for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
    if ! validate_package_name "$pkg"; then
        echo "ERROR: Security check failed - invalid package name: $pkg"
        exit 1
    fi
done

echo "All packages validated successfully."

# Check sudo access
if ! sudo -v; then
    echo "ERROR: This script requires sudo access to install packages."
    exit 1
fi

# Install missing packages individually to prevent injection attacks
echo "Installing packages individually for security..."
for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
    echo "Installing $(sanitize_for_logging "$pkg")..."
    if ! sudo dnf install -y "$pkg"; then
        echo "ERROR: Failed to install package: $(sanitize_for_logging "$pkg")"
        exit 1
    fi
done

echo "SUCCESS: Dependencies installed!"
echo ""
echo "You can now run:"
echo "  ./build-fedora.sh --build rpm     # Build RPM package"
echo "  ./build-fedora.sh --build appimage # Build AppImage"