#!/usr/bin/env bash
# Upload clipboard or piped text. Keep runner.sh beside this file for the shared helpers.
# Needs only bash and curl or wget. No Python, nothing installed.
# Every setting is a command-line flag. No config file or environment variable is read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/runner.sh" ]] || { echo 'Download runner.sh into this directory first.' >&2; exit 1; }
# shellcheck source=runner.sh
source "${SCRIPT_DIR}/runner.sh"

paste_usage() {
    cat <<EOF
Usage: bash clipboard_upload.sh --user NAME --token TOKEN --label LABEL [options]

Uploads text to clipboard/NAME/ in the relay repo. The text comes from --text,
from stdin (a pipe or redirect), or from the VM's clipboard when a clipboard
tool such as xclip is installed.

  -u, --user NAME     Your GitHub username; chooses the clipboard/ subfolder
      --token TOKEN   GitHub token with write access to the repo
  -l, --label LABEL   Short name for the paste, used in the filename
  -t, --text TEXT     Upload this text instead of stdin or the clipboard
      --repo OWNER/REPO   Default: ${DEFAULT_REPO}
      --branch NAME       Default: ${DEFAULT_BRANCH}
  -h, --help          Show this help

Examples:
  cat /var/log/auth.log | bash clipboard_upload.sh -u sid1332 --token "\$T" -l auth-log
  bash clipboard_upload.sh -u sid1332 --token "\$T" -l note -t 'Check this service'
EOF
}

LABEL='' DIRECT_TEXT='' HAVE_TEXT=false USERNAME=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--label) require_value "$@"; LABEL="$2"; shift 2 ;;
        -t|--text) [[ $# -ge 2 ]] || die 'Missing value for --text'; DIRECT_TEXT="$2"; HAVE_TEXT=true; shift 2 ;;
        -u|--user) require_value "$@"; USERNAME="$2"; shift 2 ;;
        --token) require_value "$@"; set_token "$2"; shift 2 ;;
        --repo) require_value "$@"; GITHUB_REPO="$2"; shift 2 ;;
        --branch) require_value "$@"; BRANCH="$2"; shift 2 ;;
        -h|--help) paste_usage; exit 0 ;;
        *) die "Unknown argument: $1. Run with --help for the options." ;;
    esac
done
require_core_tools
require_http_tool
validate_repo
[[ -n "$GITHUB_TOKEN" ]] || die 'Uploading needs --token.'
[[ -n "$USERNAME" ]] || die 'A username is required. Use --user NAME.'
[[ -n "$LABEL" ]] || die 'A label is required. Use --label NAME.'
USERNAME=$(normalize_user "$USERNAME") || exit 1

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
    die 'No clipboard tool is installed. Pipe text in or use --text TEXT.'
fi
if [[ ! -s "$CONTENT_FILE" ]]; then rm -f "$CONTENT_FILE"; die 'Nothing to upload.'; fi

REPO_PATH=$(new_repo_path clipboard "$USERNAME" "$LABEL" txt)
log "Uploading ${REPO_PATH}"
gh_upload "$REPO_PATH" "$CONTENT_FILE" "clipboard: ${LABEL} [${USERNAME}]" || exit 1
rm -f "$CONTENT_FILE"
ok "Uploaded: https://github.com/${GITHUB_REPO}/blob/${BRANCH}/${REPO_PATH}"
