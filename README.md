# VSCodium Remote Server for IBM AIX

Unofficial builds of the VSCodium Remote Extension Host (REH) server for
**IBM AIX 7.3 on POWER (ppc64)**, plus `vsx`, the pipeline that produces and
publishes them automatically whenever VSCodium releases.

VSCodium itself does not support AIX. These packages are what the
[open-remote-ssh AIX fork](https://github.com/tonykuttai/open-remote-ssh)
installs on the remote machine so that a VSCodium desktop can open folders,
terminals and extensions on AIX over SSH.

* **Releases:** <https://github.com/tonykuttai/vscodium-aix-server/releases>
  (tag = VSCodium version, asset `vscodium-reh-aix-ppc64-<version>.tar.gz`)
* **Issues:** <https://github.com/tonykuttai/vscodium-aix-server/issues>
  (build failures are filed there automatically, label `build-failure`)

---

## Contents

1. [What you get](#1-what-you-get)
2. [Using a release on an AIX machine](#2-using-a-release-on-an-aix-machine)
3. [What the pipeline does](#3-what-the-pipeline-does)
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

Each release is the upstream VSCodium Linux x64 server with every
platform-specific piece replaced by an AIX build:

| Component | What vsx does |
|---|---|
| Node.js runtime | Bundles the official nodejs.org `aix-ppc64` build of the Node version VS Code targets for that release. **No Node installation is required on the AIX machine.** |
| `node-pty` (terminals) | Built from the upstream tag the server bundles, with a small AIX patch; links `libutil.so.2` from [portlibforaix](https://github.com/tonykuttai/portlibforaix), shipped inside the package |
| `@vscode/spdlog` (logging) | Built from the upstream tag |
| `@vscode/native-watchdog` | Built from the upstream tag |
| `@parcel/watcher` (file watching) | Built from the upstream tag with an AIX backend (brute-force polling) |
| ripgrep (search) | Built from the exact ripgrep tag upstream's `@vscode/ripgrep-universal` pins, with PCRE2 |
| `@vscode/deviceid` | Patched to accept `aix` |
| Launchers | `bin/codium-server`, `bin/remote-cli/codium` and `bin/aix-env.sh` set `LIBPATH` and preload `aix-platform-override.cjs` into every server process |
| `aix-platform-override.cjs` | Makes VS Code take its Linux code paths (`process.platform`) and replaces `fs.watch` with stat polling so the server never touches AHAFS, the AIX kernel file-event system, which can wedge a whole machine (see [docs/OPERATIONS.md](docs/OPERATIONS.md#ahafs)) |

Every release page carries a table of exactly which versions went in
(generated from `aix-build-manifest.json`, which is also inside the tarball),
the SHA256, and install instructions. The pipeline only publishes a package
after the server has actually been started on the build host and reported
its extension host ready.

The suite as a whole provides:

* automatic detection of new VSCodium releases and publication of AIX builds
  (cron, every 4 hours by default);
* backfill of every upstream release that is missing from the releases page;
* reproducible builds of individual versions or individual modules on demand;
* a start-up smoke test gate, checksums and a build manifest per release;
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
  `libgcc` (they install under `/opt/freeware/lib`). Any host with the
  Toolbox `gcc` package already has them. Check:
  ```sh
  ls /opt/freeware/lib/pthread/ppc64/libstdc++.a /opt/freeware/lib/libgcc_s.a
  ```
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

## 3. What the pipeline does

```
cron ──► vsx cron ──► for each upstream release not yet published (oldest first):
                        fetch upstream linux-x64 server
                        pick + cache the matching official Node for AIX
                        build/patch each native module at the bundled version (cached)
                        install Node + AIX launchers
                        start the server; wait for "Extension host agent listening"
                        package  ▸ releases/<v>/*.tar.gz, .sha256, .info, .json
                        publish  ▸ GitHub release (not "latest" unless it is the highest)
                      prune local artifacts, send daily digest, rotate logs
```

Full rationale and internals: [docs/DESIGN.md](docs/DESIGN.md).
Per-module AIX details: [docs/MODULES.md](docs/MODULES.md).

---

## 4. Setting up a build host

This is what a maintainer does once on an AIX machine that will run the
pipeline. The current host is `cpap8104`; nothing is specific to it.

### 4.1 Host requirements

AIX 7.3 (7.2 TL5+ should work) with the AIX Toolbox for Open Source Software
(`dnf`/`yum`) and these packages:

| Package(s) | Why |
|---|---|
| `gcc13`, `gcc13-c++` (or `gcc`, `gcc-c++` >= 10) | C/C++ addons |
| `rust`, `cargo` (Toolbox `rust` RPM; 1.85+ for current ripgrep) | ripgrep |
| `gmake`, `git`, `curl`, `wget`, `patch` | fetching and building |
| `coreutils`, `grep`, `sed`, `tar`, `findutils`, `file` | GNU userland; `vsx check` refuses to run without GNU grep/sed/tar/sort |
| `python3` (3.9+) | JSON handling, version compare |
| `bash` (4.3+, Toolbox has 5.x) | the scripts |
| `mailx` (base AIX) with working sendmail, or `mail` | failure emails and digest |

No root is needed after the packages exist. Node.js is **not** required on
the host: vsx downloads the official AIX Node builds it needs into
`~/.cache/vsx/node/`. `strip` (base AIX) is used to shrink the bundled node.

Network access to `github.com`, `api.github.com`, `objects.githubusercontent.com`
and `nodejs.org` is required.

### 4.2 Install

```sh
git clone https://github.com/tonykuttai/vscodium-aix-server.git ~/utility/vscodium-aix-server
cd ~/utility/vscodium-aix-server

# GitHub token with `repo` scope (creates releases, uploads assets, files issues)
mkdir -p ~/.config/github && chmod 700 ~/.config/github
echo "ghp_xxx" > ~/.config/github/token && chmod 600 ~/.config/github/token

# Configuration (only VSX_EMAIL_TO is really needed)
mkdir -p ~/.config/vsx
cp config/vsx.conf.example ~/.config/vsx/vsx.conf
vi ~/.config/vsx/vsx.conf

bin/vsx check          # must end with OK
bin/vsx notify-test    # you should receive an email
bin/vsx releases       # what upstream has vs what is published
```

Optionally add `~/utility/vscodium-aix-server/bin` to `PATH`.

### 4.3 First build

```sh
bin/vsx build --latest --no-upload     # 10-20 min the first time (compiles everything)
bin/vsx smoke ~/.cache/vsx/work/<version>/server   # only if you used --keep-work
bin/vsx upload <version>               # publish when happy
```

### 4.4 Enable automation

```sh
crontab -e
# every 4 hours
0 0,4,8,12,16,20 * * * /home/<you>/utility/vscodium-aix-server/cron/vsx-cron.sh
```

Each run writes `~/.local/state/vsx/logs/<timestamp>-cron.log`; the wrapper's
own output (normally empty) goes to `logs/cron-wrapper.log`.

### 4.5 Moving to, or adding, another machine

Nothing of value lives only on a build host: releases are on GitHub, the
state directory only holds attempt counters and logs. On the new host:

```sh
bin/vsx check                     # tells you exactly which Toolbox packages to dnf install
# optional but recommended: bring the built modules and Node runtimes along
#   old host:  bin/vsx cache export /tmp/vsx-cache.tar.gz     (~80 MB)
#   new host:  bin/vsx cache import /tmp/vsx-cache.tar.gz
bin/vsx build --latest --no-upload --keep-work
```

Things learned bringing up the second host (wyvernden, 2026-10-19):

* **Rust is the only hard-to-get prerequisite.** Everything else is in a
  default Toolbox install. Without Rust, ripgrep cannot be compiled, but an
  imported cache is used automatically and the build proceeds.
* **A GitHub token is only needed to publish.** `--no-upload` builds work
  without one (the unauthenticated API allows 60 requests per hour).
* **Node.js is not needed on the host at all**; the first build downloads the
  official AIX runtime (75 MB) into `~/.cache/vsx/node`.
* **portlibforaix** (for node-pty) is cloned and built automatically into
  `~/local/portlibforaix` on first use.
* **Do not trust headers under `/opt/freeware/include`** to be present on
  every host; the node-pty patch used to rely on a stray `pty.h` there.
* The first full build takes 10 to 20 minutes on a quiet machine, longer on
  a shared one; later builds reuse the module cache and take about a minute.
* Use a separate checkout, state directory and cache for experiments (see
  Contributing); make sure only one host runs the cron job.

---

## 5. Command reference

All commands are subcommands of `bin/vsx`. Exit status is 0 on success,
non-zero on failure (except `vsx cron`, which reports failures through
notifications and exits 0 so cron stays quiet).

| Command | Purpose |
|---|---|
| `vsx check` | Report host, toolchain, token, mail and config; non-zero if something required is missing. Run this first on any new machine. |
| `vsx config` | Print the effective configuration (defaults, file, environment). |
| `vsx releases` | Table of upstream versions above the floor: published?, local package?, attempts, status. |
| `vsx build VERSION...` | Build, test, package and publish the given versions. |
| `vsx build --latest` | Same for the newest upstream release. |
| `vsx build --missing` | Same for every upstream release above `VSX_BACKFILL_FLOOR` that is not published (oldest first). This is what cron runs. |
| `vsx upload VERSION [--force]` | Publish an already packaged version from `releases/VERSION/`. Creates or updates the release, skips assets that exist (`--force` replaces them), sets "latest" only if it is the highest version. |
| `vsx smoke SERVER_DIR` | Run the start-up test against any extracted server directory. |
| `vsx module NAME VSCODIUM_VERSION` | Build and install one module (`native-watchdog`, `node-spdlog`, `node-pty`, `parcel-watcher`, `ripgrep`, `deviceid`) into that version's work tree. For debugging a single component. |
| `vsx cache export FILE` / `vsx cache import FILE` | Move built module artifacts and Node runtime tarballs between hosts (about 80 MB). Lets a host without Rust package releases, and skips the first compile on a new machine. |
| `vsx prune [--dry-run] [--legacy]` | Apply retention: keep the newest `VSX_KEEP_RELEASES` local packages and downloads, remove work trees, keep `VSX_KEEP_LOGS` logs. `--legacy` also removes the pre-2026 `scripts/vscodium-servers` tree and `/tmp` build dirs. |
| `vsx cron` | One automation tick: lock, discover, build everything pending, prune, send the daily digest if due. |
| `vsx notify-test` | Send a test email to `VSX_EMAIL_TO`. |

Build options:

| Option | Effect |
|---|---|
| `--no-upload` | Stop after packaging. |
| `--force` | Rebuild even if published or already packaged; replace existing release assets. |
| `--retry` | Ignore the attempt limiter for versions that failed repeatedly. |
| `--keep-work` | Keep `~/.cache/vsx/work/<version>/` after success (for inspection). |
| `--no-smoke` | Skip the start-up test. Debugging only; never for something you will publish. |

Every `build`, `upload` and `cron` run writes a log to
`~/.local/state/vsx/logs/`. Module compile output goes to
`~/.cache/vsx/modules/<module>/<version>-node<abi>/build.log`.

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
| `VSX_BACKFILL_FLOOR` | `1.126.04524` | Oldest upstream version `--missing`/cron will consider. |
| `VSX_MAX_ATTEMPTS` / `VSX_RETRY_AFTER_HOURS` | `3` / `24` | Park a version after N failures, retry automatically after the window. |
| `VSX_NODE_RUNTIME` | `bundle` | `bundle` ships nodejs.org's AIX Node inside the package; `host` uses `VSX_HOST_NODE` (legacy). |
| `VSX_KEEP_RELEASES` | `3` | Local packages (and upstream downloads) to keep. |
| `VSX_ISSUES_ENABLED` / `VSX_DIGEST_ENABLED` | `true` | Turn GitHub issues / the daily digest off. |
| `VSX_REPO_*` | upstream URLs | Point a module at a fork if you ever need to. |

GitHub authentication: `GITHUB_TOKEN` in the environment, else the file
`VSX_GITHUB_TOKEN_FILE` (default `~/.config/github/token`). Scope `repo`.

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

**Rebuild and republish one version** (e.g. after fixing a module)
```sh
vsx build 1.140.06880 --force
```

**A version keeps failing and is parked**: fix the cause, then
```sh
vsx build 1.135.06055 --retry
```

**Force a module to recompile**: delete its cache directory, e.g.
`rm -rf ~/.cache/vsx/modules/ripgrep`, then build.

**Test a package before publishing**
```sh
vsx build 1.140.06880 --no-upload --keep-work
# optional: stage it where the extension looks, then connect with VSCodium
C=$(grep ^Commit: releases/1.140.06880/*.info | cut -d' ' -f2)
mkdir -p ~/.vscodium-server/bin/$C
tar -xzf releases/1.140.06880/*.tar.gz -C ~/.vscodium-server/bin/$C --strip-components 1
vsx upload 1.140.06880
```

**Toolchain too old for a new ripgrep**: the build fails fast with
`this ripgrep requires rustc >= X`. Install a newer Toolbox `rust` RPM, or
set `VSX_RIPGREP_FALLBACK_TAG` and clear the module cache.

**Upstream moved to a new Node major**: nothing to do. vsx reads the target
from `remote/.npmrc` of the matching VS Code tag and fetches that major from
nodejs.org. If nodejs.org has no AIX build for it yet, the build fails with
`no official aix-ppc64 Node build found` and retries on later runs.

**Disk**: `vsx prune` runs after every cron tick. The first time on an old
host run `vsx prune --legacy --dry-run`, then without `--dry-run`, to remove
the pre-2026 layout (tens of GB of extracted servers).

---

## 9. Repository layout

```
bin/vsx                  CLI and pipeline orchestration
lib/                     shared bash libraries (see docs/DESIGN.md for each)
modules/<name>.sh        one builder per native component
templates/               launcher scripts + platform override shipped in packages
patches/                 source patches applied to upstream tags
config/vsx.conf.example  documented configuration
cron/vsx-cron.sh         cron entry point
docs/DESIGN.md           architecture and decisions
docs/MODULES.md          AIX notes per module
docs/OPERATIONS.md       runbook, incident checklist, release message
releases/                local packaged artifacts (git-ignored)
.github/workflows/       shellcheck + syntax on every push
```

---

## 10. Known limitations

* `@vscode/sqlite3` and `kerberos` are not rebuilt and remain Linux
  binaries inside the package. The server starts and is usable without them;
  features that need them (Kerberos proxy auth) do not work on AIX.
* File watching is polling based, by design: AIX's native mechanism (AHAFS,
  used by Node's `fs.watch`) has a shared, finite monitor pool and can wedge
  every process on the machine. Workspace watching goes through
  `@parcel/watcher` with a polling patch (`PARCEL_WATCHER_POLL_INTERVAL_MS`,
  default 2000 ms, stretched automatically for big trees); the few
  non-recursive watches VS Code makes itself go through a polling `fs.watch`
  shim (`VSCODIUM_AIX_FSWATCH_INTERVAL_MS`, default 1000 ms). Changes made
  outside the editor therefore show up after a second or two.
* Only ppc64 AIX 7.3 is built and tested.
* The smoke test proves the server boots; it does not exercise terminals or
  search. Please report regressions as issues.

---

## 11. Contributing

* Lint locally with `shellcheck -S warning -x bin/vsx lib/*.sh modules/*.sh cron/*.sh`
  and `bash -n` on everything; CI runs the same on every push.
* Nothing in `bin/`, `lib/` or `modules/` can be executed off AIX. Test
  changes on an AIX host in a separate checkout with its own state directory
  and no uploads, e.g.
  `VSX_STATE_DIR=~/.local/state/vsx-dev VSX_EMAIL_ENABLED=false VSX_ISSUES_ENABLED=false bin/vsx build --latest --no-upload`.
* Adding a native module: create `modules/<name>.sh` following the contract
  in `lib/modules.sh`, add it to `VSX_MODULES`, add it to the required list
  in the smoke test, and document it in `docs/MODULES.md`.

Licensed under the terms in [LICENSE](LICENSE). VSCodium, VS Code and the
native modules are the work of their respective projects; this repository
only repackages them for AIX.
