#!/usr/bin/env bash
# PURPOSE: apply the three account/FTP changes explicitly approved by the user.
# CHANGES: remove brumlow and azola login accounts WITHOUT deleting homes;
# stop and disable vsftpd. No package, repository, password-policy, or forensics work.
set -Eeuo pipefail
export LC_ALL=C
umask 077
admins='pparker tstark ppotts hhogan nfury mhill pcoulson'
authorized="$admins bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter"
backup_dir=''
accounts_changed=0
ftp_changed=0
ftp_was_enabled=''
ftp_was_active=0
brumlow_home_before=''
azola_home_before=''
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
has_sudo() { case " $(id -nG "$1") " in *' sudo '*) return 0 ;; *) return 1 ;; esac; }
home_identity() { if [ -e "$1" ] || [ -L "$1" ]; then stat -c '%d:%i:%u:%g:%a' "$1"; else printf 'absent\n'; fi; }
rollback() {
    local status="$?" ok=1 file name
    trap - ERR INT TERM
    set +e
    printf '\nBatch failed or was interrupted. Restoring the saved account/service state.\n'
    if [ "$accounts_changed" -eq 1 ]; then
        for file in passwd shadow group gshadow subuid subgid; do
            [ ! -f "$backup_dir/$file" ] || cp -a "$backup_dir/$file" "/etc/$file" || ok=0
        done
        for name in brumlow azola; do
            if [ -f "$backup_dir/cron-$name" ]; then
                cp -a "$backup_dir/cron-$name" "/var/spool/cron/crontabs/$name" || ok=0
            fi
            if [ -f "$backup_dir/mail-$name" ]; then
                cp -a "$backup_dir/mail-$name" "/var/mail/$name" || ok=0
            fi
        done
    fi
    if [ "$ftp_changed" -eq 1 ]; then
        if [ "$ftp_was_enabled" = enabled ]; then systemctl enable vsftpd || ok=0; fi
        if [ "$ftp_was_active" -eq 1 ]; then systemctl start vsftpd || ok=0; fi
    fi
    if [ "$ok" -eq 1 ]; then printf 'Saved account databases and service state restored.\n';
    else printf 'ROLLBACK NEEDS ATTENTION. Private backups: %s\n' "$backup_dir"; fi
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Root runner or sudo is required.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
for tool in userdel getent id ps stat cp mkdir systemctl visudo; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required existing tool missing: $tool"
done
for file in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "Expected regular account database: $file"
done
for name in $authorized; do getent passwd "$name" >/dev/null || fail "Authorized account is missing before changes: $name"; done
for name in $admins; do has_sudo "$name" || fail "Authorized administrator lacks sudo: $name"; done
visudo -c >/dev/null 2>&1 || fail 'Existing sudo configuration does not validate.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service is inactive: $service"; done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH must remain enabled.'
# A configured userdel hook can perform additional deletions outside this approval.
if grep -Eq '^[[:space:]]*USERDEL_(CMD|PRECMD|POSTCMD)[[:space:]]' /etc/login.defs /etc/default/useradd 2>/dev/null; then
    fail 'Custom userdel hook requires review before account removal.'
fi
for name in brumlow azola; do
    entry=$(getent passwd "$name" 2>/dev/null || true)
    [ -n "$entry" ] || continue
    uid=$(printf '%s\n' "$entry" | awk -F: '{print $3}')
    home=$(printf '%s\n' "$entry" | awk -F: '{print $6}')
    case "$name:$uid:$home" in
        brumlow:1011:/home/brumlow|azola:1020:/home/azola) ;;
        *) fail "Unexpected account identity or home path: $name" ;;
    esac
    running=$(ps -u "$uid" -o pid= 2>/dev/null || true)
    [ -z "$running" ] || fail "Account has running processes; no forced removal attempted: $name"
