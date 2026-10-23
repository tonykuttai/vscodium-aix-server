# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`vsx`: the bash **runner** that runs on an AIX 7.3 ppc64 host (build host `wyvernden6aix73`, checkout `~/utility/vscodium-aix-server`; `cpap8104` ran the previous pipeline from cron until the cut-over) and publishes the VSCodium Remote Server for AIX. Since 2026-10 the server is **built from source**: the runner checks out the VSCodium fork `tonykuttai/vscodium` (branch `aix`, or tag `aix/<version>`), runs VSCodium's `get_repo.sh` and `prepare_vscode.sh`, then the fork's `build/aix/package_reh.sh` (VS Code's own `gulp vscode-reh-aix-ppc64-min` plus the fork's AIX fixes and smoke test), packages the result and publishes `vscodium-reh-aix-ppc64-<v>.tar.gz` to GitHub releases (`tonykuttai/vscodium-aix-server`). Build logic and VS Code patches live in the fork (`patches/aix/`, `build/aix/`), never here. Consumer: the AIX fork of open-remote-ssh (`tonykuttai/open-remote-ssh`), which needs tag == version, the exact asset name, one top-level dir in the tarball, and uses `/releases/latest` as fallback.

Docs: [README.md](README.md) (users + maintainers, command/config reference), [docs/DESIGN.md](docs/DESIGN.md) (architecture, decisions), [docs/OPERATIONS.md](docs/OPERATIONS.md) (runbook), [docs/MODULES.md](docs/MODULES.md) (where each AIX fix lives in the fork). Fork build details: `docs/howto-build-aix.md` in the fork.

## Commands

```bash
# Lint (the only thing that works off-AIX; CI runs the same)
shellcheck -S warning -x bin/vsx lib/*.sh cron/*.sh
for f in bin/vsx lib/*.sh cron/*.sh; do bash -n "$f"; done

# On AIX
bin/vsx check                                   # host/toolchain/token report
bin/vsx releases                                # upstream vs published table
bin/vsx build 1.140.06880 --no-upload --keep-work   # one version, no publish (~10 min warm)
bin/vsx smoke ~/.cache/vsx/work/1.140.06880/vscodium/vscode-reh-aix-ppc64   # fork's verify_reh.sh
bin/vsx build --missing                         # what cron does
bin/vsx upload 1.140.06880                      # publish a packaged version
bin/vsx prune --dry-run
```

Testing changes on AIX: use a second checkout (`~/utility/vsx-dev`) with `VSX_CONFIG=~/.config/vsx/vsx-dev.conf` setting `VSX_STATE_DIR=$HOME/.local/state/vsx-dev` and `VSX_EMAIL_ENABLED/VSX_ISSUES_ENABLED/VSX_DIGEST_ENABLED=false`; always `--no-upload` until a package is verified. To test fork changes, point `VSX_FORK_REPO`/`VSX_FORK_REF` at your branch. The npm cache and the target Node runtime trees (`~/.cache/vsx/node`) are shared, so a rebuild takes ~10 minutes. To test a package with a real client, extract it to `~/.vscodium-server/bin/<commit>/` on the box (`--strip-components 1`); the extension uses an existing dir instead of downloading.

## Architecture (where to change what)

