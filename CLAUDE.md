# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`vsx`: a bash pipeline that runs **on an AIX 7.3 ppc64 host** (currently `cpap8104`, checkout `~/utility/vscodium-aix-server`, cron every 4h) and republishes VSCodium Remote Server for AIX. It does not build VSCodium from source: it downloads upstream `vscodium-reh-linux-x64-<v>.tar.gz`, swaps the native pieces (Node runtime, `pty.node`, `spdlog.node`, `watchdog.node`, `watcher.node`, `rg`), patches two JS files, proves the server starts, and publishes `vscodium-reh-aix-ppc64-<v>.tar.gz` to GitHub releases (`tonykuttai/vscodium-aix-server`). Consumer: the AIX fork of open-remote-ssh (`tonykuttai/open-remote-ssh`), which needs tag == version, the exact asset name, one top-level dir in the tarball, and uses `/releases/latest` as fallback.

Docs: [README.md](README.md) (users + maintainers, command/config reference), [docs/DESIGN.md](docs/DESIGN.md) (architecture, decisions), [docs/OPERATIONS.md](docs/OPERATIONS.md) (runbook), [docs/MODULES.md](docs/MODULES.md) (per-module AIX notes).

## Commands

```bash
# Lint (the only thing that works off-AIX; CI runs the same)
shellcheck -S warning -x bin/vsx lib/*.sh modules/*.sh cron/*.sh
shellcheck -S warning -s sh -e SC2148,SC2154 templates/*.sh
for f in bin/vsx lib/*.sh modules/*.sh cron/*.sh templates/*.sh; do bash -n "$f"; done

# On AIX
bin/vsx check                                   # host/toolchain/token report
bin/vsx releases                                # upstream vs published table
bin/vsx build 1.140.06880 --no-upload --keep-work   # one version, no publish
bin/vsx module ripgrep 1.140.06880              # one module only
bin/vsx smoke ~/.cache/vsx/work/1.140.06880/server
bin/vsx build --missing                         # what cron does
bin/vsx upload 1.140.06880                      # publish a packaged version
bin/vsx prune --dry-run
```

Testing changes on AIX: use a second checkout (`~/utility/vsx-dev`) with `VSX_CONFIG=~/.config/vsx/vsx-dev.conf` setting `VSX_STATE_DIR=$HOME/.local/state/vsx-dev` and `VSX_EMAIL_ENABLED/VSX_ISSUES_ENABLED/VSX_DIGEST_ENABLED=false`; always `--no-upload` until a package is verified. The module cache (`~/.cache/vsx/modules`) is shared, so rebuilds after the first take about a minute. To test a package with a real client, extract it to `~/.vscodium-server/bin/<commit>/` on the box (`--strip-components 1`); the extension uses an existing dir instead of downloading.

## Architecture (where to change what)

- `bin/vsx`: CLI dispatch, `cmd___build_one` (the per-version pipeline: fetch → runtime → modules → node+launchers → smoke → package → upload), `cmd_cron`, `cmd_prune`, `upload_version`.
- `lib/common.sh` strict mode, logging, ERR trap, `lock_acquire` (mkdir), `ver_sort/ver_gt` and `jpy` (JSON via python3). `lib/config.sh` defaults + `~/.config/vsx/vsx.conf`. `lib/env.sh` PATH/GNU checks, toolchain facts, `node_runtime_select` (official nodejs.org aix-ppc64 build matching `remote/.npmrc` of the VS Code tag), `vsx_npm`/`vsx_node_gyp`, `verify_addon`. `lib/github.sh` REST (releases, assets, issues). `lib/notify.sh` events, attempts, email, issues, digest. `lib/server.sh` server tree, launchers from `templates/`, smoke test, packaging, release notes. `lib/modules.sh` module contract + cache + helpers.
- `modules/<name>.sh`: `mod_<n>_wanted SERVER` (version from the server's own `node_modules/<pkg>/package.json`), `mod_<n>_build VERSION OUTDIR`, `mod_<n>_install OUTDIR SERVER`, optional `_cache_key`, `_note`. Order in `VSX_MODULES` (`lib/modules.sh`). Add a new `.node` to `required` in `server_smoke_test`.
- `templates/`: `server-launcher.sh`, `remote-cli.sh`, `aix-env.sh` (LIBPATH: highest GCC runtime + node-pty `native-libs`), `aix-platform-override.js` (spoofs `process.platform=linux` when the stack contains `ptyHost|server-main|server-cli|deviceid`).
- `patches/node-pty-aix.patch`: applied to the upstream node-pty tag; plus an in-script guard widening for `pty_close_inherited_fds`.
- VSCodium `1.140.06880` ↔ VS Code tag `1.140.0` (first digit of the build number is the VS Code patch level); see `vscode_tag_for`.

## Rules that are easy to get wrong

- **Never let the server touch AHAFS** (`/aha`, what libuv's `fs.watch` uses on AIX): a wedged AHAFS blocks processes unkillably machine-wide (incident 2026-10-19, `notes/AIX-WATCHERS-AND-BINARIES.md`). All watching is polling: `patches/parcel-watcher-polling.patch` for workspaces, the `fs.watch` shim in `templates/aix-platform-override.js` for VS Code's own watches (preloaded everywhere via `NODE_OPTIONS` in `aix-env.sh`, inert outside VS Code processes). Test the shim locally: `VSCODIUM_AIX_FSWATCH=force node -r templates/aix-platform-override.js <script>`. The smoke test fails if a `/aha/fs/modDir.monFactory/*vsx-smoke*` monitor appears.
- **Smoke test process handling**: the server runs in its own process group (`set -m`), is stopped by `_smoke_stop_group` (TERM, KILL, poll `ps -o stat=`), and `wait` is only called once the process is gone or a zombie. A process that survives SIGKILL is stuck in the kernel; the test reports it and fails rather than blocking.

- **Bash errexit is off inside anything tested by `if`/`!`/`||`, including subshells and functions.** That is why versions are built in a child process (`vsx __build-one`) and module build/install run as `set +e; ( set -e; ... ); rc=$?; set -e`. Keep that pattern; do not "simplify" it to `if ! fn; then`.
- **Never pass large data through argv** (AIX `ARG_MAX` is small): JSON goes via stdin/temp files (`gh_paginate`, `json_escape`).
- **AIX userland**: no `jq`, `flock`, `pgrep`, `find -delete/-mmin/-maxdepth/-print0`, `xargs -0/-r`. `/opt/freeware/bin` must be first in PATH (GNU grep/sed/tar/sort are checked). `product.json` has several nested `version` keys: use `json_field`, never grep-the-first-match.
- **Never run `npm --version` on the host's `/opt/nodejs` npm** (known crash). Module builds use the bundled runtime's npm via `vsx_npm` anyway.
- **node-pty**: do not add portlibforaix's `include/` to the include path (its `stdio.h` shadows the system header).
- **ripgrep-universal** resolves `bin/<platform>-<arch>/rg` at load time; install `rg` to both `linux-ppc64` and `aix-ppc64`. The version comes from vscode-ripgrep → ripgrep-prebuilt `config.json`, not from ripgrep HEAD (HEAD needs a newer rustc than the Toolbox ships).
- **Uploads**: `make_latest` only when the version is the highest we publish (backfills must not steal "latest"); never delete releases; skip existing assets unless `--force`.
- `releases/`, `*.tar.gz`, `*.log` are git-ignored; never commit build output. The old `scripts/` layout was removed in the 2026-10 restructure; `vsx prune --legacy` cleans its leftovers on a host.
