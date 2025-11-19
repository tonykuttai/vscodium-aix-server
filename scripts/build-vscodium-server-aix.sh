#!/bin/bash
# build-vscodium-server-aix.sh
# Main orchestrator for building VSCodium Remote Server on AIX

set -e

#=============================================================================
# Configuration
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="${BUILDDIR:-/tmp/vscodium-remote-aix/node_modules}"
VSCODIUM_LINUX_SERVER="${VSCODIUM_LINUX_SERVER:-/tmp/vscodium-remote-aix/server}"

# Global variable to store original tarball name
ORIGINAL_TARBALL_NAME=""

# Counters for summary
MODULES_ATTEMPTED=0
MODULES_SUCCESS=0
MODULES_FAILED=0

#=============================================================================
# Source utilities
#=============================================================================

if [[ ! -f "$SCRIPT_DIR/utils/aix-environment.sh" ]]; then
    echo "ERROR: Required utility script not found: $SCRIPT_DIR/utils/aix-environment.sh"
    exit 1
fi

source "$SCRIPT_DIR/utils/aix-environment.sh"

#=============================================================================
# Functions
#=============================================================================

# Print banner
print_banner() {
    echo "=========================================================================="
    echo "   VSCodium Remote Server - AIX Build System"
    echo "=========================================================================="
    echo "Build Directory: $BUILDDIR"
    echo "Server Directory: $VSCODIUM_LINUX_SERVER"
    echo "Platform: $(uname -s) $(uname -m)"
    echo "Node.js: $(node --version 2>/dev/null || echo 'Not found')"
    echo "Date: $(date)"
    echo "=========================================================================="
    echo ""
}

