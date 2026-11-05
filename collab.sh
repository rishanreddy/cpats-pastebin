#!/usr/bin/env bash
# collab.sh — manage cpats-pastebin collaborators
#
# Add or remove teammates from the GitHub repo so they can push scripts
# and upload outputs. Requires a token with admin:repo scope (or the repo
# owner running it).
#
# Usage:
#   ./collab.sh add <github-username>
#   ./collab.sh remove <github-username>
#   ./collab.sh list

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

ok()   { printf "${GREEN}[  ok ]${NC} %s\n" "$*"; }
log()  { printf "${CYAN}[cpats]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[ warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/.cpats.env" ]] && source "${SCRIPT_DIR}/.cpats.env"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

[[ -z "$GITHUB_REPO"  ]] && die "GITHUB_REPO not set in .cpats.env"
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN not set — collaborator management requires write access"

GH_API="https://api.github.com/repos/${GITHUB_REPO}"

# ── Helpers ───────────────────────────────────────────────────────────────────

gh_call() {
    local method="$1" path="$2"
    shift 2
    curl -fsSL -X "$method" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$@" \
        "${GH_API}${path}"
}

# ── Commands ──────────────────────────────────────────────────────────────────

collab_add() {
    local username="$1"
    # permission: "push" lets them push scripts + outputs. "maintain" if you
    # want them to manage the repo but not admin settings. "admin" for full access.
    local permission="${2:-push}"

    log "Inviting ${username} as collaborator (permission: ${permission})…"

    local http_code
    http_code=$(curl -sS -o /tmp/collab_resp.json -w "%{http_code}" -X PUT \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"permission\": \"${permission}\"}" \
        "${GH_API}/collaborators/${username}")

    case "$http_code" in
        201) ok "Invitation sent to ${username}. They must accept it via GitHub." ;;
        204) ok "${username} is already a collaborator." ;;
        *)
            cat /tmp/collab_resp.json >&2
            die "Failed to add collaborator (HTTP ${http_code})"
            ;;
    esac
    rm -f /tmp/collab_resp.json
}

collab_remove() {
    local username="$1"
    log "Removing ${username} from ${GITHUB_REPO}…"

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "${GH_API}/collaborators/${username}")

    case "$http_code" in
        204) ok "Removed ${username} from collaborators." ;;
        404) warn "${username} was not a collaborator." ;;
        *)   die "Failed to remove collaborator (HTTP ${http_code})" ;;
    esac
}

collab_list() {
    log "Fetching collaborators for ${GITHUB_REPO}…"
    local raw
    raw=$(gh_call GET "/collaborators")
    python3 - "$raw" <<'PYEOF'
import sys, json
users = json.loads(sys.argv[1])
if not users:
    print("  (no collaborators)")
    sys.exit(0)
for u in users:
    print(f"  → {u['login']} [{u.get('permissions', {})}]")
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

printf "\n${BOLD}cpats-pastebin collaborators${NC} │ repo: ${CYAN}%s${NC}\n\n" "$GITHUB_REPO"

CMD="${1:-}"
case "$CMD" in
    add)
        [[ -z "${2:-}" ]] && die "Usage: $(basename "$0") add <github-username>"
        collab_add "$2" "${3:-push}"
        ;;
    remove|rm)
        [[ -z "${2:-}" ]] && die "Usage: $(basename "$0") remove <github-username>"
        collab_remove "$2"
        ;;
    list|ls)
        collab_list
        ;;
    *)
        cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  add <username> [permission]   Add collaborator (permission: push/maintain/admin, default: push)
  remove <username>             Remove a collaborator
  list                          List current collaborators

Examples:
  ./collab.sh add   partneruser
  ./collab.sh add   partneruser maintain
  ./collab.sh list
  ./collab.sh remove partneruser
EOF
        ;;
esac
