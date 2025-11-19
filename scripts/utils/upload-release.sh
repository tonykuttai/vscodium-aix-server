#!/bin/bash
# upload-release.sh - Upload release to GitHub using API

set -e

#=============================================================================
# Configuration
#=============================================================================

# Get absolute path to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASES_DIR="$PROJECT_ROOT/releases"

# Debug output
echo "DEBUG INFO:"
echo "  SCRIPT_DIR: $SCRIPT_DIR"
echo "  PROJECT_ROOT: $PROJECT_ROOT"
echo "  RELEASES_DIR: $RELEASES_DIR"
echo ""

# Verify releases directory exists
if [[ ! -d "$RELEASES_DIR" ]]; then
    echo "ERROR: Releases directory not found: $RELEASES_DIR"
    echo "Creating it..."
    mkdir -p "$RELEASES_DIR"
fi

REPO_OWNER="tonykuttai"
REPO_NAME="vscodium-aix-server"
if [[ -n "$GITHUB_TOKEN" ]]; then
    TOKEN="$GITHUB_TOKEN"
elif [[ -f "$HOME/.config/github/token" ]]; then
    TOKEN=$(cat "$HOME/.config/github/token")
else
    echo "ERROR: GitHub token not found"
    echo ""
    echo "Please set GITHUB_TOKEN environment variable or create ~/.config/github/token"
    echo ""
    echo "Get token from: https://github.com/settings/tokens/new"
    echo "Required scope: repo (full control)"
    exit 1
fi

#=============================================================================
# Functions
#=============================================================================

