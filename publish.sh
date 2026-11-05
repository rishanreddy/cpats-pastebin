#!/usr/bin/env bash
# Publish one reviewed script with the authenticated GitHub CLI.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./publish.sh --user USER --source PATH --name SLUG [--repo OWNER/REPO] [--branch BRANCH]

Requires GitHub CLI authentication (`gh auth login`). The source is uploaded
through GitHub's Contents API; no Git remote or local commit is required.
EOF
}

REPO="rishanreddy/cpats-pastebin"
BRANCH="main"
USER=""
SOURCE=""
NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; REPO="$2"; shift 2 ;;
        --branch) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
        --user) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; USER="$2"; shift 2 ;;
        --source) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; SOURCE="$2"; shift 2 ;;
        --name) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid --repo." >&2; exit 2; }
[[ "$USER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "Invalid --user." >&2; exit 2; }
[[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,39}$ ]] || { echo "Invalid --name." >&2; exit 2; }
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != *..* && "$BRANCH" != *//* ]] || {
    echo "Invalid --branch." >&2
    exit 2
}
[[ -f "$SOURCE" ]] || { echo "Source file not found: $SOURCE" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI (gh) is required on the developer machine." >&2; exit 2; }
gh auth status >/dev/null || { echo "Run 'gh auth login' before publishing." >&2; exit 2; }
bash -n "$SOURCE" || { echo "Bash syntax check failed." >&2; exit 2; }
head -n 1 "$SOURCE" | grep -Eq '^#!/(usr/bin/env bash|bin/bash)$' || {
    echo "Script must begin with a Bash shebang." >&2
    exit 2
}

timestamp="$(date -u +%Y%m%d_%H%M%S)"
suffix="$(printf '%04x' "$RANDOM")"
path="scripts/${USER}/${timestamp}_${NAME}_${suffix}.sh"
content="$(base64 < "$SOURCE" | tr -d '\n')"

published_path="$(
    gh api --method PUT "repos/${REPO}/contents/${path}" \
        --field "message=script: ${NAME} [${USER}]" \
        --field "content=${content}" \
        --field "branch=${BRANCH}" \
        --jq '.content.path'
)"

[[ "$published_path" == "$path" ]] || {
    echo "GitHub did not confirm the expected published path." >&2
    exit 1
}
echo "Published: https://github.com/${REPO}/blob/${BRANCH}/${path}"
