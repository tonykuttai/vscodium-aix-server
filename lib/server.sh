#!/usr/bin/env bash
# lib/server.sh - the upstream server tree: download, inspect, install the
# runtime and launchers, smoke test, package.
#
# A "work tree" for version V lives at $VSX_WORK_DIR/V/ :
#   server/      extracted upstream linux-x64 REH, progressively patched
#   build/       module build scratch (module caches live elsewhere)
#   manifest.json what we put in (filled by modules and server steps)

[[ -n "${__vsx_loaded_server:-}" ]] && return 0
__vsx_loaded_server=1

work_dir_for()   { printf '%s/%s\n' "$VSX_WORK_DIR" "$1"; }
server_dir_for() { printf '%s/%s/server\n' "$VSX_WORK_DIR" "$1"; }

#-----------------------------------------------------------------------------
# Download + extract
#-----------------------------------------------------------------------------
server_fetch() {
    local version=$1
    local work server tarball url
    work=$(work_dir_for "$version")
    server="$work/server"
    mkdir -p "$work" "$VSX_DOWNLOADS_DIR"
    if [[ -f "$server/.extracted" ]]; then
        info "server $version already extracted at $server"
        return 0
    fi
    section "Fetching upstream VSCodium REH $version"
    tarball="$VSX_DOWNLOADS_DIR/vscodium-reh-linux-x64-$version.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        url=$(upstream_asset_url "$version")
        [[ -n "$url" ]] || die "no linux-x64 REH asset found upstream for $version"
        info "downloading $url"
        curl -fsSL --retry 3 -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    else
        info "using cached download $tarball"
    fi
    rm -rf "$server"
    mkdir -p "$server"
    tar -xzf "$tarball" -C "$server"
    [[ -f "$server/product.json" && -d "$server/out" && -d "$server/bin" ]] \
        || die "extracted tree does not look like a REH server: $server"
    local got
    got=$(json_field "$server/product.json" version)
    [[ "$got" == "$version" ]] || die "downloaded server reports version $got, expected $version"
    touch "$server/.extracted"
}

#-----------------------------------------------------------------------------
# Facts about the server tree
#-----------------------------------------------------------------------------
server_commit()   { json_field "$1/product.json" commit; }
server_version()  { json_field "$1/product.json" version; }
server_app_name() { basename "$(ls "$1"/bin/*-server 2>/dev/null | head -1)" 2>/dev/null; }

# server_bundled_version SERVER PKG : version of node_modules/PKG or empty
server_bundled_version() {
    pkg_version "$1/node_modules/$2" 2>/dev/null || true
}

# List foreign (ELF) native binaries still in the tree.
server_foreign_binaries() {
    local server=$1
    find "$server/node_modules" -name '*.node' -type f 2>/dev/null | while read -r f; do
        if file "$f" | grep -q ELF; then printf '%s\n' "${f#"$server"/}"; fi
    done
}

#-----------------------------------------------------------------------------
# Manifest: small JSON we ship alongside the release and use for notes.
#-----------------------------------------------------------------------------
manifest_set() {
    local work=$1 key=$2 value=$3
    python3 - "$work/manifest.json" "$key" "$value" <<'PY'
import json, os, sys
path, key, value = sys.argv[1:4]
d = {}
if os.path.exists(path):
    d = json.load(open(path))
cur = d
parts = key.split(".")
for p in parts[:-1]:
    cur = cur.setdefault(p, {})
cur[parts[-1]] = value
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
}

manifest_get() {
    local work=$1 key=$2
    [[ -f "$work/manifest.json" ]] || return 0
    jpy "
cur = d
for p in '$key'.split('.'):
    cur = cur.get(p, {}) if isinstance(cur, dict) else {}
r = cur if cur != {} else ''
" <"$work/manifest.json"
}

#-----------------------------------------------------------------------------
# Node runtime inside the package
#-----------------------------------------------------------------------------
server_install_node() {
    local server=$1
    section "Installing Node runtime into server ($VSX_NODE_RUNTIME)"
    # Upstream ships an x86-64 ELF node; keep a copy once, then replace.
    if [[ -f "$server/node" ]] && file "$server/node" | grep -q ELF; then
        rm -f "$server/node"
    fi
    if [[ "$VSX_NODE_RUNTIME" == "bundle" ]]; then
        cp "$VSX_NODE_BIN" "$server/node"
        chmod 755 "$server/node"
        # Strip debug symbols: 215MB -> ~160MB. The result still runs.
        if strip -X64 "$server/node" 2>/dev/null; then
            info "stripped bundled node ($(human_size "$(file_size "$server/node")"))"
        else
            warn "strip failed; shipping unstripped node"
        fi
        "$server/node" -e 'process.exit(0)' || die "bundled node does not run"
    else
        cat >"$server/node" <<EOF
#!/usr/bin/env sh
# AIX: dispatch to the host Node.js runtime.
NODE_BIN="$VSX_HOST_NODE"
if [ ! -x "\$NODE_BIN" ]; then
    echo "Error: expected Node.js at \$NODE_BIN but it is missing or not executable" >&2
    exit 1
fi
exec "\$NODE_BIN" "\$@"
EOF
        chmod 755 "$server/node"
    fi
}

