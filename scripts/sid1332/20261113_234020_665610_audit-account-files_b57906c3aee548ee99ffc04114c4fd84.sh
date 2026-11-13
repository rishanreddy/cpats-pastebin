#!/usr/bin/env bash
# Check account file metadata and UID/GID 0 assignments. Keep findings on the VM.
set -euo pipefail
export LC_ALL=C
(( EUID == 0 )) || { printf '%s\n' 'Run as root.' >&2; exit 1; }

umask 077
dir=$(mktemp -d /var/tmp/cpats-account-audit.XXXXXXXX)
report="$dir/report.txt"
status=0
{
    printf '%s\n' '== Account file permissions and ownership =='
    stat -c '%a %U:%G %n' /etc/passwd /etc/group /etc/shadow /etc/gshadow || status=1

    printf '\n%s\n' '== Accounts with UID 0 =='
    getent passwd | awk -F: '$3 == "0" {print $1, "UID 0"}' || status=1

    printf '\n%s\n' '== Groups with GID 0 =='
    getent group | awk -F: '$3 == "0" {print $1, "GID 0"}' || status=1
} >"$report" 2>&1

if (( status == 0 )); then
    printf 'Account audit complete. Read the private report on the VM: sudo cat %q\n' "$report"
else
    printf 'Account audit incomplete. Read the private report on the VM: sudo cat %q\n' "$report" >&2
fi
exit "$status"
