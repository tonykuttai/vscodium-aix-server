#!/usr/bin/env bash
# modules/deviceid.sh - @vscode/deviceid JS patch (no compilation)
#
# The package refuses unknown platforms and picks a storage path per OS.
# Teach it that "aix" behaves like "linux". Patched in place in the server
# tree; idempotent.

mod_deviceid_wanted() {
    server_bundled_version "$1" "@vscode/deviceid"
}

mod_deviceid_build() {
    # Nothing to compile; keep the cache dir so module_run's sentinel logic
    # is uniform.
    echo "deviceid: JS-only patch, no build step" >"$2/README"
}

mod_deviceid_install() {
    local server=$2
    local dir="$server/node_modules/@vscode/deviceid/dist"
    local index="$dir/index.js" storage="$dir/storage.js"
    [[ -f "$index" ]] || { warn "deviceid: $index missing"; return 0; }
    if ! grep -q 'process.platform !== "aix"' "$index"; then
        sed -i 's/process\.platform !== "linux"/process.platform !== "linux" \&\& process.platform !== "aix"/g' "$index"
        grep -q 'process.platform !== "aix"' "$index" || { error "deviceid: index.js patch did not apply"; return 1; }
    fi
    if [[ -f "$storage" ]] && ! grep -q 'process.platform === "aix"' "$storage"; then
        sed -i 's/process\.platform === "linux"/process.platform === "linux" || process.platform === "aix"/g' "$storage"
        grep -q 'process.platform === "aix"' "$storage" || { error "deviceid: storage.js patch did not apply"; return 1; }
    fi
    info "deviceid patched for aix"
}

mod_deviceid_note() { echo "dist/index.js + dist/storage.js treat aix like linux"; }
