#!/usr/bin/env bash
# PURPOSE: apply the user-approved Debian 12 PAM hardening.
# CHANGES: install password-quality/dictionary support; enforce quality and history
# for future password changes; remove pam_unix nullok from common-auth.
# Existing passwords, account aging, kernel settings, and delegated work are untouched.
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077
authorized='pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
backup_dir=''
mutating=0
install_attempted=0
quality_was_installed=0
quality_profile_created=0
history_profile_created=0
profiles_before=''
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
quality_installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' libpam-pwquality 2>/dev/null || true)" = installed ]; }
module_present() {
    local module="$1" file
    for file in "/lib/security/$module" "/usr/lib/security/$module" /lib/*/security/"$module" /usr/lib/*/security/"$module"; do
        [ ! -r "$file" ] || return 0
    done
    return 1
}
save_status() { local name; for name in $authorized; do passwd -S "$name"; done; }
rollback() {
    local status="$?" ok=1
    trap - ERR INT TERM
    set +e
    if [ "$mutating" -eq 1 ]; then
        printf '\nPAM validation failed or execution was interrupted. Restoring the original stacks.\n'
        if [ "$quality_profile_created" -eq 1 ] || [ "$history_profile_created" -eq 1 ]; then
            pam-auth-update --package --remove afa-pwquality afa-pwhistory >/dev/null 2>&1 || true
        fi
        cp -a "$backup_dir/pam.d/." /etc/pam.d/ || ok=0
        if [ "$quality_profile_created" -eq 1 ]; then rm -- /usr/share/pam-configs/afa-pwquality || ok=0; fi
        if [ "$history_profile_created" -eq 1 ]; then rm -- /usr/share/pam-configs/afa-pwhistory || ok=0; fi
        if [ "$install_attempted" -eq 1 ] && [ "$quality_was_installed" -eq 0 ] && quality_installed; then
            apt-get -o DPkg::Lock::Timeout=120 -y remove libpam-pwquality || ok=0
        fi
        # Package removal may regenerate common-*; restore originals afterwards too.
        cp -a "$backup_dir/pam.d/." /etc/pam.d/ || ok=0
        if [ -d "$backup_dir/var-lib-pam" ]; then cp -a "$backup_dir/var-lib-pam/." /var/lib/pam/ || ok=0; fi
        printf 'SET libpam-runtime/profiles %s\n' "$profiles_before" | debconf-communicate libpam-runtime >/dev/null 2>&1 || ok=0
        if [ -f "$backup_dir/pwquality.conf.before" ]; then
            cp -a "$backup_dir/pwquality.conf.before" /etc/security/pwquality.conf || ok=0
        elif [ -f /etc/security/pwquality.conf ]; then
            mv /etc/security/pwquality.conf "$backup_dir/pwquality.conf.after-failed-batch" || ok=0
        fi
        if [ "$ok" -eq 1 ]; then printf 'Original PAM configuration restored. Support libraries/dictionaries may remain installed.\n';
        else printf 'PAM RESTORE NEEDS ATTENTION. Private backups: %s\n' "$backup_dir"; fi
    else printf '\nStopped before changing PAM.\n'; fi
    systemctl is-active ssh lightdm ccsclient 2>/dev/null || true
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== PAM HARDENING PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Root runner required.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
for tool in apt-get dpkg-query pam-auth-update debconf-communicate awk sed cmp stat sha256sum; do command -v "$tool" >/dev/null || fail "Existing tool missing: $tool"; done
for file in /etc/pam.d/common-password /etc/pam.d/common-auth; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "Expected regular PAM configuration: $file"
done
module_present pam_pwhistory.so || fail 'Supported password-history module is missing.'
[ -f /etc/security/opasswd ] && [ ! -L /etc/security/opasswd ] || fail 'Expected existing regular password-history file.'
[ "$(stat -c '%a:%u:%g' /etc/security/opasswd)" = 600:0:0 ] || fail 'Password-history file needs separate permission review.'
audit=$(dpkg --audit)
[ -z "$audit" ] || fail 'Package database has incomplete work.'
for name in $authorized; do
    status=$(passwd -S "$name" | awk '{print $2}')
    [ "$status" = P ] || fail "Authorized account is not password-ready before changes: $name"
done
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'Existing SSH configuration does not validate.'
sources_before=$(sha256sum /etc/apt/sources.list)
if quality_installed; then quality_was_installed=1; fi
selection=$(printf 'GET libpam-runtime/profiles\n' | debconf-communicate libpam-runtime)
case "$selection" in '0 '*) profiles_before=${selection#0 } ;; *) fail 'Could not save current PAM profile selections.' ;; esac

printf '\n===== PRIVATE CONFIGURATION BACKUPS =====\n'
backup_dir="/root/afa-pam-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/pam.d "$backup_dir/pam.d"
cp -a /usr/share/pam-configs "$backup_dir/pam-configs"
if [ -d /var/lib/pam ]; then cp -a /var/lib/pam "$backup_dir/var-lib-pam"; fi
if [ -f /etc/security/pwquality.conf ]; then cp -a /etc/security/pwquality.conf "$backup_dir/pwquality.conf.before"; fi
if [ -d /etc/security/pwquality.conf.d ]; then cp -a /etc/security/pwquality.conf.d "$backup_dir/pwquality.conf.d.before"; fi
cp -a /etc/security/opasswd "$backup_dir/opasswd.before"
printf '%s\n' "$profiles_before" > "$backup_dir/profile-selection.before"
save_status > "$backup_dir/password-status.before"
printf 'Private backup directory: %s\n' "$backup_dir"

printf '\n===== INSTALL SUPPORTED PASSWORD QUALITY AND DICTIONARIES =====\n'
plan=$(apt-get -s -o Debug::NoLocking=1 --no-install-recommends install libpam-pwquality cracklib-runtime wamerican)
printf '%s\n' "$plan" | awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
if printf '%s\n' "$plan" | grep -E '^Remv |^Inst [^ ]+ \[' >/dev/null; then fail 'Install plan would remove or upgrade existing packages.'; fi
while IFS= read -r package; do
    case "${package%%:*}" in libpam-pwquality|libpwquality1|libpwquality-common|libcrack2|cracklib-runtime|wamerican) ;;
        *) fail "Unexpected package in plan: $package" ;;
    esac
