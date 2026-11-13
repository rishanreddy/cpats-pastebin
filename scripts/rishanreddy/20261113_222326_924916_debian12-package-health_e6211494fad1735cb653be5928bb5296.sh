#!/usr/bin/env bash
# PURPOSE: READ-ONLY check after the batch-2 package-install timeout and rollback.
# No forensics files or process arguments are read.
set -u
export LC_ALL=C
printf '===== PACKAGE-MANAGER PROCESS STATE, ARGUMENTS OMITTED =====\n'
ps -eo pid=,ppid=,stat=,etime=,time=,comm= | awk '$6 ~ /^(apt|apt-get|dpkg|mandb|dpkg-deb|dpkg-trigger|timeout)$/ {print}'
printf '\n===== PACKAGE DATABASE AUDIT =====\n'
audit=$(dpkg --audit 2>&1)
status=$?
printf 'dpkg audit exit code: %s\n' "$status"
if [ -n "$audit" ]; then printf '%s\n' "$audit"; else printf 'No incomplete package states reported.\n'; fi
printf '\n===== RELEVANT PACKAGE STATES =====\n'
dpkg-query -W -f='${Package} ${db:Status-Abbrev} ${Version}\n' ufw iptables libip6tc2 man-db chromium openssh-server sudo 2>/dev/null || true
printf '\n===== SOURCE HOST AND SUITE SUMMARY =====\n'
awk '
    $1=="deb" || $1=="deb-src" {
        for(i=2;i<=NF;i++) if($i ~ /:\/\//) {
            host=$i; sub(/^[^:]*:\/\//,"",host); sub(/\/.*/,"",host); sub(/^.*@/,"",host)
            print "Host:",host,"Suite:",$(i+1)
        }
    }
' /etc/apt/sources.list
printf '\n===== REQUIRED SERVICES AND FTP =====\n'
for service in ssh lightdm ccsclient vsftpd; do
    printf '%s active: ' "$service"; systemctl is-active "$service" 2>/dev/null || true
done
printf '\nREAD-ONLY package health check complete.\n'
