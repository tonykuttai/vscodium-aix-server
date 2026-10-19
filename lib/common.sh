#!/usr/bin/env bash
# lib/common.sh - logging, error handling, locking, small helpers.
# Sourced by bin/vsx and every other lib. Never executed directly.

[[ -n "${__vsx_loaded_common:-}" ]] && return 0
__vsx_loaded_common=1

#-----------------------------------------------------------------------------
# Strict mode. Every lib relies on this; functions used for control flow must
# be called inside `if`, `||`, or `&&` so that errexit does not fire on them.
#-----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$' \t\n'

#-----------------------------------------------------------------------------
# Logging. Everything goes to stderr and, when VSX_LOG_FILE is set, to that
# file as well. stdout is reserved for data (subcommands that print values).
#-----------------------------------------------------------------------------
VSX_LOG_FILE="${VSX_LOG_FILE:-}"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_emit() {
    local line
    line="[$(_ts)] $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$VSX_LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$VSX_LOG_FILE" 2>/dev/null || true
    fi
}

log()     { _emit "$*"; }
info()    { _emit "INFO  $*"; }
warn()    { _emit "WARN  $*"; }
error()   { _emit "ERROR $*"; }
section() { _emit ""; _emit "=== $* ==="; }

# die MESSAGE... : log and exit 1. The EXIT trap (if installed) notifies.
die() {
    error "$*"
    exit 1
}

# Record the last failing command so the EXIT trap can report it.
VSX_FAILED_CMD=""
VSX_FAILED_LINE=""
_on_err() {
    local rc=$1 line=$2 cmd=$3
    export VSX_FAILED_CMD="$cmd"
    export VSX_FAILED_LINE="$line"
    error "command failed (exit $rc) at line $line: $cmd"
}
# BASH_LINENO[0] is the line in the function that called the failing command.
trap '_on_err $? "${BASH_LINENO[0]:-$LINENO}" "$BASH_COMMAND"' ERR

#-----------------------------------------------------------------------------
# Run a command, teeing its output into the log file while preserving the
# command's own exit status (pipefail is on, but tee could in theory fail).
#-----------------------------------------------------------------------------
run_logged() {
    if [[ -n "$VSX_LOG_FILE" ]]; then
        "$@" 2>&1 | tee -a "$VSX_LOG_FILE"
        return "${PIPESTATUS[0]}"
    else
        "$@"
    fi
}

# Run a command quietly, appending its output to a file. On failure, print the
# last 40 lines so the pipeline log explains itself.
run_quiet() {
    local outfile=$1; shift
    if ! "$@" >>"$outfile" 2>&1; then
        local rc=$?
        error "command failed (exit $rc): $*"
        error "last 40 lines of $outfile:"
        tail -40 "$outfile" >&2 || true
        return "$rc"
    fi
}

#-----------------------------------------------------------------------------
# Tool checks
#-----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        have "$c" || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        die "missing required tools: ${missing[*]}"
    fi
}

#-----------------------------------------------------------------------------
# Locking without flock (not available on AIX): mkdir is atomic.
# The lock dir holds the owner pid; a stale lock (dead pid) is reclaimed.
#-----------------------------------------------------------------------------
VSX_LOCK_DIR=""

lock_acquire() {
    local dir=$1
    if mkdir "$dir" 2>/dev/null; then
        echo $$ >"$dir/pid"
        VSX_LOCK_DIR="$dir"
        return 0
    fi
    local pid
    pid=$(cat "$dir/pid" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        warn "another vsx run is active (pid $pid), lock: $dir"
        return 1
    fi
    warn "reclaiming stale lock $dir (pid ${pid:-unknown} is gone)"
    rm -rf "$dir"
    if mkdir "$dir" 2>/dev/null; then
        echo $$ >"$dir/pid"
        VSX_LOCK_DIR="$dir"
        return 0
    fi
    return 1
}

lock_release() {
    if [[ -n "$VSX_LOCK_DIR" && -d "$VSX_LOCK_DIR" ]]; then
        rm -rf "$VSX_LOCK_DIR"
        VSX_LOCK_DIR=""
    fi
}

#-----------------------------------------------------------------------------
# Version helpers. VSCodium versions look like 1.140.06880; module versions
# like 1.2.0-beta.15. We compare numerically component-wise via python so we
# never depend on GNU sort -V being present.
#-----------------------------------------------------------------------------
# ver_sort : read versions on stdin, print ascending.
ver_sort() {
    python3 -c '
import re, sys
def key(v):
    parts = re.split(r"[.\-]", v.strip())
    out = []
    for p in parts:
        out.append((0, int(p)) if p.isdigit() else (1, p))
    return out
vs = [l.strip() for l in sys.stdin if l.strip()]
for v in sorted(vs, key=key):
    print(v)
'
}

# ver_gt A B : true if A > B
ver_gt() {
    [[ "$1" == "$2" ]] && return 1
    local last
    last=$(printf '%s\n%s\n' "$1" "$2" | ver_sort | tail -1)
    [[ "$last" == "$1" ]]
}

# ver_ge A B
ver_ge() { [[ "$1" == "$2" ]] || ver_gt "$1" "$2"; }

# ver_max : read versions on stdin, print the highest.
ver_max() { ver_sort | tail -1; }

#-----------------------------------------------------------------------------
# JSON without jq: `d` is the parsed document, the expression's result is
# printed one item per line (lists) or as a scalar.
#   curl ... | jpy 'd["tag_name"]'
#   jpy '[a["name"] for a in d["assets"]]' < file.json
# Multi-line code is exec'd instead; set `r` to the value to print (or print
# directly). Never pass large data through argv: AIX ARG_MAX is small.
#-----------------------------------------------------------------------------
jpy() {
    python3 -c '
import json, sys
d = json.load(sys.stdin)
src = sys.argv[1]
if "\n" in src.strip():
    # multi-line: statements; they may print themselves or set r
    ns = {"d": d, "json": json}
    exec(src, ns)
    r = ns.get("r")
else:
    r = eval(src)
if isinstance(r, (list, tuple)):
    for x in r:
        print(x)
elif isinstance(r, bool):
    print("true" if r else "false")
elif r is None:
    pass
else:
    print(r)
' "$1"
}

# json_escape STRING : print a JSON string literal (with quotes).
json_escape() {
    printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

#-----------------------------------------------------------------------------
# Misc
#-----------------------------------------------------------------------------
# json_field FILE KEY : top-level string field of a JSON file (product.json,
# package.json). Real parsing: product.json contains several nested "version"
# keys, so grep-the-first-match is not safe.
json_field() {
    local file=$1 key=$2
    [[ -f "$file" ]] || return 1
    jpy "d.get('$key', '')" <"$file"
}

# pkg_version DIR : "version" from DIR/package.json, empty if absent.
pkg_version() {
    local dir=$1
    [[ -f "$dir/package.json" ]] || return 1
    json_field "$dir/package.json" version
}

# human_size BYTES
human_size() {
    python3 -c '
import sys
n = float(sys.argv[1])
for u in ["B", "KB", "MB", "GB"]:
    if n < 1024: print(f"{n:.1f}{u}"); break
    n /= 1024
else:
    print(f"{n:.1f}TB")
' "$1"
}

file_size() {
    # GNU stat and AIX istat differ; wc -c works everywhere.
    wc -c <"$1" | tr -d ' '
}

# tail_file FILE N : print last N lines, tolerant of a missing file.
tail_file() {
    local f=$1 n=${2:-60}
    [[ -f "$f" ]] && tail -n "$n" "$f" || true
}

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
today()   { date -u '+%Y-%m-%d'; }
