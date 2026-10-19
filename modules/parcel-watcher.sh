#!/usr/bin/env bash
# modules/parcel-watcher.sh - @parcel/watcher (parcel-bundler/watcher)
#
# AIX notes:
#   * binding.gyp has no AIX branch. We add one using the brute-force backend
#     (src/unix/legacy.cc) plus the watchman backend sources, and drop
#     -fstack-protector-strong. The file is Python-literal syntax, so we edit
#     it with Python and re-validate it with ast.literal_eval.
#   * AIX dirent has no d_type; legacy.cc is patched to stat() instead.
#   * npm install --ignore-scripts just fetches node-addon-api; node-gyp does
#     the build against our runtime.

mod_parcel_watcher_wanted() {
    server_bundled_version "$1" "@parcel/watcher"
}

mod_parcel_watcher_build() {
    local version=$1 out=$2
    env_export_compiler_flags
    git_clone_tag "$VSX_REPO_PARCEL_WATCHER" "$version" src
    cd src || return 1

    echo "patching binding.gyp for AIX"
    python3 - binding.gyp <<'PY'
import ast, re, sys
path = sys.argv[1]
text = open(path).read()
if 'OS=="aix"' not in text:
    # Drop the global stack protector flag in any quoting style.
    text = re.sub(r"""['"]cflags['"]:\s*\[\s*['"]-fstack-protector-strong['"]\s*\]""", "'cflags': []", text)
    text = text.replace("'-fstack-protector-strong'", "").replace('"-fstack-protector-strong"', "")
    aix_block = """
        ['OS=="aix"', {
          "sources": [
            "src/watchman/BSER.cc",
            "src/watchman/WatchmanBackend.cc",
            "src/shared/BruteForceBackend.cc",
            "src/unix/legacy.cc"
          ],
          "defines": [ "WATCHMAN", "BRUTE_FORCE" ],
          'cflags!': [ '-fstack-protector-strong' ],
          'cflags_cc!': [ '-fstack-protector-strong' ],
          'cflags': [ '-ftls-model=global-dynamic', '-fPIC', '-pthread' ],
          'cflags_cc': [ '-ftls-model=global-dynamic', '-fPIC', '-pthread', '-std=c++17' ]
        }],"""
    # Insert as the first entry of the target's 'conditions' list.
    m = re.search(r"""(['"]conditions['"]\s*:\s*\[)""", text)
    if not m:
        sys.exit("binding.gyp: no 'conditions' list found; module script needs updating")
    text = text[:m.end()] + aix_block + text[m.end():]
    open(path, "w").write(text)
data = ast.literal_eval(open(path).read())
targets = data.get("targets", [])
assert any('OS=="aix"' in str(t.get("conditions", "")) for t in targets), "AIX block missing after patch"
print("binding.gyp: AIX block present and file parses")
PY
    strip_stack_protector binding.gyp || true

    echo "patching src/unix/legacy.cc (no d_type on AIX)"
    # Upstream: fstatat(new_fd, ent->d_name, &attrib, ...) is called on the
    # line right before `bool isDir = ent->d_type == DT_DIR;`, so stat data is
    # already there; just use it.
    if grep -q 'bool isDir = ent->d_type == DT_DIR;' src/unix/legacy.cc; then
        sed -i 's/bool isDir = ent->d_type == DT_DIR;/bool isDir = S_ISDIR(attrib.st_mode); \/\/ AIX: dirent has no d_type/' src/unix/legacy.cc
        grep -q 'S_ISDIR(attrib.st_mode)' src/unix/legacy.cc || { echo "ERROR: legacy.cc patch failed" >&2; return 1; }
        grep -q 'struct stat attrib;' src/unix/legacy.cc || { echo "ERROR: legacy.cc no longer declares attrib; update modules/parcel-watcher.sh" >&2; return 1; }
    elif grep -q 'S_ISDIR(attrib.st_mode)' src/unix/legacy.cc; then
        echo "legacy.cc already patched"
    else
        echo "ERROR: legacy.cc d_type line not found; update modules/parcel-watcher.sh" >&2
        return 1
    fi

    vsx_npm install --ignore-scripts --no-progress --loglevel=error
    vsx_node_gyp rebuild
    verify_addon build/Release/watcher.node
    cp build/Release/watcher.node "$out/watcher.node"
}

mod_parcel_watcher_install() {
    local out=$1 server=$2
    install_file "$out/watcher.node" "$server/node_modules/@parcel/watcher/build/Release/watcher.node"
    # Make sure the JS loader cannot pick a Linux prebuilt first.
    rm -rf "$server/node_modules/@parcel/watcher/prebuilds" 2>/dev/null || true
}

mod_parcel_watcher_note() { echo "brute-force backend (no native file events on AIX)"; }
