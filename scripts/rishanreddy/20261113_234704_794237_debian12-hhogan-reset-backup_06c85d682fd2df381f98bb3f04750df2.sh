#!/usr/bin/env bash
# PURPOSE: prepare a fresh private backup for the approved local hhogan reset.
# CHANGES: root-only backup files. This script does not set or print a password.
set -euo pipefail
export LC_ALL=C
umask 077
[ "$(id -u)" -eq 0 ] || { printf 'Root runner required.\n'; exit 1; }
entry=$(getent passwd hhogan)
printf '%s\n' "$entry" | awk -F: '$1=="hhogan" && $3==1004 && $6=="/home/hhogan" {ok=1} END {exit !ok}'
case " $(id -nG hhogan) " in *' sudo '*) ;; *) printf 'Unexpected administrator membership; inspect first.\n'; exit 1 ;; esac
printf '===== PRIVATE PRE-RESET BACKUP =====\n'
backup_dir="/root/afa-hhogan-reset-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/shadow "$backup_dir/shadow.before"
if [ -f /etc/security/opasswd ]; then cp -a /etc/security/opasswd "$backup_dir/opasswd.before"; fi
passwd -S hhogan > "$backup_dir/hhogan-status.before"
chage -l hhogan > "$backup_dir/hhogan-aging.before"
printf 'Private backup directory: %s\n' "$backup_dir"
printf 'Current metadata only, no password or hash:\n'
passwd -S hhogan
printf '\nThe password has not been changed by this script.\n'
printf 'Run locally in another VM terminal: sudo passwd hhogan\n'
printf 'Enter a new unique password at the hidden prompts, at least 14 characters with upper/lower/digit/symbol.\n'
printf 'Do not put it in chat, a script, a clipboard upload, or shell arguments.\n'
printf 'If undo is necessary, restore only hhogan credential/last-change fields from the private backup, not the entire shadow/history file.\n'
