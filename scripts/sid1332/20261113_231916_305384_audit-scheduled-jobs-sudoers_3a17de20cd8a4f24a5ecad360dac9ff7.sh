#!/usr/bin/env bash
# Read-only review of scheduled jobs and sudo privileges on Debian.
set -euo pipefail
export LC_ALL=C
shopt -s nullglob

printf '%s\n' '== Cron files (counts only) =='
for file in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/*; do
    [[ -f "$file" && -r "$file" ]] || continue
    printf '%q ' "$file"
    awk '
        /^[[:space:]]*(#|$)/ || /^[[:space:]]*[[:alnum:]_]+[[:space:]]*=/ { next }
        { jobs++ }
        tolower($0) ~ /(^|[[:space:]\/;&|])(curl|wget|ssh|scp|rsync|nc|ncat)([[:space:];&|]|$)/ { network++ }
        END { printf "jobs=%d network-tool-lines=%d\n", jobs, network }
    ' "$file"
done

printf '\n%s\n' '== Executable periodic cron entries =='
for file in /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; do
    [[ -f "$file" && -x "$file" ]] || continue
    owner=$(dpkg-query -S -- "$file" 2>/dev/null) || owner=''
    if [[ -n "$owner" ]]; then
        printf '%q (package-owned)\n' "$file"
    else
        printf '%q (no package owner found)\n' "$file"
    fi
done

printf '\n%s\n' '== Installed systemd timers =='
systemctl list-unit-files --type=timer --no-legend --no-pager || true
printf '\n%s\n' '== Active systemd timers =='
systemctl list-timers --all --no-legend --no-pager | awk '
    { for (i=1; i<=NF; i++) if ($i ~ /\.timer$/) { print $i, $(i+1); break } }
' || true

printf '\n%s\n' '== Sudoers validation =='
if visudo -c >/dev/null 2>&1; then
    printf '%s\n' 'Sudoers syntax, ownership, and permissions passed visudo.'
else
    printf '%s\n' 'Sudoers validation failed. Run sudo visudo -c locally for details.'
fi

printf '\n%s\n' '== Sudoers rules to review locally =='
for file in /etc/sudoers /etc/sudoers.d/*; do
    [[ -f "$file" && -r "$file" ]] || continue
    if [[ "$file" == /etc/sudoers.d/* ]]; then
        name="${file##*/}"
        [[ "$name" != *.* && "$name" != *~ ]] || continue
    fi
    awk '
        /^[[:space:]]*(#|$)/ { next }
        /NOPASSWD[[:space:]]*:[[:space:]]*ALL([[:space:],]|$)/ {
            printf "%s:%d broad passwordless grant candidate\n", FILENAME, FNR
        }
    ' "$file"
done

printf '\n%s\n' '== README standard users with a sudo policy grant =='
for user in bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
    getent passwd "$user" >/dev/null || continue
    if sudo -n -l -U "$user" >/dev/null 2>&1; then
        printf '%s has at least one sudo grant; review locally with sudo -l -U %s\n' "$user" "$user"
    fi
done
