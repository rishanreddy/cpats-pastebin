#!/usr/bin/env bash
# Run on the VM with Bash, curl, and Python 3. No Git or packages required.
# The publisher and clipboard tool also source the API helpers in this file.
set -euo pipefail

log()  { printf '[cpats] %s\n' "$*"; }
ok()   { printf '[  ok ] %s\n' "$*"; }
warn() { printf '[ warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }
_py() { local code="$1"; shift; python3 -c "$code" "$@"; }
_urlencode() { _py 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

load_config() {
    local config_dir
    config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=/dev/null
    if [[ -f "${config_dir}/.cpats.env" ]]; then source "${config_dir}/.cpats.env"; fi
    GITHUB_REPO="${GITHUB_REPO:-}"
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    CPATS_USERNAME="${CPATS_USERNAME:-}"
    BRANCH="${BRANCH:-main}"
    GH_BACKEND=curl
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

require_tools() {
    command -v python3 >/dev/null || die 'Python 3 is required. Use a VM with python3 already available.'
    command -v curl >/dev/null || die 'curl is required.'
}

validate_repo() {
    [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Set GITHUB_REPO to owner/repo.'
    [[ -n "$BRANCH" ]] || die 'Branch cannot be empty.'
}

# Sets GH_HTTP_CODE and saves the body even on HTTP errors. A nonzero return
# means no usable HTTP response arrived. The CLI backend keeps auth inside gh.
gh_request() {
    local method="$1" endpoint="$2" response_file="$3" payload_file="${4:-}"
    local media="${5:-application/vnd.github+json}"
    GH_HTTP_CODE=000
    if [[ "${GH_BACKEND:-curl}" == cli ]]; then
        local wire_file
        wire_file=$(mktemp) || return 1
        local args=(api --include --method "$method" "repos/${GITHUB_REPO}${endpoint}" -H "Accept: ${media}")
        [[ -z "$payload_file" ]] || args+=(--input "$payload_file")
        gh "${args[@]}" > "$wire_file" 2>/dev/null || true
        if ! GH_HTTP_CODE=$(_py '
import pathlib, re, sys
wire = pathlib.Path(sys.argv[1]).read_bytes()
parts = re.split(rb"\r?\n\r?\n", wire, maxsplit=1)
if len(parts) != 2 or not parts[0].startswith(b"HTTP/"):
    sys.exit(1)
pathlib.Path(sys.argv[2]).write_bytes(parts[1])
print(parts[0].splitlines()[0].split()[1].decode())
' "$wire_file" "$response_file"); then
            rm -f "$wire_file"; GH_HTTP_CODE=000; return 1
        fi
        rm -f "$wire_file"
    else
        local args=(-sS --connect-timeout 10 --max-time 60 -X "$method" -H "Accept: ${media}")
        [[ -z "${GITHUB_TOKEN:-}" ]] || args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        [[ -z "$payload_file" ]] || args+=(-H 'Content-Type: application/json' --data-binary "@${payload_file}")
        GH_HTTP_CODE=$(curl "${args[@]}" -o "$response_file" -w '%{http_code}' \
            "https://api.github.com/repos/${GITHUB_REPO}${endpoint}") || return 1
    fi
}

gh_get() {
    local response_file result=1
    response_file=$(mktemp) || return 1
    if gh_request GET "$1" "$response_file" && [[ "$GH_HTTP_CODE" == 200 ]]; then
        cat "$response_file"
        result=0
    else
        warn "GitHub read failed for $1 (HTTP ${GH_HTTP_CODE}). Check the repo, branch, and access."
    fi
    rm -f "$response_file"
    return "$result"
}

# Creates only. Retries keep the same path and bytes, and never add an update SHA.
gh_upload() {
    local repo_path="$1" local_file="$2" commit_msg="$3"
    local upload_dir endpoint expected_sha attempt http_code=000 result=1
    [[ "${GH_BACKEND:-curl}" == cli || -n "${GITHUB_TOKEN:-}" ]] || {
        warn 'Upload requires GITHUB_TOKEN.'; return 1;
    }
    upload_dir=$(mktemp -d) || return 1
    endpoint="/contents/$(_py 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$repo_path")"
    if ! _py '
import base64, json, pathlib, sys
content = pathlib.Path(sys.argv[1]).read_bytes()
print(json.dumps({"message": sys.argv[2], "content": base64.b64encode(content).decode(), "branch": sys.argv[3]}))
' "$local_file" "$commit_msg" "$BRANCH" > "$upload_dir/payload.json"; then
        rm -rf "$upload_dir"; return 1
    fi
    expected_sha=$(_py '
import base64, hashlib, json, sys
data = base64.b64decode(json.load(open(sys.argv[1]))["content"])
print(hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest())
' "$upload_dir/payload.json") || { rm -rf "$upload_dir"; return 1; }

    for attempt in 1 2 3 4 5; do
        if gh_request PUT "$endpoint" "$upload_dir/response.json" "$upload_dir/payload.json"; then
            http_code="$GH_HTTP_CODE"
        else
            http_code=000
        fi
        if [[ "$http_code" == 201 || "$http_code" == 200 ]]; then
            if _py 'import json, sys; sys.exit(json.load(open(sys.argv[1])).get("content", {}).get("path") != sys.argv[2])' \
                "$upload_dir/response.json" "$repo_path"; then result=0; fi
            break
        fi
        # The server may have committed a create whose response was lost.
        # Matching blob hashes make that success; different bytes are a collision.
        case "$http_code" in
            000|409|422|500|502|503|504)
                if gh_request GET "${endpoint}?ref=$(_urlencode "$BRANCH")" "$upload_dir/existing.json" \
                    && [[ "$GH_HTTP_CODE" == 200 ]]; then
                    if _py 'import json, sys; sys.exit(json.load(open(sys.argv[1])).get("sha") != sys.argv[2])' \
                        "$upload_dir/existing.json" "$expected_sha"; then
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
            _py 'import json, sys; print(json.load(open(sys.argv[1])).get("message", "Unexpected GitHub response"), file=sys.stderr)' \
                "$upload_dir/response.json" || true
        fi
    fi
    rm -rf "$upload_dir"
    return "$result"
}

new_repo_path() {
    _py '
from datetime import datetime, timezone
import re, socket, sys, uuid
folder, user, label, ext = sys.argv[1:]
label = re.sub(r"[^a-z0-9_-]+", "-", label.lower()).strip("-_")[:80] or "note"
if folder == "outputs":
    host = re.sub(r"[^a-z0-9_-]+", "-", socket.gethostname().lower())[:40] or "vm"
    label += "_" + host
stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
print(f"{folder}/{user}/{stamp}_{label}_{uuid.uuid4().hex}.{ext}")
' "$@"
}

gh_list_files() {
    local raw
    raw=$(gh_get "/contents/scripts/${1}?ref=$(_urlencode "$BRANCH")") || return 1
    printf '%s' "$raw" | _py '
import json, sys
items = json.load(sys.stdin)
if not isinstance(items, list):
    sys.exit("Expected a directory listing from GitHub")
files = [i for i in items if i.get("type") == "file" and i["name"].endswith((".sh", ".bash", ".py"))]
for item in sorted(files, key=lambda i: i["name"], reverse=True):
    if any(c in item["path"] for c in "\n\r|"):
        sys.exit("Unsupported script filename")
    print(item["path"] + "|" + item["sha"])
'
}

gh_download() {
    local endpoint
    endpoint=$(_py 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$1") || return 1
    gh_request GET "/contents/${endpoint}?ref=$(_urlencode "$BRANCH")" "$2" '' 'application/vnd.github.raw+json' \
        && [[ "$GH_HTTP_CODE" == 200 ]]
}

run_script() {
    local script_path="$1" script_name="$2" run_dir="$3" interpreter=bash
    local -a pipeline_status
    [[ "${script_name##*.}" != py ]] || interpreter=python3
    RUN_OUTPUT_FILE="${run_dir}/output.txt"
    {
        printf 'script:    %s\n' "$script_name"
        printf 'timestamp: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'host:      %s\n' "$(hostname)"
        printf 'user:      %s\n' "$(whoami)"
        printf '%s\n\n' '---'
    } > "$RUN_OUTPUT_FILE" || return 1
    log "Running ${script_name}"
    if env -u GITHUB_TOKEN -u GH_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
        "$interpreter" "$script_path" 2>&1 | tee -a "$RUN_OUTPUT_FILE"; then
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
        listing=$(gh_list_files "$TARGET_USER") || return 1
        if [[ -z "$listing" ]]; then log "No scripts found for ${TARGET_USER}."; return 0; fi
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
        gh_download "$repo_path" "$script_path" || { warn 'Download failed.'; return 1; }
        # Execute only the bytes that match the version found in the listing.
        _py '
import hashlib, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
sys.exit(actual != sys.argv[2])
' "$script_path" "${latest##*|}" || { warn 'Script changed during download. Try again.'; return 1; }
    fi
    run_script "$script_path" "$script_name" "$run_dir" || return 1
    if [[ -z "$MANUAL_FILE" ]]; then
        _mark_seen "$identity" || return 1
        rm -f "$script_path"
    fi
    if [[ "$UPLOAD_OUTPUT" == true ]]; then
        local output_path
        output_path=$(new_repo_path outputs "${TARGET_USER:-${CPATS_USERNAME:-manual}}" "${script_name%.*}" txt) || return 1
        if [[ "$LOOP_MODE" == true ]]; then
            local pending
            pending=$(mktemp "${STATE_FILE}.pending.XXXXXX") || return 1
            printf '%s\n%s\n' "$RUN_OUTPUT_FILE" "$output_path" > "$pending" \
                && mv "$pending" "${STATE_FILE}.pending" || return 1
            _flush_pending || return 1
        else
            gh_upload "$output_path" "$RUN_OUTPUT_FILE" "output: ${script_name}" || return 1
            ok "Output at: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${output_path}"
        fi
    fi
    return "$RUN_EXIT_CODE"
}

runner_usage() {
    cat <<'EOF'
Usage: ./runner.sh [options]
  --user NAME        Pull the latest script from this teammate's folder
  --upload-output    Upload stdout, stderr, and exit status to GitHub
  --loop             Check for the latest script every 30 seconds
  --list             List scripts for --user without running them
  --file PATH        Run a local script instead of downloading one
  --repo OWNER/REPO  Override GITHUB_REPO from .cpats.env
  --branch NAME      Override BRANCH from .cpats.env
  -h, --help         Show help
EOF
}

runner_main() {
    load_config
    TARGET_USER='' MANUAL_FILE='' UPLOAD_OUTPUT=false LOOP_MODE=false LIST_MODE=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) require_value "$@"; TARGET_USER="$2"; shift 2 ;;
            --file) require_value "$@"; MANUAL_FILE="$2"; shift 2 ;;
            --repo) require_value "$@"; GITHUB_REPO="$2"; shift 2 ;;
            --branch) require_value "$@"; BRANCH="$2"; shift 2 ;;
            --upload-output) UPLOAD_OUTPUT=true; shift ;;
            --loop) LOOP_MODE=true; shift ;;
            --list) LIST_MODE=true; shift ;;
            -h|--help) runner_usage; return 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
    require_tools
    if [[ -n "$TARGET_USER" ]]; then TARGET_USER=$(normalize_user "$TARGET_USER") || return 1; fi
    if [[ -n "$CPATS_USERNAME" ]]; then CPATS_USERNAME=$(normalize_user "$CPATS_USERNAME") || return 1; fi
    [[ -n "$MANUAL_FILE" || -n "$TARGET_USER" ]] || die 'Specify --user NAME or --file PATH.'
    if [[ -n "$MANUAL_FILE" ]]; then
        [[ -z "$TARGET_USER" && "$LIST_MODE" == false && "$LOOP_MODE" == false ]] || die '--file cannot be combined with --user, --list, or --loop.'
        [[ -f "$MANUAL_FILE" ]] || die "File not found: ${MANUAL_FILE}"
    fi
    if [[ -z "$MANUAL_FILE" || "$UPLOAD_OUTPUT" == true ]]; then validate_repo; fi
    [[ "$UPLOAD_OUTPUT" == false || -n "$GITHUB_TOKEN" ]] || die '--upload-output requires GITHUB_TOKEN.'
    if [[ "$LIST_MODE" == true ]]; then
        local listing entry
        listing=$(gh_list_files "$TARGET_USER") || return 1
        if [[ -z "$listing" ]]; then log "No scripts found for ${TARGET_USER}."; return 0; fi
        while IFS= read -r entry; do printf '%s\n' "${entry%|*}"; done <<< "$listing"
        return 0
    fi
    if [[ -z "$MANUAL_FILE" ]]; then
        local state_dir state_key
        state_dir="${CPATS_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/cpats-pastebin}"
        mkdir -p "$state_dir" || return 1
        state_key=$(_py 'import hashlib, json, sys; print(hashlib.sha256(json.dumps(sys.argv[1:]).encode()).hexdigest())' \
            "$GITHUB_REPO" "$BRANCH" "$TARGET_USER") || return 1
        STATE_FILE="${state_dir}/${state_key}"
    fi
    if [[ "$LOOP_MODE" == true ]]; then
        log "Watching ${GITHUB_REPO}/${TARGET_USER} every 30 seconds. Ctrl+C stops the runner."
        while true; do
            run_once || warn 'Script or upload failed. Check the output above; checking again in 30 seconds.'
            sleep 30
        done
    else
        run_once
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then runner_main "$@"; fi
