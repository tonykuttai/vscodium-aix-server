#!/bin/bash
# scripts/package-existing.sh - Updated version


# This is only for packaging the working vscodium server
WORKING_DIR="$HOME/.vscodium-server/bin/9e6954323e23e2f62c1ea78348dbd1b53e5b827e"
VERSION="1.102.24914"
PACKAGE_NAME="vscodium-reh-aix-ppc64-${VERSION}"

echo "Packaging your working VSCodium server..."

# Create package directory
mkdir -p "releases/$PACKAGE_NAME"

# Copy your working server
cp -r "$WORKING_DIR"/* "releases/$PACKAGE_NAME/"

# Create tarball
cd releases
tar -czf "${PACKAGE_NAME}.tar.gz" "$PACKAGE_NAME"

echo " Package created: releases/${PACKAGE_NAME}.tar.gz"
echo " Size: $(du -h "${PACKAGE_NAME}.tar.gz" | cut -f1)"
echo ""
echo " Next steps:"
echo "1. Go to: https://github.ibm.com/tony-varghese/vscodium-aix-server/releases"
echo "2. Click 'Create a new release'"
echo "3. Upload: ${PACKAGE_NAME}.tar.gz"
echo "4. Use tag: v${VERSION}"