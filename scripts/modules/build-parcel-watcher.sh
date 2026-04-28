#!/bin/bash
# modules/build-parcel-watcher.sh
# Build @parcel/watcher module for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$BUILDDIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="parcel-watcher"
MODULE_DIR="$BUILDDIR/parcelwatcher"
REPO_URL="https://github.com/parcel-bundler/watcher.git"

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
if [[ ! -d "watcher" ]]; then
    echo "Cloning repository..."
    git clone "$REPO_URL"
fi

cd "watcher"

# Apply AIX patches to binding.gyp
echo "Applying AIX patches to binding.gyp..."

# Check if AIX condition already exists
if ! grep -q "OS==\"aix\"" binding.gyp; then
    echo "Adding AIX configuration to binding.gyp..."
    
    # Create a temporary Python script to properly insert the AIX block
    cat > /tmp/patch_binding.py << 'PYPATCH'
import json
import re

with open('binding.gyp', 'r') as f:
    content = f.read()

# Remove fstack-protector-strong from global flags
content = re.sub(r"'cflags': \[ '-fstack-protector-strong' \]", "'cflags': []", content)

# Find the position after the freebsd block (before the final closing brackets)
# Look for the end of freebsd condition
freebsd_end = content.rfind('}]', 0, content.rfind(']'))

if freebsd_end != -1:
    # Insert AIX block after freebsd
    aix_block = ''',
        ['OS=="aix"', {
          "sources": [
            "src/watchman/BSER.cc",
            "src/watchman/WatchmanBackend.cc",
            "src/shared/BruteForceBackend.cc",
            "src/unix/legacy.cc"
          ],
          "defines": [
            "WATCHMAN",
            "BRUTE_FORCE"
          ],
          'cflags!': [ '-fstack-protector-strong' ],
          'cflags_cc!': [ '-fstack-protector-strong' ],
          'cflags': [ '-ftls-model=global-dynamic', '-fPIC', '-pthread' ],
          'cflags_cc': [ '-ftls-model=global-dynamic', '-fPIC', '-pthread', '-std=c++17' ]
        }]'''
    
    # Find the position right after the freebsd closing }]
    insert_pos = freebsd_end + 2
    content = content[:insert_pos] + aix_block + content[insert_pos:]

with open('binding.gyp', 'w') as f:
    f.write(content)

print("AIX configuration added successfully")
PYPATCH

    python3 /tmp/patch_binding.py
    rm /tmp/patch_binding.py
else
    echo "AIX configuration already exists in binding.gyp"
fi

# Patch src/unix/legacy.cc for AIX compatibility
echo "Patching src/unix/legacy.cc for AIX..."
sed -i 's/bool isDir = ent->d_type == DT_DIR;/\/\/ Use S_ISDIR from stat instead of d_type (AIX doesn'\''t have d_type)\n                bool isDir = S_ISDIR(attrib.st_mode);/' src/unix/legacy.cc

# Install dependencies - run in clean environment like manual build
echo "Installing node dependencies..."
set +e
npm install --ignore-scripts > "$MODULE_DIR/npm-install.log" 2>&1
NPM_EXIT_CODE=$?
set -e
 
echo "npm install finished with code: $NPM_EXIT_CODE"
 
if [[ $NPM_EXIT_CODE -ne 0 ]]; then
    echo "ERROR: npm install failed. Check log: $MODULE_DIR/npm-install.log"
    exit 1
fi
 
# Configure with node-gyp
echo "Configuring with node-gyp..."
node-gyp configure >> "$MODULE_DIR/npm-install.log" 2>&1
 
# Build with node-gyp
echo "Building with node-gyp..."
node-gyp build >> "$MODULE_DIR/npm-install.log" 2>&1
 
echo "Build complete (Proceeding to verification)"

# Verify build
NODE_FILE="build/Release/watcher.node"
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
    printf "\033c"
    exit 0
else
    echo "ERROR: File verification failed"
    echo "Expected content: $EXPECTED_OUTPUT"
    echo "Got: $FILE_OUTPUT"
    printf "\033c"
    exit 1
fi

# Made with Bob

