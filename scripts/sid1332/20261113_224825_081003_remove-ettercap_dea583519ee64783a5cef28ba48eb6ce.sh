#!/usr/bin/env bash
# Remove the two reviewed Ettercap packages on Debian without an interactive terminal.
set -euo pipefail
export LC_ALL=C

packages=()
for package in ettercap-graphical ettercap-common; do
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' -- "$package" 2>/dev/null) || continue
    if [[ "$status" == ii* ]]; then packages+=("$package"); fi
done

if (( ${#packages[@]} == 0 )); then
    printf '%s\n' 'No reviewed Ettercap packages are installed.'
    exit 0
fi

apt=(env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -o APT::Get::AutomaticRemove=false -o APT::Get::Purge=false -o APT::Get::Upgrade=false -o APT::Get::No-New-Install=true)
if (( EUID != 0 )); then apt=(sudo -n "${apt[@]}"); fi
printf '%s' 'Command:'
printf ' %q' "${apt[@]}" --assume-yes remove -- "${packages[@]}"
printf '\n\n%s\n' 'APT preview:'
plan=$("${apt[@]}" --simulate remove -- "${packages[@]}")
printf '%s\n' "$plan"

while read -r action package rest; do
    case "$action" in
        Remv)
            case "${package%%:*}" in
                ettercap-graphical|ettercap-common) ;;
                *) printf 'Stopped: APT would also remove %s.\n' "$package" >&2; exit 1 ;;
            esac ;;
        Inst|Conf|Purg)
            printf 'Stopped: unexpected APT action %s for %s.\n' "$action" "$package" >&2
            exit 1 ;;
    esac
done <<< "$plan"

printf '%s' 'To reinstall if needed: sudo apt-get install --'
printf ' %q' "${packages[@]}"
printf '\n'
"${apt[@]}" --assume-yes remove -- "${packages[@]}" </dev/null

for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' -- "$package" 2>/dev/null) || continue
    if [[ "$status" == ii* ]]; then
        printf 'Still installed: %s\n' "$package" >&2
        exit 1
    fi
done
printf '%s\n' 'Verified: the selected Ettercap packages are no longer installed.'
