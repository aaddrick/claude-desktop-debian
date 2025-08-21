#!/bin/bash
# Install dependencies for Claude Desktop Fedora build

echo "Installing build dependencies for Claude Desktop..."

# Install missing packages
sudo dnf install -y \
    p7zip \
    p7zip-plugins \
    rpm-build \
    npm \
    wget \
    icoutils \
    ImageMagick \
    nodejs

echo "SUCCESS: Dependencies installed!"
echo ""
echo "You can now run:"
echo "  ./build-fedora.sh --build rpm     # Build RPM package"
echo "  ./build-fedora.sh --build appimage # Build AppImage"