done
brumlow_home_before=$(home_identity /home/brumlow)
azola_home_before=$(home_identity /home/azola)
ftp_was_enabled=$(systemctl is-enabled vsftpd 2>/dev/null || true)
if systemctl is-active --quiet vsftpd; then ftp_was_active=1; fi

printf '\n===== PRIVATE BACKUPS =====\n'
backup_dir="/root/afa-accounts-ftp-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
for file in passwd shadow group gshadow subuid subgid; do
    [ ! -f "/etc/$file" ] || cp -a "/etc/$file" "$backup_dir/$file"
done
for name in brumlow azola; do
    if [ -f "/var/spool/cron/crontabs/$name" ]; then cp -a "/var/spool/cron/crontabs/$name" "$backup_dir/cron-$name"; fi
    if [ -f "/var/mail/$name" ]; then cp -a "/var/mail/$name" "$backup_dir/mail-$name"; fi
done
if [ -f /etc/vsftpd.conf ]; then cp -a /etc/vsftpd.conf "$backup_dir/vsftpd.conf"; fi
printf 'ftp_was_enabled=%s\nftp_was_active=%s\n' "$ftp_was_enabled" "$ftp_was_active" > "$backup_dir/initial-state.txt"
printf 'Backup directory: %s\n' "$backup_dir"

printf '\n===== FIXES 1 AND 2: REMOVE UNAUTHORIZED LOGIN ACCOUNTS =====\n'
accounts_changed=1
for name in brumlow azola; do
    if getent passwd "$name" >/dev/null; then
        userdel -- "$name"
        printf 'Removed login account %s, without the home-removal option.\n' "$name"
    else printf '%s was already absent.\n' "$name"; fi
    if getent passwd "$name" >/dev/null; then fail "Account is still present: $name"; fi
done
[ "$(home_identity /home/brumlow)" = "$brumlow_home_before" ] || fail 'brumlow home metadata changed unexpectedly.'
[ "$(home_identity /home/azola)" = "$azola_home_before" ] || fail 'azola home metadata changed unexpectedly.'

printf '\n===== FIX 3: STOP AND DISABLE FTP =====\n'
ftp_changed=1
systemctl disable --now vsftpd
if systemctl is-active --quiet vsftpd; then fail 'vsftpd is still active.'; fi
if [ "$(systemctl is-enabled vsftpd 2>/dev/null || true)" = enabled ]; then fail 'vsftpd is still enabled.'; fi

printf '\n===== VALIDATE AUTHORIZED ACCESS AND REQUIRED SERVICES =====\n'
for name in $authorized; do getent passwd "$name" >/dev/null || fail "Authorized account is missing: $name"; done
for name in $admins; do has_sudo "$name" || fail "Authorized administrator lost sudo: $name"; done
visudo -c >/dev/null 2>&1 || fail 'Sudo policy validation failed.'
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'SSH configuration validation failed.'
for service in ssh lightdm ccsclient; do
    systemctl is-active --quiet "$service" || fail "Required service is inactive: $service"
done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled.'
listeners=$(ss -tln)
if printf '%s\n' "$listeners" | awk 'NR>1 && $4 ~ /:21$/ {found=1} END {exit !found}'; then fail 'FTP port 21 still has a listener.'; fi
printf '%s\n' "$listeners" | awk 'NR>1 && $4 ~ /:22$/ {found=1} END {exit !found}' || fail 'SSH port 22 is not listening.'
printf 'Both unauthorized accounts are absent; existing home paths and ownership are preserved.\n'
printf 'All twenty authorized accounts exist, and all seven authorized administrators retain sudo.\n'
printf 'FTP is disabled/inactive, and port 21 has no listener. SSH remains enabled and listening.\n'
printf 'SSH, LightDM, and CCS Client are active. No package or repository changes were made.\n'
printf 'Private backups for undo: %s\n' "$backup_dir"
printf 'Undo: restore the saved account databases and original FTP enablement/running state.\n'
trap - ERR INT TERM
