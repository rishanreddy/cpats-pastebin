#!/usr/bin/env bash
# reset_competition.sh — cpats-pastebin competition reset
#
# Wipes scripts/, outputs/, and clipboard/ from the GitHub repo via API.
# Preserves keep/ and all infrastructure files. Run between competitions.
#
# Usage:
#   ./reset_competition.sh [--dry-run] [--yes]

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'

log()  { printf "${CYAN}[cpats]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[  ok ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[ warn]${NC} %s\n" "$*"; }
die()  { printf "${RED}[error]${NC} %s\n" "$*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/.cpats.env" ]] && source "${SCRIPT_DIR}/.cpats.env"

GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
BRANCH="${BRANCH:-main}"

# ── Args ──────────────────────────────────────────────────────────────────────

DRY_RUN=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true;        shift ;;
        --yes|-y)   SKIP_CONFIRM=true;   shift ;;
        --repo)     GITHUB_REPO="$2";    shift 2 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--dry-run] [--yes]"
            echo "  --dry-run  Show what would be deleted without deleting"
            echo "  --yes      Skip confirmation prompt"
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────

[[ -z "$GITHUB_REPO"  ]] && die "GITHUB_REPO not set in .cpats.env"
[[ -z "$GITHUB_TOKEN" ]] && die "GITHUB_TOKEN not set — reset requires write access"

GH_API="https://api.github.com/repos/${GITHUB_REPO}"

# ── File discovery via Git tree API ──────────────────────────────────────────
# Uses the recursive tree endpoint — one API call gets every file in the repo.
# This is correct and doesn't require any JSON recursion logic in bash.

get_all_files_to_delete() {
    local tree_url="${GH_API}/git/trees/${BRANCH}?recursive=1"
    local raw
    raw=$(curl -fsSL \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$tree_url") || die "Failed to fetch repo tree. Check GITHUB_TOKEN and repo name."

    # Extract all blob paths that are under the directories we want to clear
    python3 - "$raw" <<'PYEOF'
import sys, json

data = json.loads(sys.argv[1])
if data.get("truncated"):
    print("WARNING: repo tree was truncated by GitHub API", file=sys.stderr)

CLEAR_PREFIXES = ("scripts/", "outputs/", "clipboard/")
KEEP_FILES = {".gitkeep"}

for item in data.get("tree", []):
    if item.get("type") != "blob":
        continue
    path = item["path"]
    fname = path.rsplit("/", 1)[-1]
    if fname in KEEP_FILES:
        continue
    if any(path.startswith(p) for p in CLEAR_PREFIXES):
        print(f"{path}|{item['sha']}")
PYEOF
}

# ── Delete a single file via API ─────────────────────────────────────────────

delete_file() {
    local path="$1" sha="$2"

    if [[ "$DRY_RUN" == true ]]; then
        warn "[dry-run] would delete: ${path}"
        return 0
    fi

    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({'message': 'reset: remove ' + sys.argv[1], 'sha': sys.argv[2], 'branch': sys.argv[3]}))" \
        "$path" "$sha" "$BRANCH")

    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${GH_API}/contents/${path}")

    if [[ "$http_code" == "200" ]]; then
        ok "Deleted: ${path}"
    else
        warn "Failed to delete ${path} (HTTP ${http_code})"
        return 1
    fi
}

# ── UI ────────────────────────────────────────────────────────────────────────

printf "\n${BOLD}cpats-pastebin reset${NC} │ repo: ${CYAN}%s${NC}\n\n" "$GITHUB_REPO"
printf "${YELLOW}Will delete all files in:${NC}\n"
printf "  ${RED}✗${NC} scripts/\n"
printf "  ${RED}✗${NC} outputs/\n"
printf "  ${RED}✗${NC} clipboard/\n"
printf "\n${GREEN}Will preserve:${NC}\n"
printf "  ${GREEN}✓${NC} keep/\n"
printf "  ${GREEN}✓${NC} runner.sh, clipboard_upload.sh, reset_competition.sh\n"
printf "  ${GREEN}✓${NC} README.md, .skill/, .cpats.env.example, .gitignore\n\n"

[[ "$DRY_RUN" == true ]] && warn "DRY RUN — nothing will actually be deleted\n"

if [[ "$SKIP_CONFIRM" == false && "$DRY_RUN" == false ]]; then
    printf "${BOLD}Type RESET to confirm: ${NC}"
    read -r confirm
    [[ "$confirm" == "RESET" ]] || { log "Cancelled."; exit 0; }
fi

# ── Execute ───────────────────────────────────────────────────────────────────

log "Fetching file list from GitHub…"
mapfile -t FILES < <(get_all_files_to_delete)

if [[ ${#FILES[@]} -eq 0 ]]; then
    ok "Nothing to delete — repo is already clean."
    exit 0
fi

printf "\n"
DELETED=0 FAILED=0
for entry in "${FILES[@]}"; do
    [[ -z "$entry" ]] && continue
    fpath="${entry%%|*}"
    fsha="${entry##*|}"
    if delete_file "$fpath" "$fsha"; then
        DELETED=$((DELETED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    # Respect GitHub's rate limit: 1 write/s is safe on the free tier
    sleep 0.5
done

printf "\n"
if [[ "$DRY_RUN" == true ]]; then
    warn "Dry run complete — ${#FILES[@]} files would be deleted."
elif [[ "$FAILED" -eq 0 ]]; then
    ok "Reset complete — ${DELETED} files removed. Ready for next competition."
else
    warn "Reset done with errors — ${DELETED} deleted, ${FAILED} failed."
fi
