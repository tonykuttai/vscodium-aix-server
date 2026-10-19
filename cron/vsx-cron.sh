#!/usr/bin/env bash
#
# Cron entry point. Cron's environment is minimal, so set PATH explicitly and
# never rely on interactive shell files. Everything else (locking, logging,
# notifications, retention) is handled by `vsx cron`.
#
# Install (every 4 hours):
#   crontab -e
#   0 0,4,8,12,16,20 * * * /home/varghese/utility/vscodium-aix-server/cron/vsx-cron.sh
#
# Output of this wrapper itself (should normally be empty) goes to
# $VSX_STATE_DIR/logs/cron-wrapper.log; per-run logs are written by vsx.

export PATH="/opt/freeware/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/bin"
export LANG=C
export TERM=dumb

VSX_HOME="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${VSX_STATE_DIR:-$HOME/.local/state/vsx}"
mkdir -p "$STATE_DIR/logs"

exec "$VSX_HOME/bin/vsx" cron >>"$STATE_DIR/logs/cron-wrapper.log" 2>&1
