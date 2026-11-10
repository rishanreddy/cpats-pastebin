#!/usr/bin/env bash
# Run on the VM. Needs only Bash, curl or wget, and the standard tools every Linux
# install has (sed, awk, grep, base64, sha1sum, and so on). No Python, Git, or jq,
# and nothing is installed. The VM only runs commands.
# Every setting is a command-line flag. No config file or environment variable is read.
# The publisher and clipboard tool also source the helpers in this file.
set -euo pipefail

DEFAULT_REPO='rishanreddy/cpats-pastebin'   # Forks: change this line or pass --repo.
DEFAULT_BRANCH='main'
LOOP_INTERVAL_TOKEN=30    # Seconds between checks with a token (5,000 requests/hour).
LOOP_INTERVAL_ANON=120    # Seconds between checks without one (60 requests/hour per IP).

GITHUB_REPO="$DEFAULT_REPO"
GITHUB_TOKEN=''
BRANCH="$DEFAULT_BRANCH"
GH_BACKEND=http           # http: curl or wget with --token. cli: the developer's gh login.
GH_HTTP_CODE=000
RATE_LIMIT_WAIT=0
GH_RATE_LIMIT='' GH_RATE_REMAINING='' GH_TOKEN_SCOPES='' GH_TOKEN_EXPIRES=''
LISTING=''

log()  { printf '[cpats] %s\n' "$*"; }
ok()   { printf '[  ok ] %s\n' "$*"; }
warn() { printf '[ warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# ── Text, hash, and JSON helpers. Plain shell tools only, so nothing needs installing. ──

_sha1() { if command -v sha1sum >/dev/null 2>&1; then sha1sum | cut -d' ' -f1; else shasum -a 1 | cut -d' ' -f1; fi; }

# The Git blob hash GitHub reports for a file: SHA-1 of "blob <size>", a NUL byte, then the bytes.
_blob_sha1() {
    local size
    size=$(wc -c < "$1" | tr -d '[:space:]')
    { printf 'blob %s\0' "$size"; cat "$1"; } | _sha1
}

# Lowercase, replace anything but a-z 0-9 _ - with "-", trim the ends, cut to $1 characters.
_slug() { tr -d '\n' | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | cut -c"1-$1" | sed -e 's/^[-_]*//' -e 's/[-_]*$//'; }

# Prints the value of one response header from a curl -D or wget -S dump, or nothing.
_header() { { grep -i "^[[:space:]]*$2:" "$1" 2>/dev/null | tail -n 1 | cut -d: -f2- | tr -d ' \r'; } || true; }

# Like _header, but keeps spaces inside the value, such as a date.
_header_text() {
    { grep -i "^[[:space:]]*$2:" "$1" 2>/dev/null | tail -n 1 | cut -d: -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; } || true
}

# First string value of a key in a JSON file. Works on compact and pretty-printed JSON.
_json_string() {
    { tr -d '\r\n' < "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 \
        | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'; } || true
}

# Prints true or false for permissions.push in a repo JSON file, or nothing if absent.
_json_push_permission() {
    { tr -d '\r\n ' < "$1" | grep -oE '"permissions":\{[^}]*\}' | head -n 1 \
        | grep -oE '"push":(true|false)' | cut -d: -f2; } || true
}

# stdin: a contents API directory listing. Prints "path|blob-sha" for each .sh file,
# newest name first. Names start with a UTC timestamp, so newest means last published.
# Fails if the input is not a JSON array.
parse_script_listing() {
    local json
    json=$(tr -d '\r\n')
    json="${json#"${json%%[![:space:]]*}"}"
    case "$json" in '['*) ;; *) return 1 ;; esac
    printf '%s\n' "$json" | sed 's/},[[:space:]]*{/}\
{/g' | awk '
function value(line, key,    found) {
    if (!match(line, "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\"")) return ""
    found = substr(line, RSTART, RLENGTH)
    sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", found)
    sub(/"$/, "", found)
    return found
}
{
    name = value($0, "name"); path = value($0, "path"); sha = value($0, "sha"); type = value($0, "type")
    if (type == "file" && name ~ /^[A-Za-z0-9._-]+\.sh$/ && path ~ /^[A-Za-z0-9._\/-]+$/ && length(sha) == 40 && sha ~ /^[0-9a-f]+$/)
        print name "|" path "|" sha
}' | LC_ALL=C sort -r | cut -d'|' -f2-
}

# YYYYmmdd_HHMMSS_microseconds in UTC, so names sort in the order things were created.
_utc_stamp() {
    local now
    now=$(date -u +%Y%m%d_%H%M%S_%N 2>/dev/null) || now=''
    if [[ "$now" =~ ^[0-9]{8}_[0-9]{6}_[0-9]{9}$ ]]; then printf '%s' "${now%???}"; return 0; fi
    # BSD date (macOS) has no %N. Perl ships with macOS.
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=gettimeofday -MPOSIX=strftime -e \
            '($s, $u) = gettimeofday; printf "%s_%06d", strftime("%Y%m%d_%H%M%S", gmtime($s)), $u' && return 0
    fi
    date -u +%Y%m%d_%H%M%S_000000
}

normalize_user() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || {
        warn "Invalid GitHub username: $1"; return 1;
    }
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

require_value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $1"
}

