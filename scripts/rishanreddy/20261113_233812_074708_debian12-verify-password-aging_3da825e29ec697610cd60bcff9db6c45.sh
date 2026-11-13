#!/usr/bin/env bash
# PURPOSE: independent READ-ONLY verification of approved password-aging settings.
# No credential fields, hashes, kernel settings, or forensics data are printed.
set -u
export LC_ALL=C
authorized='pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures+1)); }
printf '===== INDEPENDENT PASSWORD-AGING VERIFICATION =====\n'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]' /etc/login.defs
if awk '
    $1=="PASS_MAX_DAYS" {max=$2; nmax++}
    $1=="PASS_MIN_DAYS" {min=$2; nmin++}
    $1=="PASS_WARN_AGE" {warn=$2; nwarn++}
    END {exit (max!=90 || min!=10 || warn!=7 || nmax!=1 || nmin!=1 || nwarn!=1)}
' /etc/login.defs; then pass 'Password-aging defaults are 90/10/7'; else fail 'Unexpected defaults'; fi
today=$(( $(date -u +%s) / 86400 ))
printf '\nAccount metadata only, no hashes:\n'
for name in $authorized; do
    status=$(passwd -S "$name" 2>/dev/null || true)
    printf '%s\n' "$status"
    if printf '%s\n' "$status" | awk '$2=="P" && $4==10 && $5==90 && $6==7 {ok=1} END {exit !ok}'; then :;
    else fail "Unexpected aging/status for $name"; fi
    if awk -F: -v user="$name" -v today="$today" '
        $1==user {found=1; if($3<=0 || $3>today || today-$3>=90 || ($8!="" && $8!=-1 && $8<=today)) bad=1}
        END {exit (!found || bad)}
    ' /etc/shadow; then :; else fail "Account or password expiry issue: $name"; fi
done
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service active"; else fail "$service inactive"; fi
done
if [ "$(systemctl is-enabled ssh 2>/dev/null || true)" = enabled ]; then pass 'SSH enabled at boot'; else fail 'SSH boot enablement missing'; fi
if ufw status 2>/dev/null | grep -x 'Status: active' >/dev/null; then pass 'UFW active'; else fail 'UFW inactive'; fi
if grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null; then pass 'Security-update source retained'; else fail 'Security-update source missing'; fi
printf '\nVerification failures: %s\n' "$failures"
printf 'Actual score changes must be confirmed from the normal Desktop report.\n'
[ "$failures" -eq 0 ]