get_version_to_upload() {
    echo "Available versions in $RELEASES_DIR:"
    echo ""
    
    local versions=()
    for dir in "$RELEASES_DIR"/*/ ; do
        if [[ -d "$dir" && ! -L "$dir" ]]; then
            local ver=$(basename "$dir")
            # Skip if not a version number
            if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                versions+=("$ver")
                echo "  - $ver"
            fi
        fi
    done
    
    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "ERROR: No version directories found in $RELEASES_DIR"
        exit 1
    fi
    
    echo ""
    
    # If only one version, use it
    if [[ ${#versions[@]} -eq 1 ]]; then
        VERSION="${versions[0]}"
        echo "Using version: $VERSION"
        return 0
    fi
    
    # Otherwise, ask user or use latest
    if [[ -n "$1" ]]; then
        VERSION="$1"
        echo "Using specified version: $VERSION"
    else
        # Use the latest (last in sorted order)
        VERSION=$(printf '%s\n' "${versions[@]}" | sort -V | tail -1)
        echo "Using latest version: $VERSION"        
    fi
}

check_release_exists() {
    echo ""
    echo "Checking if release $VERSION already exists..."
    
    local response=$(curl -s \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/tags/$VERSION")
    
    if echo "$response" | grep -q '"id"'; then
        local release_id=$(echo "$response" | grep '"id"' | head -1 | grep -o '[0-9]*')
        echo "WARNING: Release $VERSION already exists (ID: $release_id)"
        echo ""    
        echo "Deleting existing release..."
        curl -s -X DELETE \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/$release_id" \
            > /dev/null
        echo "OK Deleted"
        return 0
        
    fi
    
    echo "Release does not exist - will create new one"
}

create_release() {
    echo ""
    echo "Creating GitHub release..."
    
    local version_dir="$RELEASES_DIR/$VERSION"
    local info_file="$version_dir/vscodium-reh-aix-ppc64-${VERSION}.info"
    local checksum_file="$version_dir/vscodium-reh-aix-ppc64-${VERSION}.tar.gz.sha256"
    
    # Read info
    local commit_id=""
    local checksum=""
    local built_date=""
    
    if [[ -f "$info_file" ]]; then
        commit_id=$(grep "^Commit:" "$info_file" | cut -d' ' -f2)
        built_date=$(grep "^Built:" "$info_file" | cut -d' ' -f2-)
    fi
    
    if [[ -f "$checksum_file" ]]; then
        checksum=$(cat "$checksum_file")
    fi
    
    # Create release notes (plain text, will be escaped)
    local release_notes="VSCodium Remote Server for AIX (ppc64)

Based on VSCodium ${VERSION}

This is an unofficial AIX ppc64 build of VSCodium Remote Server.

Installation:

wget https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/vscodium-reh-aix-ppc64-${VERSION}.tar.gz
tar -xzf vscodium-reh-aix-ppc64-${VERSION}.tar.gz
mkdir -p ~/.vscodium-server/bin
cp -r ${commit_id} ~/.vscodium-server/bin/

Verification:

cd ~/.vscodium-server/bin/${commit_id}
./bin/codium-server --version

Details:
- Version: ${VERSION}
- Commit: ${commit_id}
- Built: ${built_date}
- Platform: AIX 7.3 ppc64

SHA256: ${checksum}

Note: This is an unofficial community build."
    
    # Escape JSON manually (escape quotes, newlines, backslashes)
    local escaped_notes=$(echo "$release_notes" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    
    # Create JSON payload
    local json_payload=$(cat <<EOF
{
  "tag_name": "$VERSION",
  "name": "VSCodium AIX Server $VERSION",
  "body": "$escaped_notes",
  "draft": false,
  "prerelease": false
}
EOF
)
    
    # Create release
    local response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases")
    
    # Check for errors
    if echo "$response" | grep -q '"message"' && ! echo "$response" | grep -q '"upload_url"'; then
        echo "ERROR: Failed to create release"
        echo "$response"
        exit 1
    fi
    
    # Get upload URL and release ID
    UPLOAD_URL=$(echo "$response" | grep '"upload_url"' | cut -d'"' -f4 | sed 's/{?name,label}//')
    RELEASE_ID=$(echo "$response" | grep '"id"' | head -1 | grep -o '[0-9]*')
    
    if [[ -z "$UPLOAD_URL" ]]; then
        echo "ERROR: Could not get upload URL from response"
        echo "$response"
        exit 1
    fi
    
    echo "OK Release created (ID: $RELEASE_ID)"
    echo "  URL: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${VERSION}"
}

upload_asset() {
    local file="$1"
    local filename=$(basename "$file")
    
    if [[ ! -f "$file" ]]; then
        echo "  WARNING: File not found: $file"
        return 1
    fi
    
    echo ""
    echo "Uploading: $filename"
    echo "  Size: $(du -h "$file" | cut -f1)"
    
    # Determine content type
    local content_type="application/octet-stream"
    if [[ "$filename" == *.tar.gz ]]; then
        content_type="application/gzip"
    elif [[ "$filename" == *.sha256 ]]; then
        content_type="text/plain"
    elif [[ "$filename" == *.info ]]; then
        content_type="text/plain"
    fi
    
    # Upload with progress
    local response=$(curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: $content_type" \
        --data-binary @"$file" \
        "${UPLOAD_URL}?name=${filename}")
    
    if echo "$response" | grep -q '"browser_download_url"'; then
        local download_url=$(echo "$response" | grep '"browser_download_url"' | cut -d'"' -f4)
        echo "  OK Uploaded: $download_url"
        return 0
    else
        echo "  X Upload failed"
        echo "$response"
        return 1
    fi
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    local version_arg="$1"
    
    echo "=========================================="
    echo "Upload Release to GitHub"
    echo "=========================================="
    echo "Repository: $REPO_OWNER/$REPO_NAME"
    echo ""
    
    # Get version to upload
    get_version_to_upload "$version_arg"
    
    local version_dir="$RELEASES_DIR/$VERSION"
    
    if [[ ! -d "$version_dir" ]]; then
        echo "ERROR: Version directory not found: $version_dir"
        exit 1
    fi
    
    echo ""
    echo "Files to upload:"
    ls -lh "$version_dir"
    
    # Check if release exists
    check_release_exists
    
    # Create release
    create_release
    
    # Upload assets
    local tarball="$version_dir/vscodium-reh-aix-ppc64-${VERSION}.tar.gz"
    local checksum="$version_dir/vscodium-reh-aix-ppc64-${VERSION}.tar.gz.sha256"
    local info="$version_dir/vscodium-reh-aix-ppc64-${VERSION}.info"
    
    upload_asset "$tarball"
    upload_asset "$checksum"
    upload_asset "$info"
    
    echo ""
    echo "=========================================="
    echo "Upload Complete!"
    echo "=========================================="
    echo "Release URL: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${VERSION}"
    echo ""
    echo "Download command:"
    echo "  wget https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/vscodium-reh-aix-ppc64-${VERSION}.tar.gz"
    
    exit 0
}

# Run main
main "$@"