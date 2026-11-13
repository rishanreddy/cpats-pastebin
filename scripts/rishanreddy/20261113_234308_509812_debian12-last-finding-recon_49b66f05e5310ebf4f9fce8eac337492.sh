#!/usr/bin/env bash
# PURPOSE: READ-ONLY account and scheduled/startup-task assessment for the last issue.
# No passwords/hashes, raw job commands, process arguments, forensics, or kernel settings.
set -u
export LC_ALL=C
printf '===== CANDIDATE ACCOUNT PASSWORD METADATA =====\n'
passwd -S hhogan 2>/dev/null || true
printf '\n===== CENTRAL CRON AND STARTUP REVIEW, INDICATORS ONLY =====\n'
inspect() {
    local file="$1"
    [ -f "$file" ] && [ -r "$file" ] || return 0
    awk -v path="$file" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            active++
            lower=tolower($0)
            flags=""
            if(lower ~ /curl|wget|https?:\/\//) flags=flags " network-fetch"
            if(lower ~ /\/dev\/tcp|netcat|(^|[[:space:]])nc[[:space:]]/) flags=flags " network-shell"
            if(lower ~ /base64|[[:space:]]-enc[[:space:]]/) flags=flags " encoded-command"
            if(lower ~ /poll|maintenance|remote.?manage/) flags=flags " polling-maintenance"
            if(lower ~ /useradd|usermod|passwd|authorized_keys|chmod.*[+][s]/) flags=flags " account-or-privilege-change"
            if(flags!="") {print path ":" NR ":" flags " [command omitted]"; suspicious++}
        }
        END {print path ": active-lines=" active+0 ", flagged-lines=" suspicious+0}
    ' "$file"
}
inspect /etc/crontab
inspect /etc/rc.local
for file in /etc/cron.d/* /var/spool/cron/crontabs/* /home/*/.config/autostart/*.desktop; do
    [ -f "$file" ] || continue
    inspect "$file"
done
printf '\n===== ENABLED SERVICE/TIMER NAMES MATCHING MAINTENANCE/POLLING =====\n'
systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
    awk 'tolower($1) ~ /poll|maint|puppet|salt|ansible|chef|cfengine|cron|apt.*timer/ {print $1,$2}'
printf '\n===== AUTOMATIC-UPDATE CONFIGURATION, SELECTED NUMERIC SETTINGS =====\n'
apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade|Download-Upgradeable-Packages)[[:space:]]+"[0-9]+";' || true
printf '\n===== OTHER AUTHORIZED USERS WITH EMPTY PASSWORD STATUS =====\n'
for name in pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
    status=$(passwd -S "$name" 2>/dev/null || true)
    printf '%s\n' "$status" | awk '$2=="NP" {print $1,"has no password"}'
done
printf '\nRead-only assessment complete. No jobs, settings, or passwords changed.\n'
