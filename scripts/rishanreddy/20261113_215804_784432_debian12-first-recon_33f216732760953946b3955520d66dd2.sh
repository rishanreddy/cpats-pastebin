#!/usr/bin/env bash
# PURPOSE: compare the Debian 12 AFA image with the supplied scenario.
# CHANGES: READ-ONLY. No files, accounts, packages, or services are changed.
# Does not print the credential-bearing README, password hashes, key contents,
# environment variables, or process arguments. Run using sudo on the VM.
set -u
export LC_ALL=C
export SYSTEMD_PAGER=cat

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n===== %s =====\n' "$1"; }
bounded() {
    local seconds="$1"
    shift
    if have timeout; then timeout "$seconds" "$@"; else "$@"; fi
}
admins='pparker tstark ppotts hhogan nfury mhill pcoulson'
users='bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
authorized=" $admins $users "

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run this read-only script with sudo for complete results.\n'
    exit 1
fi

section 'READ-ONLY BASELINE'
printf 'Scenario: Debian 12, AFA. Primary user: pparker. Required remote service: SSH.\n'
printf 'No fixes have been applied. Findings are candidates, not scored results.\n'
date -u '+UTC observation time: %Y-%m-%d %H:%M:%S'
awk -F= '/^(ID|VERSION_ID|PRETTY_NAME)=/ {print}' /etc/os-release
printf 'Kernel: %s\n' "$(uname -r)"

