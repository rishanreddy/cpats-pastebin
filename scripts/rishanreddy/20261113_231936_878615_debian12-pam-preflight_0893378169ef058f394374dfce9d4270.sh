#!/usr/bin/env bash
# PURPOSE: READ-ONLY preflight for approved Debian 12 PAM hardening.
# No hashes, passwords, forensics, or kernel settings are read or printed.
set -u
export LC_ALL=C
printf '===== PASSWORD QUALITY AND DICTIONARY INSTALL PLAN, SIMULATION ONLY =====\n'
apt-get -s -o Debug::NoLocking=1 --no-install-recommends install libpam-pwquality cracklib-runtime wamerican 2>/dev/null |
    awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
printf '\n===== SUPPORTED EXISTING PASSWORD-HISTORY MODULE =====\n'
dpkg-query -L libpam-modules 2>/dev/null | grep '/pam_pwhistory\.so$' || true
printf '\n===== EXISTING UNIX PAM PROFILE, PASSWORD SECTION =====\n'
awk '/^Password/ {show=1} /^[A-Za-z].*:/ && !/^Password/ {show=0} show {print}' /usr/share/pam-configs/unix
printf '\n===== ACTIVE PASSWORD STACK, SAFE KNOWN MODULES ONLY =====\n'
awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    /pam_(unix|deny|permit|gnome_keyring|pwquality|pwhistory)\.so/ {print}
' /etc/pam.d/common-password
printf '\n===== EXISTING AFA PROFILE NAMES =====\n'
for file in /usr/share/pam-configs/afa-pwquality /usr/share/pam-configs/afa-pwhistory; do
    [ ! -e "$file" ] || printf 'EXISTS: %s\n' "$file"
done
printf '\n===== PAM CACHE AND HISTORY FILE METADATA ONLY =====\n'
for file in /var/lib/pam /etc/security/opasswd; do
    [ ! -e "$file" ] || stat -c '%a %U:%G %n' "$file"
done
printf '\n===== REQUIRED SERVICES =====\n'
systemctl is-active ssh lightdm ccsclient 2>/dev/null || true
printf '\nRead-only PAM preflight complete.\n'