# Copy-pasted tokens often carry a trailing newline or space, so strip whitespace.
set_token() {
    GITHUB_TOKEN="${1//[[:space:]]/}"
    [[ "$GITHUB_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die '--token is empty or has unexpected characters. Paste only the token.'
}

# Everything the scripts use besides the HTTP tool. All of it is standard on Linux Mint,
# Ubuntu, and Debian, and on macOS and Git Bash for the developer side.
require_core_tools() {
    local tool missing=''
    for tool in awk base64 cut date grep head mktemp od sed sort tail tr uname wc; do
        command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
    done
    command -v sha1sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || missing="${missing} sha1sum"
    [[ -z "$missing" ]] || die "These standard tools are missing:${missing}. They come with a normal Linux install."
}

require_http_tool() {
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die 'curl or wget is needed to reach GitHub, and this machine has neither. Linux Mint, Ubuntu, and Debian normally include at least one.'
}

validate_repo() {
    [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo must look like owner/repo.'
    [[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != *..* && "$BRANCH" != *//* ]] || die '--branch has unexpected characters.'
}

# The branch as it appears in a URL. Validated branch names only need "/" encoded.
_enc_branch() { printf '%s' "${BRANCH//\//%2F}"; }

# Reads GitHub's rate-limit headers. RATE_LIMIT_WAIT becomes the seconds to wait
# when the request was refused for rate limiting, and 0 otherwise.
note_rate_limit() {
    local file="$1" reset retry now
    RATE_LIMIT_WAIT=0
    GH_RATE_LIMIT=$(_header "$file" x-ratelimit-limit)
    GH_RATE_REMAINING=$(_header "$file" x-ratelimit-remaining)
    GH_TOKEN_SCOPES=$(_header "$file" x-oauth-scopes)
    GH_TOKEN_EXPIRES=$(_header_text "$file" github-authentication-token-expiration)
    [[ "$GH_HTTP_CODE" == 403 || "$GH_HTTP_CODE" == 429 ]] || return 0
    retry=$(_header "$file" retry-after)
    reset=$(_header "$file" x-ratelimit-reset)
    if [[ "$retry" =~ ^[0-9]+$ ]]; then
        RATE_LIMIT_WAIT="$retry"
    elif [[ "$GH_RATE_REMAINING" == 0 && "$reset" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
        if (( reset > now )); then RATE_LIMIT_WAIT=$(( reset - now + 1 )); else RATE_LIMIT_WAIT=1; fi
    fi
    if (( RATE_LIMIT_WAIT > 3700 )); then RATE_LIMIT_WAIT=3700; fi
    return 0
}

# One HTTPS request with curl, or with wget when curl is not installed.
# Sets GH_HTTP_CODE and saves the body even on HTTP errors, and writes the response
# headers to $hdr. A nonzero return means no usable HTTP response arrived.
_http_request() {
    local method="$1" url="$2" out="$3" hdr="$4" payload="$5" media="$6"
    if command -v curl >/dev/null 2>&1; then
        local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: ${media}" -D "$hdr")
        [[ -z "${GITHUB_TOKEN:-}" ]] || args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        [[ -z "$payload" ]] || args+=(-H 'Content-Type: application/json' --data-binary "@${payload}")
        GH_HTTP_CODE=$(curl "${args[@]}" -o "$out" -w '%{http_code}' "$url") || { GH_HTTP_CODE=000; return 1; }
    else
        # wget prints the response headers to stderr with -S. It exits nonzero on HTTP
        # errors, so the status comes from the headers, not the exit code.
        local args=(-q -S -O "$out" --timeout=60 --tries=1 --content-on-error --method="$method" "--header=Accept: ${media}")
        [[ -z "${GITHUB_TOKEN:-}" ]] || args+=("--header=Authorization: Bearer ${GITHUB_TOKEN}")
        [[ -z "$payload" ]] || args+=('--header=Content-Type: application/json' "--body-file=${payload}")
        wget "${args[@]}" "$url" 2> "$hdr" || true
        GH_HTTP_CODE=$(awk '/^[ \t]*HTTP\//{ code = $2 } END { print code }' "$hdr")
        [[ "$GH_HTTP_CODE" =~ ^[0-9]{3}$ ]] || { GH_HTTP_CODE=000; return 1; }
    fi
}

# Calls the GitHub API for the repo. The http backend uses --token. The cli backend
# uses the developer's `gh` login, which keeps its credential inside gh.
gh_request() {
    local method="$1" endpoint="$2" response_file="$3" payload_file="${4:-}"
    local media="${5:-application/vnd.github+json}"
    GH_HTTP_CODE=000
    RATE_LIMIT_WAIT=0
    if [[ "${GH_BACKEND:-http}" == cli ]]; then
        local err_file
        local args=(api --method "$method" "repos/${GITHUB_REPO}${endpoint}" -H "Accept: ${media}")
        [[ -z "$payload_file" ]] || args+=(--input "$payload_file")
        err_file=$(mktemp) || return 1
        if gh "${args[@]}" > "$response_file" 2> "$err_file"; then
            GH_HTTP_CODE=200
        else
            # gh prints an error body to stdout and "gh: <message> (HTTP 409)" to stderr.
            GH_HTTP_CODE=$(grep -oE '\(HTTP [0-9]{3}\)' "$err_file" | tail -n 1 | tr -dc '0-9' || true)
            [[ "$GH_HTTP_CODE" =~ ^[0-9]{3}$ ]] || { GH_HTTP_CODE=000; rm -f "$err_file"; return 1; }
        fi
        rm -f "$err_file"
    else
        local header_file="${response_file}.headers"
        _http_request "$method" "https://api.github.com/repos/${GITHUB_REPO}${endpoint}" \
            "$response_file" "$header_file" "$payload_file" "$media" || { rm -f "$header_file"; return 1; }
        note_rate_limit "$header_file"
        rm -f "$header_file"
    fi
}

# Explains a failed read. Use right after gh_request or gh_download.
gh_read_failed() {
    if (( RATE_LIMIT_WAIT > 0 )); then
        warn "GitHub's rate limit is used up. Requests work again in about ${RATE_LIMIT_WAIT}s."
        [[ -n "$GITHUB_TOKEN" ]] || warn 'Without --token GitHub allows only 60 requests per hour per IP address. A token raises that to 5,000.'
    elif [[ "$GH_HTTP_CODE" == 000 ]]; then
        warn 'Could not reach api.github.com. Check the VM network connection.'
    else
        warn "GitHub returned HTTP ${GH_HTTP_CODE} for $1. Run with --check to test the repo, branch, and token."
    fi
}

# Creates only. Retries keep the same path and bytes, and never add an update SHA.
gh_upload() {
    local repo_path="$1" local_file="$2" commit_msg="$3"
    local upload_dir endpoint expected_sha attempt http_code=000 result=1 message found
    [[ "${GH_BACKEND:-http}" == cli || -n "${GITHUB_TOKEN:-}" ]] || {
        warn 'Uploading needs --token.'; return 1;
    }
    [[ "$repo_path" =~ ^[A-Za-z0-9._/-]+$ ]] || { warn "Unsupported upload path: ${repo_path}"; return 1; }
    [[ -f "$local_file" && -r "$local_file" ]] || { warn "Cannot read ${local_file}"; return 1; }
    upload_dir=$(mktemp -d) || return 1
    endpoint="/contents/${repo_path}"
    # Keep the commit message to characters that need no JSON escaping.
    message=$(printf '%s' "$commit_msg" | sed 's|[^][A-Za-z0-9 _.:/@()-]|_|g')
    if ! {
        printf '{"message":"%s","content":"' "$message"
        base64 < "$local_file" | tr -d '\n'
        printf '","branch":"%s"}' "$BRANCH"
    } > "$upload_dir/payload.json"; then
        rm -rf "$upload_dir"; return 1
    fi
    expected_sha=$(_blob_sha1 "$local_file") || { rm -rf "$upload_dir"; return 1; }

    for attempt in 1 2 3 4 5; do
        if gh_request PUT "$endpoint" "$upload_dir/response.json" "$upload_dir/payload.json"; then
            http_code="$GH_HTTP_CODE"
        else
            http_code=000
        fi
        if [[ "$http_code" == 201 || "$http_code" == 200 ]]; then
            found=$(_json_string "$upload_dir/response.json" path)
            if [[ "$found" == "$repo_path" ]]; then result=0; fi
            break
        fi
        # The server may have committed a create whose response was lost.
        # Matching blob hashes make that success; different bytes are a collision.
        case "$http_code" in
            000|409|422|500|502|503|504)
                if gh_request GET "${endpoint}?ref=$(_enc_branch)" "$upload_dir/existing.json" \
                    && [[ "$GH_HTTP_CODE" == 200 ]]; then
                    if [[ "$(_json_string "$upload_dir/existing.json" sha)" == "$expected_sha" ]]; then
                        result=0
                    else
                        warn "Path already contains different content. Refusing to overwrite ${repo_path}."
                    fi
                    break
                fi
                # A 422 without matching content is a validation error.
                [[ "$http_code" != 422 ]] || break
                ;;
            *) break ;;
        esac
        [[ "$attempt" -lt 5 ]] || break
        warn "Upload interrupted or conflicted (HTTP ${http_code}); retrying ${attempt}/4."
        sleep "$((1 << (attempt - 1))).$((RANDOM % 1000))"
    done
    if [[ "$result" != 0 ]]; then
        warn "Upload failed for ${repo_path} (HTTP ${http_code}). Local file retained: ${local_file}"
        if [[ -s "$upload_dir/response.json" ]]; then
            found=$(_json_string "$upload_dir/response.json" message)
            [[ -z "$found" ]] || warn "GitHub said: ${found}"
        fi
        if (( RATE_LIMIT_WAIT > 0 )); then
            warn "GitHub is rate limiting this account. Try again in about ${RATE_LIMIT_WAIT}s."
        elif [[ "${GH_BACKEND:-http}" == cli ]]; then
            case "$http_code" in
                401|403|404) warn 'Run "gh auth status". The signed-in account needs write access to the repo.' ;;
            esac
        else
            case "$http_code" in
                401) warn 'GitHub rejected --token. Check that it is complete, unexpired, and not revoked.' ;;
                403|404) warn 'This token cannot write to the repo. A classic token needs the public_repo scope; a fine-grained token needs Contents: Read and write on this repo; the account must be a collaborator. Run with --check to test.' ;;
            esac
        fi
    fi
    rm -rf "$upload_dir"
    return "$result"
}

# new_repo_path FOLDER USER LABEL EXT prints a unique path such as
# scripts/sid1332/20261110_173302_123456_check_<32 hex>.sh. Outputs add the host name.
new_repo_path() {
    local folder="$1" user="$2" label host id stamp
    label=$(printf '%s' "$3" | _slug 80)
    [[ -n "$label" ]] || label=note
    if [[ "$folder" == outputs ]]; then
        host=$(uname -n | _slug 40)
        label="${label}_${host:-vm}"
    fi
    id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || id=''
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] || { warn 'Could not read /dev/urandom to make a unique file name.'; return 1; }
    stamp=$(_utc_stamp) || return 1
    printf '%s/%s/%s_%s_%s.%s' "$folder" "$user" "$stamp" "$label" "$id" "$4"
}

# Sets LISTING to "path|blob-sha" lines, newest first. A missing scripts/NAME/
# folder means nothing has been published yet, so it is an empty listing, not an error.
gh_list_files() {
    local response_file
    LISTING=''
    response_file=$(mktemp) || return 1
    if ! gh_request GET "/contents/scripts/${1}?ref=$(_enc_branch)" "$response_file"; then
        rm -f "$response_file"; gh_read_failed "scripts/${1}"; return 1
    fi
    case "$GH_HTTP_CODE" in
        200) ;;
        404) rm -f "$response_file"; return 0 ;;
        *) rm -f "$response_file"; gh_read_failed "scripts/${1}"; return 1 ;;
    esac
    LISTING=$(parse_script_listing < "$response_file") || {
        rm -f "$response_file"; warn 'GitHub did not return a directory listing.'; return 1;
    }
    rm -f "$response_file"
}

