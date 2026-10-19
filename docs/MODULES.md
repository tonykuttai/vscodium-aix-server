# Native modules: AIX notes

What each component needs on AIX, where its version comes from, and what to
look at when it breaks. The code is in `modules/<name>.sh`; shared helpers in
`lib/modules.sh`.

Common to all C/C++ addons:

* Compiled against the headers of the Node runtime that will be bundled
  (`$VSX_NODE_INCLUDE`), linked with its import file (`-Wl,-bimport:node.exp`),
  using the runtime's own `npm` and `node-gyp` (`vsx_npm`, `vsx_node_gyp`,
  which pass `--nodedir` so no headers are downloaded).
* Flags: `CFLAGS/CXXFLAGS="-ftls-model=global-dynamic -fPIC -pthread"`,
  64-bit (`-maix64`, set by node-gyp's AIX support).
* Upstream `binding.gyp` files often add `-fstack-protector-strong`, which
  Toolbox GCC rejects; `strip_stack_protector` removes it.
* Output is verified with `verify_addon`: must be a 64-bit XCOFF object and
  must `require()` under the bundled node.
* Results are cached in `~/.cache/vsx/modules/<name>/<version>-node<ABI>/`.

## native-watchdog (`@vscode/native-watchdog`)

* Source: `microsoft/node-native-watchdog`, tag `v<version>`.
* Build: `node-gyp rebuild` after stripping the stack protector flag.
* Install: `node_modules/@vscode/native-watchdog/build/Release/watchdog.node`
  (and the legacy unscoped `node_modules/native-watchdog/` if present).

## node-spdlog (`@vscode/spdlog`)

* Source: `microsoft/node-spdlog`, tag `v<version>`; spdlog itself is a git
  submodule (`git submodule update --init --recursive`).
* Build: `npm install --ignore-scripts` (for `node-addon-api`), then
  `node-gyp rebuild`.
* Runtime: needs libstdc++ from the GCC runtime on `LIBPATH`;
  `bin/aix-env.sh` adds the highest installed GCC runtime directory.

## node-pty

* Source: `microsoft/node-pty`, tag `v<version>` (currently `v1.2.0-beta.15`).
* AIX problems: no `<pty.h>` functions in libc (`openpty`, `forkpty`,
  `login_tty`); newer versions call `pty_close_inherited_fds()` which upstream
  only defines for Linux.
* Fixes:
  * `patches/node-pty-aix.patch` (3 hunks): AIX includes, `extern "C"`
    prototypes for the three pty functions. Extracted from the
    `tonykuttai/node-pty` fork, whose actual AIX diff is these ~27 lines.
  * the module script widens `#if defined(__linux__)` around
    `SetCloseOnExec`/`pty_close_inherited_fds` to include `_AIX` (the
    `fcntl(FD_CLOEXEC)` fallback works on AIX).
  * `libutil.so.2` from [portlibforaix](https://github.com/tonykuttai/portlibforaix)
    provides the pty functions. `env_ensure_portlib` clones and builds it
    into `~/local/portlibforaix` once. The library is linked explicitly and
    shipped at `node_modules/node-pty/lib/native-libs/libutil.so.2`;
    `bin/aix-env.sh` puts that directory on `LIBPATH`.
* Build: by hand with `g++` (compile + link), not node-gyp. **Do not add
  portlibforaix's `include/` to the include path**: it contains a `stdio.h`
  that shadows the system header and breaks `<cstdio>`.
* Verified with `LIBPATH` pointing at `lib/native-libs`.
* The JS side (`lib/unixTerminal.js`) calls `pty.fork()` with a signature
  that changed over time; building the same tag the server bundles keeps
  both sides in sync. If a future tag changes `pty.cc` so the patch no
  longer applies, regenerate it: the three blocks are the `_AIX` include
  block near the top, the `_AIX` branch in the platform include ladder, and
  the `extern "C"` prototypes after the `POSIX_SPAWN_SETSID` define.

## parcel-watcher (`@parcel/watcher`)

* Source: `parcel-bundler/watcher`, tag `v<version>`.
* AIX problems: no `OS=="aix"` branch in `binding.gyp`; `struct dirent` has
  no `d_type`.
* Fixes (in the module script):
  * a Python edit inserts an `OS=="aix"` block using the brute-force backend
    (`src/unix/legacy.cc`, `src/shared/BruteForceBackend.cc`) and the
    watchman backend sources, with our flags; the file is re-validated with
    `ast.literal_eval` (gyp files are Python literals).
  * `legacy.cc`: `bool isDir = ent->d_type == DT_DIR;` becomes
    `S_ISDIR(attrib.st_mode)`; the `fstatat()` filling `attrib` is on the
    previous line upstream.
* Build: `npm install --ignore-scripts`, `node-gyp rebuild`.
  * `patches/parcel-watcher-polling.patch`: upstream's brute-force backend
    has no `subscribe()` (it throws a C string, which escapes Backend.cc's
    `catch (std::exception&)` and aborts the extension host). Behind
    `BRUTE_FORCE_POLLING` (defined in our gyp block) the patch adds one
    polling thread per watcher: rescan with `readTree`, diff with
    `DirTree::getChanges`, `watcher->notify()`. State lives on
    `Watcher::state`; the thread never takes `Backend::mMutex`, so
    `unsubscribe` (called with it held) can join safely. Errors during a
    rescan go through `mEvents.error()` and polling continues.
* Install: `node_modules/@parcel/watcher/build/Release/watcher.node`;
  `prebuilds/` is removed so the loader cannot pick a Linux binary.
* Consequence: file watching polls (`PARCEL_WATCHER_POLL_INTERVAL_MS`,
  default 2000 ms, wait stretches to 3x scan time). Fine for normal
  projects; large trees are slower to react than on Linux.

## ripgrep

* Which version: VS Code depends on `@vscode/ripgrep-universal` (>= 1.140)
  or `@vscode/ripgrep` (older). Both come from `microsoft/vscode-ripgrep`,
  whose `build/platforms.js` (universal) or `lib/postinstall.js` (classic)
  pins a `microsoft/ripgrep-prebuilt` release, whose `config.json` names the
  `BurntSushi/ripgrep` tag. `mod_ripgrep_wanted` follows that chain (1.140 →
  universal 1.18.0 → prebuilt v15.0.1 → ripgrep 15.0.0). If any link is
  missing it falls back to `VSX_RIPGREP_FALLBACK_TAG` and logs a warning.
* AIX problems: `memmap2`'s `madvise()` needs a `caddr_t` cast; upstream
  HEAD may need a newer Rust than the Toolbox ships.
* Fixes: the memmap2 version from `Cargo.lock` is cloned into `vendor/`,
  patched with `sed`, and wired in with `[patch.crates-io]`; the tag's
  `rust-version` is compared with the host `rustc` first
  (`rust_check_msrv`) so a too-old toolchain fails in seconds with a clear
  message.
* Build: `cargo build --release --features pcre2` (bundled PCRE2, JIT works).
* Cache key: `<tag>-rustc<version>` so a Rust upgrade recompiles.
* Install: for ripgrep-universal, `bin/aix-ppc64/rg` **and**
  `bin/linux-ppc64/rg` (its `index.js` builds the path from
  `process.platform`, which the override reports as `linux` when loaded
  from the server); other platform directories are removed. For classic
  `@vscode/ripgrep`, `bin/rg`.

## deviceid (`@vscode/deviceid`)

* No compilation. `dist/index.js` refuses platforms other than
  win32/darwin/linux/freebsd and `dist/storage.js` picks a path per OS; both
  are `sed`-patched in place to treat `aix` like `linux`. Idempotent.
* The Windows-only `build/Release/windows.node` is left alone.

## The runtime shim (`templates/aix-platform-override.js`)

Not a module, but it is what makes the modules usable. Preloaded into every
Node process of the server via `NODE_OPTIONS=--require` (set in
`bin/aix-env.sh`) and `-r` in the launchers; inert outside VS Code's own
processes (it checks `process.argv` for `server-main.js`, `server-cli.js`,
`bootstrap-fork` or a `--type=` child and otherwise removes itself from
`NODE_OPTIONS`).

* `process.platform` returns `linux` when the call stack contains `ptyHost`,
  `server-main`, `server-cli` or `deviceid`; `aix` otherwise.
* `fs.watch` / `fs.promises.watch` are replaced with stat polling
  (`PollingFSWatcher`): non-recursive directory and file watches, the
  `FSWatcher` events `change`/`rename`/`error`/`close`, `ref`/`unref`,
  `AbortSignal`; `{ recursive: true }` throws
  `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM` so VS Code uses @parcel/watcher.
  Reason: libuv's `fs.watch` on AIX is AHAFS (`/aha`), whose monitor pool is
  shared machine-wide and, once exhausted or wedged, blocks every process
  that touches it in an unkillable state (incident 2026-10-19, see
  `notes/AIX-WATCHERS-AND-BINARIES.md`). `VSCODIUM_AIX_FSWATCH=off` restores
  native behaviour for debugging; `=force` applies the shim in any process
  (used by the local test).
* Tested off-AIX with any Node:
  `VSCODIUM_AIX_FSWATCH=force node -r templates/aix-platform-override.js <test>`.
  The smoke test on AIX fails the build if a monitor for its paths appears
  under `/aha/fs/modDir.monFactory`.

## Not rebuilt (yet)

* `@vscode/sqlite3` (`vscode-sqlite3.node`) and `kerberos`: Linux binaries
  remain in the package. The server starts and works without them. If a
  future VS Code needs sqlite on the server side, add `modules/sqlite3.sh`
  (it is a straightforward node-gyp build) and add it to `VSX_MODULES` and
  the smoke test's required list.

## Adding a module

1. Create `modules/<name>.sh` defining `mod_<name>_wanted`, `_build`,
   `_install` (and optionally `_cache_key`, `_note`). Use the helpers:
   `git_clone_tag`, `strip_stack_protector`, `vsx_npm`, `vsx_node_gyp`,
   `verify_addon`, `install_file`.
2. Append the name to `VSX_MODULES` in `lib/modules.sh` (native builds
   before JS patches).
3. If it ships a `.node` file, add its path to `required` in
   `server_smoke_test` (`lib/server.sh`).
4. Test with `vsx module <name> <vscodium-version>` then a full
   `vsx build <version> --no-upload`.
5. Document it here.
