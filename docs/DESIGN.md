# Design

This document explains how `vsx` is put together and why. Read it before
changing the runner. For day-to-day operation see
[OPERATIONS.md](OPERATIONS.md); for where each AIX fix lives see
[MODULES.md](MODULES.md). How the server is built (patches, addon fixes, gulp
target, smoke test) is documented in the VSCodium fork:
[docs/howto-build-aix.md](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md).

## 1. Problem

VSCodium publishes a Remote Extension Host (REH) server for Linux, macOS and
Windows only. The AIX fork of
[open-remote-ssh](https://github.com/tonykuttai/open-remote-ssh) needs an AIX
ppc64 server for every VSCodium version a desktop client might run, named and
tagged exactly like upstream, and published on this repository's releases
page. Nobody should have to remember to do that: an AIX host should notice new
upstream releases and publish AIX builds on its own, and tell a human only
when something needs attention.

VSCodium cannot do it for us: its releases are built by GitHub Actions in
Linux containers with cross toolchains or qemu, and AIX has no cross
toolchain, no container image and no hosted runner.

## 2. Approach: build from source, in two repositories

Until 2026-10 the pipeline downloaded VSCodium's Linux x64 server tarball and
transplanted AIX-built native pieces into it. That worked, but every component
needed its own builder, Linux binaries stayed in the package (sqlite3,
kerberos), and nothing could go upstream. The spike of 2026-10-22/23 showed
that VS Code's own build runs natively on AIX: the JS half only needs Node 24
(esbuild ships an `aix-ppc64` binary that is already in VS Code's lockfile),
and the native half is the set of addons we already knew how to build. A
full `gulp vscode-reh-aix-ppc64-min` takes about 8 minutes on
the AIX 7.3 build host (POWER10) with a warm npm cache.

The work is split the way VSCodium itself is split:

| Repository | Holds | Analogue in VSCodium |
|---|---|---|
| fork `tonykuttai/vscodium`, branch `aix` | `patches/aix/*.patch` (the `aix-ppc64` gulp target, launchers, shim, one extension build fix, a lazy l10n-dev import for big-endian build hosts), `build/aix/` (`package_reh.sh`, `fix-node-modules.sh`, `ripgrep.sh`, `verify_reh.sh`, addon patches), `docs/howto-build-aix.md` | `patches/linux/`, `build/linux/package_reh.sh` |
| this repository (`vsx`) | discovery of upstream versions, fork checkout, driving the build, packaging in the release layout, upload, notifications, retention, cron | `.github/workflows/stable-linux.yml` |

The fork is a pure superset of upstream VSCodium: `master` mirrors
`upstream/master`, `aix` is a short stack of topic commits on top, rebased
(never merged) when VSCodium moves `upstream/stable.json`. Builds that were
published are tagged `aix/<version>` so any release can be rebuilt. If
VSCodium ever accepts `patches/aix` + `build/aix` as a community-built target,
the fork shrinks to nothing and the runner keeps working unchanged. The
runner **never carries build logic**; if something about the build needs
fixing, it is fixed in the fork.

## 3. Principles

1. **Track upstream exactly.** Every version is built from the VS Code commit
   VSCodium's `upstream/stable.json` names for it, with VSCodium's own
   `get_repo.sh`, `prepare_vscode.sh` and gulp tasks. The native addons are
   compiled by `npm rebuild` from the versions in VS Code's lockfile, so the
   JS and native halves always agree. The runner refuses to build a version
   from a fork ref whose `stable.json` names a different VS Code tag.
2. **Self-contained packages.** The official nodejs.org AIX build of the Node
   version in `remote/.npmrc` is bundled as `$ROOT/node`, exactly as upstream
   bundles its Linux node. End users need no Node installation.
3. **Prove it before publishing.** `build/aix/verify_reh.sh` runs inside the
   build: every addon is a 64-bit XCOFF object that loads under the bundled
   node; the AIX shim is active in server processes (fs.watch polling,
   platform spoof); `@parcel/watcher.subscribe()` delivers an event; `rg`
   searches; the server boots, `GET /version` answers with its commit; no
   AHAFS monitor was created; the remote CLI runs. The runner then checks
   the tree is complete before packaging.
4. **Every exit path reports.** Failures email and open a GitHub issue;
   successes close the issue; quiet days still produce one digest. There is
   no path that ends in silence.
5. **Idempotent and resumable.** The fork clone, the npm cache, the target
   Node runtime tree and the ripgrep binary are cached; worktrees are
   recreated per build. Uploads skip assets that exist. Re-running anything
   is safe.
6. **Bash only, GNU userland, no root.** The runner must work on a stock
   AIX 7.3 host with Toolbox packages plus a user-local `~/local`,
   unattended, from cron. AIX specifics (ARG_MAX, no `flock`, no `pgrep`,
   `LIBPATH`) are handled in `lib/`.

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
 fork -> worktree -> build (child bash: VSCodium scripts + build/aix/package_reh.sh)
      -> manifest -> package -> upload
```

### Layers

| Path | Role |
|---|---|
| `bin/vsx` | CLI, argument parsing, the per-version pipeline, `upload_version`, prune, cron orchestration |
| `lib/common.sh` | strict mode, logging, ERR trap, locking, version compare, JSON via python |
| `lib/config.sh` | defaults, config file, derived directories |
| `lib/env.sh` | PATH/GNU tools, toolchain facts, report of the tools as the build child sees them, GitHub token |
| `lib/source.sh` | fork sync, ref selection, worktree, the build child, manifest facts, packaging |
| `lib/server.sh` | build manifest (`manifest.json`) and release notes rendered from it |
| `lib/github.sh` | REST calls: upstream discovery, our releases, assets, issues |
| `lib/notify.sh` | events log, attempt tracking, email, issues, digest |
| `config/` | documented example configuration |
| `cron/` | cron entry point |

### The per-version pipeline (`cmd___build_one`)

Stage names are what failure emails quote.

1. **fork**: `fork_sync` clones or fetches `VSX_FORK_REPO` into
   `VSX_FORK_DIR` (`~/.cache/vsx/fork`). `fork_ref_for V` picks tag
   `aix/V` if it exists (a build that was published before), else the head
   of branch `VSX_FORK_REF` (`aix`).
2. **worktree**: a detached `git worktree` at
   `~/.cache/vsx/work/V/vscodium`. Its `upstream/stable.json` must name V's
   VS Code tag (`1.140.06880 -> 1.140.0`; VSCodium encodes the VS Code patch
   level as the first digit of its build number). Otherwise the build stops
   with "rebase the aix branch onto VSCodium tag V and tag it aix/V": the
   runner never builds a version from the wrong VS Code commit.
3. **build**: a child `bash` with `LIBPATH` unset sources
   `VSX_BUILD_ENV_FILE` (`~/local/env.sh`), unsets `LIBPATH` again, and
   runs in the worktree: `get_repo.sh` (shallow VS Code checkout at the
   commit from `stable.json`), `version.sh`,
   `SKIP_NPM_INSTALL=yes prepare_vscode.sh` (VSCodium's patches plus
   `patches/aix`, `product.json`), then `build/aix/package_reh.sh`, which
   installs dependencies, applies the AIX fixes to `node_modules`, rebuilds
   the addons against the target Node, runs
   `gulp vscode-reh-aix-ppc64-min` and `build/aix/verify_reh.sh`. The
   runner passes `RELEASE_VERSION`, `OS_NAME=aix`, the cache directories,
   `VSCODE_AIX_LIBUTIL`/`VSCODE_AIX_RIPGREP`/`VSCODE_AIX_RUST_HOME` from
   its config, and `GITHUB_TOKEN`.
4. **manifest**: `manifest_from_reh` records the server commit, VS Code
   tag and commit, fork ref and commit, bundled Node version, the version
   of every shipped addon and of `rg`, the toolchain and host, and the
   `aix_build` counter (how many times this version was published).
5. **package**: `vscode-reh-aix-ppc64/` is copied under a directory named
   after the commit id and tarred as
   `releases/V/vscodium-reh-aix-ppc64-V.tar.gz`, with
   `aix-build-manifest.json` inside, plus `.sha256`, `.info` and `.json`.
   VSCodium's own tarballs are `.`-rooted; ours has one top-level directory
   because the AIX extension's native-tar extraction path needs one
   (`--strip-components 1` works with both).
6. **upload**: create or update the release, upload missing assets, set
   `make_latest` only if this is the highest version we publish (backfills
   must not steal "latest"; the extension falls back to `/releases/latest`).
7. The worktree and work dir are removed unless `--keep-work`; the attempt
   counter is cleared.

### Release contract with the extension

Unchanged from the transplant pipeline, and the reason the switch was
invisible to users: tag == VSCodium version, asset
`vscodium-reh-aix-ppc64-<version>.tar.gz`, one top-level directory in the
tarball, bundled Node, `/releases/latest` is the newest version. The
`aix_build` counter and `built` timestamp in the manifest let the extension
refresh an install when a version is rebuilt under the same tag.

### State and caches

| Location | Contents | Lifetime |
|---|---|---|
| `~/.local/state/vsx/` | lock, `events.jsonl`, `attempts/<v>`, `digest.last`, `last-pipeline-error`, `logs/` | small, kept |
| `~/.cache/vsx/fork/` | clone of the VSCodium fork | kept, fetched each build |
| `~/.cache/vsx/work/<v>/` | `vscodium/` worktree (with `vscode/` checkout and `vscode-reh-aix-ppc64/` output), `stage/`, `manifest.json` | removed on success |
| `~/.cache/vsx/npm/` | npm cache (`npm_config_cache`) | kept; the reason later builds take minutes |
| `~/.cache/vsx/node/` | target Node runtime trees (headers, `node.exp`) fetched by `package_reh.sh` | kept (one per version) |
| `~/.cache/vsx/ripgrep/` | `rg` built by `build/aix/ripgrep.sh`, per (tag, rustc) | kept |
| `<repo>/releases/<v>/` | packaged artifacts | newest `VSX_KEEP_RELEASES` kept |

## 5. Decisions and alternatives considered

**Build on the AIX host, not hybrid.** The alternative was VSCodium's Linux
`package_reh.sh` in a ppc64le container plus `remote/node_modules` built on
AIX and shipped across, the way VS Code does for alpine: two machines and an
rsync hand-off for the same patch set. One machine and one cron won once the
spike showed the whole build runs natively in minutes.

**Fork + runner, not one repository.** The patches and build scripts mirror
VSCodium's layout so that an upstream pull request is a copy; the runner is
what VSCodium's GitHub Actions do for them and is not upstream material.
Secrets, cron and notifications stay out of the fork.

**Tag what we ship.** `fork_ref_for` prefers `aix/<version>`, so a rebuild
(`--force`) uses the fork commit that produced the published package, not
whatever `aix` has become since.

**Refuse a mismatched `stable.json`.** Building version V from a fork ref
prepared for another VS Code release would produce a server with a commit id
the extension never matches. One JSON read turns that late, confusing
failure into a one-line instruction.

**Bundle Node.** nodejs.org ships official `aix-ppc64` tarballs that run on
AIX 7.3 with the Toolbox GCC runtime; gulp fetches the version from
`remote/.npmrc` and the addons are linked against that exact tree's
`node.exp`. Bundling costs ~40 MB compressed and removes a whole class of
failures (root-installed Node of the right major on every target).

**One child process per version.** Bash cannot keep `errexit` alive inside
`if ! build_one; then`, and a loop over versions must survive one failure.
Re-executing `vsx __build-one` gives each build clean error semantics and an
EXIT trap that notifies. The build itself runs in a further child `bash` so
VSCodium's `set -e` scripts and `~/local/env.sh` never touch the runner's
shell.

**Never export the runtime `LIBPATH` into the build.** The Toolbox compiler
binaries are 32-bit; with the 64-bit runtime directories that
`bin/aix-env.sh` sets first on `LIBPATH`, `gcc` refuses to start. The build
child starts with `LIBPATH` unset and unsets it again after sourcing the
environment file.

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
polling: `@parcel/watcher` with a polling `subscribe` backend for
workspaces, and an `fs.watch` shim in the preloaded override for VS Code's
own handful of non-recursive watches. The smoke test fails a build whose
server creates a monitor. Slower reaction to external changes is the
accepted price.

**No `jq`, no `flock`, no `pgrep` in the runner.** Python 3 is on every
Toolbox host, so the runner's JSON goes through `jpy`, locks are `mkdir`,
processes are `ps | grep`. Large JSON never travels through argv (AIX
`ARG_MAX` is small). VSCodium's own scripts do need `jq`, which is why the
build host carries a user-local one.

## 6. Known gaps / future work

* All file watching is polling (see "Never touch AHAFS" above), so large
  workspaces react more slowly than on Linux and the git pane can lag. A
  native AHAFS backend for `@parcel/watcher` is upstream-sized work and not
  planned.
* The `process.platform` shim is still a runtime preload. Replacing it with
  source patches (`platform.ts` plus the handful of direct checks) is
  possible now that the source is built; decide after measuring what breaks
  each way.
* Big-endian: `@vscode/l10n-dev`'s tree-sitter init is deferred during the
  build; VS Code's Node-only unit tests (`npm run test-node`) have not been
  run on AIX yet and may surface more endianness findings.
* Only `powerpc-ibm-aix7.3` is tested. Packages likely run on 7.2 TL5 with a
  recent Toolbox GCC runtime, but nothing checks that.
* The smoke test does not open a terminal. Driving the server over its
  protocol (`scripts/test-remote-integration.sh`) would catch more.
* Caching is coarse: checkout and `node_modules` are redone per version
  (fast thanks to the npm cache). Per-commit caches would help if upstream
  ever publishes several versions a day.
* Every AIX fix is a downstream workaround; [MODULES.md](MODULES.md) lists
  the upstream pull requests that would remove them.
