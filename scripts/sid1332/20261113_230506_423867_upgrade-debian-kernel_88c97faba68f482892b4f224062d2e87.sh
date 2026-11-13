#!/usr/bin/env bash
# Install the reviewed Debian 12 security kernel, retaining the running kernel.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

. /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 12 || $(dpkg --print-architecture) != amd64 ]]; then
    printf '%s\n' 'This upgrade is for Debian 12 amd64 only.' >&2
    exit 1
fi
if (( EUID != 0 )); then
    printf '%s\n' 'Run this script as root.' >&2
    exit 1
fi

target='linux-image-amd64=6.1.190-1'
installed=$(dpkg-query -W -f='${Version}' linux-image-amd64)
printf 'Running kernel: %s\nInstalled metapackage: %s\n' "$(uname -r)" "$installed"
if dpkg --compare-versions "$installed" gt '6.1.190-1'; then
    printf '%s\n' 'A newer kernel metapackage is already installed.'
    exit 0
fi

apt=(apt-get --no-remove -o DPkg::Lock::Timeout=0 -o APT::Get::AutomaticRemove=false)
plan=$("${apt[@]}" --simulate install -- "$target")
printf '%s\n' "$plan"
while read -r action package rest; do
    case "$action" in
        Inst|Conf)
            case "${package%%:*}" in
                linux-image-amd64|linux-image-6.1.0-*-amd64) ;;
                *) printf 'Stopped: unexpected APT action %s for %s.\n' "$action" "$package" >&2; exit 1 ;;
            esac ;;
        Remv|Purg) printf 'Stopped: APT would remove %s.\n' "$package" >&2; exit 1 ;;
    esac
done <<< "$plan"

printf 'Command:'
printf ' %q' "${apt[@]}" --assume-yes install -- "$target"
printf '\n'
"${apt[@]}" --assume-yes install -- "$target" </dev/null

depends=$(dpkg-query -W -f='${Depends}' linux-image-amd64)
image="${depends%% *}"
if [[ "$image" != linux-image-6.1.0-*-amd64 ]]; then
    printf 'Unexpected kernel image dependency: %s\n' "$image" >&2
    exit 1
fi
[[ $(dpkg-query -W -f='${db:Status-Status} ${Version}' linux-image-amd64) == 'installed 6.1.190-1' ]]
[[ $(dpkg-query -W -f='${db:Status-Status}' "$image") == installed ]]
release="${image#linux-image-}"
[[ -s "/boot/vmlinuz-$release" && -s "/boot/initrd.img-$release" ]]
printf 'Verified installed kernel: %s\nRunning kernel: %s\n' "$release" "$(uname -r)"
printf '%s\n' 'Reboot when ready to start using the installed kernel.'
