#!/usr/bin/env bash
# PURPOSE: READ-ONLY readiness check for the approved Chromium-only upgrade.
# No browser profiles or process arguments are printed.
set -u
export LC_ALL=C
printf '===== CHROMIUM PROCESS NAMES, ARGUMENTS OMITTED =====\n'
ps -eo user=,comm= | awk '$2 == "chromium" {print; n++} END {printf "Chromium processes: %d\n",n}'
printf '\n===== ROOT FILESYSTEM SPACE =====\n'
df -Pk /root
printf '\n===== PROFILE BACKUP SIZES, CONTENTS OMITTED =====\n'
for name in pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
    profile="/home/$name/.config/chromium"
    [ ! -d "$profile" ] || du -sk "$profile" 2>/dev/null || true
done
printf '\n===== PACKAGE DATABASE HEALTH =====\n'
audit=$(dpkg --audit)
if [ -z "$audit" ]; then printf 'No incomplete package states.\n'; else printf 'Incomplete package state requires review before upgrade.\n'; fi
printf 'Read-only readiness check complete.\n'