- `bin/vsx`: CLI dispatch, `cmd___build_one` (per-version pipeline: fork → worktree → build → manifest → package → upload), `cmd_cron`, `cmd_prune`, `upload_version`.
- `lib/common.sh` strict mode, logging, ERR trap, `lock_acquire` (mkdir), `ver_sort/ver_gt` and `jpy` (JSON via python3). `lib/config.sh` defaults + `~/.config/vsx/vsx.conf`. `lib/env.sh` PATH/GNU checks, toolchain facts, build-tools report (as seen after `VSX_BUILD_ENV_FILE`), GitHub token. `lib/source.sh` fork sync, `fork_ref_for` (tag `aix/<v>` else branch; refuses a worktree whose `upstream/stable.json` does not name `<v>`'s VS Code tag), worktree, the build child (sources the env file, unsets LIBPATH, runs `get_repo.sh`, `version.sh`, `SKIP_NPM_INSTALL=yes prepare_vscode.sh`, `build/aix/package_reh.sh`), manifest, packaging. `lib/github.sh` REST (releases, assets, issues). `lib/notify.sh` events, attempts, email, issues, digest. `lib/server.sh` manifest helpers and release notes.
- In the fork (`tonykuttai/vscodium`, branch `aix`): `patches/aix/*.patch` (VS Code: `aix-ppc64` target in `build/gulpfile.reh.ts`, launchers, `bin/aix-env.sh`, `aix-platform-override.cjs` shim with `fs.watch` polling), `build/aix/package_reh.sh`, `fix-node-modules.sh` (node-pty, @parcel/watcher polling patch, kerberos, deviceid, rg), `verify_reh.sh`, `ripgrep.sh`, `docs/howto-build-aix.md`.
- VSCodium `1.140.06880` ↔ VS Code tag `1.140.0` (first digit of the build number is the VS Code patch level); see `vscode_tag_for` in `lib/source.sh`.

## Rules that are easy to get wrong

- **Never let the server touch AHAFS** (`/aha`, what libuv's `fs.watch` uses on AIX): a wedged AHAFS blocks processes unkillably machine-wide (incident 2026-10-19, see the maintainers' internal incident notes). All watching is polling: `patches/parcel-watcher-polling.patch` for workspaces, the `fs.watch` shim in `templates/aix-platform-override.cjs` for VS Code's own watches (preloaded everywhere via `NODE_OPTIONS` in `aix-env.sh`, inert outside VS Code processes). Test the shim locally: `VSCODIUM_AIX_FSWATCH=force node -r templates/aix-platform-override.cjs <script>`. The smoke test fails if a `/aha/fs/modDir.monFactory/*vsx-smoke*` monitor appears.
- **Smoke test process handling**: the server runs in its own process group (`set -m`), is stopped by `_smoke_stop_group` (TERM, KILL, poll `ps -o stat=`), and `wait` is only called once the process is gone or a zombie. A process that survives SIGKILL is stuck in the kernel; the test reports it and fails rather than blocking.

- **Bash errexit is off inside anything tested by `if`/`!`/`||`, including subshells and functions.** That is why versions are built in a child process (`vsx __build-one`) and module build/install run as `set +e; ( set -e; ... ); rc=$?; set -e`. Keep that pattern; do not "simplify" it to `if ! fn; then`.
- **Never pass large data through argv** (AIX `ARG_MAX` is small): JSON goes via stdin/temp files (`gh_paginate`, `json_escape`).
- **AIX userland**: no `jq`, `flock`, `pgrep`, `find -delete/-mmin/-maxdepth/-print0`, `xargs -0/-r`. `/opt/freeware/bin` must be first in PATH (GNU grep/sed/tar/sort are checked). `product.json` has several nested `version` keys: use `json_field`, never grep-the-first-match.
- **Never run `npm --version` on the host's `/opt/nodejs` npm** (known crash). The build uses the user-local Node from `VSX_BUILD_ENV_FILE` and, for `remote/`, the target runtime's own npm/node-gyp (node-gyp reads `node.exp` relative to its own install, not `--nodedir`).
- **Never export the runtime `LIBPATH` in a build shell**: the Toolbox compiler binaries are 32-bit and die with "invalid magic number" when the 64-bit GCC runtime dirs come first. `lib/source.sh` unsets it for the build child.
- **The server must never use AHAFS** (libuv's AIX `fs.watch`): it wedged cpap8104 on 2026-10-19. The fork's `.cjs` shim replaces `fs.watch` with polling and `@parcel/watcher` gets polling subscriptions; `verify_reh.sh` fails if monitors appear under `/aha`.
- **Uploads**: `make_latest` only when the version is the highest we publish (backfills must not steal "latest"); never delete releases; skip existing assets unless `--force`.
- `releases/`, `*.tar.gz`, `*.log`, `notes/` are git-ignored or locally excluded; never commit build output. The old `scripts/` layout was removed in the 2026-10 restructure; `vsx prune --legacy` cleans its leftovers on a host.
