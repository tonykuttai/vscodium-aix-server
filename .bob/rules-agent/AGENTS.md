# Project rules (non-obvious only)

See CLAUDE.md for the full guidance; the points below are the ones that bite.

- Runs only on AIX 7.3 ppc64 (AIX Toolbox GNU userland first in PATH). Lint off-AIX with shellcheck + bash -n only.
- Entry point `bin/vsx`; libraries in `lib/`; one builder per native module in `modules/`; launcher templates in `templates/`; patches in `patches/`.
- Bash errexit is suppressed inside `if`/`!`/`||`: builds run per version in a child process and module steps in `( set -e; ... )` subshells. Keep it.
- AIX has small ARG_MAX, no jq/flock/pgrep and no GNU-only find/xargs flags; JSON goes through python via stdin.
- Native modules are built at the version the downloaded server bundles, against the bundled official nodejs.org AIX Node; packages ship only after the server starts in the smoke test.
- `make_latest` only for the highest published version; never delete GitHub releases; never commit `releases/` or tarballs.
