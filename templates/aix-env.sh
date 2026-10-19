# AIX runtime environment for the VSCodium server. Sourced (not executed) by
# bin/*-server and bin/remote-cli/*. The caller sets $ROOT.
#
# AIX resolves shared libraries through LIBPATH. Two things must be on it:
#   * the GCC C++ runtime (libstdc++ / libgcc_s) used by node and the addons
#   * libutil.so.2 (portlibforaix) that node-pty links against
#
# Override detection by exporting VSCODIUM_AIX_GCC_LIBPATH before launch.

_vsx_gcc_libpath="${VSCODIUM_AIX_GCC_LIBPATH:-}"
if [ -z "$_vsx_gcc_libpath" ]; then
    for _base in /opt/freeware/lib/gcc /usr/local/lib/gcc /usr/lib/gcc; do
        [ -d "$_base" ] || continue
        # Highest GCC version wins; prefer the pthread variant.
        _cand=$(ls -d "$_base"/*/*/pthread/ppc64 2>/dev/null | awk -F/ '{print $(NF-2) " " $0}' | sort -n | tail -1 | cut -d' ' -f2)
        if [ -z "$_cand" ]; then
            _cand=$(ls -d "$_base"/*/*/ppc64 2>/dev/null | awk -F/ '{print $(NF-1) " " $0}' | sort -n | tail -1 | cut -d' ' -f2)
        fi
        if [ -n "$_cand" ]; then _vsx_gcc_libpath="$_cand"; break; fi
    done
fi

_vsx_libpath="$ROOT/@PTY_LIBDIR@:/opt/freeware/lib/pthread/ppc64:/opt/freeware/lib"
[ -n "$_vsx_gcc_libpath" ] && _vsx_libpath="$_vsx_gcc_libpath:$_vsx_libpath"
LIBPATH="$_vsx_libpath${LIBPATH:+:$LIBPATH}"
export LIBPATH

# Preload the AIX shim (process.platform + fs.watch without AHAFS) into every
# Node process the server spawns (extension host, pty host, file watcher).
# The shim is inert in processes that are not VS Code's and removes itself
# from NODE_OPTIONS there, so user programs in terminals are unaffected.
case " ${NODE_OPTIONS:-} " in
    *aix-platform-override.cjs*) ;;
    *) NODE_OPTIONS="--require $ROOT/aix-platform-override.cjs${NODE_OPTIONS:+ $NODE_OPTIONS}"; export NODE_OPTIONS ;;
esac

# GNU userland first: the server shells out to tar/find/ps etc.
case ":$PATH:" in
    *:/opt/freeware/bin:*) ;;
    *) PATH="/opt/freeware/bin:$PATH"; export PATH ;;
esac

unset _vsx_gcc_libpath _vsx_libpath _base _cand
