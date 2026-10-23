#!/usr/bin/env bash
# lib/github.sh - GitHub REST API: upstream release discovery, our releases,
# asset upload, issues. curl + python only (no jq / gh on AIX).

[[ -n "${__vsx_loaded_github:-}" ]] && return 0
__vsx_loaded_github=1

GH_API="https://api.github.com"

# gh_auth_args : prints curl arguments (one per line) that add the Authorization header through a
# 0600 curl config file, so the token never appears in argv: on AIX every user can read every
# command line with ps, and uploads keep curl running for minutes.
gh_auth_args() {
    [[ -n "${GITHUB_TOKEN:-}" ]] || return 0
    local f="${VSX_STATE_DIR:-$HOME/.local/state/vsx}/.curl-github-auth"
    if [[ ! -f "$f" ]] || ! grep -qF -- "$GITHUB_TOKEN" "$f" 2>/dev/null; then
        mkdir -p "$(dirname "$f")"
        ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" > "$f.tmp" ) && mv -f "$f.tmp" "$f"
    fi
    chmod 600 "$f"
    printf -- '-K\n%s\n' "$f"
}

# gh_api METHOD PATH [JSON_BODY] : prints response body; fails on HTTP >= 400.
gh_api() {
    local method=$1 path=$2 body=${3:-}
    local url="$path"
    [[ "$path" == http* ]] || url="$GH_API$path"
    local -a args=(-sS -L --retry 3 --retry-delay 2 --connect-timeout 20 -m 120 -X "$method"
                   -H "Accept: application/vnd.github+json"
                   -H "X-GitHub-Api-Version: 2022-11-28"
                   -w '\n%{http_code}')
    local -a auth=()
    mapfile -t auth < <(gh_auth_args)
    (( ${#auth[@]} > 0 )) && args+=("${auth[@]}")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "$body")
    local out code
    out=$(curl "${args[@]}" "$url") || { error "curl failed for $method $url"; return 1; }
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    if (( code >= 400 )); then
        error "GitHub API $method $path -> HTTP $code"
        printf '%s\n' "$out" | head -c 600 >&2; echo >&2
        if grep -q 'rate limit' <<<"$out"; then
            error "GitHub API rate limit hit; is GITHUB_TOKEN / $VSX_GITHUB_TOKEN_FILE set?"
        fi
        return 1
    fi
    printf '%s' "$out"
}

# gh_paginate PATH : concatenates all pages of a list endpoint into one JSON
# array. Stops after MAX_PAGES (default 10 = 1000 items).
gh_paginate() {
    local path=$1 max_pages=${2:-10}
    local sep='?'
    [[ "$path" == *\?* ]] && sep='&'
    # Pages go through temp files: AIX has a small ARG_MAX, so large JSON
    # must never travel through argv.
    local tmpd page=1 n
    tmpd=$(mktemp -d)
    while (( page <= max_pages )); do
        gh_api GET "${path}${sep}per_page=100&page=$page" >"$tmpd/$page.json" || { rm -rf "$tmpd"; return 1; }
        n=$(jpy 'len(d)' <"$tmpd/$page.json")
        (( n < 100 )) && break
        page=$((page + 1))
    done
    python3 - "$tmpd" <<'PY2'
import json, os, sys
d = sys.argv[1]
out = []
for f in sorted(os.listdir(d), key=lambda x: int(x.split(".")[0])):
    out.extend(json.load(open(os.path.join(d, f))))
print(json.dumps(out))
PY2
    rm -rf "$tmpd"
}

#-----------------------------------------------------------------------------
# Upstream (VSCodium) releases
#-----------------------------------------------------------------------------
_reh_asset_name() { printf 'vscodium-reh-linux-x64-%s.tar.gz\n' "$1"; }

# upstream_latest_version : tag of /releases/latest
upstream_latest_version() {
    gh_api GET "/repos/$VSX_UPSTREAM_REPO/releases/latest" | jpy 'd["tag_name"]'
}

# upstream_versions_since FLOOR : all non-draft, non-prerelease upstream
# versions > FLOOR that have a linux-x64 REH asset, ascending. The asset is
# used only as the "this release is complete" signal (VSCodium uploads it
# late in its release job); the server itself is built from source.
upstream_versions_since() {
    local floor=$1
    local rels
    rels=$(gh_paginate "/repos/$VSX_UPSTREAM_REPO/releases" 5) || return 1
    jpy '
out = []
for r in d:
    if r.get("draft") or r.get("prerelease"):
        continue
    tag = r["tag_name"]
    names = {a["name"] for a in r.get("assets", [])}
    if f"vscodium-reh-linux-x64-{tag}.tar.gz" in names:
        out.append(tag)
r = out
' <<<"$rels" | while read -r v; do
        [[ -n "$v" ]] && ver_gt "$v" "$floor" && echo "$v" || true
    done | ver_sort
}

# upstream_asset_url VERSION : browser_download_url of the REH tarball.
upstream_asset_url() {
    local v=$1
    gh_api GET "/repos/$VSX_UPSTREAM_REPO/releases/tags/$v" \
        | jpy "[a['browser_download_url'] for a in d['assets'] if a['name']=='$(_reh_asset_name "$v")']" | head -1
}

#-----------------------------------------------------------------------------
# Our releases
#-----------------------------------------------------------------------------
# Only plain N.N.N tags count; an early legacy release used a 'v' prefix and
# is not something the extension can resolve.
our_release_tags() {
    local rels
    rels=$(gh_paginate "/repos/$VSX_RELEASE_REPO/releases" 5) || return 1
    jpy '[r["tag_name"] for r in d if not r.get("draft")]' <<<"$rels" \
        | { grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; } | ver_sort
}

# our_release_json TAG : release object or empty if none.
our_release_json() {
    gh_api GET "/repos/$VSX_RELEASE_REPO/releases/tags/$1" 2>/dev/null || true
}

# release_ensure TAG NAME BODY_FILE MAKE_LATEST(true|false) : create release if
# missing, else update body/latest flag. Prints release id.
release_ensure() {
    local tag=$1 name=$2 body_file=$3 make_latest=$4
    local body json existing id
    body=$(json_escape "$(cat "$body_file")")
    existing=$(our_release_json "$tag")
    if [[ -n "$existing" ]]; then
        id=$(jpy 'd["id"]' <<<"$existing")
        info "release $tag exists (id $id); updating notes, make_latest=$make_latest"
        json=$(printf '{"name":%s,"body":%s,"make_latest":"%s","draft":false,"prerelease":false}' \
               "$(json_escape "$name")" "$body" "$make_latest")
        gh_api PATCH "/repos/$VSX_RELEASE_REPO/releases/$id" "$json" >/dev/null
    else
        info "creating release $tag (make_latest=$make_latest)"
        json=$(printf '{"tag_name":%s,"name":%s,"body":%s,"make_latest":"%s","draft":false,"prerelease":false}' \
               "$(json_escape "$tag")" "$(json_escape "$name")" "$body" "$make_latest")
        existing=$(gh_api POST "/repos/$VSX_RELEASE_REPO/releases" "$json") || return 1
        id=$(jpy 'd["id"]' <<<"$existing")
    fi
    printf '%s\n' "$id"
}

# release_asset_id RELEASE_ID NAME : id of an existing asset or empty.
release_asset_id() {
    gh_api GET "/repos/$VSX_RELEASE_REPO/releases/$1/assets?per_page=100" \
        | jpy "[a['id'] for a in d if a['name']=='$2']" | head -1
}

# release_upload_asset RELEASE_ID FILE [force] : upload; skip if present
# unless force, in which case the old asset is replaced.
release_upload_asset() {
    local rid=$1 file=$2 force=${3:-false}
    local name ctype existing
    name=$(basename "$file")
    existing=$(release_asset_id "$rid" "$name")
    if [[ -n "$existing" ]]; then
        if [[ "$force" == "true" ]]; then
            info "replacing existing asset $name (id $existing)"
            gh_api DELETE "/repos/$VSX_RELEASE_REPO/releases/assets/$existing" >/dev/null
        else
            info "asset already uploaded, skipping: $name"
            return 0
        fi
    fi
    case "$name" in
        *.tar.gz) ctype="application/gzip" ;;
        *.json)   ctype="application/json" ;;
        *)        ctype="text/plain" ;;
    esac
    info "uploading $name ($(human_size "$(file_size "$file")"))"
    local out code
    local -a auth=()
    mapfile -t auth < <(gh_auth_args)
    out=$(curl -sS -L --retry 3 -X POST "${auth[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: $ctype" \
        --data-binary @"$file" \
        -w '\n%{http_code}' \
        "https://uploads.github.com/repos/$VSX_RELEASE_REPO/releases/$rid/assets?name=$name")
    code=${out##*$'\n'}
    if (( code >= 400 )); then
        error "asset upload failed (HTTP $code): ${out%$'\n'*}"
        return 1
    fi
    return 0
}

# release_published_aix_build TAG : the aix_build counter recorded in the
# published <base>.json asset for TAG; 0 if there is no release or no asset,
# 1 if the asset predates the counter. Works unauthenticated (public repo).
release_published_aix_build() {
    local tag=$1 rel url
    rel=$(our_release_json "$tag")
    [[ -n "$rel" ]] || { echo 0; return 0; }
    url=$(jpy "[a['browser_download_url'] for a in d.get('assets', []) if a['name']=='vscodium-reh-aix-ppc64-$tag.json']" <<<"$rel" | head -1)
    [[ -n "$url" ]] || { echo 0; return 0; }
    curl -fsSL --retry 2 "$url" 2>/dev/null | jpy 'int(d.get("aix_build", 1))' 2>/dev/null || echo 1
}

release_set_latest() {
    local tag=$1
    local existing id
    existing=$(our_release_json "$tag")
    [[ -n "$existing" ]] || return 0
    id=$(jpy 'd["id"]' <<<"$existing")
    gh_api PATCH "/repos/$VSX_RELEASE_REPO/releases/$id" '{"make_latest":"true"}' >/dev/null
}

#-----------------------------------------------------------------------------
# Issues (failure tracking)
#-----------------------------------------------------------------------------
# issue_find_open TITLE_SUBSTRING : number of an open issue with our label
# whose title contains the string, or empty.
issue_find_open() {
    local needle=$1
    gh_api GET "/repos/$VSX_RELEASE_REPO/issues?state=open&labels=$VSX_ISSUE_LABEL&per_page=100" \
        | jpy "[i['number'] for i in d if '$needle' in i['title'] and 'pull_request' not in i]" | head -1
}

issue_ensure_label() {
    gh_api GET "/repos/$VSX_RELEASE_REPO/labels/$VSX_ISSUE_LABEL" >/dev/null 2>&1 && return 0
    gh_api POST "/repos/$VSX_RELEASE_REPO/labels" \
        "{\"name\":\"$VSX_ISSUE_LABEL\",\"color\":\"d73a4a\",\"description\":\"Automated AIX build failure\"}" >/dev/null 2>&1 || true
}

# issue_create TITLE BODY_FILE : prints issue number.
issue_create() {
    local title=$1 body_file=$2
    issue_ensure_label
    local json
    json=$(printf '{"title":%s,"body":%s,"labels":["%s"]}' \
           "$(json_escape "$title")" "$(json_escape "$(cat "$body_file")")" "$VSX_ISSUE_LABEL")
    gh_api POST "/repos/$VSX_RELEASE_REPO/issues" "$json" | jpy 'd["number"]'
}

issue_comment() {
    local number=$1 body_file=$2
    gh_api POST "/repos/$VSX_RELEASE_REPO/issues/$number/comments" \
        "{\"body\":$(json_escape "$(cat "$body_file")")}" >/dev/null
}

issue_close() {
    local number=$1
    gh_api PATCH "/repos/$VSX_RELEASE_REPO/issues/$number" '{"state":"closed","state_reason":"completed"}' >/dev/null
}
