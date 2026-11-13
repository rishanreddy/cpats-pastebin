#!/usr/bin/env bash
# Remove only the seven non-work MP3s identified in the Debian VM report.
# Back up all remaining tracks before deleting any of them.
set -euo pipefail

dir='/home/ppotts/Music/Brandon Musser/Pure Piano Improv, Pt 2'
tracks=(
    '01-01- Ocean Motion.mp3'
    '01-02- Fall Festival.mp3'
    '01-03- Flight of the Humble Bee.mp3'
    '01-04- Tinker Bell s Dream.mp3'
    '01-05- Vertigo Delight.mp3'
    '01-06- Much Ado About Something.mp3'
    '01-07- Last Thoughts.mp3'
)

(( EUID == 0 )) || { printf '%s\n' 'Run this script with sudo.' >&2; exit 1; }
command -v dpkg-query >/dev/null

validate_file() {
    local file="$1" resolved
    resolved=$(realpath -e -- "$file") || return 1
    if [[ "$resolved" != "$file" || ! -f "$file" || -L "$file" ]]; then
        printf 'Refusing a nonregular file or redirected path: %q\n' "$file" >&2
        return 1
    fi
    if dpkg-query -S -- "$file" >/dev/null 2>&1; then
        printf 'Refusing a Debian package file: %q\n' "$file" >&2
        return 1
    fi
}

selected=()
for track in "${tracks[@]}"; do
    file="$dir/$track"
    if [[ -e "$file" || -L "$file" ]]; then
        validate_file "$file"
        selected+=("$track")
    fi
done

if (( ${#selected[@]} == 0 )); then
    printf '%s\n' 'None of the seven tracks are present.'
    exit 0
fi

umask 077
backup=$(mktemp -d /var/backups/cpats-prohibited-mp3.XXXXXXXX)
printf 'Private backup directory: %s\n' "$backup"
for track in "${selected[@]}"; do
    cp -a -- "$dir/$track" "$backup/$track"
    printf 'cp -an -- %q %q\n' "$backup/$track" "$dir/$track" >> "$backup/restore.txt"
done

for track in "${selected[@]}"; do
    file="$dir/$track"
    validate_file "$file"
    if ! cmp -s -- "$file" "$backup/$track"; then
        printf 'File changed after backup: %q\n' "$file" >&2
        exit 1
    fi
    rm -- "$file"
    printf 'Removed: %q\n' "$file"
done

for track in "${tracks[@]}"; do
    file="$dir/$track"
    if [[ -e "$file" || -L "$file" ]]; then
        printf 'Still present: %q\n' "$file" >&2
        exit 1
    fi
done
printf 'Verified: all seven tracks are absent from the album folder.\n'
printf 'Restore commands: %s/restore.txt\n' "$backup"
