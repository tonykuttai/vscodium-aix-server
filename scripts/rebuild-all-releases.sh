#!/bin/bash
# rebuild-all-releases.sh
# Rebuild all VSCodium releases with updated path fixes
# Optimized: Build native modules once, reuse for all versions

set -e

#=============================================================================
# Configuration
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="${BUILDDIR:-/tmp/vscodium-rebuild-cache/node_modules}"
VSCODIUM_LINUX_SERVER="${VSCODIUM_LINUX_SERVER:-/tmp/vscodium-remote-aix/server}"

# Versions to rebuild
VERSIONS=(
    "1.105.16999"
    "1.105.17075"
    "1.106.27818"
    "1.106.37943"
    "1.107.18627"
    "1.108.10359"
    "1.108.20787"
    "1.109.21026"
    "1.109.41146"
    "1.109.51242"
)

# Global variable to store original tarball name
ORIGINAL_TARBALL_NAME=""

# Flag to track if modules are built
MODULES_BUILT=false

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
    echo "   VSCodium Remote Server - AIX Rebuild All Releases (Optimized)"
    echo "=========================================================================="
    echo "Build Directory: $BUILDDIR"
    echo "Server Directory: $VSCODIUM_LINUX_SERVER"
    echo "Platform: $(uname -s) $(uname -m)"
    echo "Node.js: $(node --version 2>/dev/null || echo 'Not found')"
    echo "Date: $(date)"
    echo "Versions to rebuild: ${#VERSIONS[@]}"
    echo ""
    echo "Optimization: Native modules will be built once and reused"
    echo "=========================================================================="
    echo ""
}

# Build native modules once
build_native_modules_once() {
    if [[ "$MODULES_BUILT" == "true" ]]; then
        echo "=== Native modules already built, skipping ==="
        return 0
    fi
    
    echo ""
    echo "######################################################################"
    echo "# Building Native Modules (One-Time Build)"
    echo "######################################################################"
    echo ""
    
    # Reset counters
    MODULES_ATTEMPTED=0
    MODULES_SUCCESS=0
    MODULES_FAILED=0
    
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
    
    if [[ $MODULES_FAILED -gt 0 ]]; then
        echo ""
        echo "[ERROR] Failed to build native modules"
        return 1
    fi
    
    echo ""
    echo "=========================================================================="
    echo "   Native Modules Build Summary"
    echo "=========================================================================="
    echo "Modules Attempted: $MODULES_ATTEMPTED"
    echo "Modules Success:   $MODULES_SUCCESS"
    echo "Modules Failed:    $MODULES_FAILED"
    echo "=========================================================================="
    echo ""
    echo "[SUCCESS] All native modules built successfully!"
    echo "These will be reused for all ${#VERSIONS[@]} versions"
    echo ""
    
    MODULES_BUILT=true
    return 0
}

# Download specific VSCodium server version
download_vscodium_server() {
    local version="$1"
    
    echo "=== Downloading VSCodium Server $version ==="
    
    # Clean previous download
    if [[ -d "$VSCODIUM_LINUX_SERVER" ]]; then
        echo "Cleaning previous download..."
        rm -rf "$VSCODIUM_LINUX_SERVER"
    fi
    
    mkdir -p "$VSCODIUM_LINUX_SERVER"
    cd "$VSCODIUM_LINUX_SERVER"
    
    echo "Downloading version: $version"
    
    # Construct download URL for specific version
    local filename="vscodium-reh-linux-x64-${version}.tar.gz"
    local DOWNLOAD_URL="https://github.com/VSCodium/vscodium/releases/download/${version}/${filename}"
    
    echo "Download URL: $DOWNLOAD_URL"
    
    # Set global variable for packaging
    ORIGINAL_TARBALL_NAME="$filename"
    echo "Set ORIGINAL_TARBALL_NAME: $ORIGINAL_TARBALL_NAME"
    
    # Download with wget
    if ! wget -q --show-progress -P "$VSCODIUM_LINUX_SERVER" "$DOWNLOAD_URL"; then
        echo "ERROR: Download failed for $version"
        return 1
    fi
    
    echo "Extracting server..."
    tar -xzf "$filename"
    
    if [[ $? -eq 0 ]]; then
        echo "Success! VSCodium Server extracted."
        rm "$filename"
        return 0
    else
        echo "ERROR: Extraction failed"
        return 1
    fi
}

