#!/usr/bin/env bash
# lib/env.sh - AIX host environment: PATH, GNU tools, toolchain facts,
# GitHub token. Everything about Node runtimes and native addons moved to the
# VSCodium fork (build/aix); the runner only needs to find the tools.

[[ -n "${__vsx_loaded_env:-}" ]] && return 0
__vsx_loaded_env=1

#-----------------------------------------------------------------------------
# PATH and GNU userland. AIX's own grep/sed/tar lack the flags we use; the
# AIX Toolbox puts GNU versions in /opt/freeware/bin.
#-----------------------------------------------------------------------------
env_setup_path() {
    local extra="$VSX_FREEWARE_BIN:$HOME/local/bin:$HOME/.local/bin"
    case ":$PATH:" in
        *":$VSX_FREEWARE_BIN:"*) ;;
        *) export PATH="$extra:$PATH" ;;
    esac
    export npm_config_cache="$VSX_CACHE_DIR/npm"
    export npm_config_update_notifier=false
    export npm_config_fund=false
    export npm_config_audit=false
    export TERM="${TERM:-dumb}"
    export LANG="${LANG:-C}"
}

_is_gnu() { "$1" --version 2>/dev/null | head -1 | grep -q 'GNU\|Free Software'; }

env_check_gnu_tools() {
    local t bad=()
    for t in grep sed tar sort; do
        _is_gnu "$t" || bad+=("$t")
    done
    if (( ${#bad[@]} > 0 )); then
        die "GNU versions required but not first in PATH for: ${bad[*]} (install AIX Toolbox coreutils/grep/sed/tar, PATH=$PATH)"
    fi
}

#-----------------------------------------------------------------------------
# Toolchain facts for reports and the manifest.
#-----------------------------------------------------------------------------
env_detect_toolchain() {
    VSX_GCC_VERSION=$(gcc -dumpversion 2>/dev/null || echo "")
    VSX_GCC_MACHINE=$(gcc -dumpmachine 2>/dev/null || echo "")
    VSX_PYTHON_VERSION=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "")
    VSX_GIT_VERSION=$(git --version 2>/dev/null | awk '{print $3}' || echo "")
    VSX_OS_LEVEL=$(oslevel -s 2>/dev/null || uname -sr)
    # Rust comes from the user-local IBM Open SDK (VSX_RUST_HOME) when present.
    VSX_RUSTC_VERSION=$( { [[ -x "$VSX_RUST_HOME/rustc" ]] && "$VSX_RUST_HOME/rustc" --version || rustc --version; } 2>/dev/null | awk '{print $2}' || echo "")
    export VSX_GCC_VERSION VSX_GCC_MACHINE VSX_PYTHON_VERSION VSX_GIT_VERSION VSX_OS_LEVEL VSX_RUSTC_VERSION
}

# env_build_tools_report : what the build child will see after sourcing
# VSX_BUILD_ENV_FILE. Prints "tool: version|MISSING" lines; returns 1 if any
# required tool is missing.
env_build_tools_report() {
    local rc=0 t line
    while IFS= read -r line; do
        echo "$line"
        [[ "$line" == *MISSING* ]] && rc=1
    done < <(
        set +eu
        # shellcheck disable=SC1090
        [[ -f "$VSX_BUILD_ENV_FILE" ]] && . "$VSX_BUILD_ENV_FILE" 2>/dev/null
        for t in node npm jq git gcc g++ gmake python3 patch curl tar sha256sum; do
            if command -v "$t" >/dev/null 2>&1; then
                case "$t" in
                    npm) printf '%s: %s\n' "$t" "$(command -v npm)" ;;   # never `npm --version` on the host's /opt/nodejs npm
                    *)   printf '%s: %s\n' "$t" "$("$t" --version 2>&1 | head -1)" ;;
                esac
            else
                printf '%s: MISSING\n' "$t"
            fi
        done
        if [[ -x "$VSX_RUST_HOME/cargo" ]] || command -v cargo >/dev/null 2>&1; then
            printf 'cargo: %s\n' "$( { [[ -x "$VSX_RUST_HOME/cargo" ]] && "$VSX_RUST_HOME/cargo" --version || cargo --version; } 2>&1 | head -1)"
        elif [[ -n "${VSX_AIX_RIPGREP:-}" && -x "$VSX_AIX_RIPGREP" ]]; then
            printf 'cargo: not needed (VSX_AIX_RIPGREP=%s)\n' "$VSX_AIX_RIPGREP"
        else
            printf 'cargo: MISSING (ripgrep needs the IBM Open SDK for Rust, or set VSX_AIX_RIPGREP)\n'
        fi
        [[ -f "${VSX_AIX_LIBUTIL:-/nonexistent}" ]] && printf 'libutil (portlibforaix): %s\n' "$VSX_AIX_LIBUTIL" || printf 'libutil (portlibforaix): MISSING at %s\n' "${VSX_AIX_LIBUTIL:-unset}"
    )
    return $rc
}

env_require_build_tools() {
    require_cmd git gcc g++ gmake python3 curl tar file sha256sum patch
    [[ "$(uname -s)" == "AIX" ]] || die "builds must run on an AIX host (this is $(uname -s))"
    env_build_tools_report >/dev/null || die "build tools missing; run 'vsx check'"
}

#-----------------------------------------------------------------------------
# GitHub token
#-----------------------------------------------------------------------------
env_load_github_token() {
    local f
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        for f in "$VSX_GITHUB_TOKEN_FILE" "$HOME/.config/vscodium-aix/github-token"; do
            if [[ -s "$f" ]]; then
                GITHUB_TOKEN=$(tr -d '[:space:]' <"$f")
                export GITHUB_TOKEN
                break
            fi
        done
    fi
    [[ -n "${GITHUB_TOKEN:-}" ]]
}

env_report() {
    echo "host:    $(hostname) $(uname -s) $(uname -m) $VSX_OS_LEVEL"
    echo "gcc:     ${VSX_GCC_VERSION:-missing} ($VSX_GCC_MACHINE)"
    echo "rustc:   ${VSX_RUSTC_VERSION:-missing}"
    echo "python3: ${VSX_PYTHON_VERSION:-missing}  git: ${VSX_GIT_VERSION:-missing}"
    echo "fork:    $VSX_FORK_REPO @ $VSX_FORK_REF -> $VSX_FORK_DIR"
    echo "build env file: $VSX_BUILD_ENV_FILE$([[ -f "$VSX_BUILD_ENV_FILE" ]] || echo ' (MISSING)')"
}
