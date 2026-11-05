#!/usr/bin/env bash
# clipboard_upload.sh — cpats-pastebin clipboard/text uploader
#
# Uploads text to GitHub's clipboard/ folder so your AI agent can read it.
# Reads from clipboard (xclip/xsel/wl-paste), stdin, or a direct argument.
#
# Usage:
#   ./clipboard_upload.sh -l <label>
#   echo "some text" | ./clipboard_upload.sh -l <label>
#   cat /var/log/auth.log | ./clipboard_upload.sh -l auth-log
#   ./clipboard_upload.sh -l note -t "text to upload directly"
#
# Requires GITHUB_TOKEN (write access) in .cpats.env.

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
ok()  { printf "${GREEN}[  ok ]${NC} %s\n" "$*"; }
log() { printf "${CYAN}[cpats]${NC} %s\n" "$*"; }
die() { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/.cpats.env" ]] && source "${SCRIPT_DIR}/.cpats.env"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CPATS_USERNAME="${CPATS_USERNAME:-unknown}"
BRANCH="${BRANCH:-main}"

# ── Args ──────────────────────────────────────────────────────────────────────

LABEL=""
DIRECT_TEXT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") -l <label> [options]

  -l, --label <name>  Label for the file (required)
  -t, --text  <text>  Upload this text directly (skip clipboard/stdin)
  -u, --user  <name>  Override CPATS_USERNAME from config
  --repo <owner/name> Override GITHUB_REPO
  -h, --help          Show this help

The file is saved to: clipboard/<user>/<label>_<timestamp>.txt
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--label) LABEL="$2";             shift 2 ;;
        -t|--text)  DIRECT_TEXT="$2";       shift 2 ;;
        -u|--user)  CPATS_USERNAME="$2";    shift 2 ;;
        --repo)     GITHUB_REPO="$2";       shift 2 ;;
        -h|--help)  usage ;;
        *) die "Unknown argument: $1. Run with --help." ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────

[[ -z "$GITHUB_REPO"   ]] && die "GITHUB_REPO not set. Add it to .cpats.env"
[[ -z "$GITHUB_TOKEN"  ]] && die "GITHUB_TOKEN not set. Clipboard upload requires write access."
[[ -z "$LABEL"         ]] && die "Label required. Use: $(basename "$0") -l <name>"

# ── Read content ──────────────────────────────────────────────────────────────

TEXT=""

if [[ -n "$DIRECT_TEXT" ]]; then
    TEXT="$DIRECT_TEXT"
elif [[ ! -t 0 ]]; then
    # Reading from a pipe / redirect
    TEXT=$(cat)
elif command -v xclip &>/dev/null; then
    TEXT=$(xclip -selection clipboard -o 2>/dev/null) || true
elif command -v xsel &>/dev/null; then
    TEXT=$(xsel --clipboard --output 2>/dev/null) || true
elif command -v wl-paste &>/dev/null; then
    TEXT=$(wl-paste 2>/dev/null) || true
else
    die "No clipboard tool found (xclip / xsel / wl-paste) and nothing piped. Use -t 'text' or pipe with echo."
fi

[[ -z "$TEXT" ]] && die "Nothing to upload — clipboard was empty."

# ── Upload ────────────────────────────────────────────────────────────────────

GH_API="https://api.github.com/repos/${GITHUB_REPO}"
TS=$(date '+%Y%m%d_%H%M%S')
SAFE_LABEL=$(echo "$LABEL" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]-' '_' | sed 's/_*$//')
REPO_PATH="clipboard/${CPATS_USERNAME}/${SAFE_LABEL}_${TS}.txt"

log "Uploading to ${GITHUB_REPO}/${REPO_PATH}…"

# Build payload safely via Python — handles any content (quotes, backslashes, newlines, etc.)
PAYLOAD=$(python3 - "$TEXT" "$TS" "$SAFE_LABEL" "$CPATS_USERNAME" "$BRANCH" <<'PYEOF'
import sys, json, base64
text, ts, label, user, branch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
content_b64 = base64.b64encode(text.encode('utf-8')).decode()
print(json.dumps({
    "message": f"clipboard: {label} from {user} at {ts}",
    "content": content_b64,
    "branch":  branch,
}))
PYEOF
)

RESPONSE=$(curl -fsSL -X PUT \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${GH_API}/contents/${REPO_PATH}" 2>&1) || {
    echo "$RESPONSE" >&2
    die "Upload failed. Check GITHUB_TOKEN and repo permissions."
}

ok "Uploaded: clipboard/${CPATS_USERNAME}/${SAFE_LABEL}_${TS}.txt"
printf "  View: ${CYAN}https://github.com/%s/blob/%s/%s${NC}\n" \
    "$GITHUB_REPO" "$BRANCH" "$REPO_PATH"
