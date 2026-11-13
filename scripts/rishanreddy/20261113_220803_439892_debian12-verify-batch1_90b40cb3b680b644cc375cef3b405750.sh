#!/usr/bin/env bash
# PURPOSE: independent read-only verification of the five approved fixes.
# CHANGES: none. No forensics files, passwords, or process arguments are read.
set -u
export LC_ALL=C
failures=0
admins='pparker tstark ppotts hhogan nfury mhill pcoulson'
authorized="$admins bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
has_sudo() { case " $(id -nG "$1" 2>/dev/null) " in *' sudo '*) return 0 ;; *) return 1 ;; esac; }

printf '===== INDEPENDENT READ-ONLY VERIFICATION =====\n'
if [ "$(id -u)" -ne 0 ]; then printf 'Root runner required.\n'; exit 1; fi
for name in bbanner sstrange; do
    if has_sudo "$name"; then fail "$name still has sudo group privileges";
    else pass "$name is not in sudo"; fi
done
for name in $admins; do
    if has_sudo "$name"; then pass "$name retains sudo";
    else fail "$name lacks required sudo membership"; fi
done
for name in $authorized; do
    if ! getent passwd "$name" >/dev/null; then fail "Authorized account missing: $name"; fi
done
printf '\nCurrent sudo group:\n'
getent group sudo
if visudo -c >/dev/null 2>&1; then pass 'Sudo configuration validates'; else fail 'Sudo configuration is invalid'; fi

printf '\nEffective SSH policy:\n'
if /usr/sbin/sshd -t >/dev/null 2>&1; then pass 'SSH configuration validates'; else fail 'SSH configuration is invalid'; fi
effective=$(/usr/sbin/sshd -T 2>/dev/null)
printf '%s\n' "$effective" | grep -E '^(permitrootlogin|permitemptypasswords|passwordauthentication|usepam|port) '
for required in 'permitrootlogin no' 'permitemptypasswords no' 'passwordauthentication yes' 'usepam yes'; do
    if printf '%s\n' "$effective" | grep -x "$required" >/dev/null; then pass "SSH $required"; else fail "SSH expected $required"; fi
done
for name in $authorized; do
    scoped=$(/usr/sbin/sshd -T -C "user=$name,host=debian,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null)
    if printf '%s\n' "$scoped" | grep -x 'passwordauthentication yes' >/dev/null; then :;
    else fail "Password authentication unavailable for $name"; fi
    if printf '%s\n' "$scoped" | grep -qE '^(allowusers|allowgroups|denyusers|denygroups) '; then
        fail "Scoped SSH user/group restrictions need review for $name"
    fi
done
printf 'Remote authentication checks inspect policy only; actual password logins are not attempted.\n'

printf '\nLightDM guest policy:\n'
if command -v lightdm >/dev/null 2>&1; then
    guest=$(lightdm --show-config 2>/dev/null | grep -E 'allow-guest[[:space:]]*=' || true)
else
    guest=''
fi
if [ -n "$guest" ]; then
    printf '%s\n' "$guest"
    if printf '%s\n' "$guest" | grep -Eq 'allow-guest[[:space:]]*=[[:space:]]*true'; then
        fail 'Merged LightDM configuration still permits guest login'
    elif printf '%s\n' "$guest" | grep -Eq 'allow-guest[[:space:]]*=[[:space:]]*false'; then
        pass 'Merged LightDM configuration disables guest login'
    else
        fail 'Unable to establish effective LightDM guest policy'
    fi
else
    fail 'Unable to inspect merged LightDM guest configuration'
fi

printf '\nRequired services and SSH listener:\n'
for service in ssh lightdm ccsclient; do
    if systemctl is-active --quiet "$service"; then pass "$service is active"; else fail "$service is not active"; fi
done
if [ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ]; then pass 'SSH is enabled at boot'; else fail 'SSH is not enabled at boot'; fi
ss -tln 2>/dev/null | awk 'NR == 1 || $4 ~ /:22$/ {print}'
printf '\nVerification failures: %s\n' "$failures"
[ "$failures" -eq 0 ]
