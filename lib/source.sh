#!/usr/bin/env bash
# lib/source.sh - build the server from source with the VSCodium fork.
#
# The fork (VSX_FORK_REPO, branch/tag VSX_FORK_REF, default `aix`) carries
# VSCodium plus patches/aix and build/aix. For version V the runner:
#   1. fork_sync            : clone/fetch the fork into $VSX_FORK_DIR
#   2. fork_ref_for V       : pick the commit to build from (tag aix/V if it
#                             exists, else VSX_FORK_REF whose upstream/stable.json
#                             must name V's VS Code tag)
#   3. source_worktree V    : git worktree at $VSX_WORK_DIR/V/vscodium
#   4. source_build V       : get_repo.sh -> prepare_vscode.sh (SKIP_NPM_INSTALL)
#                             -> build/aix/package_reh.sh, in a child bash with
#                             the host's build environment (VSX_BUILD_ENV_FILE)
#   5. source_package V     : releases/V/vscodium-reh-aix-ppc64-V.tar.gz with
#                             the commit id as the single top-level directory
#                             (the AIX extension's native-tar path needs one),
#                             plus .sha256 / .info / .json
# Nothing in this file knows how to build a native addon; that lives in the fork.

[[ -n "${__vsx_loaded_source:-}" ]] && return 0
__vsx_loaded_source=1

work_tree_for() { printf '%s/%s/vscodium\n' "$VSX_WORK_DIR" "$1"; }
reh_dir_for()   { printf '%s/%s/vscodium/vscode-reh-aix-ppc64\n' "$VSX_WORK_DIR" "$1"; }

# vscode_tag_for 1.140.06880 -> 1.140.0 ; 1.105.16999 -> 1.105.1
# VSCodium encodes the VS Code patch level as the first digit of its build number.
vscode_tag_for() {
    local v=$1
    [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9])[0-9]*$ ]] || die "not a VSCodium version: $v"
    printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

#-----------------------------------------------------------------------------
# fork checkout
#-----------------------------------------------------------------------------
fork_sync() {
    if [[ ! -d "$VSX_FORK_DIR/.git" ]]; then
        section "Cloning $VSX_FORK_REPO into $VSX_FORK_DIR"
        git clone -q "$VSX_FORK_REPO" "$VSX_FORK_DIR" || die "cannot clone $VSX_FORK_REPO"
    fi
    git -C "$VSX_FORK_DIR" fetch -q --prune --tags origin || die "cannot fetch $VSX_FORK_REPO"
    git -C "$VSX_FORK_DIR" worktree prune 2>/dev/null || true
}

# fork_ref_for VERSION : print "<commit> <refname>" to build VERSION from.
fork_ref_for() {
    local version=$1 tag="aix/$1" commit ref
    if git -C "$VSX_FORK_DIR" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null 2>&1; then
        commit=$(git -C "$VSX_FORK_DIR" rev-parse "refs/tags/$tag^{commit}")
        ref=$tag
    else
        commit=$(git -C "$VSX_FORK_DIR" rev-parse -q --verify "origin/$VSX_FORK_REF^{commit}" 2>/dev/null) \
            || commit=$(git -C "$VSX_FORK_DIR" rev-parse -q --verify "$VSX_FORK_REF^{commit}" 2>/dev/null) \
            || die "fork ref not found: $VSX_FORK_REF (and no tag $tag)"
        ref=$VSX_FORK_REF
    fi
    printf '%s %s\n' "$commit" "$ref"
}

# source_worktree VERSION COMMIT : fresh detached worktree for this build.
source_worktree() {
    local version=$1 commit=$2 tree
    tree=$(work_tree_for "$version")
    if [[ -d "$tree" ]]; then
        git -C "$VSX_FORK_DIR" worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
    fi
    mkdir -p "$(dirname "$tree")"
    git -C "$VSX_FORK_DIR" worktree add -q --detach "$tree" "$commit" || die "cannot create worktree $tree"
    # The fork's stable.json must describe the VS Code release this version is built from,
    # unless a per-version tag (aix/VERSION) was used, which is correct by construction.
    local want have
    want=$(vscode_tag_for "$version")
    have=$(jpy 'd.get("tag","")' <"$tree/upstream/stable.json" 2>/dev/null || true)
    if [[ "$have" != "$want" ]]; then
        die "fork ref $commit has upstream/stable.json tag '$have' but $version needs '$want'. Rebase the aix branch onto VSCodium tag $version and tag it aix/$version."
    fi
    printf '%s\n' "$tree"
}

