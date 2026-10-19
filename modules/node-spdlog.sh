#!/usr/bin/env bash
# modules/node-spdlog.sh - @vscode/spdlog (microsoft/node-spdlog)
#
# AIX notes: strip -fstack-protector-strong; the spdlog sources are a git
# submodule so clone recursively. Built with node-gyp against our runtime.
# The resulting addon needs the GCC libstdc++ runtime on LIBPATH at run time
# (bin/aix-env.sh takes care of that in the package).

mod_node_spdlog_wanted() {
    server_bundled_version "$1" "@vscode/spdlog"
}

mod_node_spdlog_build() {
    local version=$1 out=$2
    env_export_compiler_flags
    git_clone_tag "$VSX_REPO_SPDLOG" "$version" src
    cd src || return 1
    git submodule update --init --recursive
    strip_stack_protector binding.gyp
    # node-addon-api headers come from the package's own dependencies.
    vsx_npm install --ignore-scripts --no-progress --loglevel=error
    vsx_node_gyp rebuild
    verify_addon build/Release/spdlog.node
    cp build/Release/spdlog.node "$out/spdlog.node"
}

mod_node_spdlog_install() {
    local out=$1 server=$2
    install_file "$out/spdlog.node" "$server/node_modules/@vscode/spdlog/build/Release/spdlog.node"
}
