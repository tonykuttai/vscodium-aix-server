# Operations runbook

For whoever keeps the AIX builds flowing. Assumes the host was set up as in
the README, section 4. Commands are relative to the repository checkout;
`vsx` means `bin/vsx`.

## Daily reality

* Cron runs `cron/vsx-cron.sh` every 4 hours. Each tick: lock, compare
  upstream releases with ours, build what is missing (oldest first), prune,
  send the digest once a day.
* You get **one digest email per day**. That is the heartbeat. Failures
  arrive immediately as email and as a GitHub issue labelled `build-failure`.
* Everything a run did is in `~/.local/state/vsx/logs/<timestamp>-<what>.log`.
  Per-module compiler output is in
  `~/.cache/vsx/modules/<module>/<key>/build.log`.

## Where things are on the host

| Path | What |
|---|---|
| `~/utility/vscodium-aix-server` | checkout running under cron (branch `main`) |
| `~/.config/vsx/vsx.conf` | configuration |
| `~/.config/github/token` | GitHub token (`repo` scope, mode 600) |
| `~/.local/state/vsx/` | `lock/`, `events.jsonl`, `attempts/`, `digest.last`, `last-pipeline-error`, `logs/` |
| `~/.cache/vsx/` | `downloads/`, `node/`, `modules/`, `work/`, `npm/` |
| `<checkout>/releases/<v>/` | packaged artifacts, newest 3 kept |
| `~/local/portlibforaix/` | `libutil.so.2` for node-pty, built on demand |

## Incident checklist

### "I got a failure email / an issue was opened"

1. Open the log named in the email. The subject names the stage:
   `fetch`, `runtime`, `module:<name>`, `runtime-install`, `launchers`,
   `smoke`, `package`, `upload`.
2. For `module:<name>` read the module's `build.log` (path is in the log).
   Typical causes and fixes:
   * *upstream tag missing* (`no tag X or vX in <repo>`): upstream renamed
     tags or the package version is not a git tag. Check the repo; adjust
     `git_clone_tag` or the module's `_wanted` function.
   * *`-fstack-protector-strong`* or other new compiler flags: extend
     `strip_stack_protector` / the module script.
   * *ripgrep MSRV*: `this ripgrep requires rustc >= X`. Install a newer
     Toolbox `rust` RPM (`dnf install rust`) or a user-local toolchain, or
     set `VSX_RIPGREP_FALLBACK_TAG` temporarily.
   * *patch does not apply* (node-pty): upstream changed `pty.cc`.
     Regenerate `patches/node-pty-aix.patch` against the new tag (the AIX
     changes are three small blocks, see MODULES.md).
   * *binding.gyp layout changed* (parcel-watcher): update the Python edit
     in `modules/parcel-watcher.sh`.
3. For `runtime`: nodejs.org has no `aix-ppc64` build for the Node major
   upstream now wants. Check <https://nodejs.org/dist/index.json>. Until one
   appears, you can set `VSX_NODE_RUNTIME=host` with a user-local Node of
   that major in `VSX_HOST_NODE` (then the package is *not* self-contained).
4. For `smoke`: the server log tail is in the run log. Usually a module that
   built but fails at runtime (missing `LIBPATH` entry, ABI mismatch).
   Reproduce with `vsx build <v> --no-upload --keep-work` and
   `vsx smoke ~/.cache/vsx/work/<v>/server`.
5. For `upload`: token expired or lost `repo` scope. `vsx check` tells you.
   Re-run `vsx upload <v>`; the package is still in `releases/<v>/`.
6. After fixing: `vsx build <v> --retry` (or just wait; cron retries after
   `VSX_RETRY_AFTER_HOURS`). A successful publish closes the issue.

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
floor only limits automatic backfill.

### "A published package is broken"

```sh
vsx build X --force     # rebuilds, re-tests, replaces the release assets
```
Releases are never deleted by vsx. If you must pull one, do it in the GitHub
UI; the extension then falls back to the latest remaining release.

## Routine tasks

| Task | Command |
|---|---|
| Status | `vsx releases` |
| Backfill | `vsx build --missing` |
| One version, no publish | `vsx build V --no-upload --keep-work` |
| Publish a built package | `vsx upload V` |
| Recompile a module | `rm -rf ~/.cache/vsx/modules/<name>` then build |
| Clean disk | `vsx prune` (automatic after each cron tick); once on an old host `vsx prune --legacy` |
| Rotate the token | replace `~/.config/github/token`; `vsx check` |
| Change email | edit `VSX_EMAIL_TO` in `~/.config/vsx/vsx.conf` |

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
The module cache (`~/.cache/vsx/modules`) is shared, so this is fast after
the first time. To test a package with a real client before publishing,
stage it under `~/.vscodium-server/bin/<commit>/` (README, section 8) and
connect with VSCodium; the extension uses an existing directory instead of
downloading.

## The release message

`lib/server.sh:release_notes` renders the body of every GitHub release from
the build manifest. It contains, in this order:

1. one line naming the version, the platform and "unofficial community build";
2. a pointer to this repository and to the upstream VSCodium release;
3. the four install commands (`wget`, `mkdir`, `tar --strip-components 1`,
   `--version`) using the real commit id;
4. the requirements on the target (AIX 7.3, Toolbox GCC runtime, no Node
   needed);
5. a table of every component with its version and a note (node runtime,
   each module, toolchain used);
6. the SHA256 of the tarball.

The README's "Using a release" section states the same requirements and the
same install commands in generic form. If you change one, change the other.
The same data is uploaded as `vscodium-reh-aix-ppc64-<v>.json` and is
inside the tarball as `aix-build-manifest.json`.

## Upgrading the toolchain

* **GCC**: any Toolbox `gcc` 10+ works; `vsx check` shows which is first in
  `PATH`. The launcher inside packages finds the highest installed GCC
  runtime on the *target*, so the build host's GCC version does not need to
  match the target's.
* **Rust**: install the newest Toolbox `rust`/`cargo` RPMs. Module cache
  keys include the rustc version, so ripgrep recompiles automatically.
* **Node**: nothing to install. Delete old runtimes from `~/.cache/vsx/node`
  when disk matters.
* **Python**: 3.9+ from the Toolbox.
