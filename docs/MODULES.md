# AIX fixes: where they live

The runner no longer builds native modules itself. Everything that makes the
server build and run on AIX is in the VSCodium fork
(<https://github.com/tonykuttai/vscodium>, branch `aix`):

| Where | What |
|---|---|
| `patches/aix/00-reh-add-aix-ppc64.patch` | the `aix-ppc64` target in `build/gulpfile.reh.ts` (nodejs.org `aix-ppc64` runtime, `aix-ppc64` in `RIPGREP_PLATFORMS`), the launchers (`bin/codium-server`, `bin/remote-cli/codium`, `bin/helpers/browser.sh`, `bin/aix-env.sh`), the `aix-platform-override.cjs` shim, `.moduleignore.aix` |
| `patches/aix/01-ext-microsoft-authentication-aix.patch` | `case 'aix'` in the extension's esbuild config |
| `patches/aix/02-build-lazy-l10n-dev.patch` | `build/lib/i18n.ts` loads `@vscode/l10n-dev` on first use (its import-time tree-sitter init is little-endian only) |
| `build/aix/package_reh.sh` | the build: `~/.gyp/include.gypi`, `npm ci`, fixes, `npm rebuild` against the target Node, gulp, verify, archive. Mirrors `build/linux/package_reh.sh` |
| `build/aix/fix-node-modules.sh` | per-package edits in `remote/node_modules` (node-pty, @parcel/watcher, kerberos, @vscode/deviceid, ripgrep-universal); **each block's comment names the upstream fix that would make it unnecessary** |
| `build/aix/node-pty-aix.patch`, `build/aix/parcel-watcher-polling.patch` | source patches applied by the fixer |
| `build/aix/ripgrep.sh` | builds `rg` from the tag `@vscode/ripgrep-universal` pins, cached per (tag, rustc) |
| `build/aix/verify_reh.sh` | the smoke test (also run by `vsx smoke`) |
| `docs/howto-build-aix.md` | prerequisites, hand-build procedure, what the package contains that Linux does not |

Read those files for the details; this page only says what breaks on AIX,
how it is worked around, and what would have to change upstream for the
workaround to disappear.

## Catalog

| Component | AIX problem | Fix | Where (fork) | Upstream PR candidate |
|---|---|---|---|---|
| all addons (node-gyp) | Toolbox GCC rejects `-fstack-protector-strong`; addons need `-fPIC` and `-ftls-model=global-dynamic` (local-exec TLS is refused by the loader); 64-bit XCOFF | `~/.gyp/include.gypi` with `cflags!` and the two flags, written by `package_reh.sh`; `-maix64` comes from node-gyp's AIX support | `build/aix/package_reh.sh` | microsoft/node-spdlog, microsoft/node-native-watchdog: make the flag `OS!="aix"` (medium likelihood) |
| all addons (link) | node-gyp takes `node.exp` (template symbols the executable exports) from the *running* node, not `--nodedir`; addons built with the host Node fail to load under the bundled one | fetch the target Node tree once (`~/.cache/vsx/node`) and run `remote/` `npm rebuild` with *its* npm | `build/aix/package_reh.sh` | nodejs/node-gyp: resolve `node.exp` from `--nodedir` on AIX (likely, clear bug) |
| libstdc++ at runtime | addons built by g++ need the GCC runtime on `LIBPATH`; nodejs.org's node does not carry it | `bin/aix-env.sh` prepends the highest installed GCC runtime dir, `/opt/freeware/lib64` and node-pty's `lib/native-libs`; sourced by every launcher | `patches/aix/00-…` | none (downstream launcher) |
| `node-pty` | no `openpty/forkpty/login_tty` in libc; no `<pty.h>`; `pty_close_inherited_fds` only under `__linux__` | `node-pty-aix.patch` (`<termios.h>` ladder, prototypes, targeted guard); link portlibforaix `libutil` from `lib/native-libs`, shipped in the package | `build/aix/fix-node-modules.sh`, `build/aix/node-pty-aix.patch` | microsoft/node-pty: implement the three functions for `_AIX` with `posix_openpt/grantpt/unlockpt/ioctl(TIOCSCTTY)`, no libutil (likely) |
| `@parcel/watcher` | no `OS=="aix"` in `binding.gyp`; `dirent` has no `d_type`; brute-force backend's `subscribe()` throws a bare C string, escapes `catch (std::exception&)` and aborts the File Watcher process, after which VS Code falls back to `fs.watch` = AHAFS | aix gyp block (brute-force + watchman sources, `BRUTE_FORCE_POLLING`); `S_ISDIR(st_mode)` in `legacy.cc`; polling subscriptions (`PARCEL_WATCHER_POLL_INTERVAL_MS`, default 2000 ms); `prebuilds/` removed | `build/aix/fix-node-modules.sh`, `build/aix/parcel-watcher-polling.patch` | parcel-bundler/watcher: `std::runtime_error` instead of C string, `S_ISDIR` fallback (very likely); polling backend and aix gyp block as opt-in (likely) |
| `kerberos` | `kerberos_common.h` selects the win32 SSPI backend unless `__linux__`/`__APPLE__`; gyp lists GSSAPI sources only for mac/linux; `dlopen` of `libgssapi_krb5` by soname fails (Toolbox ships no `.so.2` file) | `_AIX` guard, `OS=="aix"` conditions, libs from `krb5-config --libs gssapi`, `kerberos_use_rtld=false` | `build/aix/fix-node-modules.sh`, `build/aix/package_reh.sh` | mongodb-js/kerberos: `defined(_AIX)` + `OS=="aix"` (likely) |
| `@vscode/deviceid` | `dist/index.js` rejects platforms other than win32/darwin/linux/freebsd; `dist/storage.js` picks a path per OS | `sed`: treat `aix` like `linux` (idempotent) | `build/aix/fix-node-modules.sh` | microsoft/vscode-deviceid: two one-line changes (likely) |
| `@vscode/ripgrep-universal` | ships `bin/<platform>-<arch>/rg` for a fixed list, no AIX | `rg` built from the pinned ripgrep tag (vscode-ripgrep → ripgrep-prebuilt `config.json` → BurntSushi tag), `--features pcre2`, copied to `bin/aix-ppc64/`; `aix-ppc64` added to `RIPGREP_PLATFORMS` | `build/aix/ripgrep.sh`, `build/aix/fix-node-modules.sh`, `patches/aix/00-…` | microsoft/ripgrep-prebuilt `aix-ppc64` (unlikely, no AIX CI; we keep building) |
| ripgrep build (`memmap2` crate) | `madvise()` needs a `caddr_t` cast on AIX | vendor the locked memmap2 version, `sed`, `[patch.crates-io]` | `build/aix/ripgrep.sh` | RazrFalcon/memmap2-rs (likely; check whether a newer version has it) |
| `process.platform` | server, pty host and deviceid have linux/darwin/win32 paths only | `aix-platform-override.cjs` reports `linux` when the stack contains `ptyHost|server-main|server-cli|deviceid`, the real platform otherwise (ripgrep-universal in particular); preloaded via `node -r` and `NODE_OPTIONS=--require` in `bin/aix-env.sh`, inert in non-VS Code processes | `patches/aix/00-…` | none; alternative is `patches/aix` on `src/vs/base/common/platform.ts` (decide after measuring) |
| `fs.watch` | libuv implements it with AHAFS on AIX; the machine-wide monitor pool can wedge the host (incident 2026-10-19) | the shim replaces `fs.watch`/`fs.promises.watch` with stat polling (`VSCODIUM_AIX_FSWATCH_INTERVAL_MS`, default 1000 ms); `{recursive:true}` throws so VS Code uses @parcel/watcher; `VSCODIUM_AIX_FSWATCH=off` restores native for debugging; `verify_reh.sh` fails a build that creates a monitor | `patches/aix/00-…`, `build/aix/verify_reh.sh` | libuv/libuv: issue first (document or optionally disable AHAFS `fs.watch`) |
| `@vscode/l10n-dev` (build tooling) | initialises web-tree-sitter (Emscripten wasm glue, little-endian only) at import; on big-endian the promise rejects and gulp treats it as fatal | `build/lib/i18n.ts` imports it lazily (first XLF/l10n-bundle use, never reached by the REH build) | `patches/aix/02-build-lazy-l10n-dev.patch` | microsoft/vscode: this patch as is (medium); microsoft/vscode-l10n: lazy init (likely) |
| `microsoft-authentication` extension | its esbuild config has no `aix` case | `case 'aix'` with the linux layout | `patches/aix/01-…` | microsoft/vscode (medium; AIX is unsupported there) |
| `jq` on the build host | `malloc(0)` returns NULL on AIX; jq treats it as out of memory on any input | patched `src/jv_alloc.c`, static 64-bit build under `~/local` | host setup ([howto](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md)) | jqlang/jq (likely, portability bug) |
| launchers | `readlink -f` absent on base AIX; `check-requirements-linux.sh` is glibc-only | AIX launchers resolve `ROOT` portably and ship no requirements check (the extension's `server-setup.sh` special-cases aix) | `patches/aix/00-…` | none (downstream) |
| tarball layout | the AIX extension's native-tar extraction needs one top-level directory; VSCodium tars `.` | the runner re-tars with the commit id as top-level dir | `lib/source.sh:source_package` (this repo) | jeanp413/open-remote-ssh, with the rest of the AIX extension support (Phase 4) |

Not needed on AIX: `@vscode/fs-copyfile` (macOS-only addon, JS fallback),
`@vscode/windows-*` (no-ops), `cpu-features`/`ssh2` optional natives (never
built upstream either), `koffi` (gone with VSCodium's copilot removal).

## Adding an AIX fix

1. Reproduce in a kept worktree
   (`vsx build <v> --no-upload --keep-work`, tree at
   `~/.cache/vsx/work/<v>/vscodium`), following the fork's howto for the
   hand steps.
2. Put the fix where it belongs, most upstream-friendly first: a pull
   request to the package; else `patches/aix/*.patch` for VS Code build
   files; else `~/.gyp/include.gypi` for a compiler flag every addon needs;
   else a block in `build/aix/fix-node-modules.sh` (idempotent, guarded by a
   layout check that fails loudly when the package changes, with a comment
   naming the upstream fix).
3. If it ships a new `.node`, add it to the required list in
   `build/aix/verify_reh.sh`; if it changes runtime behaviour, add a check
   there (the smoke test is the only gate).
4. One topic commit on the fork's `aix` branch; its CI proves the patches
   still apply. Then `vsx build <v> --no-upload --keep-work` from the
   runner, a client session against the staged package, and a row in the
   table above.
