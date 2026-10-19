#!/usr/bin/env bash
# lib/env.sh - AIX host environment: PATH, GNU tools, toolchain discovery,
# GitHub token, portlibforaix, and the Node runtime used for building.

[[ -n "${__vsx_loaded_env:-}" ]] && return 0
__vsx_loaded_env=1

#-----------------------------------------------------------------------------
# PATH and GNU userland. AIX's own grep/sed/tar lack the flags we use; the
# AIX Toolbox puts GNU versions in /opt/freeware/bin.
#-----------------------------------------------------------------------------
env_setup_path() {
    local extra="$VSX_FREEWARE_BIN:$HOME/.local/node_modules/.bin:$HOME/.local/bin"
    case ":$PATH:" in
        *":$VSX_FREEWARE_BIN:"*) ;;
        *) export PATH="$extra:$PATH" ;;
    esac
    # Never let an interactive npm/yarn config surprise us.
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
# Toolchain facts, exported for module builders and reports.
#-----------------------------------------------------------------------------
env_detect_toolchain() {
    VSX_GCC_VERSION=$(gcc -dumpversion 2>/dev/null || echo "")
    VSX_GCC_MACHINE=$(gcc -dumpmachine 2>/dev/null || echo "")
    VSX_RUSTC_VERSION=$(rustc --version 2>/dev/null | awk '{print $2}' || echo "")
    VSX_CARGO_VERSION=$(cargo --version 2>/dev/null | awk '{print $2}' || echo "")
    VSX_PYTHON_VERSION=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "")
    VSX_GIT_VERSION=$(git --version 2>/dev/null | awk '{print $3}' || echo "")
    VSX_OS_LEVEL=$(oslevel -s 2>/dev/null || uname -sr)
    export VSX_GCC_VERSION VSX_GCC_MACHINE VSX_RUSTC_VERSION VSX_CARGO_VERSION
    export VSX_PYTHON_VERSION VSX_GIT_VERSION VSX_OS_LEVEL

    # The GCC runtime directory that must be on LIBPATH for libstdc++ users.
    VSX_GCC_LIBPATH=""
    local base
    for base in /opt/freeware/lib/gcc /usr/local/lib/gcc /usr/lib/gcc; do
        for cand in "$base/$VSX_GCC_MACHINE/$VSX_GCC_VERSION/pthread/ppc64" \
                    "$base/$VSX_GCC_MACHINE/$VSX_GCC_VERSION/ppc64" \
                    "$base/$VSX_GCC_MACHINE/$VSX_GCC_VERSION"; do
            if [[ -d "$cand" ]]; then VSX_GCC_LIBPATH="$cand"; break 2; fi
        done
    done
    export VSX_GCC_LIBPATH
}

# Compiler flags every C/C++ addon needs on AIX with GCC.
env_export_compiler_flags() {
    export CC=gcc CXX=g++
    export CFLAGS="-ftls-model=global-dynamic -fPIC -pthread"
    export CXXFLAGS="-ftls-model=global-dynamic -fPIC -pthread"
}

env_require_build_tools() {
    require_cmd git gcc g++ gmake python3 curl tar file sha256sum
    [[ "$(uname -s)" == "AIX" ]] || die "builds must run on an AIX host (this is $(uname -s))"
}

env_require_rust() {
    require_cmd cargo rustc
}

#-----------------------------------------------------------------------------
# GitHub token
#-----------------------------------------------------------------------------
env_load_github_token() {
    if [[ -z "${GITHUB_TOKEN:-}" && -f "$VSX_GITHUB_TOKEN_FILE" ]]; then
        GITHUB_TOKEN=$(tr -d '[:space:]' <"$VSX_GITHUB_TOKEN_FILE")
        export GITHUB_TOKEN
    fi
    [[ -n "${GITHUB_TOKEN:-}" ]]
}