#-----------------------------------------------------------------------------
# Launchers: bin/<app>-server, bin/remote-cli/<app>, aix-env.sh, override.
# Generated from templates/ with placeholders substituted.
#-----------------------------------------------------------------------------
_render_template() {
    local src=$1 dst=$2; shift 2
    # remaining args: KEY=VALUE pairs replacing @KEY@
    python3 - "$src" "$dst" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for kv in sys.argv[3:]:
    k, _, v = kv.partition("=")
    text = text.replace("@" + k + "@", v)
open(dst, "w").write(text)
PY
}

server_install_launchers() {
    local server=$1
    section "Installing AIX launchers"
    local app commit version
    app=$(server_app_name "$server")
    [[ -n "$app" ]] || die "could not find bin/*-server in $server"
    app=${app%-server}             # codium
    commit=$(server_commit "$server")
    version=$(server_version "$server")

    cp "$VSX_HOME/templates/aix-platform-override.js" "$server/aix-platform-override.js"
    _render_template "$VSX_HOME/templates/aix-env.sh" "$server/bin/aix-env.sh" \
        "PTY_LIBDIR=node_modules/node-pty/lib/native-libs"
    _render_template "$VSX_HOME/templates/server-launcher.sh" "$server/bin/$app-server"
    mkdir -p "$server/bin/remote-cli"
    _render_template "$VSX_HOME/templates/remote-cli.sh" "$server/bin/remote-cli/$app" \
        "APP_NAME=$app" "VERSION=$version" "COMMIT=$commit"
    chmod 755 "$server/bin/$app-server" "$server/bin/remote-cli/$app" "$server/bin/aix-env.sh"
    # Some clients look for code-server; keep upstream behaviour of one name,
    # but a symlink costs nothing.
    [[ -e "$server/bin/code-server" ]] || ln -s "$app-server" "$server/bin/code-server"
}

