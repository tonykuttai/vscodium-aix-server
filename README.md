# VSCodium Remote Server for IBM AIX

Unofficial builds of the VSCodium Remote Extension Host (REH) server for
**IBM AIX 7.3 on POWER (ppc64)**, plus `vsx`, the runner that builds and
publishes them automatically whenever VSCodium releases.

VSCodium itself does not support AIX. These packages are what the
[open-remote-ssh AIX fork](https://github.com/tonykuttai/open-remote-ssh)
installs on the remote machine so that a VSCodium desktop can open folders,
terminals and extensions on AIX over SSH.

* **Project site:** <https://tonykuttai.github.io/vscodium-aix-server/>
* **Releases:** <https://github.com/tonykuttai/vscodium-aix-server/releases>
  (tag = VSCodium version, asset `vscodium-reh-aix-ppc64-<version>.tar.gz`)
* **Issues:** <https://github.com/tonykuttai/vscodium-aix-server/issues>
  (build failures are filed there automatically, label `build-failure`)
* **Source of the server:** the VSCodium fork
  <https://github.com/tonykuttai/vscodium>, branch `aix` (`patches/aix/`,
  `build/aix/`, [docs/howto-build-aix.md](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md))

---

## Contents

1. [What you get](#1-what-you-get)
2. [Using a release on an AIX machine](#2-using-a-release-on-an-aix-machine)
3. [What the runner does](#3-what-the-runner-does)
4. [Setting up a build host](#4-setting-up-a-build-host)
5. [Command reference](#5-command-reference)
6. [Configuration reference](#6-configuration-reference)
7. [Notifications](#7-notifications)
8. [Everyday operations](#8-everyday-operations)
9. [Repository layout](#9-repository-layout)
10. [Known limitations](#10-known-limitations)
11. [Contributing](#11-contributing)

---

## 1. What you get

Each release is the VSCodium server **built from source on AIX** with VS
Code's own build pipeline (`gulp vscode-reh-aix-ppc64-min`), from the
VSCodium fork's `aix` branch at the upstream release's VS Code commit. The
fork adds an `aix-ppc64` target and the few AIX fixes the native dependencies
need; nothing in VS Code's `src/` is patched.

| Component | What is in the package |
|---|---|
| Node.js runtime | The official nodejs.org `aix-ppc64` build of the Node version VS Code targets for that release (`remote/.npmrc`), fetched by gulp. **No Node installation is required on the AIX machine.** |
| `node-pty` (terminals) | Built by node-gyp from the version the server depends on, with a small AIX patch; links `libutil.so.2` from [portlibforaix](https://github.com/tonykuttai/portlibforaix), shipped inside the package |
| `@vscode/spdlog`, `@vscode/native-watchdog` | Built by node-gyp (stack-protector flag stripped) |
| `@parcel/watcher` (file watching) | Built with an AIX gyp block and a polling `subscribe()` backend |
| `@vscode/sqlite3`, `kerberos` | Real AIX builds (kerberos against the Toolbox MIT krb5) |
| ripgrep (search) | Built from the exact ripgrep tag `@vscode/ripgrep-universal` pins, with PCRE2, installed as `bin/aix-ppc64/rg` |
| `@vscode/deviceid` | Patched to accept `aix` |
| Launchers | `bin/codium-server`, `bin/remote-cli/codium`, `bin/helpers/browser.sh` and `bin/aix-env.sh` set `LIBPATH` and preload `aix-platform-override.cjs` into every server process |
| `aix-platform-override.cjs` | Makes the few server code paths that only know linux/darwin/win32 take the Linux path (`process.platform`) and replaces `fs.watch` with stat polling so the server never touches AHAFS, the AIX kernel file-event system, which can wedge a whole machine (see [docs/OPERATIONS.md](docs/OPERATIONS.md#ahafs)) |

Every release page carries a table of exactly which versions went in
(generated from `aix-build-manifest.json`, which is also inside the tarball),
the fork ref and commit the server was built from, the SHA256, and install
instructions. The runner only publishes a package after the server has been
started on the build host, answered `GET /version` with its commit, and
created no AHAFS monitor.

The runner as a whole provides:

* automatic detection of new VSCodium releases and publication of AIX builds
  (cron, every 4 hours by default);
* backfill of every upstream release that is missing from the releases page;
* reproducible builds: every published package records the fork commit it
  was built from, and shipped builds are tagged `aix/<version>` in the fork;
* a smoke test gate, checksums and a build manifest per release;
* failure emails, GitHub issues that open on failure and close on success,
  and a daily digest so a quiet pipeline is distinguishable from a dead one;
* retention of local artifacts and logs;
* a host check that tells a new maintainer what is missing.

---

## 2. Using a release on an AIX machine

### Requirements on the target

* AIX 7.3 on POWER (`uname -p` = `powerpc`, 64-bit kernel). AIX 7.2 TL5 is
  untested but likely works.
* GCC runtime libraries from the AIX Toolbox: packages `libstdc++` and
  `libgcc`, GCC 12 or newer (they install under `/opt/freeware/lib`). Any
  host with the Toolbox `gcc` package already has them. Check:
  ```sh
  ls /opt/freeware/lib/pthread/ppc64/libstdc++.a /opt/freeware/lib/libgcc_s.a
  ```
* `krb5-libs` from the Toolbox (the `kerberos` addon links MIT krb5; present
  on most hosts).
* GNU tar (Toolbox `tar`) is recommended for extracting; `wget` or `curl`
  for downloading.
* Nothing else: Node.js is bundled.

### With the open-remote-ssh AIX extension (normal case)

Install the [AIX fork of open-remote-ssh](https://github.com/tonykuttai/open-remote-ssh)
in VSCodium and connect. The extension reads its own VSCodium version,
downloads `vscodium-reh-aix-ppc64-<version>.tar.gz` from this repository's
releases, extracts it under `~/.vscodium-server/bin/<commit>/` on the AIX
host and starts it. If no release exists for that exact version it falls back
to the latest published one.

### Manually

The commands on every release page are, for version `V` with commit `C`:

```sh
wget https://github.com/tonykuttai/vscodium-aix-server/releases/download/V/vscodium-reh-aix-ppc64-V.tar.gz
mkdir -p ~/.vscodium-server/bin/C
tar -xzf vscodium-reh-aix-ppc64-V.tar.gz -C ~/.vscodium-server/bin/C --strip-components 1
~/.vscodium-server/bin/C/bin/codium-server --version
```

`C` is in the `.info` and `.json` assets and inside the tarball (it is the
single top-level directory). To run the server by hand:

```sh
~/.vscodium-server/bin/C/bin/codium-server --accept-server-license-terms \
    --host 127.0.0.1 --port 8000 --without-connection-token
```

### If it does not start

* `exec: node: cannot execute` or `0509-036`: the GCC runtime is missing or
  not where `bin/aix-env.sh` looks. Install Toolbox `libstdc++`/`libgcc`, or
  `export VSCODIUM_AIX_GCC_LIBPATH=/path/to/dir-with-libstdc++.a` before
  launching.
* Terminal does not open: `node_modules/node-pty/lib/native-libs/libutil.so.2`
  must be present; `bin/aix-env.sh` adds it to `LIBPATH`.
* Server starts, logs `Extension host agent started`, then never answers,
  and killed servers linger as `<exiting>`: AHAFS is wedged on that machine.
  Only root can clear it (`umount /aha && mount /aha`, or a reboot). Packages
  from 2026-10-19 on avoid AHAFS entirely; check that `bin/aix-env.sh` sets
  `NODE_OPTIONS` to preload `aix-platform-override.cjs` and that
  `VSCODIUM_AIX_FSWATCH` is not set to `off`.
* Policy forbids the bundled runtime: set `VSCODIUM_AIX_NODE=/path/to/node`
  (same major version as the bundled one, see the release notes) in the
  environment the server is launched from; the launchers use it instead.
* Anything else: run `bin/codium-server --version`, then start it in the
  foreground as above and read the output. Open an issue with that output,
  `oslevel -s`, and the release version.

---

## 3. What the runner does

`vsx` is to the AIX build what GitHub Actions is to VSCodium's own releases:
it notices new upstream versions, drives the fork's build scripts on an AIX
host, and publishes the result. It carries no build logic of its own.

```
cron ──► vsx cron ──► for each upstream release not yet published (oldest first):
                        fork      ▸ fetch the VSCodium fork; pick tag aix/<v>, else branch `aix`
                        worktree  ▸ git worktree at ~/.cache/vsx/work/<v>/vscodium
                                    (its upstream/stable.json must name <v>'s VS Code tag)
                        build     ▸ get_repo.sh, version.sh, prepare_vscode.sh (no npm),
                                    build/aix/package_reh.sh: deps, AIX fixes,
                                    gulp vscode-reh-aix-ppc64-min, build/aix/verify_reh.sh
                        manifest  ▸ versions of node, every addon, VS Code tag/commit, fork ref/commit
                        package   ▸ releases/<v>/*.tar.gz (commit id as top-level dir), .sha256, .info, .json
                        publish   ▸ GitHub release (not "latest" unless it is the highest)
                      prune local artifacts, send daily digest, rotate logs
```

How the build itself works (patches, addon fixes, gulp target, smoke test) is
documented in the fork:
[docs/howto-build-aix.md](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md)
and the comments in `build/aix/*.sh`. Runner rationale and internals:
[docs/DESIGN.md](docs/DESIGN.md). Where each AIX fix lives: [docs/MODULES.md](docs/MODULES.md).

---

## 4. Setting up a build host

This is what a maintainer does once on an AIX machine that will run the
runner. Nothing is specific to the current build host; its name lives only in the maintainer's configuration.
**No root is needed at any point**: everything that is not already in the
Toolbox goes under `~/local`.

### 4.1 Host requirements

AIX 7.3 with the AIX Toolbox for Open Source Software and these packages
(usually present on a development box):

| Package(s) | Why |
|---|---|
| `gcc13`, `gcc13-c++` (GCC 12+ works) and their runtime | C/C++ addons |
| `gmake`, `cmake`, `git` (2.x), `curl`, `patch`, `readlink` (coreutils) | VSCodium's scripts, node-gyp |
| `coreutils`, `grep`, `sed`, `tar`, `file` | GNU userland; `vsx check` refuses to run without GNU grep/sed/tar/sort |
| `krb5-devel` | the `kerberos` addon |
| `python3` (3.9+) | node-gyp, JSON handling in vsx |
| `bash` (4.3+, Toolbox has 5.x) | the scripts |
| `mailx` (base AIX) with working sendmail, or `mail` | failure emails and digest |

User-local, under `~/local` (details and exact commands in the fork's
[howto](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md#host-prerequisites-no-root-needed)):

| What | Why |
|---|---|
| Node.js matching the fork's `.nvmrc` (24.x), nodejs.org `aix-ppc64` tarball | runs gulp, esbuild, TypeScript. The *target* runtime bundled in the package is downloaded by the build itself. |
| `jq` 1.7.1, built static 64-bit with the `malloc(0)` patch | `prepare_vscode.sh` and `utils.sh` need it; the Toolbox has none |
| IBM Open SDK for Rust (rpm extracted with `rpm2cpio`, e.g. `~/local/RustSDK/1.86`) | ripgrep. Optional if you point `VSX_AIX_RIPGREP` at an existing `aix-ppc64` `rg` |
| portlibforaix (`~/local/portlibforaix/lib/libutil.so.2`) | node-pty's `openpty/forkpty/login_tty` |
| `~/local/env.sh` | sourced by the build child first: puts the above on `PATH`, sets `CC`/`CXX`/`VSCODE_REMOTE_CC`/`VSCODE_REMOTE_CXX`, raises `ulimit`, exports `GITHUB_TOKEN` from the token file |

Disk: a build tree is about 30 GB (VS Code checkout, `node_modules`, gulp
output) plus the npm cache; it is removed after a successful build. Network
access to `github.com`, `api.github.com`, `objects.githubusercontent.com`,
`registry.npmjs.org` and `nodejs.org` is required.

### 4.2 Install

```sh
git clone https://github.com/tonykuttai/vscodium-aix-server.git ~/utility/vscodium-aix-server
cd ~/utility/vscodium-aix-server

# GitHub token with `repo` scope. It is needed for the build too: VS Code's
# built-in extensions are downloaded from GitHub releases during gulp.
mkdir -p ~/.config/vscodium-aix && chmod 700 ~/.config/vscodium-aix
echo "ghp_xxx" > ~/.config/vscodium-aix/github-token && chmod 600 ~/.config/vscodium-aix/github-token

# Configuration
mkdir -p ~/.config/vsx
cp config/vsx.conf.example ~/.config/vsx/vsx.conf
vi ~/.config/vsx/vsx.conf      # VSX_EMAIL_TO, VSX_GITHUB_TOKEN_FILE, VSX_AIX_RIPGREP if you have one

bin/vsx check          # must end with OK (tools as the build child sees them, fork reachable, token)
bin/vsx notify-test    # you should receive an email
bin/vsx releases       # what upstream has vs what is published
```

Optionally add `~/utility/vscodium-aix-server/bin` to `PATH`.

### 4.3 First build

```sh
bin/vsx build --latest --no-upload --keep-work   # first build is long: ~400 MB VS Code fetch, npm cache fill
bin/vsx smoke ~/.cache/vsx/work/<version>/vscodium/vscode-reh-aix-ppc64   # re-run the smoke test alone
bin/vsx upload <version>                          # publish when happy
```

With a warm npm cache a version takes about 8 minutes on the current build host (AIX 7.3, POWER10).

### 4.4 Enable automation

```sh
crontab -e
# every 4 hours
0 0,4,8,12,16,20 * * * /home/<you>/utility/vscodium-aix-server/cron/vsx-cron.sh
```

Each run writes `~/.local/state/vsx/logs/<timestamp>-cron.log`; the wrapper's
own output (normally empty) goes to `logs/cron-wrapper.log`. Only one host
may run the cron job (see the cut-over entry in
[docs/OPERATIONS.md](docs/OPERATIONS.md)).

### 4.5 Moving to, or adding, another machine

Nothing of value lives only on a build host: releases are on GitHub, the
source is in the fork, the state directory only holds attempt counters and
logs. Repeat 4.1 to 4.3 on the new host; the ripgrep binary from
`~/.cache/vsx/ripgrep` on the old host can be copied over and named in
`VSX_AIX_RIPGREP` to skip the Rust install. The step-by-step list is in
[docs/OPERATIONS.md](docs/OPERATIONS.md#new-host).

---

## 5. Command reference

All commands are subcommands of `bin/vsx`. Exit status is 0 on success,
non-zero on failure (except `vsx cron`, which reports failures through
notifications and exits 0 so cron stays quiet).

| Command | Purpose |
|---|---|
| `vsx check` | Report host, build tools as the build child sees them (after `VSX_BUILD_ENV_FILE`), fork reachability, token, mail and config; non-zero if something required is missing. Run this first on any new machine. |
| `vsx config` | Print the effective configuration (defaults, file, environment). |
| `vsx releases` | Table of upstream versions above the floor: published?, local package?, attempts, status. |
| `vsx build VERSION...` | Build, test, package and publish the given versions. |
| `vsx build --latest` | Same for the newest upstream release. |
| `vsx build --missing` | Same for every upstream release above `VSX_BACKFILL_FLOOR` that is not published (oldest first). This is what cron runs. |
| `vsx upload VERSION [--force]` | Publish an already packaged version from `releases/VERSION/`. Creates or updates the release, skips assets that exist (`--force` replaces them), sets "latest" only if it is the highest version. |
| `vsx smoke SERVER_DIR` | Run the fork's `build/aix/verify_reh.sh` against any extracted or built server directory. |
| `vsx prune [--dry-run] [--legacy]` | Apply retention: keep the newest `VSX_KEEP_RELEASES` local packages, remove work trees (fork worktrees) and leftover downloads of the old pipeline, keep `VSX_KEEP_LOGS` logs. `--legacy` also removes the pre-2026 `scripts/vscodium-servers` tree and `/tmp` build dirs. |
| `vsx cron` | One automation tick: lock, discover, build everything pending, prune, send the daily digest if due. |
| `vsx notify-test` | Send a test email to `VSX_EMAIL_TO`. |

Build options:

| Option | Effect |
|---|---|
| `--no-upload` | Stop after packaging. |
| `--force` | Rebuild even if published or already packaged (fresh worktree); replace existing release assets. |
| `--retry` | Ignore the attempt limiter for versions that failed repeatedly. |
| `--keep-work` | Keep `~/.cache/vsx/work/<version>/` (fork worktree, built tree, manifest) after success, for inspection. |

Every `build`, `upload` and `cron` run writes a log to
`~/.local/state/vsx/logs/`; the whole build output (npm, node-gyp, gulp,
verify) is in that log.

---

## 6. Configuration reference

Settings are read from `~/.config/vsx/vsx.conf` (or the file named by
`VSX_CONFIG`); any `VSX_*` environment variable overrides the file. All of
them, with defaults and explanations, are in
[config/vsx.conf.example](config/vsx.conf.example). The ones you are likely
to touch:

| Setting | Default | Meaning |
|---|---|---|
| `VSX_EMAIL_TO` | *(unset)* | Where failure emails and digests go. |
| `VSX_RELEASE_REPO` | `tonykuttai/vscodium-aix-server` | Where releases and issues are created. Change this if you fork. |
| `VSX_GITHUB_TOKEN_FILE` | `~/.config/github/token` | Token file; `GITHUB_TOKEN` in the environment wins. |
| `VSX_FORK_REPO` / `VSX_FORK_REF` | `https://github.com/tonykuttai/vscodium.git` / `aix` | The VSCodium fork and the branch to build from when no `aix/<version>` tag exists. |
| `VSX_FORK_DIR` | `~/.cache/vsx/fork` | Local clone of the fork; per-version worktrees are created from it. |
| `VSX_BUILD_ENV_FILE` | `~/local/env.sh` | Sourced by the build child before anything else (user-local Node, jq, Rust on `PATH`). |
| `VSX_AIX_LIBUTIL` | `~/local/portlibforaix/lib/libutil.so.2` | portlibforaix libutil for node-pty. |
| `VSX_AIX_RIPGREP` | *(unset)* | An `aix-ppc64` `rg` to ship instead of building one with Rust. |
| `VSX_RUST_HOME` | `~/local/RustSDK/1.86/bin` | IBM Open SDK for Rust bin dir used by `build/aix/ripgrep.sh`. |
| `VSX_MAX_OLD_SPACE_SIZE` | `8192` | Node heap (MB) for gulp. |
| `VSX_BACKFILL_FLOOR` | `1.126.04524` | Oldest upstream version `--missing`/cron will consider. |
| `VSX_MAX_ATTEMPTS` / `VSX_RETRY_AFTER_HOURS` | `3` / `24` | Park a version after N failures, retry automatically after the window. |
| `VSX_KEEP_RELEASES` | `3` | Local packages to keep. |
| `VSX_ISSUES_ENABLED` / `VSX_DIGEST_ENABLED` | `true` | Turn GitHub issues / the daily digest off. |
| `VSX_SMOKE_TIMEOUT` | `240` | Seconds `verify_reh.sh` waits for the server to listen. |

GitHub authentication: `GITHUB_TOKEN` in the environment, else the file
`VSX_GITHUB_TOKEN_FILE`. Scope `repo`. The token is passed into the build
child because gulp downloads the built-in extensions from GitHub releases.

---

## 7. Notifications

| Event | Email | GitHub issue | Digest |
|---|---|---|---|
| A version fails to build or upload | immediately, with the failing stage and the last 80 log lines | opened (or commented if one is open for that version), label `build-failure` | listed |
| A version is published | no | the open issue for it is closed | listed |
| Pipeline-level error (API down, token missing...) | immediately, but the same error at most once per 12h | no | listed |
| Nothing new upstream | no | no | listed as a quiet day |
| Once per day | the digest: upstream latest, published latest, pending versions, last 24h events, parked versions | | |

If you receive the daily digest, the pipeline is alive. If digests stop,
look at `~/.local/state/vsx/logs/` and `crontab -l` on the build host.

---

## 8. Everyday operations

**See what is pending**
```sh
vsx releases
```

**Backfill everything missing** (what cron does; safe to run by hand)
```sh
vsx build --missing
```

**Rebuild and republish one version** (e.g. after a fix in the fork)
```sh
vsx build 1.140.06880 --force
```
The release notes then show "AIX build 2" and the extension refreshes
existing installs.

**A version keeps failing and is parked**: fix the cause, then
```sh
vsx build 1.135.06055 --retry
```

**A new VSCodium release appeared and the build stops with**
`fork ref ... has upstream/stable.json tag 'X' but <v> needs 'Y'`: the fork's
`aix` branch has not been rebased onto that VSCodium release yet. Rebase,
tag `aix/<v>`, push, then build again (procedure in
[docs/OPERATIONS.md](docs/OPERATIONS.md#stable-json)).

**Test a package before publishing**
```sh
vsx build 1.140.06880 --no-upload --keep-work
# optional: stage it where the extension looks, then connect with VSCodium
C=$(grep ^Commit: releases/1.140.06880/*.info | cut -d' ' -f2)
mkdir -p ~/.vscodium-server/bin/$C
tar -xzf releases/1.140.06880/*.tar.gz -C ~/.vscodium-server/bin/$C --strip-components 1
vsx upload 1.140.06880
```

**Rebuild a package by hand, without the runner**: follow the fork's
[howto](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md)
in `~/.cache/vsx/work/<v>/vscodium` (kept with `--keep-work`) or in any
checkout of tag `aix/<v>`.

**Upstream moved to a new Node major**: the build reads the target from
`remote/.npmrc` and downloads that version from nodejs.org. If nodejs.org has
no `aix-ppc64` build for it yet, the build fails at the runtime download and
retries on later runs. The host Node (`~/local`) must match `.nvmrc`, which
moves independently; `vsx check` shows what the build child sees.

**Disk**: `vsx prune` runs after every cron tick and removes finished
worktrees. The first time on an old host run `vsx prune --legacy --dry-run`,
then without `--dry-run`, to remove the pre-2026 layout.

---

## 9. Repository layout

```
bin/vsx                  CLI, per-version pipeline, cron orchestration
lib/common.sh            strict mode, logging, locking, version compare, JSON via python
lib/config.sh            defaults + ~/.config/vsx/vsx.conf
lib/env.sh               PATH/GNU tools, toolchain facts, build-tool report, GitHub token
lib/source.sh            fork sync, ref selection, worktree, source build, manifest, packaging
lib/server.sh            build manifest and release notes
lib/github.sh            GitHub REST: upstream discovery, releases, assets, issues
lib/notify.sh            events, attempts, email, issues, digest
config/vsx.conf.example  documented configuration
cron/vsx-cron.sh         cron entry point
docs/DESIGN.md           architecture and decisions
docs/MODULES.md          where each AIX fix lives (in the fork) and its upstream status
docs/OPERATIONS.md       runbook, incident checklist, release message
releases/                local packaged artifacts (git-ignored)
.github/workflows/       shellcheck + syntax on every push
```

The server itself (patches, addon fixes, build and smoke scripts) lives in
the fork: `patches/aix/`, `build/aix/`, `docs/howto-build-aix.md` on branch
`aix` of <https://github.com/tonykuttai/vscodium>.

---

## 10. Known limitations

* File watching is polling based, by design: AIX's native mechanism (AHAFS,
  used by Node's `fs.watch`) has a shared, finite monitor pool and can wedge
  every process on the machine. Workspace watching goes through
  `@parcel/watcher` with a polling backend (`PARCEL_WATCHER_POLL_INTERVAL_MS`,
  default 2000 ms, stretched automatically for big trees); the few
  non-recursive watches VS Code makes itself go through a polling `fs.watch`
  shim (`VSCODIUM_AIX_FSWATCH_INTERVAL_MS`, default 1000 ms). Changes made
  outside the editor therefore show up after a second or two, and the git
  pane may need a manual refresh.
* Big-endian: the build defers `@vscode/l10n-dev`'s tree-sitter wasm
  initialisation (little-endian only); the shipped server is not affected.
  VS Code's own unit tests have not yet been run on AIX.
* A GitHub token is required to build, not only to publish: gulp downloads
  the built-in extensions from GitHub releases and the anonymous API limit
  (60 requests/hour) is too low.
* Only ppc64 AIX 7.3 is built and tested.
* The smoke test proves addons load, the watcher delivers events, ripgrep
  searches and the server boots and answers; it does not open a terminal.
  Please report regressions as issues.

---

## 11. Contributing

* Runner changes (this repository): lint locally with
  `shellcheck -S warning -x bin/vsx lib/*.sh cron/*.sh` and `bash -n` on
  everything; CI runs the same on every push. Nothing in `bin/` or `lib/` can
  build off AIX. Test on an AIX host in a separate checkout with its own
  state directory and no uploads, e.g.
  `VSX_STATE_DIR=~/.local/state/vsx-dev VSX_EMAIL_ENABLED=false VSX_ISSUES_ENABLED=false bin/vsx build --latest --no-upload`.
* Build changes (patches, addon fixes, launchers, smoke test) go to the
  fork's `aix` branch: <https://github.com/tonykuttai/vscodium>. The branch
  is a pure superset of upstream VSCodium, rebased on each release; one
  topic per commit. The fork's CI checks that `patches/aix` still apply to
  the VS Code commit in `upstream/stable.json`.
* The AIX fixes are candidates for upstream pull requests (node-pty,
  @parcel/watcher, kerberos, @vscode/deviceid, @vscode/l10n-dev, jq, ...);
  [docs/MODULES.md](docs/MODULES.md) lists them. Shrinking that list is the
  most useful contribution.

Licensed under the terms in [LICENSE](LICENSE). VSCodium, VS Code and the
native modules are the work of their respective projects; this repository
only builds and publishes them for AIX.