# Download VSCodium server
download_vscodium_server() {
    echo "=== Step 1: Downloading VSCodium Server ==="
    
    if [[ -d "$VSCODIUM_LINUX_SERVER" && -f "$VSCODIUM_LINUX_SERVER/.download-complete" ]]; then
        echo "VSCodium server already downloaded"
        return 0
    fi
    
    mkdir -p "$VSCODIUM_LINUX_SERVER"
    cd "$VSCODIUM_LINUX_SERVER"
    
    echo "Checking for the latest release..."
    
    # Get GitHub token from environment or file
    local github_token="$GITHUB_TOKEN"
    if [[ -z "$github_token" && -f "$HOME/.config/github/token" ]]; then
        github_token=$(cat "$HOME/.config/github/token")
        echo "Using GitHub token from ~/.config/github/token"
    fi
    
    # Fetch with authentication
    if [[ -n "$github_token" ]]; then
        echo "Using authenticated GitHub API request"
        LATEST_RELEASE_DATA=$(curl -s -H "Authorization: token $github_token" \
            https://api.github.com/repos/VSCodium/vscodium/releases/latest)
    else
        echo "WARNING: No GITHUB_TOKEN found, using unauthenticated request (rate limited)"
        LATEST_RELEASE_DATA=$(curl -s https://api.github.com/repos/VSCodium/vscodium/releases/latest)
    fi
    
    # Check for rate limit
    if echo "$LATEST_RELEASE_DATA" | grep -q "API rate limit exceeded"; then
        echo "ERROR: GitHub API rate limit exceeded"
        echo "Please set GITHUB_TOKEN environment variable or create ~/.config/github/token"
        echo "Get token from: https://github.com/settings/tokens/new"
        return 1
    fi
    
    DOWNLOAD_URL=$(echo "$LATEST_RELEASE_DATA" \
        | grep -o 'https://.*vscodium-reh-linux-x64-.*\.tar\.gz' \
        | head -n 1 \
        | tr -d '"')
    
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "ERROR: Could not find download URL for vscodium-reh-linux-x64"
        echo "API Response (first 500 chars):"
        echo "$LATEST_RELEASE_DATA" | head -c 500
        return 1
    fi
    
    local filename=$(basename "$DOWNLOAD_URL")
    echo "Latest version: $filename"
    echo "Download URL: $DOWNLOAD_URL"
    
    # Set global variable for packaging
    ORIGINAL_TARBALL_NAME="$filename"
    echo "Set ORIGINAL_TARBALL_NAME: $ORIGINAL_TARBALL_NAME"
    
    wget -q --show-progress -P "$VSCODIUM_LINUX_SERVER" "$DOWNLOAD_URL"
    
    echo "Extracting server..."
    tar -xzf "$filename"
    
    if [[ $? -eq 0 ]]; then
        echo "Success! VSCodium Server extracted."
        rm "$filename"
        touch "$VSCODIUM_LINUX_SERVER/.download-complete"
        return 0
    else
        echo "ERROR: Extraction failed"
        return 1
    fi
}

# Copy built modules to server
copy_modules_to_server() {
    echo ""
    echo "=== Copying Built Modules to Server ==="
    
    # Define source and target paths
    local modules=(
        "native-watchdog|nativewatchdog/node-native-watchdog/build/Release/watchdog.node|node_modules/native-watchdog/build/Release/watchdog.node"
        "node-spdlog|nodespdlog/node-spdlog/build/Release/spdlog.node|node_modules/@vscode/spdlog/build/Release/spdlog.node"
        "node-pty|nodepty/node-pty/build/Release/pty.node|node_modules/node-pty/build/Release/pty.node"
        "ripgrep|ripgrep/ripgrep/target/release/rg|node_modules/@vscode/ripgrep/bin/rg"
    )
    
    for module_spec in "${modules[@]}"; do
        IFS='|' read -r name source target <<< "$module_spec"
        
        local source_path="$BUILDDIR/$source"
        local target_path="$VSCODIUM_LINUX_SERVER/$target"
        local target_dir=$(dirname "$target_path")
        
        echo "Copying $name..."
        
        if [[ ! -f "$source_path" ]]; then
            echo "  WARNING: Source not found: $source_path"
            continue
        fi
        
        mkdir -p "$target_dir"
        
        # Backup original
        if [[ -f "$target_path" && ! -f "${target_path}.linux-backup" ]]; then
            cp "$target_path" "${target_path}.linux-backup"
        fi
        
        # Copy AIX version
        cp "$source_path" "$target_path"
        echo "  OK Copied to: $target_path"
    done
    
    echo "OK All modules copied to server"
}

# Run a module build script
run_module_build() {
    local module_name="$1"
    local build_script="$SCRIPT_DIR/modules/build-${module_name}.sh"
    
    echo ""
    echo "=========================================================================="
    echo "Building Module: $module_name"
    echo "=========================================================================="
    
    MODULES_ATTEMPTED=$((MODULES_ATTEMPTED + 1))
    
    if [[ ! -f "$build_script" ]]; then
        echo "[ERROR] Build script not found: $build_script"
        MODULES_FAILED=$((MODULES_FAILED + 1))
        return 1
    fi
    
    if [[ ! -x "$build_script" ]]; then
        chmod +x "$build_script"
    fi
    
    if bash "$build_script" "$BUILDDIR" "$VSCODIUM_LINUX_SERVER"; then
        echo "[SUCCESS] $module_name built successfully"
        MODULES_SUCCESS=$((MODULES_SUCCESS + 1))
        return 0
    else
        echo "[FAILED] $module_name build failed"
        MODULES_FAILED=$((MODULES_FAILED + 1))
        return 1
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================================================="
    echo "   Build Summary"
    echo "=========================================================================="
    echo "Modules Attempted: $MODULES_ATTEMPTED"
    echo "Modules Success:   $MODULES_SUCCESS"
    echo "Modules Failed:    $MODULES_FAILED"
    echo "=========================================================================="
    
    if [[ $MODULES_FAILED -gt 0 ]]; then
        echo ""
        echo "[WARNING] Some modules failed to build"
        echo "Check the logs above for details"
        return 1
    else
        echo ""
        echo "[SUCCESS] All modules built successfully!"
        echo ""
        echo "Build artifacts:"
        local servers_dir="$SCRIPT_DIR/vscodium-servers"
        echo "  Server: $servers_dir/latest"
        
        if [[ -n "$RELEASE_PACKAGE" ]]; then
            echo "  Package: $RELEASE_PACKAGE"
            echo "  Checksum: ${RELEASE_PACKAGE}.sha256"
        fi
        
        return 0
    fi
}

# Copy server to local directory with commit ID as folder name
copy_server_to_local() {
    echo ""
    echo "=== Copying Server to Local Directory ==="
    
    local product_json="$VSCODIUM_LINUX_SERVER/product.json"
    
    # Check if product.json exists
    if [[ ! -f "$product_json" ]]; then
        echo "ERROR: product.json not found at: $product_json"
        return 1
    fi
    
    # Extract commit ID using grep (avoiding node -p)
    echo "Extracting commit ID from product.json..."
    local commit_id=$(grep -o '"commit"[[:space:]]*:[[:space:]]*"[^"]*"' "$product_json" | cut -d'"' -f4)
    
    if [[ -z "$commit_id" ]]; then
        echo "ERROR: Could not extract commit ID from product.json"
        return 1
    fi
    
    echo "Commit ID: $commit_id"
    
    # Set target directory (in build-scripts folder)
    local servers_dir="$SCRIPT_DIR/vscodium-servers"
    local target_dir="$servers_dir/$commit_id"
    
    # Create parent directory if it doesn't exist
    mkdir -p "$servers_dir"
    
    # Check if target exists
    if [[ -d "$target_dir" ]]; then
        echo ""
        echo "WARNING: Directory already exists: $target_dir"
        local backup_dir="${target_dir}.backup-$(date +%Y%m%d-%H%M%S)"
        echo "Creating backup: $backup_dir"
        mv "$target_dir" "$backup_dir"
    fi
    
    # Copy server
    echo "Copying server to: $target_dir"
    cp -r "$VSCODIUM_LINUX_SERVER" "$target_dir"
    
    # Verify
    if [[ -d "$target_dir" && -f "$target_dir/package.json" ]]; then
        echo "OK Server copied successfully"
        
        # Extract version for info
        local version=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$target_dir/product.json" | cut -d'"' -f4)
        
        echo ""
        echo "Local copy created:"
        echo "  Location: $target_dir"
        echo "  Commit: $commit_id"
        echo "  Version: $version"
        
        # Show directory size
        echo "  Size: $(du -sh "$target_dir" | cut -f1)"
        
        # Create a symlink for convenience
        local symlink_path="$servers_dir/latest"
        if [[ -L "$symlink_path" ]]; then
            rm "$symlink_path"
        fi
        ln -s "$commit_id" "$symlink_path"
        echo "  Symlink: $symlink_path -> $commit_id"
        
        return 0
    else
        echo "X Copy verification failed"
        return 1
    fi
}

create_node_wrapper() {
    local servers_dir="$SCRIPT_DIR/vscodium-servers/latest"
    
    # Safety check: ensure directory exists
    if [ ! -d "$servers_dir" ]; then
        echo "Error: Directory $servers_dir not found."
        return 1
    fi
    
    cd "$servers_dir" || return 1

    # Only rename if the original binary exists and hasn't been renamed yet
    if [ -f node ] && [ ! -f node-linux-x64 ]; then
        mv node node-linux-x64
    fi

    # Create the wrapper
    # IMPORTANT: The content below must NOT be indented.
    cat > node << 'EOF'
#!/usr/bin/env sh
# Wrapper for AIX – uses system node path
NODE_BIN="/opt/nodejs/bin/node"
exec "$NODE_BIN" "$@"
EOF

    chmod +x node
    echo "Node wrapper created at $servers_dir/node"
}

# Copy and extract VSCodium server from local tarball
copy_vscodium_server() {
    local source_tarball="$1"
    
    echo "=== Step 1: Copying VSCodium Server ==="
    
    # Check if already extracted
    if [[ -d "$VSCODIUM_LINUX_SERVER" && -f "$VSCODIUM_LINUX_SERVER/.download-complete" ]]; then
        echo "VSCodium server already extracted"
        echo "Location: $VSCODIUM_LINUX_SERVER"
        return 0
    fi
    
    # Verify source tarball exists
    if [[ ! -f "$source_tarball" ]]; then
        echo "ERROR: Source tarball not found: $source_tarball"
        return 1
    fi
    
    # Get filename and save to global variable
    ORIGINAL_TARBALL_NAME=$(basename "$source_tarball")
    echo "Source tarball: $source_tarball"
    echo "Filename: $ORIGINAL_TARBALL_NAME"
    
    # Create server directory
    mkdir -p "$VSCODIUM_LINUX_SERVER"
    cd "$VSCODIUM_LINUX_SERVER"
    
    # Copy tarball if not already there
    if [[ ! -f "$ORIGINAL_TARBALL_NAME" ]]; then
        echo "Copying tarball to $VSCODIUM_LINUX_SERVER..."
        cp "$source_tarball" .
        
        if [[ $? -ne 0 ]]; then
            echo "ERROR: Failed to copy tarball"
            return 1
        fi
        
        echo "Tarball copied successfully"
    else
        echo "Tarball already present in target directory"
    fi
    
    # Extract
    echo "Extracting server..."
    tar -xzf "$ORIGINAL_TARBALL_NAME"
    
    if [[ $? -eq 0 ]]; then
        echo "Success! VSCodium Server extracted."
        
        # Verify extraction
        if [[ -f "package.json" && -d "bin" && -d "out" ]]; then
            echo "Server structure verified:"
            ls -la | head -15
            
            # Clean up tarball
            rm "$ORIGINAL_TARBALL_NAME"
            echo "Removed tarball after extraction"
            
            # Mark as complete
            touch "$VSCODIUM_LINUX_SERVER/.download-complete"
            echo "Marked as complete"
            
            return 0
        else
            echo "ERROR: Extracted server structure is incomplete"
            echo "Expected files/directories missing"
            return 1
        fi
    else
        echo "ERROR: Extraction failed"
        return 1
    fi
}

# Package server for release
package_server_release() {
    echo ""
    echo "=== Packaging Server for Release ==="
    
    local product_json="$VSCODIUM_LINUX_SERVER/product.json"
    
    # Check if product.json exists
    if [[ ! -f "$product_json" ]]; then
        echo "ERROR: product.json not found at: $product_json"
        return 1
    fi
    
    # Check if we have the original tarball name
    if [[ -z "$ORIGINAL_TARBALL_NAME" ]]; then
        echo "ERROR: Original tarball name not found"
        return 1
    fi
    
    echo "Original tarball: $ORIGINAL_TARBALL_NAME"
    
    # Create AIX package name by replacing linux-x64 with aix-ppc64
    local package_name=$(echo "$ORIGINAL_TARBALL_NAME" | sed 's/linux-x64/aix-ppc64/')
    echo "AIX package name: $package_name"
    
    # Extract version from package name
    local version=$(echo "$package_name" | sed 's/vscodium-reh-aix-ppc64-//' | sed 's/.tar.gz//')
    echo "Version: $version"
    
    # Extract commit ID for finding the server directory
    local commit_id=$(grep -o '"commit"[[:space:]]*:[[:space:]]*"[^"]*"' "$product_json" | head -1 | cut -d'"' -f4)
    
    if [[ -z "$commit_id" ]]; then
        echo "ERROR: Could not extract commit ID"
        return 1
    fi
    
    echo "Commit ID: $commit_id"
    
    # Set up paths with version subdirectory
    local releases_dir="$SCRIPT_DIR/../releases"
    local version_dir="$releases_dir/$version"
    local package_path="$version_dir/$package_name"
    
    # Create version directory
    mkdir -p "$version_dir"
    
    # Check if package already exists
    if [[ -f "$package_path" ]]; then
        echo ""
        echo "WARNING: Package already exists: $package_path"
        # Backup existing
        mv "$package_path" "${package_path}.backup-$(date +%Y%m%d-%H%M%S)"
    fi
    
    # Create tarball from the local copy
    local servers_dir="$SCRIPT_DIR/vscodium-servers"
    
    if [[ ! -d "$servers_dir/$commit_id" ]]; then
        echo "ERROR: Server directory not found: $servers_dir/$commit_id"
        return 1
    fi
    
    echo ""
    echo "Creating tarball..."
    cd "$servers_dir"
    tar -czf "$package_path" "$commit_id/"
    
    # Verify package
    if [[ -f "$package_path" ]]; then
        local package_size=$(du -h "$package_path" | cut -f1)
        echo "OK Package created: $package_path"
        echo "  Size: $package_size"
        
        # Generate SHA256 checksum
        echo ""
        echo "Generating checksum..."
        local checksum=$(sha256sum "$package_path" | cut -d' ' -f1)
        echo "$checksum" > "${package_path}.sha256"
        echo "OK Checksum: $checksum"
        echo "  Saved to: ${package_path}.sha256"
        
        # Create release info file
        local info_file="$version_dir/$package_name"
        info_file="${info_file%.tar.gz}.info"
        cat > "$info_file" << EOF
VSCodium Remote Server for AIX (ppc64)
Version: $version
Commit: $commit_id
Built: $(date)
Platform: $(uname -s) $(uname -m)
Node.js: $(node --version)
Package: $package_name
Size: $package_size
SHA256: $checksum
Original: $ORIGINAL_TARBALL_NAME
EOF
        echo "OK Info file: $info_file"
        
        # Export for other scripts
        export RELEASE_PACKAGE="$package_path"
        export RELEASE_VERSION="$version"
        export RELEASE_COMMIT="$commit_id"
        
        return 0
    else
        echo "X Packaging failed"
        return 1
    fi
}

cleanup_servers() {
    # local servers_dir="$SCRIPT_DIR/vscodium-servers"
    # rm -rf $servers_dir
    rm -rf /tmp/vscodium-remote-aix
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    print_banner
    
    # Setup environment
    echo "=== Setting up AIX build environment ==="
    if ! setup_aix_environment; then
        echo "[ERROR] Failed to setup AIX build environment"
        exit 1
    fi
    echo ""
    
    # Download VSCodium server
    if ! download_vscodium_server; then
        echo "[ERROR] Failed to download VSCodium server"
        exit 1
    fi
    echo ""
    # # Copy and extract VSCodium server from local tarball
    # LOCAL_TARBALL="/home/varghese/projects/vscodium-remote-server/server/vscodium-reh-linux-x64-1.105.16999.tar.gz"
    # if ! copy_vscodium_server "$LOCAL_TARBALL"; then
    #     echo "[ERROR] Failed to copy/extract VSCodium server"
    #     exit 1
    # fi
    # echo ""
    
    # Create build directory
    echo "=== Creating build directory ==="
    mkdir -p "$BUILDDIR"
    echo "Build directory: $BUILDDIR"
    echo ""
    
    # Build native modules in order
    run_module_build "native-watchdog"
    run_module_build "node-spdlog"
    run_module_build "node-pty"
    run_module_build "ripgrep"

    # Copy built modules to server
    copy_modules_to_server
    
    # # Apply server patches
    run_module_build "deviceid"
    run_module_build "platform-override"
    # run_module_build "path-setup"

    copy_server_to_local
    create_node_wrapper

    # Package for release
    package_server_release

    cleanup_servers
    
    # Print summary
    print_summary
    
    exit $?
}

# Run main function
main "$@"