#!/usr/bin/env bash
# PURPOSE: restore official Debian 12 security-update sources after batch-2 rollback.
# CHANGES: /etc/apt/sources.list and refreshed APT index caches only.
# Does not install, upgrade, downgrade, or remove packages. No forensics work.
set -euo pipefail
export LC_ALL=C
umask 077
printf '===== TARGETED SECURITY-UPDATE SOURCE RESTORE =====\n'
[ "$(id -u)" -eq 0 ] || { printf 'Root runner required.\n'; exit 1; }
grep -qx 'ID=debian' /etc/os-release
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release
[ -f /etc/apt/sources.list ] && [ ! -L /etc/apt/sources.list ]
[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]
for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -r "$file" ] || continue
    if grep -Eq '^[[:space:]]*(deb[[:space:]]|deb-src[[:space:]]|Types:)' "$file"; then
        printf 'Additional repository definitions require review before this targeted restore.\n'
        exit 1
    fi
done
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then
    printf 'Before: bookworm-security is already listed.\n'
else
    printf 'Before: bookworm-security is missing from the restored original source file.\n'
fi
backup_dir="/root/afa-security-source-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/apt/sources.list "$backup_dir/sources.list.before"
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' \
    > "$backup_dir/sources.list.corrected"
cp "$backup_dir/sources.list.corrected" /etc/apt/sources.list
chmod 644 /etc/apt/sources.list
printf 'Configured official bookworm, bookworm-updates, and bookworm-security sources.\n'
printf 'Source backup: %s/sources.list.before\n' "$backup_dir"

printf '\n===== REFRESH INDEXES, NO PACKAGE INSTALLATION =====\n'
refresh_status=0
timeout 300 apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update || refresh_status=$?
if [ "$refresh_status" -ne 0 ]; then
    printf 'Index refresh failed with code %s. Correct official source configuration is retained.\n' "$refresh_status"
    printf 'No installed packages were changed.\n'
    exit "$refresh_status"
fi

printf '\n===== VERIFY SECURITY INDEX AND REQUIRED SERVICES =====\n'
apt-cache policy 2>/dev/null | awk '/security\.debian\.org\/debian-security.*bookworm-security/ {print; found=1} END {exit !found}'
for service in ssh lightdm ccsclient; do
    printf '%s: ' "$service"
    systemctl is-active "$service"
done
printf '\nInstalled approved-software versions, unchanged by this script:\n'
dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' openssh-server sudo chromium
printf '\nOfficial security-update source restored and package indexes refreshed.\n'
printf 'No packages or services were installed, removed, downgraded, upgraded, stopped, or restarted.\n'
printf 'Refresh the normal Desktop Scoring Report to check the five-point item.\n'
