#!/usr/bin/env bash
# lib/notify.sh - events log, attempt tracking, email, GitHub issues, digest.
#
# Policy (see docs/OPERATIONS.md):
#   * failure  -> email immediately + open/update a GitHub issue
#   * success  -> close the matching issue; recorded for the digest
#   * digest   -> at most one email per calendar day summarising the last
#                 24h (including quiet days), sent by `vsx cron`

[[ -n "${__vsx_loaded_notify:-}" ]] && return 0
__vsx_loaded_notify=1

#-----------------------------------------------------------------------------
# Events: one JSON object per line in $VSX_EVENTS_FILE.
#   {"ts":"...","kind":"built|failed|uploaded|noop|error","version":"...","msg":"..."}
#-----------------------------------------------------------------------------
event_record() {
    local kind=$1 version=${2:-} msg=${3:-}
    python3 - "$VSX_EVENTS_FILE" "$kind" "$version" "$msg" "$(now_iso)" "${VSX_RUN_ID:-}" <<'PY'
import json, sys
path, kind, version, msg, ts, run = sys.argv[1:7]
with open(path, "a") as f:
    f.write(json.dumps({"ts": ts, "kind": kind, "version": version, "msg": msg, "run": run}) + "\n")
PY
}

# events_since HOURS : print events newer than N hours as "ts kind version msg"
events_since() {
    local hours=$1
    [[ -f "$VSX_EVENTS_FILE" ]] || return 0
    python3 - "$VSX_EVENTS_FILE" "$hours" <<'PY'
import json, sys, datetime
path, hours = sys.argv[1], float(sys.argv[2])
cut = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(hours=hours)
for line in open(path):
    try:
        e = json.loads(line)
        ts = datetime.datetime.strptime(e["ts"], "%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        continue
    if ts >= cut:
        print(f'{e["ts"]} {e["kind"]:<9} {e.get("version",""):<14} {e.get("msg","")}')
PY
}

#-----------------------------------------------------------------------------
# Attempts: $VSX_ATTEMPTS_DIR/<version> holds "count last_epoch".
#-----------------------------------------------------------------------------
attempts_get() {
    local f="$VSX_ATTEMPTS_DIR/$1"
    [[ -f "$f" ]] && cat "$f" || echo "0 0"
}

attempts_bump() {
    local v=$1 count
    read -r count _ < <(attempts_get "$v")
    echo "$((count + 1)) $(date +%s)" >"$VSX_ATTEMPTS_DIR/$v"
}

attempts_clear() { rm -f "$VSX_ATTEMPTS_DIR/$1"; }

# attempts_should_skip VERSION : true if this version has failed too often
# and the retry window has not elapsed.
attempts_should_skip() {
    local v=$1 count last now
    read -r count last < <(attempts_get "$v")
    (( count < VSX_MAX_ATTEMPTS )) && return 1
    now=$(date +%s)
    if (( now - last > VSX_RETRY_AFTER_HOURS * 3600 )); then
        # retry window elapsed: allow one more go, but keep the count.
        return 1
    fi
    return 0
}

#-----------------------------------------------------------------------------
# Email
#-----------------------------------------------------------------------------
# send_email SUBJECT BODY_FILE
send_email() {
    local subject=$1 body_file=$2
    if [[ "$VSX_EMAIL_ENABLED" != "true" ]]; then
        info "email disabled; would send: $subject"
        return 0
    fi
    if [[ -z "$VSX_EMAIL_TO" ]]; then
        warn "VSX_EMAIL_TO not set; cannot send: $subject"
        return 1
    fi
    if have mailx; then
        mailx -s "$subject" -r "$VSX_EMAIL_FROM" "$VSX_EMAIL_TO" <"$body_file"
    elif have mail; then
        mail -s "$subject" "$VSX_EMAIL_TO" <"$body_file"
    elif have sendmail; then
        { printf 'To: %s\nFrom: %s\nSubject: %s\n\n' "$VSX_EMAIL_TO" "$VSX_EMAIL_FROM" "$subject"; cat "$body_file"; } \
            | sendmail -t
    else
        warn "no mail command available; cannot send: $subject"
        return 1
    fi
    info "email sent to $VSX_EMAIL_TO: $subject"
}

_body_footer() {
    cat <<EOF

---
host:     $(hostname)
run:      ${VSX_RUN_ID:-manual}
log:      ${VSX_LOG_FILE:-<none>}
vsx:      $VSX_HOME ($(git -C "$VSX_HOME" rev-parse --short HEAD 2>/dev/null || echo 'no git'))
EOF
}

#-----------------------------------------------------------------------------
# Failure: email + issue
#-----------------------------------------------------------------------------
# notify_failure VERSION SUMMARY [LOG_FILE]
notify_failure() {
    local version=$1 summary=$2 logf=${3:-${VSX_LOG_FILE:-}}
    local body
    body=$(mktemp)
    {
        echo "VSCodium AIX build failed"
        echo
        echo "version: ${version:-n/a}"
        echo "summary: $summary"
        [[ -n "$VSX_FAILED_CMD" ]] && echo "command: $VSX_FAILED_CMD (line $VSX_FAILED_LINE)"
        echo
        echo "Last 80 log lines:"
        echo "-------------------"
        tail_file "$logf" 80
        _body_footer
    } >"$body"
    event_record failed "$version" "$summary"
    send_email "[vsx] FAILED ${version:+$version }- $summary" "$body" || true
    if [[ "$VSX_ISSUES_ENABLED" == "true" ]] && env_load_github_token; then
        _issue_for_failure "$version" "$summary" "$body" || warn "could not file GitHub issue"
    fi
    rm -f "$body"
}

_issue_for_failure() {
    local version=$1 summary=$2 body=$3
    local title="Build failed: ${version:-pipeline} - $summary"
    local md
    md=$(mktemp)
    {
        echo "Automated report from \`vsx\` on $(hostname)."
        echo
        echo "**Version:** ${version:-n/a}"
        echo "**Summary:** $summary"
        echo "**Time:** $(now_iso)"
        echo
        echo '<details><summary>Log tail</summary>'
        echo
        echo '```'
        tail_file "${VSX_LOG_FILE:-/dev/null}" 120
        echo '```'
        echo '</details>'
    } >"$md"
    local number
    number=$(issue_find_open "${version:-pipeline}" || true)
    if [[ -n "$number" ]]; then
        issue_comment "$number" "$md" && info "updated issue #$number"
    else
        number=$(issue_create "$title" "$md") && info "opened issue #$number"
    fi
    rm -f "$md"
}

# notify_success VERSION : close open failure issue for that version.
notify_success() {
    local version=$1
    event_record uploaded "$version" "published"
    attempts_clear "$version"
    if [[ "$VSX_ISSUES_ENABLED" == "true" ]] && env_load_github_token; then
        local number md
        number=$(issue_find_open "$version" || true)
        if [[ -n "$number" ]]; then
            md=$(mktemp)
            echo "Resolved: $version built and published by run ${VSX_RUN_ID:-manual} on $(now_iso)." >"$md"
            issue_comment "$number" "$md" && issue_close "$number" && info "closed issue #$number"
            rm -f "$md"
        fi
    fi
}

#-----------------------------------------------------------------------------
# Daily digest
#-----------------------------------------------------------------------------
digest_due() {
    [[ "$VSX_DIGEST_ENABLED" == "true" ]] || return 1
    local stamp="$VSX_STATE_DIR/digest.last"
    [[ -f "$stamp" ]] || return 0
    [[ "$(cat "$stamp")" != "$(today)" ]]
}

# digest_send LATEST_UPSTREAM PUBLISHED_LATEST PENDING_LIST
digest_send() {
    local upstream=$1 published=$2 pending=$3
    local body
    body=$(mktemp)
    {
        echo "VSCodium AIX daily digest for $(today)"
        echo
        echo "latest upstream VSCodium: $upstream"
        echo "latest published AIX:     $published"
        if [[ -n "$pending" ]]; then
            echo "pending / not yet built:  $pending"
        else
            echo "pending / not yet built:  none"
        fi
        echo
        echo "Events in the last 24h:"
        echo "-----------------------"
        local ev
        ev=$(events_since 24)
        if [[ -n "$ev" ]]; then printf '%s\n' "$ev"; else echo "(quiet: no builds, no failures)"; fi
        echo
        echo "Failed versions awaiting retry:"
        local f any=false
        for f in "$VSX_ATTEMPTS_DIR"/*; do
            [[ -f "$f" ]] || continue
            any=true
            printf '  %s attempts=%s\n' "$(basename "$f")" "$(cut -d' ' -f1 "$f")"
        done
        $any || echo "  none"
        _body_footer
    } >"$body"
    if send_email "[vsx] digest $(today): upstream $upstream, published $published" "$body"; then
        today >"$VSX_STATE_DIR/digest.last"
    fi
    rm -f "$body"
}