gh_download() {
    [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    gh_request GET "/contents/${1}?ref=$(_enc_branch)" "$2" '' 'application/vnd.github.raw+json' \
        && [[ "$GH_HTTP_CODE" == 200 ]]
}

run_script() {
    local script_path="$1" script_name="$2" run_dir="$3"
    local -a pipeline_status
    RUN_OUTPUT_FILE="${run_dir}/output.txt"
    {
        printf 'script:    %s\n' "$script_name"
        printf 'timestamp: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'host:      %s\n' "$(uname -n)"
        printf 'user:      %s\n' "$(id -un)"
        printf '%s\n\n' '---'
    } > "$RUN_OUTPUT_FILE" || return 1
    log "Running ${script_name}"
    if env -u GITHUB_TOKEN -u GH_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
        bash "$script_path" 2>&1 | tee -a "$RUN_OUTPUT_FILE"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    RUN_EXIT_CODE="${pipeline_status[0]}"
    [[ "${pipeline_status[1]}" == 0 ]] || { warn 'Could not save script output.'; return 1; }
    printf '\n---\nexit code: %s\n' "$RUN_EXIT_CODE" | tee -a "$RUN_OUTPUT_FILE" || return 1
    log "Output saved locally: ${RUN_OUTPUT_FILE}"
}

_last_seen() { if [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"; fi; }
_mark_seen() {
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || return 1
    printf '%s\n' "$1" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

_flush_pending() {
    [[ -f "${STATE_FILE}.pending" ]] || return 0
    local output_file repo_path
    { IFS= read -r output_file; IFS= read -r repo_path; } < "${STATE_FILE}.pending" || return 1
    gh_upload "$repo_path" "$output_file" "output: ${repo_path##*/} [${TARGET_USER}]" || return 1
    rm -f "${STATE_FILE}.pending"
    ok "Output at: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${repo_path}"
}

run_once() {
    local script_path="$MANUAL_FILE" script_name run_dir listing latest identity='' repo_path=''
    if [[ "$LOOP_MODE" == true ]]; then _flush_pending || return 1; fi
    if [[ -z "$MANUAL_FILE" ]]; then
        gh_list_files "$TARGET_USER" || return 1
        listing="$LISTING"
        if [[ -z "$listing" ]]; then log "No scripts found for ${TARGET_USER} yet."; return 0; fi
        latest="${listing%%$'\n'*}"
        repo_path="${latest%|*}"
        identity="$latest"
        if [[ "$LOOP_MODE" == true && "$(_last_seen)" == "$identity" ]]; then
            log "No new scripts from ${TARGET_USER}."; return 0
        fi
    fi
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cpats_run_XXXXXXXX") || return 1
    if [[ -n "$MANUAL_FILE" ]]; then
        script_name="$(basename "$MANUAL_FILE")"
    else
        script_name="${repo_path##*/}"
        script_path="${run_dir}/${script_name}"
        log "Downloading ${repo_path}"
        gh_download "$repo_path" "$script_path" || { gh_read_failed "$repo_path"; return 1; }
        # Execute only the bytes that match the version found in the listing.
        [[ "$(_blob_sha1 "$script_path")" == "${latest##*|}" ]] || { warn 'Script changed during download. Try again.'; return 1; }
    fi
    run_script "$script_path" "$script_name" "$run_dir" || return 1
    if [[ -z "$MANUAL_FILE" ]]; then
        _mark_seen "$identity" || return 1
        rm -f "$script_path"
    fi
    if [[ "$UPLOAD_OUTPUT" == true ]]; then
        local output_path
        output_path=$(new_repo_path outputs "$TARGET_USER" "${script_name%.*}" txt) || return 1
        if [[ "$LOOP_MODE" == true ]]; then
            local pending
            pending=$(mktemp "${STATE_FILE}.pending.XXXXXX") || return 1
            printf '%s\n%s\n' "$RUN_OUTPUT_FILE" "$output_path" > "$pending" \
                && mv "$pending" "${STATE_FILE}.pending" || return 1
            _flush_pending || return 1
        else
            gh_upload "$output_path" "$RUN_OUTPUT_FILE" "output: ${script_name} [${TARGET_USER}]" || return 1
            ok "Output at: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${output_path}"
        fi
    fi
    return "$RUN_EXIT_CODE"
}

# Tests the repo, branch, and token with two cheap requests, then explains what works.
check_setup() {
    local response write scopes expires problems=0
    response=$(mktemp) || return 1
    log "Checking ${GITHUB_REPO} on branch ${BRANCH}"
    if ! gh_request GET '' "$response"; then
        rm -f "$response"; warn 'Could not reach api.github.com. Check the VM network connection.'; return 1
    fi
    case "$GH_HTTP_CODE" in
        200) ok "Repo ${GITHUB_REPO} is reachable." ;;
        401) rm -f "$response"; warn 'GitHub rejected --token. Check that it is complete, unexpired, and not revoked.'; return 1 ;;
        404) rm -f "$response"; warn "Repo ${GITHUB_REPO} was not found. Check --repo. A private repo also needs --token."; return 1 ;;
        *) rm -f "$response"; gh_read_failed "${GITHUB_REPO}"; return 1 ;;
    esac
    write=$(_json_push_permission "$response")
    scopes="$GH_TOKEN_SCOPES"
    expires="$GH_TOKEN_EXPIRES"
    if gh_request GET "/branches/$(_enc_branch)" "$response" && [[ "$GH_HTTP_CODE" == 200 ]]; then
        ok "Branch ${BRANCH} exists."
    else
        warn "Branch ${BRANCH} was not found. Check --branch."; problems=1
    fi
    rm -f "$response"
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log 'No --token: downloading and running scripts works. Uploading output or pastes needs a token.'
    elif [[ "$write" == false ]]; then
        warn 'The token is valid, but its account cannot push to this repo. Ask the owner to add it as a collaborator.'; problems=1
    elif [[ -n "$scopes" && ",${scopes}," != *,repo,* && ",${scopes}," != *,public_repo,* ]]; then
        warn "The classic token's scopes (${scopes}) do not include public_repo, so uploads will fail."; problems=1
    elif [[ -n "$scopes" ]]; then
        ok "Token accepted. Its account can push, and its scopes are: ${scopes}."
    else
        ok 'Token accepted, and its account can push. Fine-grained tokens also need Contents: Read and write on this repo.'
    fi
    if [[ -n "$GITHUB_TOKEN" && -n "$expires" ]]; then
        log "This token expires: ${expires}. A token that lasts about a day is safest."
    elif [[ -n "$GITHUB_TOKEN" ]]; then
        log 'GitHub reports no expiration date for this token. Prefer one that expires within a day.'
    fi
    [[ -z "$GH_RATE_REMAINING" ]] || log "GitHub requests left this hour: ${GH_RATE_REMAINING} of ${GH_RATE_LIMIT}."
    return "$problems"
}

