#!/usr/bin/env bash
# Upload clipboard or piped text. Keep runner.sh beside this file for API helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/runner.sh" ]] || { echo 'Download runner.sh into this directory first.' >&2; exit 1; }
# shellcheck source=runner.sh
source "${SCRIPT_DIR}/runner.sh"
load_config

LABEL='' DIRECT_TEXT='' HAVE_TEXT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--label) require_value "$@"; LABEL="$2"; shift 2 ;;
        -t|--text) [[ $# -ge 2 ]] || die 'Missing value for --text'; DIRECT_TEXT="$2"; HAVE_TEXT=true; shift 2 ;;
        -u|--user) require_value "$@"; CPATS_USERNAME="$2"; shift 2 ;;
        --repo) require_value "$@"; GITHUB_REPO="$2"; shift 2 ;;
        --branch) require_value "$@"; BRANCH="$2"; shift 2 ;;
        -h|--help)
            echo 'Usage: ./clipboard_upload.sh -l LABEL [-t TEXT] [-u USER] [--repo OWNER/REPO] [--branch NAME]'
            echo 'Reads text from --text, stdin, or an existing clipboard tool.'
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
require_tools
validate_repo
[[ -n "$GITHUB_TOKEN" ]] || die 'GITHUB_TOKEN is required.'
[[ -n "$LABEL" ]] || die 'A label is required. Use -l NAME.'
CPATS_USERNAME=$(normalize_user "$CPATS_USERNAME") || exit 1

CONTENT_FILE=$(mktemp "${TMPDIR:-/tmp}/cpats_clipboard_XXXXXXXX")
if [[ "$HAVE_TEXT" == true ]]; then
    printf '%s' "$DIRECT_TEXT" > "$CONTENT_FILE"
elif [[ ! -t 0 ]]; then
    cat > "$CONTENT_FILE"
elif command -v wl-paste >/dev/null; then
    wl-paste > "$CONTENT_FILE" || die "Cannot read clipboard. Local file: ${CONTENT_FILE}"
elif command -v xclip >/dev/null; then
    xclip -selection clipboard -o > "$CONTENT_FILE" || die "Cannot read clipboard. Local file: ${CONTENT_FILE}"
elif command -v xsel >/dev/null; then
    xsel --clipboard --output > "$CONTENT_FILE" || die "Cannot read clipboard. Local file: ${CONTENT_FILE}"
else
    rm -f "$CONTENT_FILE"
    die 'No clipboard tool is installed. Pipe text or use -t TEXT.'
fi
if [[ ! -s "$CONTENT_FILE" ]]; then rm -f "$CONTENT_FILE"; die 'Nothing to upload.'; fi

REPO_PATH=$(new_repo_path clipboard "$CPATS_USERNAME" "$LABEL" txt)
log "Uploading ${REPO_PATH}"
gh_upload "$REPO_PATH" "$CONTENT_FILE" "clipboard: ${LABEL} [${CPATS_USERNAME}]" || exit 1
rm -f "$CONTENT_FILE"
ok "Uploaded: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${REPO_PATH}"
