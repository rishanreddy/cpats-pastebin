#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY verification of the approved UFW-only batch.
set -u
export LC_ALL=C
failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
printf '===== INDEPENDENT UFW VERIFICATION =====\n'
state=$(dpkg-query -W -f='${db:Status-Status}' ufw 2>/dev/null || true)
if [ "$state" = installed ]; then pass 'UFW is fully installed'; else fail 'UFW is not fully installed'; fi
if command -v ufw >/dev/null 2>&1; then
    status=$(ufw status verbose 2>&1)
    printf '%s\n' "$status"
    if printf '%s\n' "$status" | grep -x 'Status: active' >/dev/null; then pass 'UFW is active'; else fail 'UFW inactive'; fi
    if printf '%s\n' "$status" | grep -E '^Default: deny \(incoming\), allow \(outgoing\)' >/dev/null; then pass 'Incoming-deny/outgoing-allow defaults'; else fail 'Unexpected defaults'; fi
    for rule in '^22/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere' '^22/tcp \(v6\)[[:space:]]+ALLOW IN[[:space:]]+Anywhere \(v6\)'; do
        if printf '%s\n' "$status" | grep -E "$rule" >/dev/null; then pass 'Required SSH allow rule present'; else fail 'SSH allow rule missing'; fi
    done
else fail 'UFW executable missing'; fi
if grep -x 'ENABLED=yes' /etc/ufw/ufw.conf >/dev/null; then pass 'UFW persistent configuration enabled'; else fail 'UFW persistence missing'; fi
if [ "$(systemctl is-enabled ufw 2>/dev/null || true)" = enabled ]; then pass 'UFW service enabled at boot'; else fail 'UFW boot enablement missing'; fi
if grep -Eq '^IPV6=yes' /etc/default/ufw; then pass 'IPv6 firewall support enabled'; else fail 'IPv6 support disabled'; fi
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service active"; else fail "$service inactive"; fi
done
if [ "$(systemctl is-enabled ssh 2>/dev/null || true)" = enabled ]; then pass 'SSH enabled at boot'; else fail 'SSH boot enablement missing'; fi
ss -tln 2>/dev/null | awk 'NR==1 || $4 ~ /:(21|22)$/ {print}'
if systemctl is-active --quiet vsftpd; then fail 'FTP became active again'; else pass 'FTP remains inactive'; fi
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then pass 'Security-update source retained'; else fail 'Security-update source missing'; fi
audit=$(dpkg --audit)
if [ -z "$audit" ]; then pass 'Package database clean'; else fail 'Incomplete package state detected'; fi
printf '\nVerification failures: %s\n' "$failures"
printf 'Checks inspect firewall policy and service state; actual remote password logins were not attempted.\n'
[ "$failures" -eq 0 ]