runner_usage() {
    cat <<EOF
Usage: bash runner.sh --user NAME [options]

Runs the newest script from scripts/NAME/ in the relay repo and can upload the
output. Every setting is a flag; no config file or environment variable is read.
Needs only bash and curl or wget. Nothing is installed, and no Python is used.

What to do (pick one):
  --user NAME         Run the newest script published for NAME
  --file PATH         Run a local script instead of downloading one
  --list              With --user: list NAME's scripts without running them
  --check             Test the repo, branch, and token, then exit

Options:
  --upload-output     Upload the script's output to outputs/NAME/ (needs --token)
  --loop              Keep running; run each newly published script once
  --interval SECONDS  Seconds between checks with --loop
                      (default ${LOOP_INTERVAL_TOKEN} with --token, ${LOOP_INTERVAL_ANON} without)
  --token TOKEN       GitHub token. Needed only to upload; also raises the API
                      rate limit from 60 to 5,000 requests per hour.
  --repo OWNER/REPO   Default: ${DEFAULT_REPO}
  --branch NAME       Default: ${DEFAULT_BRANCH}
  --state-dir PATH    Where --loop remembers what it ran
                      (default ~/.local/state/cpats-pastebin)
  -h, --help          Show this help

Examples:
  bash runner.sh --check --token "\$T"
  bash runner.sh --user sid1332
  bash runner.sh --user sid1332 --token "\$T" --upload-output --loop
  bash runner.sh --file ./fix.sh
EOF
}

