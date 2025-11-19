#!/bin/bash
# modules/build-node-pty.sh
# Build node-pty module for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$BUILDDIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="node-pty"
MODULE_DIR="$BUILDDIR/nodepty"
PORTLIB_URL="https://github.com/tonykuttai/portlibforaix.git"
NODEPTY_URL="https://github.com/tonykuttai/node-pty.git"
PORTLIB_INSTALL="$HOME/local/portlibforaix"

echo "Building $MODULE_NAME..."
echo "Build directory: $MODULE_DIR"

# Skip if already built
if [[ -f "$MODULE_DIR/.build-complete" ]]; then
    echo "$MODULE_NAME already built"
    exit 0
fi

# Get Node.js version
NODE_VERSION=$(node -p "process.versions.node")
echo "Node.js version: $NODE_VERSION"

# Create and enter build directory
mkdir -p "$MODULE_DIR"
cd "$MODULE_DIR"

# Build portlibforaix if not installed
if [[ ! -f "$PORTLIB_INSTALL/lib/libutil.so.2" ]]; then
    echo "Building portlibforaix dependency..."
    
    if [[ ! -d "portlibforaix" ]]; then
        git clone "$PORTLIB_URL" portlibforaix
    fi
    
    cd portlibforaix
    mkdir -p "$PORTLIB_INSTALL/lib"
    mkdir -p "$PORTLIB_INSTALL/include"
    
    make
    make install
    
    cd "$MODULE_DIR"
    echo "portlibforaix built successfully"
else
    echo "portlibforaix already installed"
fi

# Clone node-pty if not exists
if [[ ! -d "node-pty" ]]; then
    echo "Cloning node-pty..."
    git clone "$NODEPTY_URL" node-pty
fi

cd "node-pty"

# Install dependencies
echo "Installing node dependencies..."
set +e
# Redirect all output to log file
npm install --no-progress --no-audit --no-fund --loglevel=error > "$MODULE_DIR/npm-install.log" 2>&1
NPM_EXIT_CODE=$?
set -e
echo "npm install finished with code: $NPM_EXIT_CODE (Proceeding to verification)"

# Create build directory
mkdir -p build/Release

# Compile
echo "Compiling source..."
g++ -o build/Release/pty.o -c src/unix/pty.cc \
  -I/opt/nodejs/include/node \
  -I$HOME/.cache/node-gyp/${NODE_VERSION}/include/node \
  -I./node_modules/node-addon-api \
  -I/opt/freeware/include \
  -std=gnu++17 -D_GLIBCXX_USE_CXX11_ABI=0 \
  -fPIC -pthread -Wall -Wextra -Wno-unused-parameter \
  -maix64 -O3 -fno-omit-frame-pointer

# Link
echo "Linking shared library..."
g++ -shared -maix64 \
  -Wl,-bimport:/opt/nodejs/include/node/node.exp \
  -pthread \
  -o build/Release/pty.node \
  build/Release/pty.o \
  -L$PORTLIB_INSTALL/lib \
  $PORTLIB_INSTALL/lib/libutil.so.2 \
  -lpthread \
  -lstdc++

# Test module
echo "Testing module..."
node -e "
try {
  const pty = require('./build/Release/pty.node');
  console.log('OK Module test passed!');
  process.exit(0);
} catch (error) {
  console.error('X Module test failed:', error.message);
  process.exit(1);
}"

if [[ $? -eq 0 ]]; then
    echo "SUCCESS: $MODULE_NAME built and tested"
    touch "$MODULE_DIR/.build-complete"
    exit 0
else
    echo "ERROR: Module test failed"
    exit 1
fi