source_worktree_remove() {
    local version=$1 tree
    tree=$(work_tree_for "$version")
    [[ -d "$tree" ]] || return 0
    git -C "$VSX_FORK_DIR" worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
    git -C "$VSX_FORK_DIR" worktree prune 2>/dev/null || true
}

#-----------------------------------------------------------------------------
# the build itself
#-----------------------------------------------------------------------------
# source_build VERSION TREE : runs VSCodium's scripts and the fork's AIX
# packaging in a child bash. The child sources VSX_BUILD_ENV_FILE first
# (user-local Node/jq/Rust on PATH) and never inherits a runtime LIBPATH: the
# Toolbox compiler binaries are 32-bit and the 64-bit runtime dirs break them.
source_build() {
    local version=$1 tree=$2
    section "Source build of VSCodium $version (fork worktree $tree)"
    local -a envs=(
        "RELEASE_VERSION=$version"
        "OS_NAME=aix" "VSCODE_QUALITY=stable" "CI_BUILD=no"
        "MAX_OLD_SPACE_SIZE=${VSX_MAX_OLD_SPACE_SIZE}"
        "SHOULD_BUILD_REH=yes" "SHOULD_BUILD_REH_WEB=no"
        "VSCODE_AIX_NODE_CACHE=$VSX_NODE_CACHE_DIR"
        "VSCODE_AIX_RG_CACHE=$VSX_CACHE_DIR/ripgrep"
        "VSX_BUILD_ENV_FILE=$VSX_BUILD_ENV_FILE"
    )
    [[ -n "${VSX_AIX_LIBUTIL:-}" ]]  && envs+=("VSCODE_AIX_LIBUTIL=$VSX_AIX_LIBUTIL")
    [[ -n "${VSX_AIX_RIPGREP:-}" ]]  && envs+=("VSCODE_AIX_RIPGREP=$VSX_AIX_RIPGREP")
    [[ -n "${VSX_RUST_HOME:-}" ]]    && envs+=("VSCODE_AIX_RUST_HOME=$VSX_RUST_HOME")
    [[ -n "${GITHUB_TOKEN:-}" ]]     && envs+=("GITHUB_TOKEN=$GITHUB_TOKEN")

    env -u LIBPATH "${envs[@]}" bash -c '
        set -eo pipefail
        if [[ -f "$VSX_BUILD_ENV_FILE" ]]; then
            # shellcheck disable=SC1090
            . "$VSX_BUILD_ENV_FILE"
        fi
        unset LIBPATH
        cd "$1"
        for t in node npm jq git gcc g++ gmake python3; do
            command -v "$t" >/dev/null || { echo "source_build: $t not on PATH after sourcing $VSX_BUILD_ENV_FILE" >&2; exit 2; }
        done
        echo "node $(node --version) npm $(npm --version 2>/dev/null || echo ?) jq $(jq --version)"
        echo "=== get_repo.sh";        . ./get_repo.sh
        echo "=== version.sh";         . ./version.sh
        echo "=== prepare_vscode.sh";  SKIP_NPM_INSTALL=yes . ./prepare_vscode.sh
        echo "=== build/aix/package_reh.sh"; ./build/aix/package_reh.sh
    ' _ "$tree" || die "source build failed (see log)"

    local reh
    reh=$(reh_dir_for "$version")
    [[ -f "$reh/product.json" && -x "$reh/node" ]] || die "build finished but $reh is incomplete"
    info "built: $reh"
}

#-----------------------------------------------------------------------------
# facts about the built tree, for the manifest
#-----------------------------------------------------------------------------
reh_commit() { json_field "$1/product.json" commit; }

# reh_pkg_version REH PKG : version of node_modules/PKG, or empty
reh_pkg_version() {
    local f="$1/node_modules/$2/package.json"
    [[ -f "$f" ]] && json_field "$f" version || true
}