#-----------------------------------------------------------------------------
# portlibforaix provides openpty/forkpty/login_tty (libutil.so.2) for node-pty.
#-----------------------------------------------------------------------------
env_ensure_portlib() {
    local lib="$VSX_PORTLIB_DIR/lib/libutil.so.2"
    if [[ -f "$lib" ]]; then
        return 0
    fi
    section "Installing portlibforaix into $VSX_PORTLIB_DIR"
    local tmp="$VSX_WORK_DIR/portlibforaix"
    rm -rf "$tmp"
    git clone -q "$VSX_REPO_PORTLIB" "$tmp"
    mkdir -p "$VSX_PORTLIB_DIR/lib" "$VSX_PORTLIB_DIR/include"
    (cd "$tmp" && gmake && gmake install) || die "portlibforaix build failed"
    [[ -f "$lib" ]] || die "portlibforaix did not produce $lib"
    rm -rf "$tmp"
}

#-----------------------------------------------------------------------------
# Node runtime for building (and, in bundle mode, for shipping).
#
# After node_runtime_select, these are exported:
#   VSX_NODE_HOME     root of the runtime (has bin/ include/ lib/)
#   VSX_NODE_BIN      path to the node executable
#   VSX_NODE_VERSION  e.g. 24.21.0
#   VSX_NODE_ABI      process.versions.modules, e.g. 137
#   VSX_NPM_CLI       path to npm-cli.js (run with VSX_NODE_BIN)
#   VSX_NODE_GYP      path to node-gyp.js  (run with VSX_NODE_BIN)
#   VSX_NODE_INCLUDE  include/node directory with headers
#   VSX_NODE_EXP      node.exp import file for -Wl,-bimport
#-----------------------------------------------------------------------------

# node_required_version VSCODIUM_VERSION : print the Node version upstream
# targets for that release (from microsoft/vscode remote/.npmrc), or empty.
node_required_version() {
    local vscodium_version=$1
    local vscode_tag
    vscode_tag=$(vscode_tag_for "$vscodium_version")
    local npmrc
    npmrc=$(curl -fsSL --retry 2 "https://raw.githubusercontent.com/microsoft/vscode/$vscode_tag/remote/.npmrc" 2>/dev/null || true)
    printf '%s\n' "$npmrc" | grep -E '^target=' | head -1 | cut -d'"' -f2
}

# vscode_tag_for 1.140.06880 -> 1.140.0 ; 1.105.16999 -> 1.105.1
# VSCodium encodes the VS Code patch level as the first digit of its build
# number.
vscode_tag_for() {
    local v=$1
    local major minor build
    IFS=. read -r major minor build <<<"$v"
    printf '%s.%s.%s\n' "$major" "$minor" "${build:0:1}"
}

# node_pick_available WANTED : print the nodejs.org version that has an
# aix-ppc64 tarball: WANTED itself if available, else the newest in the same
# major line.
node_pick_available() {
    local wanted=$1
    local major=${wanted%%.*}
    local index="$VSX_DOWNLOADS_DIR/nodejs-index.json"
    # Refresh the index at most once a day (python: AIX find has no -mmin).
    if [[ ! -f "$index" ]] || ! python3 -c 'import os,sys,time; sys.exit(0 if time.time()-os.path.getmtime(sys.argv[1]) < 86400 else 1)' "$index"; then
        curl -fsSL --retry 2 "$VSX_NODE_DIST_URL/index.json" -o "$index.tmp" && mv "$index.tmp" "$index" || true
    fi
    [[ -f "$index" ]] || return 1
    jpy "
have = [e['version'][1:] for e in d if 'aix-ppc64' in e.get('files', [])]
w = '$wanted'
if w in have:
    print(w)
else:
    same = [v for v in have if v.split('.')[0] == '$major']
    if same:
        same.sort(key=lambda s: [int(x) for x in s.split('.')])
        print(same[-1])
" <"$index" | head -1
}

