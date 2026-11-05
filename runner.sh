#!/usr/bin/env bash
# runner.sh — cpats-pastebin VM runner
#
# Pulls the latest script pushed by a teammate, runs it, and optionally
# uploads the output back to GitHub. No installs needed beyond curl + bash.
#
# Usage:
#   ./runner.sh --user <github-username> [--upload-output] [--loop]
#   ./runner.sh --file <local-script>
#   ./runner.sh --list --user <github-username>
#
# Config (.cpats.env in same directory):
#   GITHUB_REPO="rishanreddy/cpats-pastebin"
#   GITHUB_TOKEN="ghp_..."   # required for private repos; also needed for --upload-output
#   CPATS_USERNAME="yourname"

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

log()     { printf "${CYAN}[cpats]${NC} %s\n" "$*"; }
ok()      { printf "${GREEN}[  ok ]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[ warn]${NC} %s\n" "$*" >&2; }
die()     { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/.cpats.env" ]] && source "${SCRIPT_DIR}/.cpats.env"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CPATS_USERNAME="${CPATS_USERNAME:-}"
BRANCH="${BRANCH:-main}"

# ── Args ──────────────────────────────────────────────────────────────────────

TARGET_USER=""
UPLOAD_OUTPUT=false
LOOP_MODE=false
MANUAL_FILE=""
LIST_MODE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --user <name>       Pull and run the latest script from this teammate
  --upload-output     Upload the run output back to GitHub
  --loop              Re-check every 30s for new scripts (runs until Ctrl+C)
  --list              List available scripts for --user instead of running
  --file <path>       Run a local file directly (skips GitHub pull)
  --repo <owner/name> Override GITHUB_REPO from config
  --branch <name>     Branch to use (default: main)
  -h, --help          Show this help

Examples:
  ./runner.sh --user alice --upload-output
  ./runner.sh --user alice --loop --upload-output
  ./runner.sh --list --user alice
  ./runner.sh --file /tmp/my_fix.sh
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          TARGET_USER="$2";    shift 2 ;;
        --upload-output) UPLOAD_OUTPUT=true;  shift   ;;
        --loop)          LOOP_MODE=true;      shift   ;;
        --file)          MANUAL_FILE="$2";    shift 2 ;;
        --list)          LIST_MODE=true;      shift   ;;
        --repo)          GITHUB_REPO="$2";    shift 2 ;;
        --branch)        BRANCH="$2";         shift 2 ;;
        -h|--help)       usage ;;
        *) die "Unknown argument: $1. Run with --help for usage." ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────

[[ -z "$GITHUB_REPO" ]] && die "GITHUB_REPO not set. Add it to .cpats.env — see .cpats.env.example"
[[ -z "$MANUAL_FILE" && -z "$TARGET_USER" ]] && die "Specify --user <name> or --file <path>. Run with --help for usage."

if [[ "$UPLOAD_OUTPUT" == true && -z "$GITHUB_TOKEN" ]]; then
    warn "--upload-output requires GITHUB_TOKEN in .cpats.env. Disabling output upload."
    UPLOAD_OUTPUT=false
fi

# ── GitHub API ────────────────────────────────────────────────────────────────

GH_API="https://api.github.com/repos/${GITHUB_REPO}"

# Build curl auth args. Token is required for private repos (reads AND writes).
# For public repos, reads work without a token.
_curl_args() {
    local args=(-fsSL -H "Accept: application/vnd.github.v3+json")
    [[ -n "$GITHUB_TOKEN" ]] && args+=(-H "Authorization: token ${GITHUB_TOKEN}")
    printf '%s\0' "${args[@]}"
}

gh_get() {
    # gh_get <api-path> → stdout (JSON)
    local path="$1"
    local args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done < <(_curl_args)
    curl "${args[@]}" "${GH_API}${path}"
}

gh_put() {
    # gh_put <api-path> <json-payload> → stdout (JSON)
    local path="$1" payload="$2"
    local args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done < <(_curl_args)
    [[ -n "$GITHUB_TOKEN" ]] || die "gh_put requires GITHUB_TOKEN"
    curl "${args[@]}" -X PUT -H "Content-Type: application/json" -d "$payload" "${GH_API}${path}"
}