# manifest_from_reh WORK REH TREE : record what went in.
manifest_from_reh() {
    local work=$1 reh=$2 tree=$3 pkg v
    manifest_set "$work" commit "$(reh_commit "$reh")"
    manifest_set "$work" vscode.commit "$(git -C "$tree/vscode" rev-parse HEAD 2>/dev/null || echo "")"
    manifest_set "$work" vscode.tag "$(jpy 'd.get("tag","")' <"$tree/upstream/stable.json")"
    manifest_set "$work" node.version "$("$reh/node" --version 2>/dev/null | sed 's/^v//')"
    manifest_set "$work" node.source "nodejs.org aix-ppc64"
    for pkg in node-pty @parcel/watcher @vscode/spdlog @vscode/native-watchdog @vscode/sqlite3 kerberos @vscode/ripgrep-universal @vscode/deviceid; do
        v=$(reh_pkg_version "$reh" "$pkg")
        [[ -n "$v" ]] && manifest_set "$work" "modules.$pkg.version" "$v"
    done
    manifest_set "$work" "modules.node-pty.note" "portlibforaix libutil for openpty/forkpty"
    manifest_set "$work" "modules.@parcel/watcher.note" "brute-force backend with polling subscriptions"
    manifest_set "$work" "modules.kerberos.note" "GSSAPI backend, MIT krb5 from the Toolbox"
    local rg="$reh/node_modules/@vscode/ripgrep-universal/bin/aix-ppc64/rg"
    [[ -x "$rg" ]] && manifest_set "$work" "modules.@vscode/ripgrep-universal.note" "$("$rg" --version 2>/dev/null | head -1)"
    manifest_set "$work" toolchain.gcc "$VSX_GCC_VERSION"
    manifest_set "$work" toolchain.rustc "${VSX_RUSTC_VERSION:-}"
    manifest_set "$work" toolchain.host "$(hostname) $VSX_OS_LEVEL"
    manifest_set "$work" smoke_test "passed (build/aix/verify_reh.sh)"
}

#-----------------------------------------------------------------------------
# package in the release layout
#-----------------------------------------------------------------------------
source_package() {
    local version=$1
    local work reh commit outdir base pkg staging
    work=$(work_dir_for "$version")
    reh=$(reh_dir_for "$version")
    commit=$(reh_commit "$reh")
    outdir="$VSX_RELEASES_DIR/$version"
    base="vscodium-reh-aix-ppc64-$version"
    pkg="$outdir/$base.tar.gz"
    section "Packaging $version -> $pkg"
    mkdir -p "$outdir"

    staging="$work/stage"
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -rl "$reh" "$staging/$commit" 2>/dev/null || cp -r "$reh" "$staging/$commit"
    cp "$work/manifest.json" "$staging/$commit/aix-build-manifest.json"

    rm -f "$pkg"
    tar -C "$staging" -czf "$pkg" "$commit"
    rm -rf "$staging"
    local sum size
    sum=$(sha256sum "$pkg" | cut -d' ' -f1)
    echo "$sum  $base.tar.gz" >"$pkg.sha256"
    size=$(file_size "$pkg")
    cp "$work/manifest.json" "$outdir/$base.json"
    cat >"$outdir/$base.info" <<EOF2
VSCodium Remote Server for AIX (ppc64), built from source
Version: $version
Commit: $commit
Built: $(date)
AIX build: $(manifest_get "$work" aix_build)
Fork: $(manifest_get "$work" fork.repo) @ $(manifest_get "$work" fork.ref) ($(manifest_get "$work" fork.commit))
VS Code: $(manifest_get "$work" vscode.tag) ($(manifest_get "$work" vscode.commit))
Host: $(hostname) $(uname -s) $(uname -m) ($VSX_OS_LEVEL)
Node: v$(manifest_get "$work" node.version) (nodejs.org aix-ppc64, bundled)
GCC: $VSX_GCC_VERSION
Rust: ${VSX_RUSTC_VERSION:-n/a}
Package: $base.tar.gz
Size: $size ($(human_size "$size"))
SHA256: $sum
EOF2
    info "package: $pkg ($(human_size "$size"))"
    info "sha256:  $sum"
}
