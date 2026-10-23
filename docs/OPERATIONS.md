# Operations runbook

For whoever keeps the AIX builds flowing. Assumes the host was set up as in
the README, section 4. Commands are relative to the repository checkout;
`vsx` means `bin/vsx`. The build itself is the fork's business
([howto-build-aix.md](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md));
this runbook is about keeping the runner, the host and the releases healthy.

## Daily reality

* Cron runs `cron/vsx-cron.sh` every 4 hours. Each tick: lock, compare
  upstream releases with ours, build what is missing (oldest first), prune,
  send the digest once a day.
* You get **one digest email per day**. That is the heartbeat. Failures
  arrive immediately as email and as a GitHub issue labelled `build-failure`.
* Everything a run did is in `~/.local/state/vsx/logs/<timestamp>-<what>.log`,
  including the full npm/node-gyp/gulp/verify output of the build child.
* A version takes about 8 minutes with a warm npm cache; the first build on
  a host is longer (VS Code shallow fetch ~400 MB, npm cache fill).

## Where things are on the host

| Path | What |
|---|---|
| `~/utility/vscodium-aix-server` | checkout running under cron (branch `main`) |
| `~/.config/vsx/vsx.conf` | configuration |
| `~/.config/vscodium-aix/github-token` | GitHub token (`repo` scope, mode 600); named by `VSX_GITHUB_TOKEN_FILE` and exported as `GITHUB_TOKEN` by `~/local/env.sh` |
| `~/local/` | user-local build tools: `node-v24.x`, `bin/jq`, `RustSDK/<ver>`, `portlibforaix/`, `env.sh` |
| `~/.gyp/include.gypi` | written by `build/aix/package_reh.sh` on every build (AIX gyp defaults); a previous copy is kept as `.pre-vscodium` |
| `~/.local/state/vsx/` | `lock/`, `events.jsonl`, `attempts/`, `digest.last`, `last-pipeline-error`, `logs/` |
| `~/.cache/vsx/` | `fork/` (clone), `work/<v>/` (worktrees), `npm/`, `node/` (target runtimes), `ripgrep/` |
| `<checkout>/releases/<v>/` | packaged artifacts, newest 3 kept |

## Incident checklist

### "I got a failure email / an issue was opened"

1. Open the log named in the email. The subject names the stage:
   `fork`, `worktree`, `build`, `manifest`, `package`, `upload`.
2. `fork`: the fork cannot be cloned or fetched, or neither tag `aix/<v>`
   nor branch `VSX_FORK_REF` exists. Check network and
   `git ls-remote https://github.com/tonykuttai/vscodium.git`.
