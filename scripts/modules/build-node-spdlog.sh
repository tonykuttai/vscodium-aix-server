#!/bin/bash
# modules/build-node-spdlog.sh
# Build node-spdlog module for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$BUILDDIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="node-spdlog"
MODULE_DIR="$BUILDDIR/nodespdlog"
REPO_URL="https://github.com/microsoft/node-spdlog.git"

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
if [[ ! -d "node-spdlog" ]]; then
    echo "Cloning repository..."
    git clone "$REPO_URL"
fi

cd "node-spdlog"

# Initialize submodules BEFORE npm install
echo "Initializing git submodules..."
git submodule update --init --recursive

# Install dependencies with terminal protection
echo "Installing node dependencies (and building native module)..."
export CXXFLAGS="-ftls-model=global-dynamic -fPIC -pthread"
export CFLAGS="-ftls-model=global-dynamic -fPIC -pthread"
export TERM=dumb
export LANG=C

set +e
# Redirect all output to log file
npm install --no-progress --no-audit --no-fund --loglevel=error > "$MODULE_DIR/npm-install.log" 2>&1
NPM_EXIT_CODE=$?
set -e

echo "npm install finished with code: $NPM_EXIT_CODE (Proceeding to verification)"

# Verify build
NODE_FILE="build/Release/spdlog.node"
if [[ ! -f "$NODE_FILE" ]]; then
    echo "ERROR: Build output not found: $NODE_FILE"
    echo "Check log file: $MODULE_DIR/npm-install.log"
    exit 1
fi

unset CFLAGS
unset CXXFLAGS

FILE_OUTPUT=$(file "$NODE_FILE")
EXPECTED_OUTPUT="64-bit XCOFF executable or object module"

if echo "$FILE_OUTPUT" | grep -qF "$EXPECTED_OUTPUT"; then
    echo "SUCCESS: $MODULE_NAME built and verified"
    touch "$MODULE_DIR/.build-complete"
    # Reset terminal to clean state
    printf "\033c"
    exit 0
else
    echo "ERROR: File verification failed"
    echo "Expected content: $EXPECTED_OUTPUT"
    echo "Got: $FILE_OUTPUT"
    printf "\033c"
    exit 1
fi