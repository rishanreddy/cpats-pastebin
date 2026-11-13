#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY verification of the security-update source fix.
set -eu
export LC_ALL=C
printf '===== SECURITY-UPDATE SOURCE VERIFICATION =====\n'
awk '
    $1 == "deb" && /security\.debian\.org\/debian-security/ && /[[:space:]]bookworm-security[[:space:]]/ {
        print "PASS: active official bookworm-security source is configured"; found=1
    }
    END {if (!found) {print "FAIL: security source missing"; exit 1}}
' /etc/apt/sources.list
apt-cache policy 2>/dev/null | awk '
    /security\.debian\.org\/debian-security.*bookworm-security\/main/ {
        print "PASS: bookworm-security/main package index is loaded"; found=1
    }
    END {if (!found) {print "FAIL: security index missing"; exit 1}}
'
audit=$(dpkg --audit)
if [ -n "$audit" ]; then printf 'FAIL: package database requires attention\n'; exit 1; fi
printf 'PASS: package database has no incomplete package states\n'
for service in ssh lightdm ccsclient; do
    systemctl is-active --quiet "$service"
    printf 'PASS: %s is active\n' "$service"
done
printf 'Read-only verification complete. Actual score must be checked in the Desktop report.\n'