3. `worktree`, message `has upstream/stable.json tag 'X' but <v> needs 'Y'`:
   a new VSCodium release the fork has not caught up with. See
   [the stable.json entry](#stable-json) below. This is the expected
   failure after every upstream release until the rebase is done.
4. `build`: everything inside VSCodium's scripts and `package_reh.sh`.
   Search the log for the last `=== ` marker to see which script failed,
   then the first error above the failure. Typical causes:
   * *`<tool> not on PATH after sourcing ~/local/env.sh`*: the env file or a
     user-local tool moved. `vsx check` shows what the build child sees.
   * *patch does not apply* in `prepare_vscode.sh`: upstream changed a file
     `patches/aix` touches. Fix in the fork, push, rebuild; the fork's CI
     normally catches this the day VSCodium bumps.
   * *addon fails to compile or load* (`npm rebuild` in `remote/`, or
     `fix-build-tools: ... layout changed`): a dependency changed layout.
     The fix belongs in `build/aix/fix-node-modules.sh`,
     `fix-build-tools.sh` or their patches.
   * *nodejs.org has no `aix-ppc64` build* for the Node in `remote/.npmrc`:
     wait; cron retries.
   * *ripgrep*: `cargo not found` (set `VSX_RUST_HOME` or `VSX_AIX_RIPGREP`)
     or an MSRV error (newer IBM Open SDK for Rust needed).
   * *GitHub rate limit* while gulp downloads built-in extensions: the token
     was not passed or is invalid. `vsx check`.
   * *verify_reh.sh failed*: the server built but fails the smoke test; the
     log tail shows which check. Reproduce with
     `vsx build <v> --no-upload --keep-work` then
     `vsx smoke ~/.cache/vsx/work/<v>/vscodium/vscode-reh-aix-ppc64`.
5. `upload`: token expired or lost `repo` scope. `vsx check` tells you.
   Re-run `vsx upload <v>`; the package is still in `releases/<v>/`.
6. After fixing: `vsx build <v> --retry` (or just wait; cron retries after
   `VSX_RETRY_AFTER_HOURS`). A successful publish closes the issue.

### <a name="stable-json"></a>"A new VSCodium release appeared but the build stops with the stable.json message"

The runner builds version V only from a fork commit whose
`upstream/stable.json` names V's VS Code tag. After VSCodium releases, the
fork's `aix` branch must be rebased onto that release and the result tagged.
In a clone of the fork (`origin` = fork, `upstream` = VSCodium/vscodium):

```sh
git fetch upstream --tags
git push origin upstream/master:master          # master mirrors upstream, never edited
git checkout aix
git rebase master aix                            # or: git rebase <VSCodium tag>, if master is ahead of the release
# resolve conflicts in patches/aix (git apply --ignore-whitespace must still succeed);
# one topic per commit, squash fix-ups into their topic
git push --force-with-lease origin aix           # force-push of aix is expected after a rebase
git tag aix/<V> && git push origin aix/<V>
```

Then `vsx build <V>` (or wait for cron). Tag only after the build has passed
if you are unsure; the runner falls back to the branch head when no tag
exists, and the tag can be added afterwards on the same commit. The fork's
GitHub Actions check that `patches/aix` apply to the new VS Code commit, so
a red CI on `aix` tells you before the AIX box does.

### "No digest for two days"

```sh
crontab -l                                   # is the job still there?
tail -50 ~/.local/state/vsx/logs/cron-wrapper.log
ls -lt ~/.local/state/vsx/logs | head
ls ~/.local/state/vsx/lock && cat ~/.local/state/vsx/lock/pid   # stale lock? vsx reclaims dead pids itself
vsx check
vsx notify-test                              # does mail work at all?
```

### "The desktop says no server for version X"

```sh
vsx releases            # is X pending, parked, or older than the floor?
vsx build X             # build and publish it now
```
If X is older than `VSX_BACKFILL_FLOOR`, pass it explicitly as above; the
floor only limits automatic backfill. X needs a fork ref for its VS Code
tag (tag `aix/X`, or the branch if it is the current release).

### "A published package is broken"

```sh
vsx build X --force     # fresh worktree, rebuilds, re-tests, replaces the release assets
```
The release notes then show "AIX build N" and the extension refreshes
installs. Releases are never deleted by vsx. If you must pull one, do it in
the GitHub UI; the extension then falls back to the latest remaining release.

### <a name="ahafs"></a>"Servers start but never answer; killed processes stay `<exiting>`; ssh logins hang"

AHAFS (`/aha`, the AIX kernel file-event filesystem) is wedged. Node's native
`fs.watch` enters it and never returns; the affected processes cannot be
killed. Diagnose with `truss -f` on a hanging process (last syscalls are
`mkdir("/aha/fs/modDir.monFactory/...")`) or
`node -e 'require("fs").watch("/tmp")'` hanging. Only root can clear it:
`umount /aha && mount /aha`, or a reboot. Packages built since 2026-10-19
never enter AHAFS (polling shim + polling @parcel/watcher) and the smoke
test fails a build that does. Full write-up in the maintainers' internal
incident notes (kept outside the repository).

## Rules for the build host

* **Never export the runtime `LIBPATH` in a shell that builds.** The
  Toolbox compiler binaries are 32-bit; with the 64-bit runtime directories
  that a server's `bin/aix-env.sh` sets first on `LIBPATH`, `gcc` and `g++`
  refuse to start (`0509-036`). The runner starts the build child with
  `LIBPATH` unset. Build by hand only in a fresh login shell, never after
  sourcing `aix-env.sh` or starting a server there; `~/local/env.sh` must
  not set `LIBPATH` either.
* No root is used anywhere. If something seems to need `dnf install`,
  build it under `~/local` instead and put it on `PATH` in `env.sh`.

## Routine tasks

| Task | Command |
|---|---|
| Status | `vsx releases` |
| Backfill | `vsx build --missing` |
| One version, no publish | `vsx build V --no-upload --keep-work` |
| Publish a built package | `vsx upload V` |
| Smoke test a built tree again | `vsx smoke ~/.cache/vsx/work/V/vscodium/vscode-reh-aix-ppc64` |
| Force ripgrep to recompile | `rm -rf ~/.cache/vsx/ripgrep` (and unset `VSX_AIX_RIPGREP`), then build |
| Fresh target Node tree | `rm -rf ~/.cache/vsx/node/node-v<ver>-aix-ppc64*`, then build |
| Clean disk | `vsx prune` (automatic after each cron tick); once on an old host `vsx prune --legacy` |
| Rotate the token | replace `~/.config/vscodium-aix/github-token`; `vsx check` |
| Change email | edit `VSX_EMAIL_TO` in `~/.config/vsx/vsx.conf` |

## <a name="new-host"></a>Setting up a new build host (no root)

Checklist, in order. The fork's
[howto](https://github.com/tonykuttai/vscodium/blob/aix/docs/howto-build-aix.md#host-prerequisites-no-root-needed)
has the exact build commands for each tool.

1. Toolbox packages (usually present): GCC 12+ with runtime, `gmake`,
   `cmake`, `git`, `curl`, `patch`, `python3`, `krb5-devel`, GNU
   `coreutils`/`grep`/`sed`/`tar`/`file`, `bash`. `/opt/freeware/bin` first
   on `PATH`. If something is missing and nobody can install it, build it
   under `~/local`.
2. `~/local/node-v24.x` from the nodejs.org `aix-ppc64` tarball, the version
   in the fork's `.nvmrc`. `~/local/node` as a symlink to it keeps `env.sh`
   stable across upgrades.
3. `~/local/bin/jq`: jq 1.7.1 from source, static, 64-bit, with the
   `src/jv_alloc.c` change so `malloc(0)` is never called (AIX returns NULL
   and jq reports out of memory). Flags are in the howto.
4. Rust, one of: extract the IBM Open SDK for Rust rpm with
   `rpm2cpio ... | cpio -idm` under `~/local`, relocated to
   `~/local/RustSDK/<ver>` (`VSX_RUST_HOME` = its `bin`); or copy an
   existing `aix-ppc64` `rg` from another host's `~/.cache/vsx/ripgrep/`
   and set `VSX_AIX_RIPGREP`. The copy is enough until the ripgrep tag
   that `@vscode/ripgrep-universal` pins changes.
5. `git clone https://github.com/tonykuttai/portlibforaix ~/local/portlibforaix && make`
   there, giving `lib/libutil.so.2` (`VSX_AIX_LIBUTIL`).
6. Token: `~/.config/vscodium-aix/github-token`, mode 600, `repo` scope.
7. `~/local/env.sh`: `~/local/node/bin` and `~/local/bin` first on `PATH`;
   `CC=gcc CXX=g++ VSCODE_REMOTE_CC=gcc VSCODE_REMOTE_CXX=g++`; `ulimit`
   raised where allowed; `GITHUB_TOKEN` exported from the token file. No
   `LIBPATH`.
8. Clone this repository, write `~/.config/vsx/vsx.conf`
   (`VSX_EMAIL_TO`, `VSX_GITHUB_TOKEN_FILE`, `VSX_AIX_RIPGREP` or
   `VSX_RUST_HOME`), then `bin/vsx check` until it prints `OK`.
9. `bin/vsx build --latest --no-upload --keep-work` (20 to 30 minutes the
   first time). Stage the package under `~/.vscodium-server/bin/<commit>`
   and connect with a real client (README, section 8) before publishing.
10. Only then: `vsx upload`, crontab. Make sure no other host still runs the
    cron job (next section).

## Cut-over from cpap8104 (completed 2026-10-23)

Done on 2026-10-23: cpap8104's `vsx-cron.sh` entry was removed (its crontab is backed up in
`~/crontab.backup.20261022-213915` there), wyvernden6aix73 runs the runner from cron, and 1.140.06880 was
republished from the new pipeline. The steps are kept for the next host move.

`cpap8104` ran the previous pipeline (Linux tarball + transplanted modules)
under cron until the source build was proven on `wyvernden6aix73`. Two hosts
publishing to the same repository would race on `make_latest` and on
assets. To move:

1. On wyvernden: `vsx check` is `OK`; `vsx build --latest --no-upload
   --keep-work` passes; a client session against the staged package works
   (terminal, search, file watching, git).
2. Run both once, side by side, for the same version with `--no-upload`.
   Compare the extracted tarballs (`diff -rq`): same commit, same bundled
   Node major, same launcher set; the source build additionally has AIX
   `sqlite3`/`kerberos` binaries and no ELF file left
   (`find . -type f | xargs file | grep ELF` must be empty).
3. On cpap8104: `crontab -e`, remove the `vsx-cron.sh` line. Leave the
   checkout and caches in place for one release cycle in case of rollback.
4. On wyvernden: add the crontab line (README 4.4). Watch the first tick's
   log and the next day's digest.
5. After one upstream release has been published from wyvernden without
   intervention: `vsx prune --legacy` on cpap8104 and remove its checkout.

## Testing changes to vsx itself

Never test in the checkout cron uses. Use a second checkout with its own
state directory and notifications off:

```sh
git clone -b <branch> https://github.com/tonykuttai/vscodium-aix-server.git ~/utility/vsx-dev
cat > ~/.config/vsx/vsx-dev.conf <<EOF
VSX_STATE_DIR=\$HOME/.local/state/vsx-dev
VSX_EMAIL_ENABLED=false
VSX_ISSUES_ENABLED=false
VSX_DIGEST_ENABLED=false
EOF
cd ~/utility/vsx-dev
VSX_CONFIG=~/.config/vsx/vsx-dev.conf bin/vsx check
VSX_CONFIG=~/.config/vsx/vsx-dev.conf bin/vsx build --latest --no-upload --keep-work
```
The fork clone, npm cache, Node runtime trees and ripgrep binary under
`~/.cache/vsx` are shared with the production checkout (set `VSX_CACHE_DIR`
too if you need isolation). To test a package with a real client before
publishing, stage it under `~/.vscodium-server/bin/<commit>/` (README,
section 8) and connect with VSCodium; the extension uses an existing
directory instead of downloading.

To test a change to the build itself, point `VSX_FORK_REPO`/`VSX_FORK_REF`
at your fork branch in the dev config; the runner builds from any ref whose
`stable.json` matches the version.

## The release message

`lib/server.sh:release_notes` renders the body of every GitHub release from
the build manifest. It contains, in this order:

1. one line naming the version, the platform and "unofficial community
   build", and the AIX build number (with a refresh note on rebuilds);
2. "built from source" with links to this repository, the fork branch and
   commit, and the upstream VSCodium release;
3. the four install commands (`wget`, `mkdir`, `tar --strip-components 1`,
   `--version`) using the real commit id;
4. the requirements on the target (AIX 7.3, Toolbox GCC runtime 12+,
   `krb5-libs`, no Node needed);
5. a table of every component with its version and a note (VS Code tag and
   commit, node runtime, each addon, ripgrep, toolchain and host);
6. the SHA256 of the tarball.

The README's "Using a release" section states the same requirements and the
same install commands in generic form. If you change one, change the other.
The same data is uploaded as `vscodium-reh-aix-ppc64-<v>.json` and is
inside the tarball as `aix-build-manifest.json`.

## Upgrading the toolchain

* **GCC**: Toolbox `gcc` 12+ works; `vsx check` shows which is first in
  `PATH`. The launcher inside packages finds the highest installed GCC
  runtime on the *target*, so the build host's GCC version does not need to
  match the target's.
* **Rust**: a newer IBM Open SDK for Rust goes under `~/local/RustSDK/<ver>`;
  update `VSX_RUST_HOME`. The ripgrep cache key includes the rustc version,
  so `rg` recompiles automatically.
* **Host Node**: when the fork's `.nvmrc` moves, install that version under
  `~/local` and repoint the symlink used by `env.sh`. The *bundled* Node is
  separate and downloaded per version into `~/.cache/vsx/node`; delete old
  ones when disk matters.
* **jq**, **Python**: 1.7.1 with the `malloc(0)` fix and Toolbox 3.9+ are
  fine; nothing depends on newer features.
