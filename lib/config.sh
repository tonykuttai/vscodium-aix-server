#!/usr/bin/env bash
# lib/config.sh - defaults, config file loading, derived directories.
#
# Precedence (highest first):
#   1. environment variables already set (VSX_*)
#   2. $VSX_CONFIG file, else ~/.config/vsx/vsx.conf
#   3. defaults below
#
# See config/vsx.conf.example for documentation of every setting.

[[ -n "${__vsx_loaded_config:-}" ]] && return 0
__vsx_loaded_config=1

config_load() {
    local file="${VSX_CONFIG:-$HOME/.config/vsx/vsx.conf}"
    if [[ -f "$file" ]]; then
        # Plain KEY=value lines (shell syntax, so $HOME etc. expand). A key
        # already present in the environment wins over the file, which lets
        # `VSX_X=... vsx ...` override settings for one run and lets child
        # processes inherit the parent's effective settings.
        local line key
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(VSX_[A-Z0-9_]+)= ]] || continue
            key=${BASH_REMATCH[1]}
            [[ -n "${!key:-}" ]] && continue
            eval "$line"
        done <"$file"
        VSX_CONFIG_FILE="$file"
    else
        VSX_CONFIG_FILE=""
    fi

    # --- repositories ------------------------------------------------------
    : "${VSX_UPSTREAM_REPO:=VSCodium/vscodium}"
    : "${VSX_RELEASE_REPO:=tonykuttai/vscodium-aix-server}"
    : "${VSX_GITHUB_TOKEN_FILE:=$HOME/.config/github/token}"

    # --- what to build -----------------------------------------------------
    # Oldest upstream version `vsx build --missing` will consider.
    : "${VSX_BACKFILL_FLOOR:=1.126.04524}"
    # Give up on a version after this many failed attempts (until --retry).
    : "${VSX_MAX_ATTEMPTS:=3}"
    # Hours to wait before automatically retrying a failed version.
    : "${VSX_RETRY_AFTER_HOURS:=24}"

    # --- node runtime ------------------------------------------------------
    # bundle : download the official nodejs.org AIX build that matches the
    #          Node major upstream targets, compile addons against it, and
    #          ship it inside the tarball as $ROOT/node (self-contained).
    # host   : build against and dispatch to VSX_HOST_NODE (legacy layout).
    : "${VSX_NODE_RUNTIME:=bundle}"
    : "${VSX_HOST_NODE:=/opt/nodejs/bin/node}"
    : "${VSX_NODE_DIST_URL:=https://nodejs.org/dist}"
    # Used only if upstream's required Node version cannot be determined.
    : "${VSX_NODE_FALLBACK_VERSION:=24.21.0}"

    # --- directories -------------------------------------------------------
    : "${VSX_STATE_DIR:=$HOME/.local/state/vsx}"
    : "${VSX_CACHE_DIR:=$HOME/.cache/vsx}"
    : "${VSX_RELEASES_DIR:=$VSX_HOME/releases}"
    : "${VSX_PORTLIB_DIR:=$HOME/local/portlibforaix}"
    : "${VSX_FREEWARE_BIN:=/opt/freeware/bin}"

    # --- retention ---------------------------------------------------------
    : "${VSX_KEEP_RELEASES:=3}"
    : "${VSX_KEEP_LOGS:=40}"

    # --- notifications -----------------------------------------------------
    : "${VSX_EMAIL_TO:=}"
    : "${VSX_EMAIL_FROM:=vsx@$(hostname)}"
    : "${VSX_EMAIL_ENABLED:=true}"
    : "${VSX_ISSUES_ENABLED:=true}"
    : "${VSX_ISSUE_LABEL:=build-failure}"
    : "${VSX_DIGEST_ENABLED:=true}"

    # --- smoke test --------------------------------------------------------
    : "${VSX_SMOKE_TIMEOUT:=120}"

    # --- module sources (override to point at forks) -----------------------
    : "${VSX_REPO_NODE_PTY:=https://github.com/microsoft/node-pty.git}"
    : "${VSX_REPO_SPDLOG:=https://github.com/microsoft/node-spdlog.git}"
    : "${VSX_REPO_WATCHDOG:=https://github.com/microsoft/node-native-watchdog.git}"
    : "${VSX_REPO_PARCEL_WATCHER:=https://github.com/parcel-bundler/watcher.git}"
    : "${VSX_REPO_RIPGREP:=https://github.com/BurntSushi/ripgrep.git}"
    : "${VSX_REPO_MEMMAP2:=https://github.com/RazrFalcon/memmap2-rs.git}"
    : "${VSX_REPO_PORTLIB:=https://github.com/tonykuttai/portlibforaix.git}"
    : "${VSX_RIPGREP_FALLBACK_TAG:=15.0.0}"

    export VSX_UPSTREAM_REPO VSX_RELEASE_REPO VSX_GITHUB_TOKEN_FILE
    export VSX_BACKFILL_FLOOR VSX_MAX_ATTEMPTS VSX_RETRY_AFTER_HOURS
    export VSX_NODE_RUNTIME VSX_HOST_NODE VSX_NODE_DIST_URL VSX_NODE_FALLBACK_VERSION
    export VSX_STATE_DIR VSX_CACHE_DIR VSX_RELEASES_DIR VSX_PORTLIB_DIR VSX_FREEWARE_BIN
    export VSX_KEEP_RELEASES VSX_KEEP_LOGS
    export VSX_EMAIL_TO VSX_EMAIL_FROM VSX_EMAIL_ENABLED VSX_ISSUES_ENABLED VSX_ISSUE_LABEL VSX_DIGEST_ENABLED
    export VSX_SMOKE_TIMEOUT
    export VSX_REPO_NODE_PTY VSX_REPO_SPDLOG VSX_REPO_WATCHDOG VSX_REPO_PARCEL_WATCHER
    export VSX_REPO_RIPGREP VSX_REPO_MEMMAP2 VSX_REPO_PORTLIB VSX_RIPGREP_FALLBACK_TAG

    # Derived
    VSX_LOG_DIR="$VSX_STATE_DIR/logs"
    VSX_WORK_DIR="$VSX_CACHE_DIR/work"
    VSX_DOWNLOADS_DIR="$VSX_CACHE_DIR/downloads"
    VSX_NODE_CACHE_DIR="$VSX_CACHE_DIR/node"
    VSX_MODULE_CACHE_DIR="$VSX_CACHE_DIR/modules"
    VSX_EVENTS_FILE="$VSX_STATE_DIR/events.jsonl"
    VSX_ATTEMPTS_DIR="$VSX_STATE_DIR/attempts"
    export VSX_LOG_DIR VSX_WORK_DIR VSX_DOWNLOADS_DIR VSX_NODE_CACHE_DIR VSX_MODULE_CACHE_DIR
    export VSX_EVENTS_FILE VSX_ATTEMPTS_DIR

    mkdir -p "$VSX_STATE_DIR" "$VSX_LOG_DIR" "$VSX_WORK_DIR" "$VSX_DOWNLOADS_DIR" \
             "$VSX_NODE_CACHE_DIR" "$VSX_MODULE_CACHE_DIR" "$VSX_ATTEMPTS_DIR" "$VSX_RELEASES_DIR"
}

config_show() {
    local v
    echo "config file: ${VSX_CONFIG_FILE:-<none, defaults>}"
    for v in $(compgen -v VSX_ | sort); do
        case "$v" in
            VSX_GITHUB_TOKEN) continue ;;
        esac
        printf '  %-28s %s\n' "$v" "${!v}"
    done
}
