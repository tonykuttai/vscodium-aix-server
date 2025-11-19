#!/bin/bash
# auto-build-release.sh - Automated VSCodium AIX build and release pipeline

set -e

#=============================================================================
# Configuration
#=============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPTS_DIR="$SCRIPT_DIR"
CACHE_DIR="$HOME/.vscodium-build-cache"
CACHE_FILE="$CACHE_DIR/last-built.txt"
LOG_DIR="$CACHE_DIR/logs"

VSCODIUM_REPO="VSCodium/vscodium"

# Email configuration
EMAIL_TO="${EMAIL_TO:-tony.varghese@ibm.com}"  # Change this!
EMAIL_FROM="${EMAIL_FROM:-vscodium-build@$(hostname)}"
SEND_EMAIL="${SEND_EMAIL:-true}"  # Set to false to disable emails

# Create directories
mkdir -p "$CACHE_DIR" "$LOG_DIR"

# Log file with timestamp
LOG_FILE="$LOG_DIR/auto-build-$(date +%Y%m%d-%H%M%S).log"

#=============================================================================
# Functions
#=============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    log ""
    log "=========================================="
    log "$1"
    log "=========================================="
}

send_email() {
    local subject="$1"
    local body="$2"
    local priority="${3:-normal}"  # low, normal, high
    
    if [[ "$SEND_EMAIL" != "true" ]]; then
        log "Email notifications disabled, skipping: $subject"
        return 0
    fi
    
    log "Sending email notification: $subject"
    
    # Create email body with log excerpt
    local email_body="$body

---
Hostname: $(hostname)
Date: $(date)
Log file: $LOG_FILE

Last 50 lines of log:
---
$(tail -50 "$LOG_FILE")
"
    
    # Send email (try different mail commands)
    if command -v mailx &> /dev/null; then
        echo "$email_body" | mailx -s "$subject" -r "$EMAIL_FROM" "$EMAIL_TO"
    elif command -v mail &> /dev/null; then
        echo "$email_body" | mail -s "$subject" "$EMAIL_TO"
    else
        log "WARNING: No mail command found, cannot send email"
        return 1
    fi
    
    log "OK Email sent to: $EMAIL_TO"
}