# Parse a JSON string safely using Python (always available on Ubuntu/Mint/Debian)
_py() { python3 -c "$1"; }

# List files in a directory, return newline-separated "path|sha" pairs
gh_list_files() {
    local dir_path="$1"
    local raw
    raw=$(gh_get "/contents/${dir_path}?ref=${BRANCH}") || return 1
    _py "
import sys, json
items = json.loads('''${raw//\'/\'\\\'\'}''')
if not isinstance(items, list): sys.exit(0)
for i in items:
    if i.get('type') == 'file':
        print(i['path'] + '|' + i['sha'])
" 2>/dev/null
}

# Download a file from GitHub to a local path
gh_download() {
    local repo_path="$1" dest="$2"
    # Use raw URL — avoids base64 decoding, works for text scripts
    local raw_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${BRANCH}/${repo_path}"
    local args=(-fsSL)
    [[ -n "$GITHUB_TOKEN" ]] && args+=(-H "Authorization: token ${GITHUB_TOKEN}")
    curl "${args[@]}" "$raw_url" -o "$dest"
}

# Upload a file to GitHub. Handles create and update (fetches SHA if needed).
gh_upload() {
    local repo_path="$1" local_file="$2" commit_msg="$3"
    [[ -n "$GITHUB_TOKEN" ]] || die "gh_upload requires GITHUB_TOKEN"

    # Base64-encode file content (Python handles this correctly cross-platform)
    local content_b64
    content_b64=$(_py "import base64, sys; sys.stdout.write(base64.b64encode(open('${local_file}','rb').read()).decode())")

    # Check if the file already exists (get its SHA for update)
    local existing_sha=""
    local existing
    existing=$(gh_get "/contents/${repo_path}?ref=${BRANCH}" 2>/dev/null) || true
    if echo "$existing" | grep -q '"sha"'; then
        existing_sha=$(_py "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('sha',''))" <<< "$existing")
    fi

    # Build JSON payload safely via Python
    local payload
    payload=$(_py "
import json, sys
d = {
    'message': sys.argv[1],
    'content': sys.argv[2],
    'branch':  sys.argv[3],
}
if sys.argv[4]: d['sha'] = sys.argv[4]
print(json.dumps(d))
" "$commit_msg" "$content_b64" "$BRANCH" "$existing_sha")

    gh_put "/contents/${repo_path}" "$payload" > /dev/null
}

# ── Script discovery ──────────────────────────────────────────────────────────

# Returns the repo path of the most recently uploaded script for a user.
# Scripts are named YYYYMMDD_HHMMSS_description.ext so lexicographic sort = time sort.
get_latest_script() {
    local username="$1"
    local listing
    listing=$(gh_list_files "scripts/${username}") || \
        die "Could not read scripts/${username}/ — check repo name and token."

    local latest
    latest=$(echo "$listing" \
        | grep -E '\.(sh|py|bash)\|' \
        | sort -t'/' -k3 -r \
        | head -1 \
        | cut -d'|' -f1)

    [[ -z "$latest" ]] && die "No scripts found in scripts/${username}/"
    echo "$latest"
}

list_scripts() {
    local username="$1"
    local listing
    listing=$(gh_list_files "scripts/${username}") || {
        warn "No scripts found for user '${username}'"
        return
    }
    printf "\nScripts from ${BOLD}%s${NC}:\n" "$username"
    echo "$listing" \
        | grep -E '\.(sh|py|bash)\|' \
        | sort -t'/' -k3 -r \
        | cut -d'|' -f1 \
        | while IFS= read -r p; do
            printf "  ${GREEN}→${NC} %s\n" "$(basename "$p")"
        done
    echo
}

# ── Script execution ──────────────────────────────────────────────────────────

run_script() {
    local script_path="$1" script_name="$2"
    local ext="${script_name##*.}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local output_file="/tmp/cpats_output_${ts}.txt"
    local exit_code_file="/tmp/cpats_exit_${ts}.txt"

    printf "\n${BOLD}── Running: %s ──${NC}\n\n" "$script_name"
    chmod +x "$script_path"

    # Header written to output file
    {
        printf "script:    %s\n" "$script_name"
        printf "timestamp: %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf "host:      %s\n" "$(hostname)"
        printf "user:      %s\n" "$(whoami)"
        printf "%s\n\n" "---"
    } > "$output_file"

    # Run the script. We write exit code to a temp file instead of capturing
    # it through a pipe (pipes always return 0 for the outer command).
    {
        set +e
        case "$ext" in
            py)
                if   command -v uv      &>/dev/null; then env -u GITHUB_TOKEN -u GH_TOKEN uv run "$script_path"
                elif command -v python3 &>/dev/null; then env -u GITHUB_TOKEN -u GH_TOKEN python3 "$script_path"
                else die "No Python runtime found (expected uv or python3)"
                fi
                ;;
            *)
                env -u GITHUB_TOKEN -u GH_TOKEN bash "$script_path"
                ;;
        esac
        status=$?
        echo "$status" > "$exit_code_file"
        exit "$status"
    } 2>&1 | tee -a "$output_file"

    # Read the actual exit code
    local exit_code=0
    [[ -f "$exit_code_file" ]] && exit_code=$(cat "$exit_code_file")
    printf "\n---\nexit code: %s\n" "$exit_code" >> "$output_file"
    rm -f "$exit_code_file"

    printf "\n"
    if [[ "$exit_code" -eq 0 ]]; then
        ok "Finished (exit 0)"
    else
        warn "Finished with exit code ${exit_code}"
    fi

    # Return output path via stdout — caller captures it
    echo "$output_file"
}

