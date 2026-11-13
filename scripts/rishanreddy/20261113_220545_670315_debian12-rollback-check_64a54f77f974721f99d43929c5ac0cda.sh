#!/usr/bin/env bash
# PURPOSE: READ-ONLY verification of automatic rollback and validation diagnostics.
set -u
set -o pipefail
export LC_ALL=C
backup=/root/afa-batch1-20261113T220452Z-3777
printf '===== BACKUP COMPARISON =====\n'
for pair in '/etc/group:group' '/etc/gshadow:gshadow' '/etc/ssh/sshd_config:sshd_config' '/etc/lightdm/lightdm.conf:lightdm.conf'; do
    file=${pair%%:*}; saved=${pair#*:}
    if cmp -s "$file" "$backup/$saved"; then printf 'RESTORED: %s\n' "$file";
    else printf 'DIFFERS FROM BACKUP: %s\n' "$file"; fi
done
printf '\n===== CURRENT SSH POLICY =====\n'
for name in pparker pcarter; do
    printf '%s:\n' "$name"
    effective=$(/usr/sbin/sshd -T -C "user=$name,host=debian,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null)
    printf '%s\n' "$effective" | grep -E '^(permitrootlogin|permitemptypasswords|passwordauthentication|usepam) '
    printf 'Full effective-output byte count: '
    printf '%s\n' "$effective" | wc -c
done
printf '\n===== QUIET-GREP PIPELINE DIAGNOSTIC =====\n'
printf 'Inspecting pipeline exit statuses only; no additional configuration is printed.\n'
effective=$(/usr/sbin/sshd -T -C 'user=pcarter,host=debian,addr=127.0.0.1,laddr=127.0.0.1,lport=22' 2>/dev/null)
bad=0
for iteration in $(seq 1 40); do
    printf '%s\n' "$effective" | grep -qx 'permitemptypasswords yes'
    codes=("${PIPESTATUS[@]}")
    if [ "${codes[0]}" -ne 0 ] || [ "${codes[1]}" -ne 0 ]; then
        printf 'Iteration %s: producer=%s grep=%s\n' "$iteration" "${codes[0]}" "${codes[1]}"
        bad=$((bad+1))
    fi
done
printf 'Nonzero quiet-grep pipeline results: %s of 40\n' "$bad"
printf '\n===== GROUP AND REQUIRED SERVICES =====\n'
getent group sudo
systemctl is-active ssh lightdm ccsclient 2>/dev/null || true
printf '\nRead-only diagnostic complete.\n'
