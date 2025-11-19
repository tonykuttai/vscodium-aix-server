#!/bin/bash
# modules/build-native-watchdog.sh
# Build native-watchdog module for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$BUILDDIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="native-watchdog"
MODULE_DIR="$BUILDDIR/nativewatchdog"
REPO_URL="https://github.com/microsoft/node-native-watchdog.git"

echo "Building $MODULE_NAME..."
echo "Build directory: $MODULE_DIR"

# Skip if already built
if [[ -f "$MODULE_DIR/.build-complete" ]]; then
    echo "$MODULE_NAME already built"
    exit 0
fi

# Create and enter build directory
mkdir -p "$MODULE_DIR"
cd "$MODULE_DIR"

# Clone repository if not exists
if [[ ! -d "node-native-watchdog" ]]; then
    echo "Cloning repository..."
    git clone "$REPO_URL"
fi

cd "node-native-watchdog"

# Configure and build
echo "Configuring with node-gyp..."
node-gyp configure

echo "Building..."
node-gyp build

# Verify build
NODE_FILE="build/Release/watchdog.node"
if [[ ! -f "$NODE_FILE" ]]; then
    echo "ERROR: Build output not found: $NODE_FILE"
    exit 1
fi

FILE_OUTPUT=$(file "$NODE_FILE")
EXPECTED_OUTPUT="64-bit XCOFF executable or object module not stripped"

if echo "$FILE_OUTPUT" | grep -qF "$EXPECTED_OUTPUT"; then
    echo "SUCCESS: $MODULE_NAME built and verified"
    touch "$MODULE_DIR/.build-complete"
    exit 0
else
    echo "ERROR: File verification failed"
    echo "Expected: $EXPECTED_OUTPUT"
    echo "Got: $FILE_OUTPUT"
    exit 1
fi