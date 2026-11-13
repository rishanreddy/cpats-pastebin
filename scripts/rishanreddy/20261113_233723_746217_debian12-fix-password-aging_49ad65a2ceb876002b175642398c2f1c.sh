#!/usr/bin/env bash
# PURPOSE: apply the explicitly approved 90/10/7 password-aging batch.
# CHANGES: login.defs defaults and min/max/warn aging fields for authorized users.
# No passwords, last-change dates, inactive periods, or account expiry dates change.
# Confidential account-file backups remain root-only; no hashes are ever printed.
set -Eeuo pipefail
export LC_ALL=C
umask 077
authorized='pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
backup_dir=''
mutating=0
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
rollback() {
    local status="$?" ok=1 name old_min old_max old_warn
    trap - ERR INT TERM
    set +e
    if [ "$mutating" -eq 1 ]; then
        printf '\nValidation failed or execution interrupted. Restoring original aging values.\n'
        cp -a "$backup_dir/login.defs.before" /etc/login.defs || ok=0
        while read -r name old_min old_max old_warn; do
            if getent passwd "$name" >/dev/null; then
                chage -m "$old_min" -M "$old_max" -W "$old_warn" "$name" || ok=0
            else
                printf 'Account disappeared during batch; review required: %s\n' "$name"
                ok=0
            fi
        done < "$backup_dir/aging.before"
        if [ "$ok" -eq 1 ]; then printf 'Original defaults and aging fields restored without overwriting password hashes.\n';
        else printf 'AGING RESTORE NEEDS ATTENTION. Private backups: %s\n' "$backup_dir"; fi
    else printf '\nStopped before changing password-aging policy.\n'; fi
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== PASSWORD-AGING PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Root runner required.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
for tool in chage passwd getent awk date stat cp cmp systemctl; do command -v "$tool" >/dev/null || fail "Existing tool missing: $tool"; done
for file in /etc/login.defs /etc/shadow; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "Expected regular configuration file: $file"
done
today=$(( $(date -u +%s) / 86400 ))
for name in $authorized; do
    state=$(passwd -S "$name" | awk '{print $2}')
    [ "$state" = P ] || fail "Authorized account is not password-ready: $name"
    # Inspect only age/expiry fields in memory. Never emit credential fields.
    awk -F: -v user="$name" -v today="$today" '
        $1==user {
            found=1
            if($3 !~ /^[0-9]+$/ || $3<=0 || $3>today || today-$3>=90) bad=1
            if($8!="" && $8!=-1 && $8<=today) bad=1
        }
        END {exit (!found || bad)}
    ' /etc/shadow || fail "The 90-day policy would expire an account or metadata needs review: $name"
done
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'Existing SSH configuration does not validate.'
shadow_mode_before=$(stat -c '%a:%u:%g' /etc/shadow)
defs_mode_before=$(stat -c '%a:%u:%g' /etc/login.defs)

printf '\n===== PRIVATE BACKUPS =====\n'
backup_dir="/root/afa-password-aging-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/login.defs "$backup_dir/login.defs.before"
cp -a /etc/shadow "$backup_dir/shadow.before"
for name in $authorized; do
    passwd -S "$name" >> "$backup_dir/password-status.before"
    passwd -S "$name" | awk '{print $1,$4,$5,$6}' >> "$backup_dir/aging.before"
done
printf 'Private backup directory: %s\n' "$backup_dir"

printf '\n===== SET PASSWORD-AGING DEFAULTS =====\n'
awk '
    BEGIN {value["PASS_MAX_DAYS"]=90; value["PASS_MIN_DAYS"]=10; value["PASS_WARN_AGE"]=7}
    $1 in value {if(!seen[$1]++) print $1 "\t" value[$1]; next}
    {print}
    END {
        if(!seen["PASS_MAX_DAYS"]) print "PASS_MAX_DAYS\t90"
        if(!seen["PASS_MIN_DAYS"]) print "PASS_MIN_DAYS\t10"
        if(!seen["PASS_WARN_AGE"]) print "PASS_WARN_AGE\t7"
    }
' /etc/login.defs > "$backup_dir/login.defs.staged"
mutating=1
cp "$backup_dir/login.defs.staged" /etc/login.defs

printf '\n===== APPLY TO TWENTY AUTHORIZED ACCOUNTS =====\n'
for name in $authorized; do
    chage -M 90 -m 10 -W 7 "$name"
    printf 'Applied min=10 max=90 warn=7: %s\n' "$name"
done

printf '\n===== VERIFY DEFAULTS AND ACCOUNT FIELDS =====\n'
awk '
    $1=="PASS_MAX_DAYS" {max=$2; nmax++}
    $1=="PASS_MIN_DAYS" {min=$2; nmin++}
    $1=="PASS_WARN_AGE" {warn=$2; nwarn++}
    END {exit (max!=90 || min!=10 || warn!=7 || nmax!=1 || nmin!=1 || nwarn!=1)}
' /etc/login.defs || fail 'Aging defaults did not validate.'
for name in $authorized; do
    status=$(passwd -S "$name")
    printf '%s\n' "$status" | awk '$2=="P" && $4==10 && $5==90 && $6==7 {ok=1} END {exit !ok}' || fail "Unexpected account-aging fields: $name"
    printf '%s\n' "$status" >> "$backup_dir/password-status.after"
done
# Compare credential/last-change/expiry data only in memory. Nothing confidential
# is printed or sent to stdout. Rollback uses chage, not a stale shadow-file copy.
awk -F: '
    FNR==NR {saved[$1]=$2 FS $3 FS $7 FS $8 FS $9; old_count++; next}
    {new_count++; if(!($1 in saved) || saved[$1]!=($2 FS $3 FS $7 FS $8 FS $9)) bad=1}
    END {exit (bad || old_count!=new_count)}
' "$backup_dir/shadow.before" /etc/shadow || fail 'Credential or non-aging account data changed unexpectedly.'
[ "$(stat -c '%a:%u:%g' /etc/shadow)" = "$shadow_mode_before" ] || fail 'Shadow-file permissions changed unexpectedly.'
[ "$(stat -c '%a:%u:%g' /etc/login.defs)" = "$defs_mode_before" ] || fail 'login.defs permissions changed unexpectedly.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled at boot.'
ufw status | grep -x 'Status: active' >/dev/null || fail 'UFW is not active.'
grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null || fail 'Security-update source missing.'
printf '\n===== RESULT =====\n'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]' /etc/login.defs
printf 'All twenty authorized accounts have min=10, max=90, warn=7.\n'
printf 'Passwords, last-change dates, inactive fields, and account-expiry fields are unchanged.\n'
printf 'No authorized password is immediately expired under the new 90-day policy.\n'
printf 'Required services, SSH boot enablement, active UFW, and security sources are preserved.\n'
printf 'Private backups and original aging values: %s\n' "$backup_dir"
printf 'Undo: restore login.defs and use aging.before with chage to restore only original min/max/warn fields.\n'
printf 'Do not restore an old shadow file over subsequent legitimate password changes.\n'
trap - ERR INT TERM
