#!/usr/bin/env bash
# Read-only audit of kernel settings relevant to a Debian SSH workstation.
set -euo pipefail
export LC_ALL=C

printf '%s\n' '== Kernel status =='
uname -r
dpkg-query -W -f='${Version}\n' linux-image-amd64 || true

printf '\n%s\n' '== Effective sysctl values =='
keys=(
    kernel.dmesg_restrict kernel.kptr_restrict kernel.yama.ptrace_scope
    fs.protected_hardlinks fs.protected_symlinks
    net.ipv4.ip_forward net.ipv6.conf.all.forwarding
    net.ipv4.tcp_syncookies net.ipv4.icmp_echo_ignore_broadcasts
    net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects
    net.ipv4.conf.all.secure_redirects net.ipv4.conf.default.secure_redirects
    net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects
    net.ipv4.conf.all.accept_source_route net.ipv4.conf.default.accept_source_route
    net.ipv6.conf.all.accept_redirects net.ipv6.conf.default.accept_redirects
    net.ipv6.conf.all.accept_source_route net.ipv6.conf.default.accept_source_route
)
for key in "${keys[@]}"; do
    sysctl "$key" 2>/dev/null || printf '%s unavailable\n' "$key"
done

printf '\n%s\n' '== Matching persistent settings =='
for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
    [[ -f "$file" && -r "$file" ]] || continue
    # Print only numeric assignments for the keys above, never arbitrary config text.
    awk -v keys="${keys[*]}" '
        BEGIN { n = split(keys, items, " "); for (i = 1; i <= n; i++) wanted[items[i]] = 1 }
        /^[[:space:]]*[#;]/ { next }
        {
            line = $0
            sub(/[[:space:]]*[#;].*$/, "", line)
            if (split(line, parts, "=") != 2) next
            key = parts[1]; value = parts[2]
            gsub(/[[:space:]]/, "", key); sub(/^-/, "", key); gsub(/\//, ".", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key in wanted && value ~ /^-?[0-9]+$/) printf "%s:%d: %s = %s\n", FILENAME, FNR, key, value
        }
    ' "$file"
done
printf '\n%s\n' '== SSH service =='
systemctl is-active ssh.service || true
