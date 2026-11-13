#!/usr/bin/env bash
# PURPOSE: READ-ONLY current-state check for the next proposed accounts/FTP batch.
# No forensics files, credential contents, or process arguments are read.
set -u
export LC_ALL=C
printf '===== CURRENT OBSERVATION TIME =====\n'
date -u '+%Y-%m-%d %H:%M:%S UTC'
printf '\n===== ACCOUNTS ABSENT FROM THE AUTHORIZED LIST =====\n'
for name in brumlow azola; do
    entry=$(getent passwd "$name" 2>/dev/null || true)
    if [ -z "$entry" ]; then printf '%s is already absent.\n' "$name"; continue; fi
    printf '%s\n' "$entry" | awk -F: '{print $1,"uid=" $3,"gid=" $4,"home=" $6,"shell=" $7}'
    id "$name" 2>/dev/null || true
    printf 'Running executable names owned by this account, arguments omitted:\n'
    ps -u "$name" -o pid=,stat=,comm= 2>/dev/null || true
done
printf '\n===== FTP AND REQUIRED SERVICES =====\n'
for service in vsftpd ssh lightdm ccsclient; do
    printf '%s active: ' "$service"; systemctl is-active "$service" 2>/dev/null || true
    printf '%s enabled: ' "$service"; systemctl is-enabled "$service" 2>/dev/null || true
done
ss -tln 2>/dev/null | awk 'NR==1 || $4 ~ /:(21|22)$/ {print}'
printf '\n===== SECURITY SOURCE STILL PRESENT =====\n'
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then
    printf 'Official bookworm-security source remains configured.\n'
else printf 'Security source missing; investigate before changes.\n'; fi
printf '\nRead-only check complete. No accounts or services changed.\n'