upload_output() {
    local output_file="$1" username="$2" script_name="$3"
    local base="${script_name%.*}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local repo_path="outputs/${username}/${base}_${ts}.txt"

    log "Uploading output → ${repo_path}"
    gh_upload "$repo_path" "$output_file" "output: ${script_name} [${username}]"
    ok "Output at: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${repo_path}"
}

# ── Loop state tracking ───────────────────────────────────────────────────────

STATE_FILE="/tmp/.cpats_last_${TARGET_USER:-manual}"
_last_seen() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""; }
_mark_seen() { echo "$1" > "$STATE_FILE"; }

# ── Main ──────────────────────────────────────────────────────────────────────

run_once() {
    local script_path="" script_name="" run_user="${TARGET_USER:-${CPATS_USERNAME:-manual}}"

    if [[ -n "$MANUAL_FILE" ]]; then
        [[ -f "$MANUAL_FILE" ]] || die "File not found: ${MANUAL_FILE}"
        script_path="$MANUAL_FILE"
        script_name="$(basename "$MANUAL_FILE")"
    else
        local repo_path
        repo_path=$(get_latest_script "$TARGET_USER")
        script_name="$(basename "$repo_path")"

        if [[ "$LOOP_MODE" == true && "$(_last_seen)" == "$script_name" ]]; then
            log "No new scripts from ${TARGET_USER} (latest: ${script_name})"
            return 0
        fi

        script_path="/tmp/cpats_dl_$$_${script_name}"
        log "Downloading ${repo_path}…"
        gh_download "$repo_path" "$script_path"
        ok "Downloaded"
    fi

    local output_file
    output_file=$(run_script "$script_path" "$script_name")
    _mark_seen "$script_name"

    if [[ "$UPLOAD_OUTPUT" == true ]]; then
        upload_output "$output_file" "$run_user" "$script_name"
    else
        log "Output saved locally: ${output_file}"
        [[ -z "$GITHUB_TOKEN" ]] || log "Add --upload-output to push it back to GitHub"
    fi

    # Cleanup downloaded temp file (but not --file mode, that's the user's file)
    [[ -n "$TARGET_USER" ]] && rm -f "$script_path"
}

printf "\n${BOLD}cpats-pastebin${NC} │ repo: ${CYAN}%s${NC} │ branch: %s\n\n" "$GITHUB_REPO" "$BRANCH"

if [[ "$LIST_MODE" == true ]]; then
    list_scripts "$TARGET_USER"
    exit 0
fi

if [[ "$LOOP_MODE" == true ]]; then
    log "Loop mode — checking every 30s for new scripts from '${TARGET_USER}' (Ctrl+C to stop)"
    echo
    while true; do
        run_once || warn "Run failed, retrying in 30s…"
        sleep 30
    done
else
    run_once
fi