done < <(printf '%s\n' "$plan" | awk '/^Inst / {print $2}')
mutating=1
install_attempted=1
apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 --no-install-recommends -y install libpam-pwquality cracklib-runtime wamerican
module_present pam_pwquality.so || fail 'Installed password-quality module is missing.'
for extension in pwd pwi hwm; do
    [ -s "/var/cache/cracklib/cracklib_dict.$extension" ] || fail "Cracklib dictionary component missing: $extension"
done

printf '\n===== STAGE MODERN PAM PASSWORD PROFILES =====\n'
printf '%s\n' \
    'Name: AFA password quality' 'Default: yes' 'Priority: 1024' 'Password-Type: Primary' \
    'Password:' \
    ' requisite pam_pwquality.so retry=3 minlen=14 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 enforce_for_root' \
    'Password-Initial:' \
    ' requisite pam_pwquality.so retry=3 minlen=14 difok=3 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 enforce_for_root' \
    > "$backup_dir/afa-pwquality.staged"
printf '%s\n' \
    'Name: AFA five-password history' 'Default: yes' 'Priority: 1000' 'Password-Type: Primary' \
    'Password:' ' requisite pam_pwhistory.so remember=5 retry=3 use_authtok enforce_for_root' \
    'Password-Initial:' ' requisite pam_pwhistory.so remember=5 retry=3 enforce_for_root' \
    > "$backup_dir/afa-pwhistory.staged"
for profile in afa-pwquality afa-pwhistory; do
    target="/usr/share/pam-configs/$profile"
    if [ -e "$target" ]; then
        cmp -s "$backup_dir/$profile.staged" "$target" || fail "Existing custom PAM profile differs; not overwriting: $profile"
    else
        cp "$backup_dir/$profile.staged" "$target"
        chmod 644 "$target"
        if [ "$profile" = afa-pwquality ]; then quality_profile_created=1; else history_profile_created=1; fi
    fi
