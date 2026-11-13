#!/usr/bin/env bash
# Inspect browser defaults and, if confirmed, show SSH and UFW status.
set -euo pipefail
export LC_ALL=C
(( EUID == 0 )) || { printf '%s\n' 'Run this audit as root.' >&2; exit 1; }

umask 077
dir=$(mktemp -d /var/tmp/cpats-browser-audit.XXXXXXXX)
report="$dir/report.txt"

audit() {
    local label="$1" mime response handler
    shift
    for mime in x-scheme-handler/http x-scheme-handler/https; do
        if response=$(timeout 5 "$@" gio mime "$mime" 2>/dev/null); then
            handler=$(awk '/^Default application for / { print $NF; exit }' <<< "$response")
            printf '%s %s: %q\n' "$label" "$mime" "${handler:-unresolved}"
            if [[ "$handler" != chromium.desktop ]]; then all_chromium=no; fi
        else
            printf '%s %s: query failed\n' "$label" "$mime"
            all_chromium=no
        fi
    done
}

(
    all_chromium=yes
    printf '%s\n' '== System defaults with no user overrides =='
    audit system env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
        HOME=/nonexistent XDG_CURRENT_DESKTOP=MATE
    printf 'Debian browser alternative: %s\n' "$(readlink -f /etc/alternatives/x-www-browser || true)"

    printf '\n%s\n' '== Authorized users: default handlers in a standard MATE environment =='
    for user in pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
        if ! entry=$(getent passwd "$user"); then
            printf '%s: account unavailable for browser check\n' "$user"
            all_chromium=no
            continue
        fi
        IFS=: read -r name placeholder uid gid gecos home shell <<< "$entry"
        audit "$user" runuser -u "$user" -- env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            LC_ALL=C HOME="$home" USER="$user" XDG_CURRENT_DESKTOP=MATE
    done

    if [[ "$all_chromium" == yes ]]; then
        printf '\n%s\n' '== SSH and firewall: compare the SSH port with UFW inbound rules =='
        systemctl is-active ssh.service || true
        /usr/sbin/sshd -T | awk '$1 == "port" {print "Configured SSH port:", $2}' || true
        ufw status verbose || true
    else
        printf '\n%s\n' 'SSH/UFW review deferred because at least one browser result needs review.'
    fi
) > "$report" 2>&1
printf 'Browser audit complete. Read the private report on the VM: sudo cat %q\n' "$report"
