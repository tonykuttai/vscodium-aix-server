#!/usr/bin/env bash
# modules/node-pty.sh - node-pty (microsoft/node-pty) with the AIX patch
#
# AIX notes:
#   * AIX libc has no openpty/forkpty/login_tty. portlibforaix provides them
#     as libutil.so.2; we link it explicitly and ship it next to the addon in
#     lib/native-libs/ (found through LIBPATH set by bin/aix-env.sh).
#   * patches/node-pty-aix.patch adds the AIX includes and prototypes. It is
#     applied to the exact upstream tag the server bundles, so the JS side
#     (lib/unixTerminal.js) and the native side always agree on the fork()
#     signature.
#   * Compiled and linked by hand rather than through node-gyp: the import
#     file (-bimport node.exp) and libutil placement are simpler to control.
#   * Do NOT add portlibforaix/include to the include path: it carries a
#     stdio.h that shadows the system one and breaks <cstdio>.

mod_node_pty_wanted() {
    server_bundled_version "$1" "node-pty"
}

mod_node_pty_build() {
    local version=$1 out=$2
    env_ensure_portlib
    local libutil="$VSX_PORTLIB_DIR/lib/libutil.so.2"
    git_clone_tag "$VSX_REPO_NODE_PTY" "$version" src
    cd src || return 1
    echo "applying patches/node-pty-aix.patch"
    patch -p1 --forward --batch <"$VSX_HOME/patches/node-pty-aix.patch"
    grep -q 'defined(_AIX)' src/unix/pty.cc || { echo "ERROR: AIX patch did not apply" >&2; return 1; }
    # node-pty >= 1.2.0-beta.x closes inherited fds in the child with
    # pty_close_inherited_fds(), but only defines it for Linux while calling
    # it on every non-Apple platform. The fcntl(FD_CLOEXEC) fallback inside
    # works on AIX, so widen the guard.
    if grep -q 'pty_close_inherited_fds' src/unix/pty.cc; then
        python3 - src/unix/pty.cc <<'PY2'
import sys
path = sys.argv[1]
src = open(path).read()
old = "#if defined(__linux__)\n\nstatic int\nSetCloseOnExec(int fd) {"
new = "#if defined(__linux__) || defined(_AIX)\n\nstatic int\nSetCloseOnExec(int fd) {"
if "defined(_AIX)\n\nstatic int\nSetCloseOnExec" in src:
    print("pty_close_inherited_fds already enabled for AIX")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("enabled pty_close_inherited_fds for AIX")
else:
    sys.exit("pty.cc: pty_close_inherited_fds layout changed; update modules/node-pty.sh")
PY2
    fi

    vsx_npm install --ignore-scripts --no-progress --loglevel=error
    [[ -d node_modules/node-addon-api ]] || { echo "ERROR: node-addon-api not installed" >&2; return 1; }

    mkdir -p build/Release lib/native-libs
    cp "$libutil" lib/native-libs/

    echo "compiling pty.cc"
    g++ -c src/unix/pty.cc -o build/Release/pty.o \
        -I"$VSX_NODE_INCLUDE" \
        -Inode_modules/node-addon-api \
        -I/opt/freeware/include \
        -std=gnu++17 -D_GLIBCXX_USE_CXX11_ABI=0 \
        -ftls-model=global-dynamic -fPIC -pthread \
        -Wall -Wextra -Wno-unused-parameter \
        -maix64 -O3 -fno-omit-frame-pointer

    echo "linking pty.node"
    g++ -shared -maix64 -pthread \
        -Wl,-bimport:"$VSX_NODE_EXP" \
        -o build/Release/pty.node build/Release/pty.o \
        lib/native-libs/libutil.so.2 \
        -lpthread -lstdc++

    verify_addon build/Release/pty.node "$PWD/lib/native-libs"
    cp build/Release/pty.node "$out/pty.node"
    mkdir -p "$out/native-libs"
    cp lib/native-libs/libutil.so.2 "$out/native-libs/"
}

mod_node_pty_install() {
    local out=$1 server=$2
    install_file "$out/pty.node" "$server/node_modules/node-pty/build/Release/pty.node"
    mkdir -p "$server/node_modules/node-pty/lib/native-libs"
    cp "$out/native-libs/libutil.so.2" "$server/node_modules/node-pty/lib/native-libs/"
    chmod 755 "$server/node_modules/node-pty/lib/native-libs/libutil.so.2"
    # Upstream ships a macOS-only spawn-helper and prebuilt dirs we do not use.
    rm -rf "$server/node_modules/node-pty/prebuilds" 2>/dev/null || true
}

mod_node_pty_note() { echo "upstream tag + patches/node-pty-aix.patch, links portlibforaix libutil.so.2"; }