check_new_release() {
    log_section "Checking for New Release"
    
    # Get GitHub token from environment or file
    local github_token="$GITHUB_TOKEN"
    if [[ -z "$github_token" && -f "$HOME/.config/github/token" ]]; then
        github_token=$(cat "$HOME/.config/github/token")
        log "Using GitHub token from ~/.config/github/token"
    fi
    
    # Get latest release info from GitHub
    log "Fetching latest release from $VSCODIUM_REPO..."
    
    # Fetch with authentication
    local release_data
    if [[ -n "$github_token" ]]; then
        log "Using authenticated GitHub API request"
        release_data=$(curl -s -H "Authorization: token $github_token" \
            "https://api.github.com/repos/$VSCODIUM_REPO/releases/latest")
    else
        log "WARNING: No GitHub token found, using unauthenticated request (rate limited)"
        release_data=$(curl -s "https://api.github.com/repos/$VSCODIUM_REPO/releases/latest")
    fi
    
    # Check for API rate limit
    if echo "$release_data" | grep -q "API rate limit exceeded"; then
        log "ERROR: GitHub API rate limit exceeded"
        send_email "ERROR VSCodium AIX Build - API Rate Limit" \
            "Failed to check for new releases: GitHub API rate limit exceeded." \
            "high"
        return 1
    fi
    
    # Extract tag
    LATEST_TAG=$(echo "$release_data" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    
    if [[ -z "$LATEST_TAG" ]]; then
        log "ERROR: Could not fetch latest release"
        send_email "ERROR VSCodium AIX Build - Fetch Failed" \
            "Failed to fetch latest release information from GitHub." \
            "high"
        return 1
    fi
    
    log "Latest release: $LATEST_TAG"
    
    # Check if already built
    if [[ -f "$CACHE_FILE" ]]; then
        LAST_BUILT=$(cat "$CACHE_FILE")
        log "Last built: $LAST_BUILT"
        
        if [[ "$LAST_BUILT" == "$LATEST_TAG" ]]; then
            log "Already built: $LATEST_TAG"
            return 10  # Return 10 = already built
        fi
    else
        log "No previous build found"
    fi
    
    log "New release detected: $LATEST_TAG"
    
    # Send notification about new release
    send_email "ALERT VSCodium AIX Build - New Release Detected" \
        "New VSCodium release detected: $LATEST_TAG
        
Previous version: ${LAST_BUILT:-None}
New version: $LATEST_TAG

Build will start automatically..." \
        "normal"
    
    return 0  # New release available
}

run_build() {
    log_section "Building VSCodium Server for AIX"
    
    cd "$BUILD_SCRIPTS_DIR"
    
    log "Executing build script..."
    log "This will download, build, and package automatically"
    log "This may take 10-15 minutes..."
    
    # Just run the build script - it handles everything
    if bash build-vscodium-server-aix.sh 2>&1 | tee -a "$LOG_FILE"; then
        log "OK Build completed successfully"
        return 0
    else
        log "X Build failed"
        return 1
    fi
}

upload_release() {
    log_section "Uploading Release to GitHub"
    
    # Check if GITHUB_TOKEN is set
    if [[ -z "$GITHUB_TOKEN" ]]; then
        if [[ -f "$HOME/.config/github/token" ]]; then
            export GITHUB_TOKEN=$(cat "$HOME/.config/github/token")
        else
            log "ERROR: GITHUB_TOKEN not set"
            return 1
        fi
    fi
    
    # Get the latest version from releases directory
    local releases_dir="$PROJECT_ROOT/releases"
    log "Looking for releases in: $releases_dir"
    
    local latest_version=$(ls -1 "$releases_dir" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    
    if [[ -z "$latest_version" ]]; then
        log "ERROR: No version found in releases directory"
        return 1
    fi
    
    log "Version to upload: $latest_version"
    
    # Change to scripts directory before running upload script
    cd "$SCRIPT_DIR"
    
    # Run upload script
    if bash upload-release.sh "$latest_version" 2>&1 | tee -a "$LOG_FILE"; then
        log "OK Upload completed successfully"
        return 0
    else
        log "X Upload failed"
        return 1
    fi
}

update_cache() {
    log_section "Updating Cache"
    
    log "Recording built version: $LATEST_TAG"
    echo "$LATEST_TAG" > "$CACHE_FILE"
    
    # Keep last 10 log files
    log "Cleaning old log files..."
    cd "$LOG_DIR"
    ls -t auto-build-*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    
    log "OK Cache updated"
}

send_notification() {
    local status="$1"
    local message="$2"
    
    log ""
    log "=========================================="
    log "NOTIFICATION: $status"
    log "$message"
    log "=========================================="
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    log_section "VSCodium AIX Auto-Build Pipeline"
    log "Started at: $(date)"
    log "Log file: $LOG_FILE"
    log "Email notifications: $SEND_EMAIL (to: $EMAIL_TO)"
    
    # Send start notification
    send_email "START VSCodium AIX Build - Started" \
        "Automated build pipeline started.
        
Checking for new VSCodium releases..." \
        "low"
    
    # Check for new release
    check_new_release
    local check_result=$?
    
    if [[ $check_result -eq 10 ]]; then
        log "No new release to build. Exiting."
        send_notification "INFO" "No new VSCodium release. Last built: $LAST_BUILT"
        
        # Send no-update email (optional - comment out if too many emails)
        send_email "INFO VSCodium AIX Build - No Update" \
            "No new VSCodium release available.
            
Current version: $LAST_BUILT
Checked at: $(date)" \
            "low"
        
        exit 0
    elif [[ $check_result -ne 0 ]]; then
        log "Error checking releases. Exiting."
        send_notification "ERROR" "Failed to check for new releases"
        
        send_email "ERROR VSCodium AIX Build - Check Failed" \
            "Failed to check for new releases from GitHub.
            
Please check the logs for details." \
            "high"
        
        exit 1
    fi
    
    # Run build (download + build + package all handled by build script)
    if ! run_build; then
        log "Build failed. Exiting."
        send_notification "ERROR" "Build failed for VSCodium $LATEST_TAG"
        
        send_email "ERROR VSCodium AIX Build - Build Failed" \
            "Build failed for VSCodium $LATEST_TAG
            
Please check the logs and fix any issues.
Log file: $LOG_FILE" \
            "high"
        
        exit 1
    fi
    
    # Upload release
    if ! upload_release; then
        log "Upload failed. Build was successful but upload failed."
        send_notification "WARNING" "Build successful for $LATEST_TAG but upload failed. Manual upload required."
        
        send_email "WARNING VSCodium AIX Build - Upload Failed" \
            "Build completed successfully for VSCodium $LATEST_TAG, but upload to GitHub failed.
            
The package is ready at: $PROJECT_ROOT/releases/$LATEST_TAG/
            
Please upload manually or check GitHub token permissions.
Log file: $LOG_FILE" \
            "high"
        
        exit 1
    fi
    
    # Update cache
    update_cache
    
    # Success notification
    log_section "Pipeline Complete!"
    log "Version: $LATEST_TAG"
    log "Completed at: $(date)"
    
    send_notification "SUCCESS" "VSCodium AIX Server $LATEST_TAG built and released successfully!"
    
    send_email "SUCCESS VSCodium AIX Build - Success" \
        "VSCodium AIX Server $LATEST_TAG built and released successfully!
        
Version: $LATEST_TAG
Release URL: https://github.com/tonykuttai/vscodium-aix-server/releases/tag/$LATEST_TAG

Download command:
wget https://github.com/tonykuttai/vscodium-aix-server/releases/download/$LATEST_TAG/vscodium-reh-aix-ppc64-$LATEST_TAG.tar.gz

Completed at: $(date)" \
        "normal"
    
    exit 0
}

# Trap errors
trap 'log "ERROR: Script failed at line $LINENO"; exit 1' ERR

# Run main
main "$@"