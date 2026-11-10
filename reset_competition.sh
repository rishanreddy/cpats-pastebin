#!/usr/bin/env bash
# reset_competition.sh — cpats-pastebin competition reset
#
# Deletes the files under scripts/, outputs/, and clipboard/ through the GitHub
# API. Keeps keep/ and every tool. Run it on your own computer between
# competitions. Uses your GitHub CLI login (`gh auth login`): no token flag and
# no config file.
#
# Usage:
#   bash reset_competition.sh [--dry-run] [--yes] [--repo OWNER/REPO] [--branch NAME]

set -euo pipefail

DEFAULT_REPO='rishanreddy/cpats-pastebin'

log()  { printf '[cpats] %s\n' "$*"; }
ok()   { printf '[  ok ] %s\n' "$*"; }
warn() { printf '[ warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: bash reset_competition.sh [options]

Deletes everything under scripts/, outputs/, and clipboard/ (placeholders stay).
Keeps keep/, the tools, the docs, and the Git history.

  --dry-run           List what would be deleted and delete nothing
  --yes, -y           Skip the typed confirmation
  --repo OWNER/REPO   Default: ${DEFAULT_REPO}
  --branch NAME       Default: main
  -h, --help          Show this help

Stop all runners and publishers first. Needs the GitHub CLI signed in with
write access to the repo: gh auth login
EOF
}

DRY_RUN=false SKIP_CONFIRM=false REPO="$DEFAULT_REPO" BRANCH=main
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --yes|-y) SKIP_CONFIRM=true; shift ;;
        --repo) [[ $# -ge 2 ]] || die 'Missing value for --repo'; REPO="$2"; shift 2 ;;
        --branch) [[ $# -ge 2 ]] || die 'Missing value for --branch'; BRANCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1. Run with --help for the options." ;;
    esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo must look like owner/repo.'
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != *..* && "$BRANCH" != *//* ]] || die '--branch has unexpected characters.'
command -v gh >/dev/null || die 'GitHub CLI (gh) is required. Install it, then run: gh auth login'
gh auth status >/dev/null 2>&1 || die 'Not signed in. Run: gh auth login'

# One call returns every file in the repo. gh's built-in --jq filter keeps the ones to
# delete, so no Python or separate jq is needed. A first line of TRUNCATED means
# GitHub cut the list short.
list_files_to_delete() {
    gh api "repos/${REPO}/git/trees/${BRANCH}?recursive=1" --jq '
        (if .truncated then "TRUNCATED" else empty end),
        (.tree[]
         | select(.type == "blob")
         | select(.path | test("^(scripts|outputs|clipboard)/"))
         | select(.path | test("(^|/)\\.gitkeep$") | not)
         | "\(.path)|\(.sha)")' \
        || die "Could not read ${REPO} on branch ${BRANCH}. Check --repo, --branch, and gh auth status."
}

delete_file() {
    local path="$1" sha="$2"
    if [[ "$DRY_RUN" == true ]]; then
        warn "[dry-run] would delete: ${path}"
        return 0
    fi
    if gh api --method DELETE "repos/${REPO}/contents/${path}" \
        -f "message=reset: remove ${path}" -f "sha=${sha}" -f "branch=${BRANCH}" >/dev/null 2>&1; then
        ok "Deleted: ${path}"
    else
        warn "Failed to delete ${path}"
        return 1
    fi
}

printf '\ncpats-pastebin reset | repo: %s | branch: %s\n\n' "$REPO" "$BRANCH"
printf 'Will delete everything in:\n  x scripts/\n  x outputs/\n  x clipboard/\n\n'
printf 'Will keep:\n  + keep/\n  + the runner, publisher, clipboard tool, and docs\n  + the Git history (old files stay visible in past commits)\n\n'
[[ "$DRY_RUN" == false ]] || warn 'DRY RUN: nothing will be deleted.'

if [[ "$SKIP_CONFIRM" == false && "$DRY_RUN" == false ]]; then
    printf 'Type RESET to confirm: '
    read -r CONFIRM
    [[ "$CONFIRM" == RESET ]] || { log 'Cancelled.'; exit 0; }
fi

log 'Fetching the file list from GitHub'
FILE_LIST=$(list_files_to_delete)
if [[ "$FILE_LIST" == TRUNCATED* ]]; then
    warn 'GitHub truncated the file list. Run the reset again afterwards to finish.'
    FILE_LIST="${FILE_LIST#TRUNCATED}"
    FILE_LIST="${FILE_LIST#$'\n'}"
fi
if [[ -z "$FILE_LIST" ]]; then
    ok 'Nothing to delete. The repo is already clean.'
    exit 0
fi

COUNT=0 DELETED=0 FAILED=0
while IFS= read -r ENTRY; do
    [[ -n "$ENTRY" ]] || continue
    COUNT=$((COUNT + 1))
    if delete_file "${ENTRY%%|*}" "${ENTRY##*|}"; then DELETED=$((DELETED + 1)); else FAILED=$((FAILED + 1)); fi
    # Stay under GitHub's secondary rate limit for rapid writes.
    [[ "$DRY_RUN" == true ]] || sleep 1
done <<< "$FILE_LIST"

printf '\n'
if [[ "$DRY_RUN" == true ]]; then
    warn "Dry run complete: ${COUNT} files would be deleted."
elif [[ "$FAILED" -eq 0 ]]; then
    ok "Reset complete: ${DELETED} files removed."
else
    warn "Reset finished with errors: ${DELETED} deleted, ${FAILED} failed. Run it again to retry."
    exit 1
fi
