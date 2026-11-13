#!/usr/bin/env bash
# Review and optionally remove the installed Freeciv packages on Debian.
set -euo pipefail
export LC_ALL=C

packages=()
for package in freeciv freeciv-client-gtk3 freeciv-data freeciv-server; do
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' -- "$package" 2>/dev/null) || continue
    if [[ "$status" == ii* ]]; then packages+=("$package"); fi
done

if (( ${#packages[@]} == 0 )); then
    printf '%s\n' 'No Freeciv packages from the inventory are installed.'
    exit 0
fi

printf '%s' 'Command: sudo apt-get remove --'
printf ' %q' "${packages[@]}"
printf '\n\n%s\n' 'APT preview:'
plan=$(apt-get --simulate remove -- "${packages[@]}")
printf '%s\n' "$plan"

while read -r action package rest; do
    [[ "$action" == Remv || "$action" == Purg ]] || continue
    case "$package" in
        freeciv|freeciv-client-gtk3|freeciv-data|freeciv-server) ;;
        *) printf 'Stopped: APT would also remove %s.\n' "$package" >&2; exit 1 ;;
    esac
done <<< "$plan"

if [[ ! -t 0 || ! -t 1 ]]; then
    printf '%s\n' 'Run this script directly in an interactive VM terminal to approve removal.'
    exit 0
fi

printf '\n%s' 'Freeciv is a possible sound source. Type REMOVE to approve the command above: '
if ! IFS= read -r answer || [[ "$answer" != REMOVE ]]; then
    printf '%s\n' 'Removal cancelled.'
    exit 0
fi
sudo apt-get remove -- "${packages[@]}"
