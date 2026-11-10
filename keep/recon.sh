#!/usr/bin/env bash
# Read-only baseline recon for a CyberPatriot Linux practice image (Linux Mint, Ubuntu, Debian).
#
# It changes nothing: no files are written, and no accounts, packages, services, or
# settings are touched. It never prints password hashes or private keys. A missing tool
# or a section that needs root is reported and skipped, never an error.
#
# For complete results run it as root, by starting the runner with sudo. Publish it with:
#   bash publish.sh --user NAME --source keep/recon.sh --name recon
# The output goes to outputs/NAME/ and is PUBLIC, like everything in this repo.
set -u

have()    { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" -eq 0 ]; }
# Run a command with a time limit when `timeout` exists, so a slow search cannot hang the report.
limit()   { local secs="$1"; shift; if have timeout; then timeout "$secs" "$@"; else "$@"; fi; }
# Print "(nothing found)" when a section produces no output.
report() {
    local title="$1" fn="$2" out
    printf '\n===== %s =====\n' "$title"
    out=$("$fn" 2>/dev/null) || true
    if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '(nothing found)\n'; fi
}
nonblank() { grep -vE '^[[:space:]]*(#|$)' "$@"; }

s_host() {
    printf 'time (UTC): %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf 'host: %s   user: %s   root: %s\n' "$(uname -n)" "$(id -un)" "$(if is_root; then echo yes; else echo no; fi)"
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
    printf 'kernel: %s\n' "$(uname -r)"
}

# The scenario README and the forensics questions usually sit on a Desktop.
s_readme() {
    local f lower
    for f in /home/*/Desktop/* /root/Desktop/*; do
        [ -f "$f" ] || continue
        lower=$(printf '%s' "${f##*/}" | tr '[:upper:]' '[:lower:]')
        case "$lower" in *readme*|*forensic*) ;; *) continue ;; esac
        printf '\n--- %s ---\n' "$f"
        case "$lower" in
            *.html|*.htm) sed -e 's/<[^>]*>//g' "$f" | grep -v '^[[:space:]]*$' | head -n 200 ;;
            *) head -n 200 "$f" ;;
        esac
    done
    printf '\nOther files that look like a README or forensics question:\n'
    find /home /root /opt /srv -maxdepth 4 -type f \( -iname '*readme*' -o -iname '*forensic*' \) 2>/dev/null | head -n 40
}

s_users() {
    echo 'UID 0 and regular users (UID >= 1000):'
    awk -F: '$3 == 0 || ($3 >= 1000 && $3 < 65534) { printf "  %-20s uid=%-6s gid=%-6s home=%-24s shell=%s\n", $1, $3, $4, $6, $7 }' /etc/passwd
    echo
    echo 'Every account that can log in (shell is not nologin or false):'
    awk -F: '$7 !~ /(nologin|false)$/ && $7 != "" { print "  " $1 "  " $7 }' /etc/passwd
}

s_groups() {
    local g
    for g in sudo admin wheel adm lpadmin sambashare docker shadow; do getent group "$g"; done
}

s_passwords() {
    is_root || { echo '(needs root: start the runner with sudo)'; return; }
    echo 'name status(L=locked NP=no password P=has password) last-change min max warn inactive'
    passwd -S -a
}

