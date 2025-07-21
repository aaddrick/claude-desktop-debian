#!/bin/bash
set -euo pipefail

# Arguments from build.sh
VERSION="$1"
ARCH="$2"
WORK_DIR="$3"
APP_STAGING_DIR="$4"
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"

# RPM build environment
RPM_BUILD_ROOT="$WORK_DIR/rpmbuild"
SPEC_FILE="$RPM_BUILD_ROOT/SPECS/claude-desktop.spec"

# Create the directory structure rpmbuild needs
mkdir -p "$RPM_BUILD_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

echo "⚙️ Finding best available application icon..."
LARGEST_ICON_PATH=$(ls -1v "$WORK_DIR"/claude_*.png | tail -n 1)

if [ -z "$LARGEST_ICON_PATH" ] || [ ! -f "$LARGEST_ICON_PATH" ]; then
    echo "❌ No suitable .png icon files (claude_*.png) found in $WORK_DIR"
    exit 1
fi
echo "✓ Using icon: $(basename "$LARGEST_ICON_PATH")"

echo "⚙️ Generating .spec file for RPM build..."

cat > "$SPEC_FILE" << EOF
# --- Auto-generated spec file ---
Name:       $PACKAGE_NAME
Version:    $VERSION
Release:    1
Summary:    $DESCRIPTION
License:    Proprietary
URL:        https://claude.ai
Source0:    # No source tarball, we use files already in place
BuildArch:  $ARCH
Requires:   libX11-xcb, libxkbcommon, GConf2, nss, alsa-lib

%description
$DESCRIPTION
Unofficial Linux build.

%install
rm -rf %{buildroot}
# 1. Create the main application directory
mkdir -p %{buildroot}/opt/$PACKAGE_NAME

# 2. Copy the core Electron files (executable, locales, etc.) into it
cp -a "$APP_STAGING_DIR/node_modules/electron/dist/"* %{buildroot}/opt/$PACKAGE_NAME/

# 3. Rename the generic 'electron' executable to our app's name
mv %{buildroot}/opt/$PACKAGE_NAME/electron %{buildroot}/opt/$PACKAGE_NAME/$PACKAGE_NAME

# 4. Create the standard 'resources' directory that Electron expects
mkdir -p %{buildroot}/opt/$PACKAGE_NAME/resources

# 5. Move the actual Claude app code (app.asar) into the 'resources' directory
cp -a "$APP_STAGING_DIR/app.asar" %{buildroot}/opt/$PACKAGE_NAME/resources/
cp -a "$APP_STAGING_DIR/app.asar.unpacked" %{buildroot}/opt/$PACKAGE_NAME/resources/

# 6. Copy the language files into the 'resources' directory
cp "$WORK_DIR/claude-extract/lib/net45/resources/"*-*.json %{buildroot}/opt/$PACKAGE_NAME/resources/

# --- Create menu and icon entries ---
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
cp "$LARGEST_ICON_PATH" %{buildroot}/usr/share/icons/hicolor/512x512/apps/$PACKAGE_NAME.png

cat > %{buildroot}/usr/share/applications/$PACKAGE_NAME.desktop << DESKTOP_EOF
[Desktop Entry]
Name=Claude
Comment=$DESCRIPTION
Exec=/opt/$PACKAGE_NAME/$PACKAGE_NAME %u
Icon=$PACKAGE_NAME
Type=Application
Terminal=false
Categories=Office;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
DESKTOP_EOF

%files
/opt/$PACKAGE_NAME
/usr/share/applications/$PACKAGE_NAME.desktop
/usr/share/icons/hicolor/512x512/apps/$PACKAGE_NAME.png

%post
/bin/touch --no-create /usr/share/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database -q || :

%postun
if [ \$1 -eq 0 ] ; then
    /bin/touch --no-create /usr/share/icons/hicolor &>/dev/null || :
    /usr/bin/update-desktop-database -q || :
fi
EOF

echo "✅ Spec file created at $SPEC_FILE"
echo "📦 Building RPM package..."
rpmbuild -bb "$SPEC_FILE" --define "_topdir $RPM_BUILD_ROOT" --define "_rpmdir $WORK_DIR"
echo "✅ RPM build process finished."