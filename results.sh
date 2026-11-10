#!/usr/bin/env bash
# results.sh — fetch what a VM sent back to the relay repo, and optionally wait for it.
#
# Run on your own computer. Uses your GitHub CLI login (`gh auth login`), so there is
# no token flag and no config file. Pure Bash plus gh; no Python.
#
# Exit codes: 0 printed a result, 3 timed out waiting, 4 nothing exists yet, 1 error.

set -euo pipefail

DEFAULT_REPO='rishanreddy/cpats-pastebin'
POLL_SECONDS=10

log()  { printf '[cpats] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: bash results.sh --user NAME [options]

Prints the newest file the VM for NAME uploaded: script output by default, or text
pasted with clipboard_upload.sh. It can wait for a result to arrive, which is how
you find out what a script you just published did.

  --user NAME         Whose VM (a GitHub username). Required.
  --kind KIND         outputs (default) or clipboard
  --script FILE       Only the output of this script. Use the file name that
                      publish.sh printed. Matches the "script:" line in the output.
  --wait SECONDS      Keep checking every ${POLL_SECONDS}s for up to SECONDS (0 to 3600).
                      With no --script, waits for a file newer than the newest one now.
  --list              List the file names (oldest first) and exit
  --repo OWNER/REPO   Default: ${DEFAULT_REPO}
  --branch NAME       Default: main
  -h, --help          Show this help

Examples:
  bash results.sh --user sid1332                       # newest output right now
  bash results.sh --user sid1332 --script 20261110_173302_123456_recon_ab12.sh --wait 180
  bash results.sh --user sid1332 --kind clipboard --wait 120
  bash results.sh --user sid1332 --list

Needs the GitHub CLI signed in: gh auth login
EOF
}

NAME='' KIND=outputs SCRIPT='' WAIT=0 LIST=false REPO="$DEFAULT_REPO" BRANCH=main
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user|--kind|--script|--wait|--repo|--branch)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $1"
            case "$1" in
                --user) NAME="$2" ;; --kind) KIND="$2" ;; --script) SCRIPT="$2" ;;
                --wait) WAIT="$2" ;; --repo) REPO="$2" ;; --branch) BRANCH="$2" ;;
            esac
            shift 2 ;;
        --list) LIST=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1. Run with --help for the options." ;;
    esac
done

[[ -n "$NAME" ]] || die 'Missing --user NAME. Run with --help for examples.'
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die "Invalid GitHub username: ${NAME}"
NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
[[ "$KIND" == outputs || "$KIND" == clipboard ]] || die '--kind must be outputs or clipboard.'
[[ "$WAIT" =~ ^[0-9]+$ && "$WAIT" -le 3600 ]] || die '--wait must be a whole number of seconds from 0 to 3600.'
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '--repo must look like owner/repo.'
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ && "$BRANCH" != *..* && "$BRANCH" != *//* ]] || die '--branch has unexpected characters.'
if [[ -n "$SCRIPT" ]]; then
    SCRIPT="${SCRIPT##*/}"
    [[ "$SCRIPT" =~ ^[A-Za-z0-9._-]+\.sh$ ]] || die '--script must be the published .sh file name.'
    [[ "$KIND" == outputs ]] || die '--script only applies to --kind outputs.'
fi
command -v gh >/dev/null || die 'GitHub CLI (gh) is required. Install it, then run: gh auth login'
gh auth status >/dev/null 2>&1 || die 'Not signed in. Run: gh auth login'

REF="${BRANCH//\//%2F}"

# File names in the folder, oldest first. A missing folder (HTTP 404) just means nothing yet.
# gh prints an error body on stdout even with --jq, so only trust stdout when gh succeeds.
list_names() {
    local out errors
    errors=$(mktemp)
    if out=$(gh api "repos/${REPO}/contents/${KIND}/${NAME}?ref=${REF}" \
            --jq '[.[] | select(.type == "file")] | map(.name) | sort | .[]' 2>"$errors"); then
        if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
    elif ! grep -q 'HTTP 404' "$errors"; then
        log "GitHub error while listing ${KIND}/${NAME}: $(head -n 1 "$errors")"
    fi
    rm -f "$errors"
}

fetch() { gh api -H 'Accept: application/vnd.github.raw+json' "repos/${REPO}/contents/${KIND}/${NAME}/${1}?ref=${REF}"; }

# Newest output whose first line says it came from $SCRIPT. Checks the 8 newest files.
matching_output() {
    local candidate first
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        first=$(fetch "$candidate" 2>/dev/null | head -n 1 || true)
        if [[ "$first" == "script:    ${SCRIPT}" ]]; then printf '%s' "$candidate"; return 0; fi
    done < <(printf '%s\n' "$1" | LC_ALL=C sort -r | head -n 8)
    return 1
}

if [[ "$LIST" == true ]]; then list_names; exit 0; fi

before=$(list_names | tail -n 1)
attempts=$(( WAIT / POLL_SECONDS + 1 ))
for (( attempt = 1; attempt <= attempts; attempt++ )); do
    names=$(list_names)
    found=''
    if [[ -n "$SCRIPT" ]]; then
        found=$(matching_output "$names" || true)
    else
        found=$(printf '%s\n' "$names" | tail -n 1)
        # While waiting, only a file newer than the newest one at the start counts.
        if (( WAIT > 0 )) && [[ "$found" == "$before" ]]; then found=''; fi
    fi
    if [[ -n "$found" ]]; then
        printf '==> %s/%s/%s\n' "$KIND" "$NAME" "$found"
        fetch "$found" || die "Could not read ${KIND}/${NAME}/${found}."
        exit 0
    fi
    (( attempt < attempts )) || break
    log "Nothing yet. Checking again in ${POLL_SECONDS}s (attempt ${attempt} of ${attempts})."
    sleep "$POLL_SECONDS"
done

if (( WAIT > 0 )); then
    log "Nothing arrived within ${WAIT}s. The VM's runner may not be running, may lack --upload-output, or the script may still be running."
    exit 3
fi
log "No ${KIND} found for ${NAME} yet."
exit 4
