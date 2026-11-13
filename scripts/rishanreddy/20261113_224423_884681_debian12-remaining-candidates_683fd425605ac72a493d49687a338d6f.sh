#!/usr/bin/env bash
# PURPOSE: READ-ONLY inventory of remaining prohibited software/media and Chromium.
# No forensics questions, answer files, passwords, or process arguments are read.
set -u
export LC_ALL=C
printf '===== INSTALLED SOFTWARE CANDIDATES =====\n'
dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' 2>/dev/null |
    awk '$2 == "installed" && $1 ~ /^(chromium.*|ettercap.*|netcat.*|ncat|inetutils-telnet|telnet|john|hydra|nmap|wireshark.*|freeciv.*|ufw|libpam-pwquality|libpam-passwdqc)$/ {print}'
printf '\n===== CHROMIUM VERSION CANDIDATES =====\n'
apt-cache policy chromium chromium-common chromium-sandbox 2>/dev/null |
    awk '/^[^[:space:]][^:]*:$/ || /^[[:space:]]*(Installed|Candidate):/ {print}'
printf '\n===== CHROMIUM UPDATE PLAN, SIMULATION ONLY =====\n'
apt-get -s -o Debug::NoLocking=1 --no-install-recommends --only-upgrade install chromium chromium-common chromium-sandbox 2>/dev/null |
    awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
printf '\n===== MEDIA FILES IN EMPLOYEE MUSIC FOLDER, LIST ONLY =====\n'
if [ -d /home/ppotts/Music ]; then
    find /home/ppotts/Music -xdev -type f \( -iname '*.mp3' -o -iname '*.mp4' -o -iname '*.m4a' -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.avi' -o -iname '*.mkv' \) -printf '%s bytes %p\n' 2>/dev/null
fi
printf '\n===== SELECTED CURRENT PASSWORD POLICY =====\n'
grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]' /etc/login.defs 2>/dev/null || true
for file in /etc/pam.d/common-password /etc/pam.d/common-auth; do
    [ -r "$file" ] || continue
    printf '%s:\n' "$file"
    awk '
        /^[[:space:]]*#/ {next}
        {for(i=1;i<=NF;i++) if($i ~ /(^|\/)pam_[[:alnum:]_]+\.so$/) printf "module=%s ",$i;
         for(i=1;i<=NF;i++) if($i ~ /^(nullok|obscure|yescrypt|sha512|enforce_for_root)$/ || $i ~ /^(minlen|remember|[duloc]credit|retry|difok)=-?[0-9]+$/) printf "%s ",$i;
         printf "\n"}
    ' "$file"
done
printf '\nRead-only candidate review complete. Nothing was changed.\n'
