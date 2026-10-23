# AGENTS.md

Guidance for coding agents working in this repository. The authoritative,
detailed version is [CLAUDE.md](CLAUDE.md); keep the two in sync.

## Commands

```bash
# Lint (only thing that works off-AIX; CI runs the same)
shellcheck -S warning -x bin/vsx lib/*.sh cron/*.sh
for f in bin/vsx lib/*.sh cron/*.sh; do bash -n "$f"; done

# On the AIX build host
bin/vsx check
bin/vsx releases
bin/vsx build <version> --no-upload --keep-work
bin/vsx smoke ~/.cache/vsx/work/<version>/server
bin/vsx upload <version>
```

## Non-obvious rules

- Builds run only on AIX 7.3 ppc64 with the AIX Toolbox; nothing in `bin/`,
  `lib/` runs on Linux/macOS. Test in a second checkout with its
  own `VSX_STATE_DIR` and notifications disabled, always `--no-upload` first.
- Bash disables errexit inside `if`/`!`/`||` contexts; per-version builds run
  in a child process and module steps in `( set -e; ... )` subshells with
  `set +e` around them. Keep that pattern.
- AIX: small `ARG_MAX` (JSON via stdin/files), no `jq`/`flock`/`pgrep`, no
  GNU-only `find`/`xargs` flags, `/opt/freeware/bin` first in PATH, never
  `npm --version` on `/opt/nodejs`.
- Native modules are built at the version the downloaded server bundles,
  against the official nodejs.org AIX Node that upstream targets; the
  release is only packaged after the server starts (`server_smoke_test`).
- `make_latest` only for the highest published version; never delete
  releases; `releases/` and tarballs are git-ignored.
