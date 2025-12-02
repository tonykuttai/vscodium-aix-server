#!/bin/bash
# cron-wrapper.sh - Wrapper for cron job execution
# Running every 4 hours
# $ crontab -e 
# 0 0,4,8,12,16,20 * * * /home/varghese/utility/vscodium-aix-server/scripts/cron-wrapper.sh
# crontab -l

# Source profile to get environment variables
if [[ -f "$HOME/.profile" ]]; then
    source "$HOME/.profile"
fi

if [[ -f "$HOME/.bashrc" ]]; then
    source "$HOME/.bashrc"
fi

# Set working directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Run the main script
bash auto-build-release.sh >> "$HOME/.vscodium-build-cache/logs/cron-wrapper.log" 2>&1

exit $?