# node_runtime_install VERSION : download + verify + extract into the cache.
# Prints VSX_NODE_HOME.
node_runtime_install() {
    local version=$1
    local name="node-v$version-aix-ppc64"
    local home="$VSX_NODE_CACHE_DIR/$name"
    if [[ -x "$home/bin/node" && -f "$home/.complete" ]]; then
        printf '%s\n' "$home"
        return 0
    fi
    section "Installing Node.js v$version (official aix-ppc64 build) into cache"
    local tarball="$VSX_DOWNLOADS_DIR/$name.tar.gz"
    local sums="$VSX_DOWNLOADS_DIR/$name.SHASUMS256.txt"
    if [[ ! -f "$tarball" ]]; then
        curl -fsSL --retry 3 -o "$tarball.part" "$VSX_NODE_DIST_URL/v$version/$name.tar.gz"
        mv "$tarball.part" "$tarball"
    fi
    curl -fsSL --retry 3 -o "$sums" "$VSX_NODE_DIST_URL/v$version/SHASUMS256.txt"
    (cd "$VSX_DOWNLOADS_DIR" && grep " $name.tar.gz\$" "$sums" | sha256sum -c - >/dev/null) \
        || die "checksum mismatch for $tarball"
    rm -rf "$home"
    tar -xzf "$tarball" -C "$VSX_NODE_CACHE_DIR"
    [[ -x "$home/bin/node" ]] || die "extracted Node runtime has no bin/node: $home"
    "$home/bin/node" -e 'process.exit(0)' || die "downloaded node does not run on this host"
    touch "$home/.complete"
    printf '%s\n' "$home"
}

# node_runtime_select VSCODIUM_VERSION : decide which Node to build with and
# export the VSX_NODE_* variables.
node_runtime_select() {
    local vscodium_version=$1
    local home
    if [[ "$VSX_NODE_RUNTIME" == "host" ]]; then
        [[ -x "$VSX_HOST_NODE" ]] || die "VSX_HOST_NODE not executable: $VSX_HOST_NODE"
        home=$(cd "$(dirname "$VSX_HOST_NODE")/.." && pwd)
        VSX_NODE_SOURCE="host"
    else
        local wanted picked
        wanted=$(node_required_version "$vscodium_version" || true)
        if [[ -z "$wanted" ]]; then
            warn "could not determine upstream Node version for $vscodium_version; using fallback $VSX_NODE_FALLBACK_VERSION"
            wanted="$VSX_NODE_FALLBACK_VERSION"
        fi
        picked=$(node_pick_available "$wanted" || true)
        if [[ -z "$picked" ]]; then
            die "no official aix-ppc64 Node build found for $wanted (major ${wanted%%.*}) at $VSX_NODE_DIST_URL"
        fi
        if [[ "$picked" != "$wanted" ]]; then
            info "upstream targets Node $wanted; nearest aix-ppc64 build is $picked"
        fi
        home=$(node_runtime_install "$picked")
        VSX_NODE_SOURCE="bundle"
        VSX_NODE_UPSTREAM_TARGET="$wanted"
    fi

    VSX_NODE_HOME="$home"
    VSX_NODE_BIN="$home/bin/node"
    VSX_NODE_VERSION=$("$VSX_NODE_BIN" -p 'process.versions.node')
    VSX_NODE_ABI=$("$VSX_NODE_BIN" -p 'process.versions.modules')
    VSX_NODE_INCLUDE="$home/include/node"
    VSX_NODE_EXP="$home/include/node/node.exp"
    VSX_NPM_CLI="$home/lib/node_modules/npm/bin/npm-cli.js"
    VSX_NODE_GYP="$home/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js"
    [[ -f "$VSX_NODE_INCLUDE/node_api.h" ]] || die "Node headers missing: $VSX_NODE_INCLUDE"
    [[ -f "$VSX_NODE_EXP" ]] || die "node.exp missing: $VSX_NODE_EXP"
    [[ -f "$VSX_NPM_CLI" ]] || die "npm not found inside Node runtime: $VSX_NPM_CLI"
    [[ -f "$VSX_NODE_GYP" ]] || die "node-gyp not found inside npm: $VSX_NODE_GYP"
    export VSX_NODE_HOME VSX_NODE_BIN VSX_NODE_VERSION VSX_NODE_ABI VSX_NODE_INCLUDE VSX_NODE_EXP
    export VSX_NPM_CLI VSX_NODE_GYP VSX_NODE_SOURCE
    export VSX_NODE_UPSTREAM_TARGET="${VSX_NODE_UPSTREAM_TARGET:-}"
    # Put the selected runtime first so plain `node` inside builders is it.
    export PATH="$home/bin:$PATH"
    info "Node runtime: v$VSX_NODE_VERSION (ABI $VSX_NODE_ABI, $VSX_NODE_SOURCE) at $home"
}

