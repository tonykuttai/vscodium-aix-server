#!/bin/bash
# modules/build-ripgrep.sh
# Build ripgrep for AIX

set -e

BUILDDIR="$1"
SERVER_DIR="$2"

if [[ -z "$BUILDDIR" ]]; then
    echo "Usage: $0 <build_directory> <server_directory>"
    exit 1
fi

MODULE_NAME="ripgrep"
MODULE_DIR="$BUILDDIR/ripgrep"
REPO_URL="https://github.com/BurntSushi/ripgrep.git"

echo "Building $MODULE_NAME..."
echo "Build directory: $MODULE_DIR"

# Skip if already built
if [[ -f "$MODULE_DIR/.build-complete" ]]; then
    echo "$MODULE_NAME already built"
    exit 0
fi

# Set compiler environment
export CC=gcc
export CXX=g++

# Create and enter build directory
mkdir -p "$MODULE_DIR"
cd "$MODULE_DIR"

# Clone repository if not exists
if [[ ! -d "ripgrep" ]]; then
    echo "Cloning repository..."
    git clone "$REPO_URL" ripgrep
fi

cd ripgrep

# Restore build.rs if deleted
if [[ ! -f build.rs ]]; then
    echo "Restoring build.rs..."
    git restore build.rs
fi

# Extract memmap2 version from Cargo.lock
echo "Extracting memmap2 version..."
MEMMAP2_VERSION=$(awk '/^name = "memmap2"$/ {found=1; next} found && /^version = / {print $3; found=0; exit}' Cargo.lock | tr -d '"')

if [[ -z "$MEMMAP2_VERSION" ]]; then
    echo "ERROR: Could not extract memmap2 version from Cargo.lock"
    exit 1
fi

echo "Detected memmap2 version: $MEMMAP2_VERSION"

# Clone and patch memmap2
if [[ ! -d vendor/memmap2 ]]; then
    echo "Cloning memmap2..."
    mkdir -p vendor
    cd vendor
    git clone https://github.com/RazrFalcon/memmap2-rs.git memmap2
    cd memmap2
    git checkout "v${MEMMAP2_VERSION}"
    cd ../..
else
    echo "memmap2 already exists in vendor/"
fi

# Apply AIX fix to memmap2
echo "Applying AIX fix to memmap2..."
sed -i 's/madvise(self\.ptr\.offset(offset), len, advice)/madvise(self.ptr.offset(offset) as libc::caddr_t, len, advice)/' \
    vendor/memmap2/src/unix.rs

# Add patch to Cargo.toml if not present
if ! grep -q '\[patch.crates-io\]' Cargo.toml; then
    echo "Adding patch to Cargo.toml..."
    cat >> Cargo.toml << 'EOF'

[patch.crates-io]
memmap2 = { path = "vendor/memmap2" }
EOF
fi

# Build ripgrep
echo "Building ripgrep..."
cargo build --release --features pcre2

# Verify build
RG_BINARY="target/release/rg"
if [[ ! -f "$RG_BINARY" ]]; then
    echo "ERROR: ripgrep binary not found: $RG_BINARY"
    exit 1
fi

# Test ripgrep
echo "Testing ripgrep..."
if "$RG_BINARY" --version >/dev/null 2>&1; then
    echo "SUCCESS: $MODULE_NAME built and tested"
    echo "Binary location: $(pwd)/$RG_BINARY"
    touch "$MODULE_DIR/.build-complete"
    exit 0
else
    echo "ERROR: ripgrep test failed"
    exit 1
fi