s_sudoers() {
    is_root || { echo '(needs root: start the runner with sudo)'; return; }
    nonblank /etc/sudoers /etc/sudoers.d/* | sed 's/^/  /'
    echo
    echo 'Lines that skip the password prompt:'
    grep -rHE 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d
}

s_logins() {
    last -n 15
    echo
    echo 'Guest and automatic login settings:'
    grep -rHE '^[[:space:]]*(allow-guest|autologin-user|AutomaticLogin|AutomaticLoginEnable)' /etc/lightdm /etc/gdm3 /etc/gdm /etc/sddm.conf /etc/sddm.conf.d
}

s_pwpolicy() {
    local f
    grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|ENCRYPT_METHOD|LOGIN_RETRIES)' /etc/login.defs
    for f in /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account /etc/security/pwquality.conf; do
        [ -r "$f" ] || continue
        printf -- '--- %s ---\n' "$f"
        nonblank "$f"
    done
}

s_ssh() {
    if have sshd && is_root; then
        sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|permitemptypasswords|protocol|x11forwarding|pubkeyauthentication|maxauthtries|usepam|allowusers|allowgroups) '
    elif [ -r /etc/ssh/sshd_config ]; then
        nonblank /etc/ssh/sshd_config
    else
        echo '(sshd is not installed)'
    fi
}

s_firewall() {
    if have ufw; then
        if is_root; then ufw status verbose; else echo '(ufw status needs root: start the runner with sudo)'; fi
    else
        echo '(ufw is not installed)'
    fi
    if have iptables && is_root; then iptables -S | head -n 40; fi
}

s_ports() {
    if have ss; then ss -tulpn; elif have netstat; then netstat -tulpn; else echo '(neither ss nor netstat found)'; fi
}

s_services() {
    have systemctl || { echo '(systemctl is not available)'; return; }
    echo 'Running services:'
    systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{ print "  " $1 }'
    echo
    echo 'Enabled at boot:'
    systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend | awk '{ print "  " $1 }'
}

# Names that are often unauthorized or insecure on these images. Compare with the README:
# a match is a lead to check, not proof that something must be removed.
s_packages() {
    have dpkg-query || { echo '(dpkg is not available)'; return; }
    echo 'Packages that deserve a look:'
    dpkg-query -W -f='${Package}\n' | grep -E '^(nmap|zenmap|john|hydra|netcat.*|ncat|nikto|medusa|sqlmap|ettercap.*|kismet|aircrack-ng|ophcrack.*|fcrackzip|pdfcrack|dsniff|hping3|socat|wireshark.*|tshark|tcpdump|telnet|telnetd|vsftpd|proftpd.*|pure-ftpd.*|tftpd.*|apache2|nginx|lighttpd|samba|nfs-kernel-server|bind9|dovecot.*|postfix|snmpd|xinetd|rsh.*|talk.*|squid|openssh-server|cups|avahi-daemon|transmission.*|deluge.*|ktorrent|qbittorrent|minetest|freeciv.*|wesnoth.*|aisleriot|gnome-mines|gnome-sudoku|gnome-games|iagno|lightsoff|quadrapassel|swell-foop|tali|hitori)$' | sed 's/^/  /'
    echo
    echo 'Most recent package installs:'
    grep ' install ' /var/log/dpkg.log | tail -n 30 | sed 's/^/  /'
    if have snap; then echo; echo 'Snaps:'; snap list; fi
}

s_updates() {
    have apt-get || { echo '(apt-get is not available)'; return; }
    printf 'Packages that a real upgrade would change (simulation only): %s\n' "$(apt-get -s upgrade | grep -c '^Inst')"
    echo
    echo 'Automatic update settings:'
    nonblank /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/10periodic | sed 's/^/  /'
    echo
    echo 'Package sources:'
    nonblank /etc/apt/sources.list /etc/apt/sources.list.d/* | sed 's/^/  /'
}

s_persistence() {
    local u
    echo '/etc/crontab:'
    nonblank /etc/crontab | sed 's/^/  /'
    echo
    echo 'Files in the cron folders:'
    find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -maxdepth 1 -type f | sed 's/^/  /'
    if is_root; then
        echo
        while IFS=: read -r u _; do
            crontab -l -u "$u" | sed "s/^/  [crontab $u] /"
        done < /etc/passwd
    fi
    echo
    echo 'systemd timers:'
    systemctl list-timers --all --no-pager --no-legend | sed 's/^/  /'
    echo
    echo '/etc/rc.local:'
    nonblank /etc/rc.local | sed 's/^/  /'
    echo
    echo 'Autostart entries:'
    find /etc/xdg/autostart /home/*/.config/autostart -maxdepth 1 -type f | head -n 60 | sed 's/^/  /'
}

s_processes() { ps -eo user,pid,ppid,comm,args | head -n 150; }

s_media() {
    find /home /root /srv /opt /tmp -xdev -type f \( -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.wmv' \) | head -n 100
}

s_suid() { limit 120 find / -xdev -type f -perm -4000 | head -n 80; }

s_worldwritable() { limit 120 find / -xdev -type f -perm -0002 -not -path '/proc/*' | head -n 60; }

s_permissions() {
    stat -c '%a %U:%G %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /etc/login.defs
}

s_network() {
    local k
    echo '/etc/hosts:'
    nonblank /etc/hosts | sed 's/^/  /'
    echo
    for k in net.ipv4.ip_forward net.ipv4.tcp_syncookies kernel.randomize_va_space net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.send_redirects net.ipv4.icmp_echo_ignore_broadcasts; do
        printf '  %s = %s\n' "$k" "$(sysctl -n "$k")"
    done
}

s_homes() {
    local d item names
    for d in /home/*; do
        [ -d "$d" ] || continue
        names=''
        for item in "$d"/* "$d"/.[!.]*; do
            [ -e "$item" ] && names="${names}${item##*/} "
        done
        printf '%s: %s\n' "$d" "$names"
    done
}

printf 'CyberPatriot baseline recon. READ-ONLY: this script changes nothing on the VM.\n'
report 'HOST' s_host
report 'README AND FORENSICS FILES' s_readme
report 'USERS' s_users
report 'ADMIN-LIKE GROUPS' s_groups
report 'PASSWORD STATUS (no hashes are printed)' s_passwords
report 'SUDO RULES' s_sudoers
report 'RECENT LOGINS, GUEST AND AUTOLOGIN SETTINGS' s_logins
report 'PASSWORD POLICY (login.defs, PAM)' s_pwpolicy
report 'SSH SERVER SETTINGS' s_ssh
report 'FIREWALL' s_firewall
report 'LISTENING PORTS' s_ports
report 'SERVICES' s_services
report 'PACKAGES AND SNAPS' s_packages
report 'UPDATES' s_updates
report 'SCHEDULED TASKS AND STARTUP ITEMS' s_persistence
report 'PROCESSES (first 150)' s_processes
report 'AUDIO AND VIDEO FILES' s_media
report 'SETUID FILES' s_suid
report 'WORLD-WRITABLE FILES (first 60)' s_worldwritable
report 'PERMISSIONS OF KEY FILES' s_permissions
report 'NETWORK AND KERNEL SETTINGS' s_network
report 'HOME DIRECTORY CONTENTS' s_homes
printf '\n===== DONE =====\n'