section 'DESKTOP FORENSICS FILE LOCATIONS'
printf 'Question contents and the credential-bearing README are omitted from public output.\n'
for desktop in /home/*/Desktop /root/Desktop; do
    [ -d "$desktop" ] || continue
    find "$desktop" -maxdepth 1 -type f -iname '*forensic*' -print 2>/dev/null
done

section 'AUTHORIZED ACCOUNT CHECK'
for name in $admins $users; do
    entry=$(getent passwd "$name" 2>/dev/null) || entry=''
    if [ -z "$entry" ]; then
        printf 'MISSING authorized account: %s\n' "$name"
        continue
    fi
    printf '%s\n' "$entry" | awk -F: '{printf "%s uid=%s gid=%s home=%s shell=%s\n",$1,$3,$4,$6,$7}'
    passwd -S "$name" 2>/dev/null
    id -nG "$name" 2>/dev/null
done
printf '\nLocal UID 0 and regular accounts:\n'
while IFS=: read -r name _ uid gid _ home shell; do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    if [ "$uid" -eq 0 ] || { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; }; then
        printf '%s uid=%s gid=%s home=%s shell=%s' "$name" "$uid" "$gid" "$home" "$shell"
        case "$authorized" in *" $name "*) printf ' [authorized]\n' ;;
            *) if [ "$name" = root ]; then printf ' [root: direct login prohibited]\n';
               else printf ' [NOT IN README: investigate]\n'; fi ;;
        esac
    fi
done < /etc/passwd
printf '\nOther local accounts with login shells:\n'
awk -F: '$3 > 0 && $3 < 1000 && $7 !~ /(nologin|false)$/ && $7 != "" {print $1, "uid=" $3, "shell=" $7}' /etc/passwd
printf '\nRoot password status, no hash:\n'
passwd -S root 2>/dev/null

section 'ADMINISTRATION AND SUDO'
for group in sudo admin wheel shadow docker; do getent group "$group" 2>/dev/null || true; done
if have visudo; then visudo -c 2>&1; fi
printf 'Sudo policy files containing password-prompt bypasses, commands omitted:\n'
grep -rlE '^[[:space:]]*[^#].*(NOPASSWD|!authenticate)' /etc/sudoers /etc/sudoers.d 2>/dev/null || true
printf 'Sudo policy files containing include directives, contents omitted:\n'
grep -rlE '^[[:space:]]*([#@]include)' /etc/sudoers /etc/sudoers.d 2>/dev/null || true

section 'PASSWORD POLICY'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|ENCRYPT_METHOD|LOGIN_RETRIES)[[:space:]]' /etc/login.defs 2>/dev/null || true
for file in /etc/pam.d/common-password /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/sshd; do
    [ -r "$file" ] || continue
    printf '\n%s, module names and selected policy options only:\n' "$file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        { for (i=1; i<=NF; i++) {
            if ($i ~ /(^|\/)pam_[[:alnum:]_]+\.so$/) printf "line %d module=%s", NR, $i
        }
        for (i=1; i<=NF; i++) {
            if ($i ~ /^(nullok|nullok_secure|try_first_pass|use_first_pass|use_authtok|yescrypt|sha512|md5|obscure|enforce_for_root)$/ ||
                $i ~ /^(minlen|[duloc]credit|retry|remember|minclass|difok|deny|unlock_time|fail_interval|rounds)=-?[0-9]+$/)
                printf " %s", $i
        }
        printf "\n" }
    ' "$file"
done
for file in /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf /etc/security/faillock.conf /etc/security/pwhistory.conf; do
    [ -r "$file" ] || continue
    printf '\n%s:\n' "$file"
    grep -E '^[[:space:]]*(minlen|minclass|[duloc]credit|difok|maxrepeat|maxclassrepeat|dictcheck|usercheck|enforcing|enforce_for_root|deny|unlock_time|fail_interval|remember)[[:space:]=]' "$file" 2>/dev/null || true
done

section 'SSH CONFIGURATION AND SERVICE'
sshd_bin=$(command -v sshd 2>/dev/null || true)
[ -n "$sshd_bin" ] || { [ ! -x /usr/sbin/sshd ] || sshd_bin=/usr/sbin/sshd; }
if [ -n "$sshd_bin" ]; then
    if "$sshd_bin" -t >/dev/null 2>&1; then printf 'sshd syntax: VALID\n';
    else printf 'sshd syntax: INVALID, investigate before any reload\n'; fi
    "$sshd_bin" -T 2>/dev/null | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|pubkeyauthentication|usepam|maxauthtries|x11forwarding|allowusers|allowgroups|denyusers|denygroups|authenticationmethods|authorizedkeysfile) ' || true
    printf 'Files containing Match directives, scoped settings need further inspection:\n'
    grep -rlE '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || true
else
    printf 'SSH server executable not found. SSH is required.\n'
fi
if have systemctl; then
    for service in ssh.service ssh.socket; do
        printf '%s enabled: ' "$service"; systemctl is-enabled "$service" 2>/dev/null || true
        printf '%s active: ' "$service"; systemctl is-active "$service" 2>/dev/null || true
    done
fi

section 'FIREWALL AND LISTENING SOCKETS'
if have ufw; then ufw status verbose 2>/dev/null; else printf 'UFW executable not found.\n'; fi
if have ss; then ss -tuln 2>/dev/null; fi

section 'LIGHTDM AND BROWSER'
printf 'Configured display manager:\n'
if [ -r /etc/X11/default-display-manager ]; then
    IFS= read -r display_manager < /etc/X11/default-display-manager || true
    printf '%s\n' "$display_manager"
fi
printf 'Guest and automatic-login settings:\n'
grep -rHE '^[[:space:]]*(allow-guest|autologin-user|autologin-user-timeout|greeter-hide-users)[[:space:]]*=' /etc/lightdm 2>/dev/null || true
if have update-alternatives; then update-alternatives --query x-www-browser 2>/dev/null | grep -E '^(Name|Status|Value|Alternative|Priority):'; fi
for file in /etc/xdg/mimeapps.list /usr/share/applications/mimeapps.list /home/*/.config/mimeapps.list /home/*/.local/share/applications/mimeapps.list; do
    [ -r "$file" ] || continue
    grep -HE '^(x-scheme-handler/https?|text/html)=' "$file" 2>/dev/null || true
done

section 'PACKAGE VERSIONS AND CANDIDATES'
if have dpkg-query; then
    dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' 2>/dev/null |
        awk '$2 == "installed" && $1 ~ /^(chromium.*|openssh-server|sudo|ufw|lightdm|libpam-pwquality|libpam-passwdqc|libpam-modules|unattended-upgrades|nmap|zenmap|john|hydra|netcat.*|ncat|nikto|medusa|sqlmap|ettercap.*|kismet|aircrack-ng|ophcrack.*|fcrackzip|pdfcrack|dsniff|hping3|socat|wireshark.*|tshark|tcpdump|telnet.*|inetutils-telnet.*|vsftpd|proftpd.*|samba|apache2|nginx|snmpd|xinetd|rsh.*|transmission.*|deluge.*|ktorrent|qbittorrent|minetest|freeciv.*|wesnoth.*|aisleriot|gnome-mines|gnome-sudoku|ansible.*|puppet.*|salt-.*|chef.*|cfengine.*)$/ {print}'
fi
if have apt-cache; then
    apt-cache policy chromium openssh-server ufw lightdm sudo 2>/dev/null |
        awk '/^[^[:space:]][^:]*:$/ || /^[[:space:]]*(Installed|Candidate):/ {print}'
fi
if have apt-get; then
    printf 'Cached upgrade simulation, no index refresh and no package changes:\n'
    bounded 60 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null |
        awk '/^Inst / {n++} END {printf "Packages proposed for upgrade: %d. This uses existing package indexes.\n",n}'
fi

section 'RUNNING AND ENABLED SERVICES'
if have systemctl; then
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}'
    printf '\nEnabled services:\n'
    systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}'
    printf '\nTimer names, commands omitted:\n'
    systemctl list-unit-files --type=timer --no-pager --no-legend 2>/dev/null | awk '{print $1,$2}'
fi
printf '\nProcess executable names, arguments omitted to protect runner credentials:\n'
ps -eo user=,comm= 2>/dev/null

section 'SCHEDULED TASK FILE LOCATIONS'
find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron/crontabs -maxdepth 1 -type f -print 2>/dev/null || true
printf 'Commands are omitted until targeted review to avoid uploading credentials.\n'

section 'MEDIA CANDIDATES, LIST ONLY'
bounded 45 find /home /srv /opt -xdev -type f \( -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.wmv' \) -print 2>/dev/null |
    awk 'NR <= 100 {print} END {if (NR>100) print "Additional paths omitted; total observed:",NR}'
printf 'Media candidates can be forensics evidence. Do not delete before reading questions.\n'

section 'SECURITY FILE PERMISSIONS'
stat -c '%a %U:%G %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/ssh/sshd_config /etc/login.defs 2>/dev/null || true

section 'NEXT STEPS'
printf 'Read Desktop forensics questions before modifying evidence.\n'
printf 'Review candidates against the README, approve a reversible fix batch, then verify.\n'
printf 'Preserve all authorized users, SSH, LightDM, CCS Client, and UTC.\n'
printf 'READ-ONLY inspection complete. No vulnerabilities were changed by this script.\n'
