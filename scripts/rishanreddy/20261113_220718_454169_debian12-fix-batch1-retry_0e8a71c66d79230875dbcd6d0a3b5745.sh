#!/usr/bin/env bash
# PURPOSE: apply the five changes explicitly approved by the user.
# CHANGES: remove bbanner/sstrange from sudo; prohibit SSH root and empty-password
# logins; disable LightDM guest login. Back up affected files, validate, reload SSH.
# No forensics files, user passwords, or home directories are read or changed.
set -Eeuo pipefail
export LC_ALL=C
umask 077
admins='pparker tstark ppotts hhogan nfury mhill pcoulson'
authorized="$admins bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter"
backup_dir=''
mutating=0
sshd_bin=/usr/sbin/sshd

has_sudo() {
    case " $(id -nG "$1") " in *' sudo '*) return 0 ;; *) return 1 ;; esac
}
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
rollback() {
    local status="$?" restore_ok=1
    trap - ERR INT TERM
    set +e
    if [ "$mutating" -eq 1 ]; then
        printf '\nValidation failed or execution interrupted. Restoring this batch\047s backups.\n'
        cp -a "$backup_dir/group" /etc/group || restore_ok=0
        cp -a "$backup_dir/gshadow" /etc/gshadow || restore_ok=0
        cp -a "$backup_dir/sshd_config" /etc/ssh/sshd_config || restore_ok=0
        cp -a "$backup_dir/lightdm.conf" /etc/lightdm/lightdm.conf || restore_ok=0
        if "$sshd_bin" -t >/dev/null 2>&1; then
            systemctl reload ssh || restore_ok=0
        else
            printf 'Restored SSH configuration failed validation; no reload attempted.\n'
            restore_ok=0
        fi
        if [ "$restore_ok" -eq 1 ]; then printf 'Backup files restored and SSH reloaded.\n';
        else printf 'RESTORE NEEDS ATTENTION. Backups: %s\n' "$backup_dir"; fi
    fi
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR
trap rollback INT TERM

printf '===== APPROVED BATCH 1: PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Run through the root runner or with sudo.'
grep -qx 'ID=debian' /etc/os-release || fail 'This batch is for Debian only.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
for tool in gpasswd visudo systemctl sed grep cp mkdir stat; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required existing tool missing: $tool"
done
[ -x "$sshd_bin" ] || fail 'sshd executable not found.'
for file in /etc/group /etc/gshadow /etc/ssh/sshd_config /etc/lightdm/lightdm.conf; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "Expected regular configuration file: $file"
done
for name in $admins; do has_sudo "$name" || fail "Authorized administrator lacks sudo before changes: $name"; done
for name in bbanner sstrange; do
    getent passwd "$name" >/dev/null || fail "Authorized account is missing: $name"
    [ "$(id -gn "$name")" != sudo ] || fail "Unexpected primary sudo group for $name; investigate first."
done
visudo -c >/dev/null 2>&1 || fail 'Existing sudo configuration is invalid.'
"$sshd_bin" -t >/dev/null 2>&1 || fail 'Existing SSH configuration is invalid.'
systemctl is-active --quiet ssh || fail 'SSH must already be active.'
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled as expected.'
if grep -qiE '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    fail 'Unexpected scoped SSH rules require review before this batch.'
fi
grep -qE '^[[:space:]]*allow-guest[[:space:]]*=' /etc/lightdm/lightdm.conf || fail 'Guest configuration moved; inspect before editing.'

printf '\n===== ROOT-ONLY BACKUPS =====\n'
backup_dir="/root/afa-batch1-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/group "$backup_dir/group"
cp -a /etc/gshadow "$backup_dir/gshadow"
cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config"
cp -a /etc/lightdm/lightdm.conf "$backup_dir/lightdm.conf"
printf 'Backup directory: %s\n' "$backup_dir"

printf '\n===== FIXES 1 AND 2: REMOVE UNAUTHORIZED SUDO MEMBERSHIPS =====\n'
mutating=1
for name in bbanner sstrange; do
    if has_sudo "$name"; then gpasswd -d "$name" sudo;
    else printf '%s is already outside sudo.\n' "$name"; fi
done

printf '\n===== FIXES 3 AND 4: SSH LOGIN POLICY =====\n'
for directive in PermitRootLogin PermitEmptyPasswords; do
    if grep -qiE "^[[:space:]]*$directive[[:space:]]" /etc/ssh/sshd_config; then
        sed -i -E "s/^[[:space:]]*$directive[[:space:]].*/$directive no/I" /etc/ssh/sshd_config
    else
        printf '\n%s no\n' "$directive" >> /etc/ssh/sshd_config
    fi
done

printf '\n===== FIX 5: DISABLE LIGHTDM GUEST LOGIN =====\n'
sed -i -E 's/^[[:space:]]*allow-guest[[:space:]]*=.*/allow-guest=false/' /etc/lightdm/lightdm.conf

printf '\n===== VALIDATION BEFORE SSH RELOAD =====\n'
visudo -c >/dev/null 2>&1 || fail 'Sudo validation failed.'
for name in $admins; do has_sudo "$name" || fail "Administrator lost sudo: $name"; done
for name in bbanner sstrange; do
    if has_sudo "$name"; then fail "Unexpected sudo membership remains: $name"; fi
    getent passwd "$name" >/dev/null || fail "Authorized account missing after change: $name"
done
"$sshd_bin" -t >/dev/null 2>&1 || fail 'SSH syntax validation failed.'
for name in $authorized; do
    effective=$("$sshd_bin" -T -C "user=$name,host=debian,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null)
    # Consume all output: grep -q can close a pipe early and make printf return
    # SIGPIPE under pipefail, producing a false validation failure.
    printf '%s\n' "$effective" | grep -x 'permitrootlogin no' >/dev/null || fail "Root-login policy is overridden for $name"
    printf '%s\n' "$effective" | grep -x 'permitemptypasswords no' >/dev/null || fail "Empty-password policy is overridden for $name"
    printf '%s\n' "$effective" | grep -x 'passwordauthentication yes' >/dev/null || fail "Password SSH login would be unavailable for $name"
    printf '%s\n' "$effective" | grep -x 'usepam yes' >/dev/null || fail "Unexpected PAM setting for $name"
    if printf '%s\n' "$effective" | grep -qE '^(allowusers|allowgroups|denyusers|denygroups) '; then
        fail "Unexpected SSH access restrictions for $name require manual review."
    fi
done
grep -qx 'allow-guest=false' /etc/lightdm/lightdm.conf || fail 'LightDM guest setting did not apply.'
printf 'Sudo policy, seven administrators, twenty accounts, and SSH settings validated.\n'

printf '\n===== RELOAD SSH AND CHECK REQUIRED SERVICES =====\n'
systemctl reload ssh
systemctl is-active --quiet ssh || fail 'SSH is inactive after reload.'
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is no longer enabled.'
systemctl is-active --quiet lightdm || fail 'LightDM is unexpectedly inactive.'
systemctl is-active --quiet ccsclient || fail 'CCS Client is unexpectedly inactive.'

printf '\n===== RESULT =====\n'
getent group sudo
"$sshd_bin" -T 2>/dev/null | grep -E '^(permitrootlogin|permitemptypasswords|passwordauthentication|usepam) '
grep -E '^[[:space:]]*allow-guest[[:space:]]*=' /etc/lightdm/lightdm.conf
printf 'SSH is enabled and active. LightDM and CCS Client are active.\n'
printf 'LightDM was not restarted. Guest policy applies to subsequent login screens.\n'
printf 'Existing user sessions may retain cached group membership until next login.\n'
printf 'Backups for undo: %s\n' "$backup_dir"
printf 'Undo: restore group, gshadow, sshd_config, and lightdm.conf to their original paths; validate SSH, then reload ssh.\n'
printf 'Five approved fixes applied. Check the scoring report for actual points.\n'
mutating=0
trap - ERR INT TERM
