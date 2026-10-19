#!/usr/bin/env bash
# modules/native-watchdog.sh - @vscode/native-watchdog (microsoft/node-native-watchdog)
#
# AIX notes: upstream binding.gyp adds -fstack-protector-strong which AIX GCC
# rejects; strip it. Otherwise a plain node-gyp build.

mod_native_watchdog_wanted() {
    server_bundled_version "$1" "@vscode/native-watchdog"
}

mod_native_watchdog_build() {
    local version=$1 out=$2
    env_export_compiler_flags
    git_clone_tag "$VSX_REPO_WATCHDOG" "$version" src
    cd src || return 1
    strip_stack_protector binding.gyp
    vsx_node_gyp rebuild
    verify_addon build/Release/watchdog.node
    cp build/Release/watchdog.node "$out/watchdog.node"
}

mod_native_watchdog_install() {
    local out=$1 server=$2
    install_file "$out/watchdog.node" "$server/node_modules/@vscode/native-watchdog/build/Release/watchdog.node"
    # Older servers also had an unscoped copy.
    if [[ -d "$server/node_modules/native-watchdog" ]]; then
        install_file "$out/watchdog.node" "$server/node_modules/native-watchdog/build/Release/watchdog.node"
    fi
}