# Copy built modules to server
copy_modules_to_server() {
    echo ""
    echo "=== Copying Pre-Built Modules to Server ==="
    
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
            echo "  ERROR: Source not found: $source_path"
            return 1
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

    # Copy node-pty native libraries
    echo ""
    echo "Copying node-pty native libraries..."
    local pty_native_libs_src="$BUILDDIR/nodepty/node-pty/lib/native-libs"
    local pty_native_libs_dst="$VSCODIUM_LINUX_SERVER/node_modules/node-pty/lib/native-libs"
    
    if [[ -d "$pty_native_libs_src" ]]; then
        mkdir -p "$pty_native_libs_dst"
        cp -r "$pty_native_libs_src/"* "$pty_native_libs_dst/"
        echo "  OK Copied native-libs to: $pty_native_libs_dst"
        
        # Verify the copy
        if [[ -f "$pty_native_libs_dst/libutil.so.2" ]]; then
            echo "  OK Verified: libutil.so.2 present"
        else
            echo "  WARNING: libutil.so.2 not found after copy"
        fi
    else
        echo "  ERROR: Native libs directory not found: $pty_native_libs_src"
        return 1
    fi
        
    echo "OK All modules copied to server"
    return 0
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
    cat > node << 'EOF'
#!/usr/bin/env sh
# Wrapper for AIX – uses system node path
NODE_BIN="$(which node)"

if [ ! -x "$NODE_BIN" ]; then
    echo "Error: expected Node.js at $NODE_BIN but it's missing or not executable" >&2
    exit 1
fi

exec "$NODE_BIN" "$@"

EOF

    chmod +x node
    echo "Node wrapper created at $servers_dir/node"
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

cleanup_server_download() {
    echo "Cleaning up server download..."
    rm -rf "$VSCODIUM_LINUX_SERVER"
}

# Upload release to GitHub
upload_release() {
    local version="$1"
    
    echo ""
    echo "=== Uploading Release to GitHub ==="
    
    # Check if GITHUB_TOKEN is set
    if [[ -z "$GITHUB_TOKEN" ]]; then
        if [[ -f "$HOME/.config/github/token" ]]; then
            export GITHUB_TOKEN=$(cat "$HOME/.config/github/token")
        else
            echo "ERROR: GITHUB_TOKEN not set"
            return 1
        fi
    fi
    
    # Change to utils directory
    cd "$SCRIPT_DIR/utils"
    
    # Run upload script
    if bash upload-release.sh "$version"; then
        echo "OK Upload completed for $version"
        return 0
    else
        echo "ERROR: Upload failed for $version"
        return 1
    fi
}

# Build single version (reusing pre-built modules)
build_single_version() {
    local version="$1"
    
    echo ""
    echo "######################################################################"
    echo "# Processing Version: $version"
    echo "######################################################################"
    echo ""
    
    # Download specific version
    if ! download_vscodium_server "$version"; then
        echo "[ERROR] Failed to download VSCodium server $version"
        return 1
    fi
    echo ""
    
    # Copy pre-built modules to server
    if ! copy_modules_to_server; then
        echo "[ERROR] Failed to copy modules to server"
        return 1
    fi
    
    # Apply server patches (deviceid and platform-override)
    echo ""
    echo "=== Applying Server Patches ==="
    run_module_build "deviceid"
    run_module_build "platform-override"

    copy_server_to_local
    create_node_wrapper

    # Package for release
    package_server_release

    cleanup_server_download
    
    echo ""
    echo "[SUCCESS] Version $version built successfully"
    
    return 0
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    print_banner
    
    echo "Versions to rebuild:"
    for ver in "${VERSIONS[@]}"; do
        echo "  - $ver"
    done
    echo ""
    
    read -p "Continue with rebuild of all ${#VERSIONS[@]} versions? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted by user"
        exit 0
    fi
    
    # Setup environment once
    echo ""
    echo "=== Setting up AIX build environment ==="
    if ! setup_aix_environment; then
        echo "[ERROR] Failed to setup AIX build environment"
        exit 1
    fi
    echo ""
    
    # Build native modules once
    if ! build_native_modules_once; then
        echo "[ERROR] Failed to build native modules"
        exit 1
    fi
    
    # Track overall results
    local total=${#VERSIONS[@]}
    local success=0
    local failed=0
    local failed_versions=()
    local start_time=$(date +%s)
    
    # Process each version
    for version in "${VERSIONS[@]}"; do
        echo ""
        echo "======================================================================"
        echo "Processing $version ($(($success + $failed + 1))/$total)"
        echo "======================================================================"
        
        # Build version
        if build_single_version "$version"; then
            # Upload to GitHub
            if upload_release "$version"; then
                success=$((success + 1))
                echo ""
                echo "[SUCCESS] Version $version completed successfully"
            else
                failed=$((failed + 1))
                failed_versions+=("$version (upload failed)")
                echo ""
                echo "[FAILED] Version $version - upload failed"
            fi
        else
            failed=$((failed + 1))
            failed_versions+=("$version (build failed)")
            echo ""
            echo "[FAILED] Version $version - build failed"
        fi
        
        echo ""
        echo "Progress: $(($success + $failed))/$total (Success: $success, Failed: $failed)"
    done
    
    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    
    # Final summary
    echo ""
    echo "======================================================================"
    echo "   REBUILD COMPLETE!"
    echo "======================================================================"
    echo "Total versions: $total"
    echo "Successful: $success"
    echo "Failed: $failed"
    echo "Duration: ${hours}h ${minutes}m"
    echo ""
    echo "Native modules were built once and reused for all versions"
    echo ""
    
    if [[ $failed -gt 0 ]]; then
        echo "Failed versions:"
        for ver in "${failed_versions[@]}"; do
            echo "  - $ver"
        done
        echo ""
        exit 1
    else
        echo "All versions rebuilt and uploaded successfully!"
        echo ""
        exit 0
    fi
}

# Run main function
main "$@"
