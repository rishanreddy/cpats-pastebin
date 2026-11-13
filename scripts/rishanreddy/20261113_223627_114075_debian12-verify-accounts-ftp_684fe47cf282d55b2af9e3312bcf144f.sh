#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY verification of the approved account/FTP batch.
set -u
export LC_ALL=C
failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
admins='pparker tstark ppotts hhogan nfury mhill pcoulson'
authorized="$admins bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter"
printf '===== INDEPENDENT ACCOUNT AND FTP VERIFICATION =====\n'
for name in brumlow azola; do
    if getent passwd "$name" >/dev/null; then fail "Unauthorized account still exists: $name";
    else pass "Unauthorized account is absent: $name"; fi
    if [ -d "/home/$name" ]; then
        pass "Home directory preserved: /home/$name"
        stat -c '%a %u:%g %n' "/home/$name"
    else fail "Expected preserved home directory missing: /home/$name"; fi
done
for name in $authorized; do
    if getent passwd "$name" >/dev/null; then :; else fail "Authorized account missing: $name"; fi
done
for name in $admins; do
    case " $(id -nG "$name" 2>/dev/null) " in
        *' sudo '*) pass "$name retains sudo" ;; *) fail "$name lacks sudo" ;;
    esac
done
if systemctl is-active --quiet vsftpd; then fail 'FTP is still active'; else pass 'FTP is inactive'; fi
if [ "$(systemctl is-enabled vsftpd 2>/dev/null || true)" = enabled ]; then fail 'FTP remains enabled'; else pass 'FTP is not enabled at boot'; fi
listeners=$(ss -tln 2>/dev/null)
printf '%s\n' "$listeners" | awk 'NR==1 || $4 ~ /:(21|22)$/ {print}'
if printf '%s\n' "$listeners" | awk 'NR>1 && $4 ~ /:21$/ {found=1} END {exit !found}'; then fail 'FTP port 21 remains open'; else pass 'No FTP listener on port 21'; fi
if printf '%s\n' "$listeners" | awk 'NR>1 && $4 ~ /:22$/ {found=1} END {exit !found}'; then pass 'SSH is listening on port 22'; else fail 'SSH listener missing'; fi
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service is active"; else fail "$service is inactive"; fi
done
if [ "$(systemctl is-enabled ssh 2>/dev/null || true)" = enabled ]; then pass 'SSH remains enabled at boot'; else fail 'SSH is not enabled'; fi
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then pass 'Security-update source remains configured'; else fail 'Security-update source missing'; fi
printf '\nUFW package state for the next proposal, no changes:\n'
dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' ufw 2>/dev/null || true
if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>/dev/null || true; fi
printf '\nVerification failures: %s\n' "$failures"
[ "$failures" -eq 0 ]