runner_main() {
    local interval='' state_dir="${HOME}/.local/state/cpats-pastebin" check_mode=false
    TARGET_USER='' MANUAL_FILE='' UPLOAD_OUTPUT=false LOOP_MODE=false LIST_MODE=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) require_value "$@"; TARGET_USER="$2"; shift 2 ;;
            --file) require_value "$@"; MANUAL_FILE="$2"; shift 2 ;;
            --token) require_value "$@"; set_token "$2"; shift 2 ;;
            --repo) require_value "$@"; GITHUB_REPO="$2"; shift 2 ;;
            --branch) require_value "$@"; BRANCH="$2"; shift 2 ;;
            --interval) require_value "$@"; interval="$2"; shift 2 ;;
            --state-dir) require_value "$@"; state_dir="$2"; shift 2 ;;
            --upload-output) UPLOAD_OUTPUT=true; shift ;;
            --loop) LOOP_MODE=true; shift ;;
            --list) LIST_MODE=true; shift ;;
            --check) check_mode=true; shift ;;
            -h|--help) runner_usage; return 0 ;;
            *) die "Unknown argument: $1. Run with --help for the options." ;;
        esac
    done
    require_core_tools
    validate_repo
    if [[ "$check_mode" == true ]]; then require_http_tool; check_setup; return; fi
    if [[ -n "$TARGET_USER" ]]; then TARGET_USER=$(normalize_user "$TARGET_USER") || return 1; fi
    [[ -n "$MANUAL_FILE" || -n "$TARGET_USER" ]] || die 'Specify --user NAME (or --file PATH). Run with --help for examples.'
    if [[ -n "$MANUAL_FILE" ]]; then
        [[ "$LIST_MODE" == false && "$LOOP_MODE" == false ]] || die '--file cannot be combined with --list or --loop.'
        [[ -z "$TARGET_USER" || "$UPLOAD_OUTPUT" == true ]] || die 'With --file, --user only picks the outputs/ folder. Add --upload-output or drop --user.'
        [[ -f "$MANUAL_FILE" ]] || die "File not found: ${MANUAL_FILE}"
    fi
    if [[ "$UPLOAD_OUTPUT" == true ]]; then
        [[ -n "$GITHUB_TOKEN" ]] || die '--upload-output needs --token. Without one the output stays on the VM.'
        [[ -n "$TARGET_USER" ]] || die '--upload-output needs --user NAME to choose the outputs/ folder.'
    fi
    # A local script that is not uploaded never touches the network.
    if [[ -z "$MANUAL_FILE" || "$UPLOAD_OUTPUT" == true ]]; then require_http_tool; fi
    if [[ -n "$interval" ]]; then
        [[ "$LOOP_MODE" == true ]] || die '--interval only applies with --loop.'
        [[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 5 && "$interval" -le 86400 ]] || die '--interval must be a whole number of seconds from 5 to 86400.'
    elif [[ -n "$GITHUB_TOKEN" ]]; then
        interval="$LOOP_INTERVAL_TOKEN"
    else
        interval="$LOOP_INTERVAL_ANON"
    fi
    if [[ "$LIST_MODE" == true ]]; then
        local entry
        [[ -n "$TARGET_USER" ]] || die '--list needs --user NAME.'
        gh_list_files "$TARGET_USER" || return 1
        if [[ -z "$LISTING" ]]; then log "No scripts found for ${TARGET_USER}."; return 0; fi
        while IFS= read -r entry; do printf '%s\n' "${entry%|*}"; done <<< "$LISTING"
        return 0
    fi
    if [[ -z "$MANUAL_FILE" ]]; then
        local state_key
        mkdir -p "$state_dir" || return 1
        state_key=$(printf '%s\n%s\n%s\n' "$GITHUB_REPO" "$BRANCH" "$TARGET_USER" | _sha1) || return 1
        STATE_FILE="${state_dir}/${state_key}"
    fi
    if [[ "$LOOP_MODE" == true ]]; then
        local pause
        log "Watching ${GITHUB_REPO} scripts/${TARGET_USER}/ every ${interval}s. Ctrl+C stops the runner."
        if [[ -z "$GITHUB_TOKEN" ]]; then
            log 'No --token, so GitHub allows 60 requests per hour per IP address. A token raises that to 5,000.'
            if (( interval < 90 )); then warn "Checking every ${interval}s without a token will probably hit that limit."; fi
        fi
        while true; do
            RATE_LIMIT_WAIT=0
            run_once || warn 'The run or an upload failed. Check the output above.'
            pause="$interval"
            if (( RATE_LIMIT_WAIT > pause )); then
                pause="$RATE_LIMIT_WAIT"
                warn "Pausing ${pause}s until GitHub's rate limit resets."
            fi
            sleep "$pause"
        done
    else
        run_once
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then runner_main "$@"; fi
