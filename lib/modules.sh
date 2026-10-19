#!/usr/bin/env bash
# lib/modules.sh - manifest-driven native module pipeline.
#
# Each modules/<name>.sh defines (with '-' in <name> replaced by '_'):
#   mod_<n>_wanted  SERVER          -> prints the version to build (from the
#                                      server's own node_modules), or nothing
#                                      if the module is not in this server
#   mod_<n>_build   VERSION OUTDIR  -> builds into OUTDIR (cwd = OUTDIR)
#   mod_<n>_install OUTDIR SERVER   -> copies artifacts into the server tree
#   mod_<n>_cache_key VERSION       -> optional; default "<version>-node<ABI>"
#   mod_<n>_note                    -> optional one-line note for the manifest
#
# Builds are cached under $VSX_MODULE_CACHE_DIR/<name>/<key>/ with a
# .build-complete sentinel, so backfilling several VSCodium versions that
# bundle the same module version compiles it once.

[[ -n "${__vsx_loaded_modules:-}" ]] && return 0
__vsx_loaded_modules=1

# Order matters only in that patches run after native installs.
# shellcheck disable=SC2034  # iterated by bin/vsx
VSX_MODULES=(native-watchdog node-spdlog node-pty parcel-watcher ripgrep deviceid)

_mod_fn() { printf 'mod_%s_%s' "${1//-/_}" "$2"; }

module_source() {
    local name=$1
    local file="$VSX_HOME/modules/$name.sh"
    [[ -f "$file" ]] || die "no module script: $file"
    # shellcheck disable=SC1090
    source "$file"
}

# module_run NAME SERVER WORK : wanted -> build (cached) -> install -> manifest
module_run() {
    local name=$1 server=$2 work=$3
    module_source "$name"
    local wanted key cache note
    wanted=$("$(_mod_fn "$name" wanted)" "$server" || true)
    if [[ -z "$wanted" ]]; then
        warn "module $name: not present in this server, skipping"
        manifest_set "$work" "modules.$name.version" "skipped"
        return 0
    fi
    if declare -F "$(_mod_fn "$name" cache_key)" >/dev/null; then
        key=$("$(_mod_fn "$name" cache_key)" "$wanted")
    else
        key="$wanted-node$VSX_NODE_ABI"
    fi
    cache="$VSX_MODULE_CACHE_DIR/$name/$key"
    section "Module $name $wanted"
    if [[ -f "$cache/.build-complete" ]]; then
        info "using cached build: $cache"
    else
        rm -rf "$cache"
        mkdir -p "$cache"
        info "building in $cache (log: $cache/build.log)"
        # errexit must stay active inside the builder: run it in a subshell
        # that re-enables -e while this shell has -e off (bash ignores -e
        # inside anything tested by if/!/||, including subshells).
        local rc
        set +e
        ( set -e; cd "$cache" && "$(_mod_fn "$name" build)" "$wanted" "$cache" ) >>"$cache/build.log" 2>&1
        rc=$?
        set -e
        if (( rc != 0 )); then
            error "module $name $wanted failed to build (exit $rc); last 60 lines of $cache/build.log:"
            tail -60 "$cache/build.log" >&2 || true
            rm -f "$cache/.build-complete"
            return 1
        fi
        date -u '+%Y-%m-%dT%H:%M:%SZ' >"$cache/.build-complete"
        info "built $name $wanted"
    fi
    local irc
    set +e
    ( set -e; "$(_mod_fn "$name" install)" "$cache" "$server" )
    irc=$?
    set -e
    (( irc == 0 )) || { error "module $name: install failed (exit $irc)"; return 1; }
    manifest_set "$work" "modules.$name.version" "$wanted"
    if declare -F "$(_mod_fn "$name" note)" >/dev/null; then
        note=$("$(_mod_fn "$name" note)")
        [[ -n "$note" ]] && manifest_set "$work" "modules.$name.note" "$note"
    fi
    return 0
}

#-----------------------------------------------------------------------------
# Helpers shared by module scripts
#-----------------------------------------------------------------------------
# git_clone_tag REPO TAG DIR : shallow clone of one tag (tries TAG, vTAG).
git_clone_tag() {
    local repo=$1 tag=$2 dir=$3 t
    for t in "$tag" "v$tag"; do
        if git clone -q --depth 1 --branch "$t" "$repo" "$dir" 2>/dev/null; then
            echo "cloned $repo @ $t"
            return 0
        fi
    done
    echo "ERROR: no tag $tag or v$tag in $repo" >&2
    return 1
}

# strip_stack_protector FILE : remove -fstack-protector-strong from a
# binding.gyp in whatever form it appears (AIX GCC rejects it).
strip_stack_protector() {
    local f=$1
    sed -i -e "s/, *['\"]-fstack-protector-strong['\"]//g" \
           -e "s/['\"]-fstack-protector-strong['\"], *//g" \
           -e "s/['\"]-fstack-protector-strong['\"]//g" "$f"
    if grep -q 'fstack-protector-strong' "$f"; then
        echo "ERROR: could not remove -fstack-protector-strong from $f" >&2
        return 1
    fi
    return 0
}

# install_file SRC DST : mkdir -p and copy, keeping one backup of a foreign
# original for debugging (never shipped: packaging deletes *.linux-backup).
install_file() {
    local src=$1 dst=$2
    mkdir -p "$(dirname "$dst")"
    if [[ -f "$dst" && ! -f "$dst.linux-backup" ]] && file "$dst" | grep -q ELF; then
        mv "$dst" "$dst.linux-backup"
    fi
    cp "$src" "$dst"
    chmod 755 "$dst"
    info "installed $(basename "$src") -> ${dst#*/server/}"
}

# rust_check_msrv CARGO_TOML : fail if rustc is older than rust-version.
rust_check_msrv() {
    local toml=$1 msrv
    msrv=$(grep -E '^rust-version' "$toml" | head -1 | cut -d'"' -f2)
    [[ -n "$msrv" ]] || return 0
    if ! python3 -c '
import sys
def k(v): return [int(x) for x in v.split(".")]
sys.exit(0 if k(sys.argv[1]) >= k(sys.argv[2]) else 1)
' "$VSX_RUSTC_VERSION" "$msrv"; then
        echo "ERROR: this ripgrep requires rustc >= $msrv but the host has $VSX_RUSTC_VERSION." >&2
        echo "       Install a newer Rust (AIX Toolbox rust1.90 RPM, or a user-local copy) or" >&2
        echo "       set VSX_RIPGREP_FALLBACK_TAG to an older ripgrep release." >&2
        return 1
    fi
    echo "rustc $VSX_RUSTC_VERSION satisfies rust-version $msrv"
}
