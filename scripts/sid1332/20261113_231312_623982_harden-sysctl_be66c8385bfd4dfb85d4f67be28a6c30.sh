#!/usr/bin/env bash
# Persist and apply selected workstation hardening settings on Debian.
set -euo pipefail
export LC_ALL=C
config=/etc/sysctl.conf
begin='# BEGIN CPATS workstation hardening'
end='# END CPATS workstation hardening'

(( EUID == 0 )) || { echo 'Run as root.' >&2; exit 1; }
[[ -f "$config" && ! -L "$config" ]] || { echo 'Expected a regular /etc/sysctl.conf.' >&2; exit 1; }
systemctl is-active --quiet ssh.service
[[ $(sysctl -n net.ipv4.ip_forward) == 0 ]] || { echo 'IPv4 forwarding is active; review router settings first.' >&2; exit 1; }

keys=(kernel.kptr_restrict kernel.yama.ptrace_scope)
values=(1 1)
for entry in /proc/sys/net/ipv4/conf/*; do
    [[ -d "$entry" ]] || continue
    iface="${entry##*/}"
    [[ "$iface" =~ ^[a-zA-Z0-9_.-]+$ ]] || { printf 'Unexpected interface name: %q\n' "$iface" >&2; exit 1; }
    for setting in accept_redirects secure_redirects send_redirects accept_source_route; do
        keys+=("net/ipv4/conf/$iface/$setting")
        values+=(0)
    done
done

old=()
for i in "${!keys[@]}"; do
    current=$(sysctl -n "${keys[i]}")
    [[ "$current" =~ ^[0-9]+$ ]]
    old+=("$current")
    # Preserve stronger restrictions. A ptrace setting of 3 cannot be lowered.
    if (( i < 2 && current > 1 )); then values[i]="$current"; fi
done

umask 077
backup=$(mktemp -d /var/backups/cpats-sysctl.XXXXXXXX)
cp -a -- "$config" "$backup/sysctl.conf"
for i in "${!keys[@]}"; do
    printf '%s = %s\n' "${keys[i]}" "${old[i]}"
done > "$backup/runtime.conf"
printf 'Backup directory: %s\n' "$backup"
printf 'Restore: cp -a -- %q %q && sysctl -p %q\n' "$backup/sysctl.conf" "$config" "$backup/runtime.conf"

temp=''
applying=no
cleanup() {
    local result=$?
    if [[ "$result" != 0 && "$applying" == yes ]]; then
        printf '%s\n' 'Hardening failed. Restoring the saved live values.' >&2
        sysctl -p "$backup/runtime.conf" || printf 'Live rollback failed. See %s/runtime.conf.\n' "$backup" >&2
    fi
    if [[ -n "$temp" ]]; then rm -f -- "$temp"; fi
}
trap cleanup EXIT

# Build a replacement with the original file metadata and one managed block.
temp=$(mktemp /etc/.cpats-sysctl.XXXXXXXX)
cp -a -- "$config" "$temp"
awk -v begin="$begin" -v end="$end" '
    $0 == begin { if (inside) exit 1; inside = 1; next }
    $0 == end { if (!inside) exit 1; inside = 0; next }
    !inside { print }
    END { if (inside) exit 1 }
' "$backup/sysctl.conf" > "$temp"
{
    printf '%s\n' "$begin"
    for i in "${!keys[@]}"; do
        printf '%s = %s\n' "${keys[i]}" "${values[i]}"
    done
    printf '%s\n' "$end"
} >> "$temp"

applying=yes
for i in "${!keys[@]}"; do
    key="${keys[i]}"
    wanted="${values[i]}"
    if [[ $(sysctl -n "$key") != "$wanted" ]]; then sysctl -w "$key=$wanted"; fi
    [[ $(sysctl -n "$key") == "$wanted" ]]
done
systemctl is-active ssh.service
cmp -s -- "$config" "$backup/sysctl.conf" || { echo 'sysctl.conf changed during the audit; leaving that edit in place.' >&2; exit 1; }
mv -fT -- "$temp" "$config"
applying=no
temp=''
printf '%s\n' 'Verified live settings and saved them in /etc/sysctl.conf.'
