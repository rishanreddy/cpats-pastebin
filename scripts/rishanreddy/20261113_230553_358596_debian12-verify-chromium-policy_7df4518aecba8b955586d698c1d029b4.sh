#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY browser verification and remaining policy inventory.
# No forensics files, profile contents, passwords, or process arguments are read.
set -u
export LC_ALL=C
failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
printf '===== INDEPENDENT CHROMIUM VERIFICATION =====\n'
for package in chromium chromium-common chromium-sandbox; do
    version=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
    state=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
    candidate=$(apt-cache policy "$package" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ {print $2}')
    printf '%s installed=%s candidate=%s state=%s\n' "$package" "$version" "$candidate" "$state"
    if [ "$state" = installed ] && [ "$version" = 156.0.8078.79-1~deb12u1 ] && [ "$version" = "$candidate" ]; then
        pass "$package matches the official candidate"
    else fail "Unexpected installed/candidate state for $package"; fi
done
/usr/bin/chromium --version 2>/dev/null || fail 'Browser version command failed'
default=$(update-alternatives --query x-www-browser 2>/dev/null | awk '/^Value:/ {print $2}')
if [ "$default" = /usr/bin/chromium ]; then pass 'Chromium remains the system browser default'; else fail 'Unexpected browser default'; fi
printf '\nPrimary user browser MIME defaults:\n'
grep -E '^(text/html|x-scheme-handler/https?)=' /home/pparker/.config/mimeapps.list 2>/dev/null || true
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service active"; else fail "$service inactive"; fi
done
if ufw status 2>/dev/null | grep -x 'Status: active' >/dev/null; then pass 'UFW remains active'; else fail 'UFW inactive'; fi
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then pass 'Security-update source retained'; else fail 'Security-update source missing'; fi
audit=$(dpkg --audit)
if [ -z "$audit" ]; then pass 'Package database clean'; else fail 'Incomplete package state'; fi
if [ -d /root/afa-chromium-20261113T225851Z-54894/profiles/pparker/chromium ]; then pass 'Private pre-upgrade profile backup exists'; else fail 'Expected private profile backup missing'; fi

printf '\n===== REMAINING POLICY INVENTORY, NO CHANGES =====\n'
dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' unattended-upgrades libpam-pwquality libpam-passwdqc 2>/dev/null || true
printf '\nAutomatic-update intervals, selected numeric directives only:\n'
apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade|Download-Upgradeable-Packages|AutocleanInterval)[[:space:]]+"[0-9]+";' || true
printf '\nPassword aging defaults:\n'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]' /etc/login.defs 2>/dev/null || true
printf '\nActive password modules and selected options only:\n'
for file in /etc/pam.d/common-password /etc/pam.d/common-auth; do
    printf '%s:\n' "$file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {for(i=1;i<=NF;i++) if($i ~ /(^|\/)pam_[[:alnum:]_]+\.so$/) printf "module=%s ",$i;
         for(i=1;i<=NF;i++) if($i ~ /^(nullok|obscure|yescrypt|sha512|enforce_for_root)$/ || $i ~ /^(minlen|remember|[duloc]credit|retry|difok)=-?[0-9]+$/) printf "%s ",$i;
         printf "\n"}
    ' "$file"
done
printf '\nBrowser verification failures: %s\n' "$failures"
[ "$failures" -eq 0 ]