done
cp -a /etc/security/pwquality.conf "$backup_dir/pwquality.conf.packaged"
awk '
    /^[[:space:]]*(minlen|difok|ucredit|lcredit|dcredit|ocredit|dictcheck|usercheck|enforcing)[[:space:]]*=/ {next}
    {print}
' /etc/security/pwquality.conf > "$backup_dir/pwquality.conf.staged"
printf '\n%s\n' '# AFA password quality policy' 'minlen = 14' 'difok = 3' \
    'ucredit = -1' 'lcredit = -1' 'dcredit = -1' 'ocredit = -1' \
    'dictcheck = 1' 'usercheck = 1' 'enforcing = 1' >> "$backup_dir/pwquality.conf.staged"
cp "$backup_dir/pwquality.conf.staged" /etc/security/pwquality.conf
chmod 644 /etc/security/pwquality.conf
pam-auth-update --package --disable pwquality --enable afa-pwquality afa-pwhistory
sed -i -E '/^[[:space:]]*auth[[:space:]].*pam_unix\.so/ s/(^|[[:space:]])nullok(_secure)?([[:space:]]|$)/\1\3/g' /etc/pam.d/common-auth

printf '\n===== VALIDATE STACK ORDER AND MODULE AVAILABILITY =====\n'
awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    /pam_pwquality\.so/ {q=NR; nq++; if($2!="requisite" || $0 !~ /minlen=14/ || $0 !~ /enforce_for_root/) bad=1}
    /pam_pwhistory\.so/ {h=NR; nh++; if($2!="requisite" || $0 !~ /remember=5/ || $0 !~ /use_authtok/ || $0 !~ /enforce_for_root/) bad=1}
    /pam_unix\.so/ {u=NR; nu++; if($0 !~ /use_authtok/) bad=1}
    END {if(nq!=1 || nh!=1 || nu!=1 || !(q<h && h<u) || bad) exit 1}
' /etc/pam.d/common-password || fail 'Password stack order or token propagation is invalid.'
if grep -E '^[[:space:]]*auth[[:space:]].*pam_unix\.so.*[[:space:]]nullok(_secure)?([[:space:]]|$)' /etc/pam.d/common-auth >/dev/null; then
    fail 'Empty-password bypass is still present.'
fi
for file in /etc/pam.d/common-auth /etc/pam.d/common-password /etc/pam.d/common-account /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    while IFS= read -r module; do module_present "$module" || fail "Referenced module is unavailable: $module"; done \
        < <(awk '!/^[[:space:]]*#/ {for(i=1;i<=NF;i++) if($i ~ /^pam_[[:alnum:]_]+\.so$/) print $i}' "$file")
done
save_status > "$backup_dir/password-status.after"
cmp -s "$backup_dir/password-status.before" "$backup_dir/password-status.after" || fail 'Existing account password status changed unexpectedly.'
audit=$(dpkg --audit)
[ -z "$audit" ] || fail 'Package database has incomplete work after install.'
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'SSH validation failed.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
ufw status | grep -x 'Status: active' >/dev/null || fail 'UFW became inactive.'
[ "$(sha256sum /etc/apt/sources.list)" = "$sources_before" ] || fail 'Repository configuration changed unexpectedly.'
printf '\n===== RESULT =====\n'
awk '!/^[[:space:]]*#/ && /pam_(pwquality|pwhistory|unix)\.so/ {print}' /etc/pam.d/common-password
printf 'Quality checks require at least 14 characters, upper/lower/digit/symbol, and dictionary checks.\n'
printf 'Five-password history is enforced before pam_unix, including root-initiated changes.\n'
printf 'Local pam_unix authentication no longer uses nullok.\n'
printf 'Existing password status is unchanged for every authorized user, including pparker.\n'
printf 'SSH/LightDM/CCS Client remain active; UFW active; security sources unchanged.\n'
printf 'Private configuration/selection backups: %s\n' "$backup_dir"
printf 'Undo: remove custom profiles through pam-auth-update, restore saved common-* and profile selections, and restore pwquality configuration before removing a referenced module.\n'
printf 'Validation is structural; a user-entered sudo/password-change test is still needed for interactive authentication.\n'
trap - ERR INT TERM
