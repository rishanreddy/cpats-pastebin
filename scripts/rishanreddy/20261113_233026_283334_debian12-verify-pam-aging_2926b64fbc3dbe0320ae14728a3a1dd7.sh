#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY verification of the approved PAM hardening.
# No passwords, hashes, history contents, forensics, or kernel settings are read.
set -u
export LC_ALL=C
failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
authorized='pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
module_present() {
    local module="$1" file
    for file in "/lib/security/$module" "/usr/lib/security/$module" /lib/*/security/"$module" /usr/lib/*/security/"$module"; do
        [ ! -r "$file" ] || return 0
    done
    return 1
}
printf '===== INDEPENDENT PAM VERIFICATION =====\n'
if awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    /pam_pwquality\.so/ {
        q=NR; nq++;
        if($2!="requisite" || $0 !~ /minlen=14/ || $0 !~ /ucredit=-1/ || $0 !~ /lcredit=-1/ || $0 !~ /dcredit=-1/ || $0 !~ /ocredit=-1/ || $0 !~ /enforce_for_root/) bad=1
    }
    /pam_pwhistory\.so/ {
        h=NR; nh++;
        if($2!="requisite" || $0 !~ /remember=5/ || $0 !~ /use_authtok/ || $0 !~ /enforce_for_root/) bad=1
    }
    /pam_unix\.so/ {u=NR; nu++; if($0 !~ /use_authtok/ || $0 !~ /yescrypt/) bad=1}
    END {exit (nq!=1 || nh!=1 || nu!=1 || !(q<h && h<u) || bad)}
' /etc/pam.d/common-password; then
    pass 'Quality then history then pam_unix, with required token propagation and yescrypt'
else fail 'Password module ordering or policy options are invalid'; fi
awk '!/^[[:space:]]*#/ && /pam_(pwquality|pwhistory|unix)\.so/ {print}' /etc/pam.d/common-password
if grep -E '^[[:space:]]*auth[[:space:]].*pam_unix\.so.*[[:space:]]nullok(_secure)?([[:space:]]|$)' /etc/pam.d/common-auth >/dev/null; then
    fail 'Local authentication still permits the nullok bypass'
else pass 'No pam_unix nullok option in common-auth'; fi
for module in pam_pwquality.so pam_pwhistory.so pam_unix.so pam_deny.so pam_permit.so; do
    if module_present "$module"; then pass "Module available: $module"; else fail "Module missing: $module"; fi
done
for extension in pwd pwi hwm; do
    if [ -s "/var/cache/cracklib/cracklib_dict.$extension" ]; then pass "Dictionary component available: $extension";
    else fail "Dictionary component missing: $extension"; fi
done
if [ "$(stat -c '%a:%u:%g' /etc/security/opasswd 2>/dev/null)" = 600:0:0 ]; then pass 'Password-history file is private root:root 600';
else fail 'Password-history file permissions are unexpected'; fi
for name in $authorized; do
    state=$(passwd -S "$name" 2>/dev/null | awk '{print $2}')
    if [ "$state" != P ]; then fail "Authorized account is not password-ready: $name"; fi
done
printf '\nCurrent password-aging defaults, no changes:\n'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]' /etc/login.defs 2>/dev/null || true
printf '\nAuthorized account aging metadata, no passwords or hashes:\n'
printf 'name status last-change minimum-days maximum-days warning-days inactive-days\n'
for name in $authorized; do passwd -S "$name" 2>/dev/null || true; done
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service active"; else fail "$service inactive"; fi
done
if /usr/sbin/sshd -t >/dev/null 2>&1; then pass 'SSH configuration validates'; else fail 'SSH validation failed'; fi
if ufw status 2>/dev/null | grep -x 'Status: active' >/dev/null; then pass 'UFW active'; else fail 'UFW inactive'; fi
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then pass 'Security-update source retained'; else fail 'Security-update source missing'; fi
audit=$(dpkg --audit)
if [ -z "$audit" ]; then pass 'Package database clean'; else fail 'Incomplete package state'; fi
printf '\nVerification failures: %s\n' "$failures"
printf 'Interactive login and password-change tests require local user-entered credentials.\n'
[ "$failures" -eq 0 ]
