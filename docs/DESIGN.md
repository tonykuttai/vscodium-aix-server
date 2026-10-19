# Design

This document explains how `vsx` is put together and why. Read it before
changing the pipeline. For day-to-day operation see
[OPERATIONS.md](OPERATIONS.md); for the per-module AIX specifics see
[MODULES.md](MODULES.md).

## 1. Problem

VSCodium publishes a Remote Extension Host (REH) server for Linux, macOS and
Windows only. The AIX fork of
[open-remote-ssh](https://github.com/tonykuttai/open-remote-ssh) needs an AIX
ppc64 server for every VSCodium version a desktop client might run, named and
tagged exactly like upstream, and published on this repository's releases
page. Nobody should have to remember to do that: an AIX host should notice new
upstream releases and publish AIX builds on its own, and tell a human only
when something needs attention.

## 2. Approach: repackage, don't rebuild

Building VS Code from source on AIX is not realistic (Electron toolchain,
hours of build time, constant upstream churn). Almost all of the server is
platform-neutral JavaScript. What is platform specific is small:

| What | Why it matters on AIX |
|---|---|
| `node` runtime | upstream ships a Linux x86-64 ELF binary |
| `@vscode/native-watchdog` | C++ addon |
| `@vscode/spdlog` | C++ addon |
| `node-pty` | C++ addon, needs `openpty`/`forkpty` that AIX libc lacks |
| `@parcel/watcher` | C++ addon, no AIX backend upstream |
| ripgrep (`@vscode/ripgrep-universal`) | Rust binary |
| `@vscode/deviceid` | JS that rejects unknown platforms |
| `process.platform` | VS Code only has `linux`/`darwin`/`win32` code paths |

So the pipeline downloads the upstream `vscodium-reh-linux-x64-<v>.tar.gz`,
replaces exactly those pieces with AIX builds, proves the result starts, and
re-tars it as `vscodium-reh-aix-ppc64-<v>.tar.gz`.

## 3. Principles

1. **Track upstream exactly.** Every native component is built from the
   upstream tag matching the version found in the downloaded server's own
   `node_modules/<pkg>/package.json`. The JS half and the native half of a
   module therefore always agree. "Latest" means "what upstream ships", not
   "HEAD of some repo", which is what broke ripgrep in September 2026.
2. **Self-contained packages.** The official nodejs.org AIX build of the Node
   major upstream targets is bundled as `$ROOT/node`, exactly as upstream
   bundles its Linux node. End users need no Node installation.
3. **Prove it before publishing.** A build is only packaged after every
   addon loads under the bundled runtime, ripgrep runs, the real server
   starts, logs `Extension host agent listening`, answers `GET /version`,
   and has created no AHAFS monitor. The server is run in its own process
   group and stopped by polling, never by a blocking `wait`.
4. **Every exit path reports.** Failures email and open a GitHub issue;
   successes close the issue; quiet days still produce one digest. There is
   no path that ends in silence (the original pipeline had three).
5. **Idempotent and resumable.** Module builds are cached by (module,
   version, Node ABI). Uploads skip assets that exist. Re-running anything is
   safe.
6. **Bash only, GNU userland, AIX quirks isolated.** The build must run on a
   stock AIX 7.3 host with Toolbox packages, unattended, from cron. All AIX
   specifics (ARG_MAX, no `flock`, no `jq`, no `pgrep`, `LIBPATH`, XCOFF) are
   handled in `lib/` so module scripts stay readable.

## 4. Architecture

```
            cron (every 4h)
                 |
          cron/vsx-cron.sh            minimal env, appends to cron-wrapper.log
                 |
             bin/vsx cron             lock -> discover -> build each -> prune -> digest
                 |
     +-----------+-----------+
     |                       |
 bin/vsx __build-one V   bin/vsx __build-one W      one child process per version
     |                                              (keeps errexit semantics)
     v
 fetch -> runtime -> modules -> node+launchers -> smoke -> package -> upload
```

### Layers

| Path | Role |
|---|---|
| `bin/vsx` | CLI, argument parsing, the per-version pipeline, cron orchestration |
| `lib/common.sh` | strict mode, logging, ERR trap, locking, version compare, JSON via python |
| `lib/config.sh` | defaults, config file, derived directories |
| `lib/env.sh` | PATH/GNU tools, toolchain facts, GitHub token, portlibforaix, Node runtime selection |
| `lib/github.sh` | REST calls: upstream discovery, our releases, assets, issues |
| `lib/notify.sh` | events log, attempt tracking, email, issues, digest |
| `lib/server.sh` | server tree: fetch, inspect, runtime install, launchers, smoke test, package, release notes |
| `lib/modules.sh` | module contract, cache, runner, shared helpers |
| `modules/*.sh` | one file per native component |
| `templates/` | launcher scripts and the platform override shipped in the package |
| `patches/` | source patches applied to upstream tags |
| `config/` | documented example configuration |
| `cron/` | cron entry point |

### The per-version pipeline (`cmd___build_one`)

1. **fetch** the upstream REH tarball into `~/.cache/vsx/downloads` and
   extract to `~/.cache/vsx/work/<v>/server`.
2. **runtime**: derive the VS Code tag (`1.140.06880 -> 1.140.0`), read
   `remote/.npmrc` from microsoft/vscode for `target=`, pick that version
   (or the newest same-major) with an `aix-ppc64` tarball on nodejs.org,
   download, verify SHA256, cache under `~/.cache/vsx/node`. Export
   `VSX_NODE_*` so every module compiles against *this* runtime's headers
   and `node.exp`, and uses *its* npm/node-gyp.
3. **modules**: for each entry of `VSX_MODULES`, `module_run` asks the module
   for the wanted version, builds it (cached), installs it into the tree and
   records it in `manifest.json`.
4. **node + launchers**: replace the ELF `node` with the stripped AIX one;
   render `bin/<app>-server`, `bin/remote-cli/<app>`, `bin/aix-env.sh` and
   `aix-platform-override.cjs` from `templates/`.
5. **smoke**: required addons present + XCOFF + load; ripgrep runs; server
   boots to "Extension host agent listening" within `VSX_SMOKE_TIMEOUT`.
6. **package**: tar with the commit id as the single top-level directory
   (the extension extracts with `--strip-components 1`), plus `.sha256`,
   `.info`, `.json` (manifest).
7. **upload**: create or update the release, upload missing assets, set
   `make_latest` only if this is the highest version we publish (backfills
   must not steal "latest"; the extension falls back to `/releases/latest`).

### Module contract

A module is a sourced bash file defining `mod_<name>_wanted`, `_build`,
`_install`, optionally `_cache_key` and `_note`. See the header of
`lib/modules.sh`. Builds run in a subshell with `set -e` re-enabled so any
failing command aborts the build (bash silently disables `-e` inside anything
tested by `if`/`||`/`!`; the original scripts fell into exactly that trap).

### State and caches

| Location | Contents | Lifetime |
|---|---|---|
| `~/.local/state/vsx/` | lock, `events.jsonl`, `attempts/<v>`, `digest.last`, `logs/` | small, kept |
| `~/.cache/vsx/downloads/` | upstream tarballs, node tarballs, nodejs index | pruned with releases |
| `~/.cache/vsx/node/` | extracted Node runtimes | kept (one per version) |
| `~/.cache/vsx/modules/<m>/<key>/` | module sources + build log + artifacts | kept (rebuild by deleting) |
| `~/.cache/vsx/work/<v>/` | server tree being built | removed on success |
| `<repo>/releases/<v>/` | packaged artifacts | newest `VSX_KEEP_RELEASES` kept |

## 5. Decisions and alternatives considered

**Bundle Node instead of relying on `/opt/nodejs`.** The old packages
dispatched to `/opt/nodejs/bin/node` on the *user's* machine, so every AIX
target needed a root-installed Node of the right major, and the build host's
Node had to match too. nodejs.org ships official `aix-ppc64` tarballs, they
run on AIX 7.3 with the Toolbox GCC runtime, and their npm/node-gyp work on
AIX. Bundling costs ~40 MB compressed and removes a whole class of failures.
`VSX_NODE_RUNTIME=host` keeps the old behaviour if ever needed.

**Build modules at the bundled version, not a fork's HEAD.** node-pty was
built from a fork that had diverged 213 commits behind upstream, with build
artifacts committed. The fork's actual AIX change is 27 lines; it now lives
in `patches/node-pty-aix.patch` and is applied to the upstream tag. One
additional guard change for newer node-pty is done in the module script.

**One child process per version.** Bash cannot keep `errexit` alive inside
`if ! build_one; then`, and a loop over versions must survive one failure.
Re-executing `vsx __build-one` gives each build clean error semantics and an
EXIT trap that notifies.

**GitHub issues in addition to email.** Mail on AIX depends on sendmail
configuration that nobody monitors; an issue is visible to every maintainer
and closes itself when the version finally publishes.

**Every upstream release, oldest first.** The desktop client asks for its own
exact version. Building only "latest" at each cron tick skips releases that
appear between ticks. Oldest-first means `make_latest` ends on the highest.

**Attempt limiter.** A version that fails three times is parked for 24h so a
broken upstream does not produce an email every four hours, while still
retrying automatically later and immediately with `--retry`.

**Never touch AHAFS.** AIX's kernel file-event filesystem (`/aha`), which
libuv uses for `fs.watch`, has a machine-wide monitor pool; when it wedges,
every process entering it blocks unkillably until root remounts `/aha` or
reboots (incident 2026-10-19). All file watching in the package is therefore
polling: `@parcel/watcher` with a polling `subscribe` patch for workspaces,
and an `fs.watch` shim in the preloaded override for VS Code's own handful of
non-recursive watches. Slower reaction to external changes is the accepted
price.

**No `jq`, no `flock`, no `pgrep`.** Not on the Toolbox host. Python 3 is,
so JSON goes through `jpy`, locks are `mkdir`, processes are `ps | grep`.
Large JSON never travels through argv (AIX `ARG_MAX` is small).

## 6. Known gaps / future work

* `@vscode/sqlite3` and `kerberos` remain Linux binaries in the package. The
  server starts and works without them today (they are loaded lazily); if a
  future VS Code requires sqlite on the server, add a module for it.
* All file watching is polling (see "Never touch AHAFS" above), so large
  workspaces react more slowly than on Linux. An AHAFS backend is not a
  goal: it is the thing that took the build host down.
* Only `powerpc-ibm-aix7.3` is tested. Packages likely run on 7.2 TL5 with a
  recent Toolbox GCC runtime, but nothing checks that.
* The smoke test proves the server starts; it does not open a terminal or
  search. Driving the server over its protocol would catch more.
* Rust on the host is whatever the Toolbox provides. If a ripgrep tag ever
  needs a newer MSRV than installed, the build fails fast with a clear
  message; the fix is a user-local or Toolbox Rust upgrade.
