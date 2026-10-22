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

    # --- source build (the VSCodium fork that carries patches/aix + build/aix) --
    : "${VSX_FORK_REPO:=https://github.com/tonykuttai/vscodium.git}"
    # Branch to build from when no per-version tag aix/<version> exists.
    : "${VSX_FORK_REF:=aix}"
    : "${VSX_FORK_DIR:=$HOME/.cache/vsx/fork}"
    # Sourced by the build child before anything else: puts the user-local
    # Node (.nvmrc version), jq and Rust on PATH. No root on AIX hosts.
    : "${VSX_BUILD_ENV_FILE:=$HOME/local/env.sh}"
    # portlibforaix libutil for node-pty; an aix-ppc64 rg to skip the Rust build;
    # the IBM Open SDK for Rust bin dir used by build/aix/ripgrep.sh.
    : "${VSX_AIX_LIBUTIL:=$HOME/local/portlibforaix/lib/libutil.so.2}"
    : "${VSX_AIX_RIPGREP:=}"
    : "${VSX_RUST_HOME:=$HOME/local/RustSDK/1.86/bin}"
    : "${VSX_MAX_OLD_SPACE_SIZE:=8192}"

    # --- directories -------------------------------------------------------
    : "${VSX_STATE_DIR:=$HOME/.local/state/vsx}"
    : "${VSX_CACHE_DIR:=$HOME/.cache/vsx}"
    : "${VSX_RELEASES_DIR:=$VSX_HOME/releases}"
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

    # --- smoke test (build/aix/verify_reh.sh timeout, seconds) ---------------
    : "${VSX_SMOKE_TIMEOUT:=240}"

    export VSX_UPSTREAM_REPO VSX_RELEASE_REPO VSX_GITHUB_TOKEN_FILE
    export VSX_BACKFILL_FLOOR VSX_MAX_ATTEMPTS VSX_RETRY_AFTER_HOURS
    export VSX_FORK_REPO VSX_FORK_REF VSX_FORK_DIR VSX_BUILD_ENV_FILE
    export VSX_AIX_LIBUTIL VSX_AIX_RIPGREP VSX_RUST_HOME VSX_MAX_OLD_SPACE_SIZE
    export VSX_STATE_DIR VSX_CACHE_DIR VSX_RELEASES_DIR VSX_FREEWARE_BIN
    export VSX_KEEP_RELEASES VSX_KEEP_LOGS
    export VSX_EMAIL_TO VSX_EMAIL_FROM VSX_EMAIL_ENABLED VSX_ISSUES_ENABLED VSX_ISSUE_LABEL VSX_DIGEST_ENABLED
    export VSX_SMOKE_TIMEOUT

    # Derived
    VSX_LOG_DIR="$VSX_STATE_DIR/logs"
    VSX_WORK_DIR="$VSX_CACHE_DIR/work"
    VSX_DOWNLOADS_DIR="$VSX_CACHE_DIR/downloads"
    # Target Node runtime trees (headers + node.exp) fetched by build/aix/package_reh.sh
    VSX_NODE_CACHE_DIR="$VSX_CACHE_DIR/node"
    VSX_EVENTS_FILE="$VSX_STATE_DIR/events.jsonl"
    VSX_ATTEMPTS_DIR="$VSX_STATE_DIR/attempts"
    export VSX_LOG_DIR VSX_WORK_DIR VSX_DOWNLOADS_DIR VSX_NODE_CACHE_DIR
    export VSX_EVENTS_FILE VSX_ATTEMPTS_DIR

    mkdir -p "$VSX_STATE_DIR" "$VSX_LOG_DIR" "$VSX_WORK_DIR" "$VSX_DOWNLOADS_DIR" \
             "$VSX_NODE_CACHE_DIR" "$VSX_ATTEMPTS_DIR" "$VSX_RELEASES_DIR"
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
