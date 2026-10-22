#!/usr/bin/env bash
# lib/server.sh - the per-version work tree's manifest, and the GitHub release
# notes rendered from it. (Downloading/patching the upstream Linux server is
# gone: the server is built from source by the fork, see lib/source.sh.)
#
# A work tree for version V lives at $VSX_WORK_DIR/V/ :
#   vscodium/     git worktree of the fork; vscodium/vscode is the VS Code
#                 checkout; vscodium/vscode-reh-aix-ppc64 the gulp output
#   stage/        packaging staging area
#   manifest.json what we put in (shipped as aix-build-manifest.json and as the
#                 release's .json asset)

[[ -n "${__vsx_loaded_server:-}" ]] && return 0
__vsx_loaded_server=1

work_dir_for() { printf '%s/%s\n' "$VSX_WORK_DIR" "$1"; }

# server_commit DIR : commit id of an extracted/built server tree
server_commit() { json_field "$1/product.json" commit; }

#-----------------------------------------------------------------------------
# Manifest: small JSON we ship alongside the release and use for notes.
#-----------------------------------------------------------------------------
manifest_set() {
    local work=$1 key=$2 value=$3 kind=${4:-str}
    python3 - "$work/manifest.json" "$key" "$value" "$kind" <<'PY'
import json, os, sys
path, key, value, kind = sys.argv[1:5]
if kind == "int":
    value = int(value)
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
# Release notes
#-----------------------------------------------------------------------------
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
    local sum aix_build built rebuild_note="" fork_repo_path fork_ref fork_commit
    sum=$(cut -d' ' -f1 "$VSX_RELEASES_DIR/$version/$base.tar.gz.sha256")
    fork_repo_path=$([[ -f "$manifest" ]] && jpy 'd.get("fork",{}).get("repo","")' <"$manifest" || echo "")
    fork_repo_path=${fork_repo_path#https://github.com/}; fork_repo_path=${fork_repo_path%.git}
    [[ -n "$fork_repo_path" ]] || fork_repo_path="tonykuttai/vscodium"
    fork_ref=$([[ -f "$manifest" ]] && jpy 'd.get("fork",{}).get("ref","aix")' <"$manifest" || echo aix)
    fork_commit=$([[ -f "$manifest" ]] && jpy 'd.get("fork",{}).get("commit","")' <"$manifest" || echo "")
    aix_build=$([[ -f "$manifest" ]] && jpy 'd.get("aix_build", 1)' <"$manifest" || echo 1)
    built=$([[ -f "$manifest" ]] && jpy 'd.get("built", "")' <"$manifest" || echo "")
    if (( aix_build > 1 )); then
        rebuild_note="**AIX build $aix_build** (rebuild of $version, built $built). Existing installs are refreshed automatically by aix-remote-ssh >= 0.1.1; with older extension versions run \`rm -rf ~/.vscodium-server/bin/$commit\` on the AIX host before reconnecting."
    else
        rebuild_note="AIX build $aix_build, built $built."
    fi
    cat >"$out" <<EOF
VSCodium Remote Server **$version** for IBM AIX 7.3 (ppc64). Unofficial community build.
$rebuild_note

Built from source on AIX by [vscodium-aix-server](https://github.com/$VSX_RELEASE_REPO) with the
VS Code/VSCodium build (\`gulp vscode-reh-aix-ppc64-min\`) from the fork
[$(dirname "$fork_repo_path")/$(basename "$fork_repo_path")](https://github.com/$fork_repo_path/tree/$fork_ref)
(\`$fork_ref\` at \`${fork_commit:0:12}\`), for upstream
[VSCodium $version](https://github.com/$VSX_UPSTREAM_REPO/releases/tag/$version).

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
* The GCC runtime from the AIX Toolbox (\`libstdc++\`, \`libgcc\`, GCC 12 or newer) and \`krb5-libs\`, normally present under \`/opt/freeware/lib\`.
* GNU tar from the Toolbox is recommended for extracting.

### Contents
$(manifest_render_table "$manifest")

SHA256: \`$sum\`
EOF
}

manifest_render_table() {
    local file=$1
    [[ -f "$file" ]] || { echo "(no manifest)"; return 0; }
    python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("| component | version | note |")
print("|---|---|---|")
vs = d.get("vscode", {})
if vs:
    print(f"| VS Code | {vs.get('tag','?')} | commit {vs.get('commit','')[:12]} |")
n = d.get("node", {})
if n:
    print(f"| node runtime | v{n.get('version','?')} | {n.get('source','')}, bundled |")
for name, m in sorted(d.get("modules", {}).items()):
    print(f"| {name} | {m.get('version','?')} | {m.get('note','')} |")
t = d.get("toolchain", {})
if t:
    print(f"| toolchain | gcc {t.get('gcc','')}, rustc {t.get('rustc','')} | {t.get('host','')} |")
PY
}