# Wrappers so module builders never call a global npm/node-gyp.
# NOTE: never run `npm --version` on AIX hosts; the IBM SDK npm is known to
# crash on it. Existence checks only.
vsx_npm()      { "$VSX_NODE_BIN" "$VSX_NPM_CLI" "$@"; }
vsx_node_gyp() { "$VSX_NODE_BIN" "$VSX_NODE_GYP" --nodedir="$VSX_NODE_HOME" "$@"; }

# Verify a built addon is an AIX XCOFF object and loads under our runtime.
verify_addon() {
    local file=$1
    local libpath_extra=${2:-}
    [[ -f "$file" ]] || { error "addon missing: $file"; return 1; }
    # require() needs an absolute path; a bare relative path is a module name.
    file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    local ft
    ft=$(file "$file")
    if ! grep -q 'XCOFF' <<<"$ft"; then
        error "not an AIX XCOFF object: $file ($ft)"
        return 1
    fi
    if ! LIBPATH="${libpath_extra:+$libpath_extra:}${VSX_GCC_LIBPATH:+$VSX_GCC_LIBPATH:}${LIBPATH:-}" \
         "$VSX_NODE_BIN" -e "require(process.argv[1])" "$file" >/dev/null 2>&1; then
        error "addon failed to load under node v$VSX_NODE_VERSION: $file"
        LIBPATH="${libpath_extra:+$libpath_extra:}${VSX_GCC_LIBPATH:+$VSX_GCC_LIBPATH:}${LIBPATH:-}" \
            "$VSX_NODE_BIN" -e "require(process.argv[1])" "$file" 2>&1 | tail -5 >&2 || true
        return 1
    fi
    return 0
}

env_report() {
    echo "Host:      $(uname -s) $(uname -m) ($VSX_OS_LEVEL)"
    echo "GCC:       ${VSX_GCC_VERSION:-missing} ($VSX_GCC_MACHINE) runtime: ${VSX_GCC_LIBPATH:-not found}"
    echo "Rust:      rustc ${VSX_RUSTC_VERSION:-missing}, cargo ${VSX_CARGO_VERSION:-missing}"
    echo "Python:    ${VSX_PYTHON_VERSION:-missing}"
    echo "Git:       ${VSX_GIT_VERSION:-missing}"
    echo "Host node: $([[ -x "$VSX_HOST_NODE" ]] && "$VSX_HOST_NODE" --version || echo missing) ($VSX_HOST_NODE)"
    echo "portlib:   $([[ -f "$VSX_PORTLIB_DIR/lib/libutil.so.2" ]] && echo installed || echo missing) ($VSX_PORTLIB_DIR)"
    echo "mailx:     $(have mailx && echo yes || echo no)"
    echo "GH token:  $(env_load_github_token && echo present || echo MISSING)"
    echo "Node mode: $VSX_NODE_RUNTIME"
    echo "Cached node runtimes: $(ls -1 "$VSX_NODE_CACHE_DIR" 2>/dev/null | tr '\n' ' ')"
}
