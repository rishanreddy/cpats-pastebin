#!/usr/bin/env bash
# collab.sh — manage cpats-pastebin collaborators
#
# Run on your own computer by the repo owner. Uses your GitHub CLI login
# (`gh auth login`), so there is no token flag or config file.
#
# Usage:
#   bash collab.sh add USERNAME [--permission push|maintain|admin]
#   bash collab.sh remove USERNAME
#   bash collab.sh list
#   Add --repo OWNER/REPO to manage a different repo.

set -euo pipefail

DEFAULT_REPO='rishanreddy/cpats-pastebin'

ok()   { printf '[  ok ] %s\n' "$*"; }
log()  { printf '[cpats] %s\n' "$*"; }
warn() { printf '[ warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: bash collab.sh <command> [options]

Commands:
  add USERNAME      Invite USERNAME as a collaborator. They must accept the email
                    or the invitation at https://github.com/${DEFAULT_REPO}/invitations
  remove USERNAME   Remove a collaborator
  list              List collaborators and any pending invitations

Options:
  --permission LEVEL  With add: push (default), maintain, or admin
  --repo OWNER/REPO   Default: ${DEFAULT_REPO}
  -h, --help          Show this help

Needs the GitHub CLI signed in as the repo owner: gh auth login
EOF
}

COMMAND='' TARGET='' PERMISSION=push REPO="$DEFAULT_REPO"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --permission) [[ $# -ge 2 ]] || die 'Missing value for --permission'; PERMISSION="$2"; shift 2 ;;
        --repo) [[ $# -ge 2 ]] || die 'Missing value for --repo'; REPO="$2"; shift 2 ;;
        -*) die "Unknown argument: $1. Run with --help for the options." ;;
        *)
            if [[ -z "$COMMAND" ]]; then COMMAND="$1"
            elif [[ -z "$TARGET" ]]; then TARGET="$1"
            else die "Unexpected argument: $1"
            fi
            shift ;;
    esac
done

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo must look like owner/repo.'
[[ "$PERMISSION" =~ ^(push|maintain|admin)$ ]] || die '--permission must be push, maintain, or admin.'
if [[ -n "$TARGET" ]]; then
    [[ "$TARGET" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die "Invalid GitHub username: ${TARGET}"
fi
[[ -n "$COMMAND" ]] || { usage; exit 0; }
command -v gh >/dev/null || die 'GitHub CLI (gh) is required. Install it, then run: gh auth login'
gh auth status >/dev/null 2>&1 || die 'Not signed in. Run: gh auth login'

case "$COMMAND" in
    add)
        [[ -n "$TARGET" ]] || die 'Usage: bash collab.sh add USERNAME'
        log "Inviting ${TARGET} to ${REPO} (permission: ${PERMISSION})"
        RESPONSE=$(gh api --method PUT "repos/${REPO}/collaborators/${TARGET}" -f "permission=${PERMISSION}") \
            || die "Could not add ${TARGET}. Only the repo owner or an admin can do this."
        if [[ -z "$RESPONSE" ]]; then
            ok "${TARGET} already has access."
        else
            ok "Invitation sent. ${TARGET} must accept it at https://github.com/${REPO}/invitations"
        fi
        ;;
    remove|rm)
        [[ -n "$TARGET" ]] || die 'Usage: bash collab.sh remove USERNAME'
        gh api --method DELETE "repos/${REPO}/collaborators/${TARGET}" >/dev/null \
            || die "Could not remove ${TARGET}. They may not be a collaborator, or you are not an admin."
        ok "Removed ${TARGET}."
        ;;
    list|ls)
        log "Collaborators on ${REPO}"
        gh api "repos/${REPO}/collaborators" --jq '.[] | "  \(.login) (\(.role_name // "member"))"' \
            || die 'Could not list collaborators. Only a repo admin can.'
        PENDING=$(gh api "repos/${REPO}/invitations" --jq '.[] | "  \(.invitee.login) (invited, not accepted yet)"' 2>/dev/null || true)
        [[ -z "$PENDING" ]] || printf '%s\n' "$PENDING"
        ;;
    *) die "Unknown command: ${COMMAND}. Run with --help." ;;
esac