#-----------------------------------------------------------------------------
# Smoke test: start the real server and wait for the extension host.
#-----------------------------------------------------------------------------
server_smoke_test() {
    local server=$1
    section "Smoke test: starting server"
    local app logf data pid ok=false i
    app=$(server_app_name "$server")
    data=$(mktemp -d "${TMPDIR:-/tmp}/vsx-smoke.XXXXXX")
    logf="$data/server.log"

    # 1. the addons we are responsible for exist, are XCOFF, and load
    local f rc=0
    local -a required=(
        node_modules/@vscode/native-watchdog/build/Release/watchdog.node
        node_modules/@vscode/spdlog/build/Release/spdlog.node
        node_modules/node-pty/build/Release/pty.node
        node_modules/@parcel/watcher/build/Release/watcher.node
    )
    for f in "${required[@]}"; do
        if [[ ! -f "$server/$f" ]]; then
            error "required addon missing from server tree: $f"
            rc=1
        fi
    done
    (( rc == 0 )) || { rm -rf "$data"; die "server tree is incomplete"; }
    # ... plus anything else that is a .node file and ours to verify
    while read -r f; do
        [[ -n "$f" ]] || continue
        case "$f" in
            */windows.node|*kerberos*|*sqlite3*) continue ;;   # not ours
        esac
        if ! verify_addon "$server/$f" "$server/node_modules/node-pty/lib/native-libs"; then rc=1; fi
    done < <(find "$server/node_modules" -name '*.node' -type f | sed "s|^$server/||")
    (( rc == 0 )) || { rm -rf "$data"; die "one or more addons failed to load"; }

    # 2. ripgrep runs
    local rg
    rg=$(find "$server/node_modules/@vscode" -path '*ripgrep*' -name rg -type f 2>/dev/null | grep -E 'aix-ppc64|/bin/rg$' | head -1 || true)
    if [[ -n "$rg" ]]; then
        "$rg" --version >/dev/null || { rm -rf "$data"; die "ripgrep binary does not run: $rg"; }
    else
        warn "no ripgrep binary found to test"
    fi

    # 3. the server boots, the extension host comes up, HTTP answers, and no
    #    AHAFS monitor was created (the fs.watch shim must keep us out of /aha:
    #    a wedged AHAFS blocks processes unkillably, see
    #    notes/AIX-WATCHERS-AND-BINARIES.md).
    local commit port
    commit=$(server_commit "$server")
    # Job control gives the server its own process group, so the extension
    # host / pty host / file watcher children can be killed with it.
    set -m
    (
        cd "$server" || exit 1
        exec "./bin/$app" --accept-server-license-terms --host 127.0.0.1 --port 0 \
            --without-connection-token --server-data-dir "$data/data" \
            --extensions-dir "$data/ext" --telemetry-level off
    ) >"$logf" 2>&1 &
    pid=$!
    set +m
    for ((i = 0; i < VSX_SMOKE_TIMEOUT; i++)); do
        if grep -q 'Extension host agent listening' "$logf" 2>/dev/null; then ok=true; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 1
    done
    local fail=""
    if ! $ok; then
        fail="server did not reach 'Extension host agent listening' within ${VSX_SMOKE_TIMEOUT}s"
    else
        port=$(sed -n 's/.*Extension host agent listening on \([0-9][0-9]*\).*/\1/p' "$logf" | head -1)
        if [[ -z "$port" ]]; then
            fail="could not read the listening port from the server log"
        elif ! curl -fsS -m 15 "http://127.0.0.1:$port/version" 2>/dev/null | grep -q "$commit"; then
            fail="server is listening on $port but does not answer GET /version with its commit"
        fi
        if [[ -z "$fail" && -d /aha/fs/modDir.monFactory ]]; then
            local mon
            mon=$(timeout 10 find /aha/fs/modDir.monFactory -name '*vsx-smoke*' 2>/dev/null | head -3 || true)
            if [[ -n "$mon" ]]; then
                fail="server created AHAFS monitors (fs.watch shim not active?): $mon"
            fi
        fi
    fi
    if ! _smoke_stop_group "$pid"; then
        fail="${fail:+$fail; }server process $pid did not exit after SIGKILL (stuck in the kernel, AHAFS wedged?)"
    fi
    if [[ -n "$fail" ]]; then
        error "$fail"
        error "server log:"
        tail -60 "$logf" >&2 || true
        rm -rf "$data"
        return 1
    fi
    if grep -qiE 'error|cannot find module|not supported' "$logf"; then
        warn "server log contains error lines (review):"
        grep -iE 'error|cannot find module|not supported' "$logf" | head -10 >&2 || true
    fi
    info "smoke test passed (extension host listening, /version answered, no AHAFS use)"

    # 4. remote CLI responds
    local cli
    cli=$(ls "$server"/bin/remote-cli/* 2>/dev/null | head -1)
    if [[ -n "$cli" ]] && ! "$cli" --version >/dev/null 2>&1; then
        warn "remote-cli --version failed (non-fatal)"
    fi
    rm -rf "$data"
}

# _smoke_stop_group PID : TERM then KILL the process group of PID (and PID
# itself), polling instead of calling `wait` on a process that may be stuck
# in the kernel. Returns 1 if PID is still alive afterwards.
_smoke_stop_group() {
    local pid=$1 sig i st
    for sig in TERM KILL; do
        kill "-$sig" -- "-$pid" 2>/dev/null || kill "-$sig" "$pid" 2>/dev/null || true
        for ((i = 0; i < 10; i++)); do
            st=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
            # gone, or a zombie waiting for us: reap and done
            if [[ -z "$st" || "$st" == Z* ]]; then
                wait "$pid" 2>/dev/null || true
                return 0
            fi
            sleep 1
        done
    done
    return 1
}

#-----------------------------------------------------------------------------
# Package: releases/<version>/vscodium-reh-aix-ppc64-<version>.tar.gz + .sha256
# + .info + .json. Top-level directory inside the tarball is the commit id
# (open-remote-ssh extracts with --strip-components 1).
#-----------------------------------------------------------------------------
server_package() {
    local version=$1
    local work server commit outdir base pkg staging
    work=$(work_dir_for "$version")
    server="$work/server"
    commit=$(server_commit "$server")
    outdir="$VSX_RELEASES_DIR/$version"
    base="vscodium-reh-aix-ppc64-$version"
    pkg="$outdir/$base.tar.gz"
    section "Packaging $version -> $pkg"
    mkdir -p "$outdir"

    # Clean build leftovers we never want to ship.
    # (AIX find has no -delete; -exec is portable)
    find "$server" -name '*.linux-backup' -exec rm -f {} + 2>/dev/null || true
    find "$server" -name '*.backup' -type f -exec rm -f {} + 2>/dev/null || true
    if find "$server" -name '*.linux-backup' | grep -q .; then
        die "backup files still present in server tree; refusing to package"
    fi
    rm -f "$server/.extracted"

    staging="$work/stage"
    rm -rf "$staging"
    mkdir -p "$staging"
    # Hard-link copy is instant; fall back to cp if the FS refuses.
    cp -rl "$server" "$staging/$commit" 2>/dev/null || cp -r "$server" "$staging/$commit"
    cp "$work/manifest.json" "$staging/$commit/aix-build-manifest.json" 2>/dev/null || true

    rm -f "$pkg"
    tar -C "$staging" -czf "$pkg" "$commit"
    rm -rf "$staging"
    local sum size
    sum=$(sha256sum "$pkg" | cut -d' ' -f1)
    echo "$sum  $base.tar.gz" >"$pkg.sha256"
    size=$(file_size "$pkg")
    cp "$work/manifest.json" "$outdir/$base.json" 2>/dev/null || true
    cat >"$outdir/$base.info" <<EOF
VSCodium Remote Server for AIX (ppc64)
Version: $version
Commit: $commit
Built: $(date)
Host: $(hostname) $(uname -s) $(uname -m) ($VSX_OS_LEVEL)
Node: v$VSX_NODE_VERSION (ABI $VSX_NODE_ABI, $VSX_NODE_SOURCE)
GCC: $VSX_GCC_VERSION
Rust: $VSX_RUSTC_VERSION
Package: $base.tar.gz
Size: $size ($(human_size "$size"))
SHA256: $sum
EOF
    info "package: $pkg ($(human_size "$size"))"
    info "sha256:  $sum"
}

# release_notes VERSION OUTFILE : markdown body for the GitHub release.
# Reads the manifest that was packaged next to the tarball, so notes can be
# (re)generated long after the work tree is gone.
release_notes() {
    local version=$1 out=$2
    local base manifest commit
    base="vscodium-reh-aix-ppc64-$version"
    manifest="$VSX_RELEASES_DIR/$version/$base.json"
    [[ -f "$manifest" ]] || manifest="$(work_dir_for "$version")/manifest.json"
    commit=""
    [[ -f "$manifest" ]] && commit=$(jpy 'd.get("commit","")' <"$manifest")
    [[ -n "$commit" ]] || commit=$(grep '^Commit:' "$VSX_RELEASES_DIR/$version/$base.info" | cut -d' ' -f2)
    [[ -n "$commit" ]] || die "cannot determine commit for $version (no manifest or .info)"
    local sum
    sum=$(cut -d' ' -f1 "$VSX_RELEASES_DIR/$version/$base.tar.gz.sha256")
    cat >"$out" <<EOF
VSCodium Remote Server **$version** for IBM AIX 7.3 (ppc64). Unofficial community build.

Produced by [vscodium-aix-server](https://github.com/$VSX_RELEASE_REPO) from upstream
[VSCodium $version](https://github.com/$VSX_UPSTREAM_REPO/releases/tag/$version): the Linux x64
server with its native modules rebuilt for AIX.

### Install
\`\`\`sh
wget https://github.com/$VSX_RELEASE_REPO/releases/download/$version/$base.tar.gz
mkdir -p ~/.vscodium-server/bin/$commit
tar -xzf $base.tar.gz -C ~/.vscodium-server/bin/$commit --strip-components 1
~/.vscodium-server/bin/$commit/bin/codium-server --version
\`\`\`
The [open-remote-ssh AIX extension](https://github.com/tonykuttai/open-remote-ssh) does this automatically.

### Requirements on the AIX machine
* AIX 7.3 on POWER (ppc64). No Node.js installation is needed: the matching Node runtime is bundled (set \`VSCODIUM_AIX_NODE\` to use your own binary of the same major instead).
* The GCC runtime from the AIX Toolbox (\`libstdc++\`, \`libgcc\`), normally present under \`/opt/freeware/lib\`.
* GNU tar from the Toolbox is recommended for extracting.

### Contents
$(manifest_render_table "$manifest")

SHA256: \`$sum\`
EOF
}

# manifest_render_table MANIFEST_FILE : markdown table of what went in.
manifest_render_table() {
    local file=$1
    [[ -f "$file" ]] || { echo "(no manifest)"; return 0; }
    python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("| component | version | note |")
print("|---|---|---|")
n = d.get("node", {})
if n:
    print(f"| node runtime | v{n.get('version','?')} | {n.get('source','')}, ABI {n.get('abi','')}, upstream target {n.get('upstream_target','')} |")
for name, m in sorted(d.get("modules", {}).items()):
    print(f"| {name} | {m.get('version','?')} | {m.get('note','')} |")
t = d.get("toolchain", {})
if t:
    print(f"| toolchain | gcc {t.get('gcc','')}, rustc {t.get('rustc','')} | {t.get('host','')} |")
PY
}
