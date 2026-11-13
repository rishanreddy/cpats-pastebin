#!/usr/bin/env bash
# Locate MP3s for the Debian 12 forensics question.
# The default scan is read-only. Removal requires an interactive confirmation.
set -euo pipefail

is_packaged() {
    dpkg-query -S -- "$1" >/dev/null 2>&1
}

scan() {
    local root path
    local -a roots=(/)
    for root in /home /root /var /tmp /opt /srv /usr; do
        if mountpoint -q -- "$root"; then roots+=("$root"); fi
    done

    printf '%s\n' 'MP3 paths (review which files are unrelated to work):'
    find "${roots[@]}" -xdev \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /mnt -o -path /media \) -prune -o \
        -type f -iname '*.mp3' -print0 \
        | LC_ALL=C sort -zu \
        | while IFS= read -r -d '' path; do
            if is_packaged "$path"; then
                printf '  %q [Debian package file]\n' "$path"
            else
                printf '  %q\n' "$path"
            fi
        done
    printf '\n%s\n' 'To remove confirmed non-work files, run this script directly in a VM terminal with --delete and the exact absolute paths.'
}

check_path() {
    local path="$1" resolved
    resolved=$(realpath -e -- "$path") || return 1
    if [[ "$path" != /* || "$resolved" != "$path" || ! -f "$path" || -L "$path" || "$path" != *.[mM][pP]3 ]]; then
        printf 'Refusing an invalid or noncanonical MP3 path: %q\n' "$path" >&2
        return 1
    fi
    if is_packaged "$path"; then
        printf 'Refusing to remove a Debian package file: %q\n' "$path" >&2
        return 1
    fi
}

delete_selected() {
    local path answer backup backup_file index=0
    local -a fingerprints=()
    if [[ ! -t 0 || ! -t 1 || $# -eq 0 ]]; then
        printf '%s\n' 'Use --delete with exact absolute MP3 paths in an interactive VM terminal.' >&2
        return 2
    fi
    if [[ $(id -u) != 0 ]]; then
        printf '%s\n' 'Run --delete with sudo so backups can be stored under /var/backups.' >&2
        return 2
    fi
    command -v dpkg-query >/dev/null

    for path in "$@"; do
        check_path "$path"
        fingerprints+=("$(stat -c '%d:%i:%s:%y:%z' -- "$path")")
    done
    printf '%s\n' 'Remove these files from their current locations? Private backups will be saved under /var/backups.'
    printf '  %q\n' "$@"
    printf '%s' 'Type DELETE to confirm: '
    if ! IFS= read -r answer || [[ "$answer" != DELETE ]]; then
        printf '%s\n' 'Cancelled.'
        return 0
    fi

    umask 077
    backup=$(mktemp -d /var/backups/cpats-mp3.XXXXXXXX)
    printf 'Backup directory: %s\n' "$backup"
    for path in "$@"; do
        check_path "$path"
        if [[ $(stat -c '%d:%i:%s:%y:%z' -- "$path") != "${fingerprints[index]}" ]]; then
            printf 'File changed since review: %q\n' "$path" >&2
            return 1
        fi
        backup_file="$backup/$((index + 1)).bak"
        cp -p -- "$path" "$backup_file"
        if [[ $(stat -c '%d:%i:%s:%y:%z' -- "$path") != "${fingerprints[index]}" ]]; then
            printf 'File changed during backup: %q\n' "$path" >&2
            return 1
        fi
        printf 'cp -p -- %q %q\n' "$backup_file" "$path" >> "$backup/restore.txt"
        rm -- "$path"
        printf 'Removed: %q\n' "$path"
        index=$((index + 1))
    done
}

case "${1:-}" in
    '') scan ;;
    --delete) shift; delete_selected "$@" ;;
    *) printf 'Usage: bash %s [--delete /absolute/file.mp3 ...]\n' "$0" >&2; exit 2 ;;
esac
