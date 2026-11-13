#!/usr/bin/env bash
# PURPOSE: apply the approved Debian 12 repositories, UFW, and FTP batch.
# CHANGES: replace the frozen source; refresh indexes; install UFW if missing;
# allow TCP/22, deny other unsolicited incoming traffic, allow outgoing; disable FTP.
# No release upgrade, general package upgrade, or forensics work is performed.
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077
backup_dir=''
sources_changed=0
firewall_changed=0
ftp_changed=0
ufw_was_installed=0
ufw_was_active=0
ufw_install_attempted=0
ftp_was_enabled=''
ftp_was_active=0
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]; }
rollback() {
    local status="$?" ok=1
    trap - ERR INT TERM
    set +e
    printf '\nBatch failed or was interrupted. Restoring approved changes where possible.\n'
    if [ "$firewall_changed" -eq 1 ]; then
        ufw --force disable || ok=0
        if [ -d "$backup_dir/ufw-before" ]; then cp -a "$backup_dir/ufw-before/." /etc/ufw/ || ok=0; fi
        if [ -f "$backup_dir/default-ufw" ]; then cp -a "$backup_dir/default-ufw" /etc/default/ufw || ok=0; fi
        if [ "$ufw_was_active" -eq 1 ]; then ufw --force enable || ok=0; fi
        if [ -s "$backup_dir/iptables-before.rules" ]; then iptables-restore < "$backup_dir/iptables-before.rules" || ok=0; fi
        if [ -s "$backup_dir/ip6tables-before.rules" ]; then ip6tables-restore < "$backup_dir/ip6tables-before.rules" || ok=0; fi
    fi
    if [ "$ftp_changed" -eq 1 ]; then
        if [ "$ftp_was_enabled" = enabled ]; then systemctl enable vsftpd || ok=0; fi
        if [ "$ftp_was_active" -eq 1 ]; then systemctl start vsftpd || ok=0; fi
    fi
    if [ "$ufw_install_attempted" -eq 1 ] && [ "$ufw_was_installed" -eq 0 ] && installed ufw; then
        apt-get -o DPkg::Lock::Timeout=60 -y remove ufw || ok=0
    fi
    if [ "$sources_changed" -eq 1 ]; then
        cp -a "$backup_dir/sources.list" /etc/apt/sources.list || ok=0
        printf 'Source configuration restored. Downloaded package indexes can be rebuilt with apt-get update.\n'
    fi
    if [ "$ok" -eq 1 ]; then printf 'Rollback completed. Newly installed dependency libraries may remain.\n';
    else printf 'ROLLBACK NEEDS ATTENTION. Backup directory: %s\n' "$backup_dir"; fi
    systemctl is-active ssh lightdm ccsclient 2>/dev/null || true
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== APPROVED BATCH 2: PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Run as root through the runner or sudo.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Only Debian 12 is approved.'
for tool in apt-get apt-cache dpkg-query systemctl grep awk cp mkdir chmod timeout ss; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required existing tool missing: $tool"
done
[ -f /etc/apt/sources.list ] && [ ! -L /etc/apt/sources.list ] || fail 'Expected a regular sources.list file.'
[ -r /usr/share/keyrings/debian-archive-keyring.gpg ] || fail 'Official Debian archive keyring is missing.'
for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -Eq '^[[:space:]]*(deb[[:space:]]|deb-src[[:space:]]|Types:)' "$file"; then
        fail 'Additional repository definitions appeared; inspect them before changing sources.'
    fi
done
for service in ssh lightdm ccsclient; do
    systemctl is-active --quiet "$service" || fail "Required service is not active: $service"
done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled.'
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'SSH configuration does not validate.'
ssh_effective=$(/usr/sbin/sshd -T 2>/dev/null)
printf '%s\n' "$ssh_effective" | grep -x 'port 22' >/dev/null || fail 'SSH port changed; firewall rule needs review.'
ftp_was_enabled=$(systemctl is-enabled vsftpd 2>/dev/null || true)
if systemctl is-active --quiet vsftpd; then ftp_was_active=1; fi
if installed ufw; then
    ufw_was_installed=1
    if ufw status 2>/dev/null | grep -x 'Status: active' >/dev/null; then ufw_was_active=1; fi
fi

printf '\n===== ROOT-ONLY BACKUPS =====\n'
backup_dir="/root/afa-batch2-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
cp -a /etc/apt/sources.list "$backup_dir/sources.list"
if [ -d /etc/apt/sources.list.d ]; then cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d"; fi
if [ -d /etc/ufw ]; then cp -a /etc/ufw "$backup_dir/ufw-before"; fi
if [ -f /etc/default/ufw ]; then cp -a /etc/default/ufw "$backup_dir/default-ufw"; fi
printf 'ufw_was_installed=%s\nufw_was_active=%s\nftp_was_enabled=%s\nftp_was_active=%s\n' \
    "$ufw_was_installed" "$ufw_was_active" "$ftp_was_enabled" "$ftp_was_active" > "$backup_dir/initial-state.txt"
printf 'Backup directory: %s\n' "$backup_dir"

printf '\n===== FIX 1: OFFICIAL SOURCES PINNED TO DEBIAN 12 =====\n'
sources_changed=1
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware' \
    > /etc/apt/sources.list
chmod 644 /etc/apt/sources.list
printf 'Configured bookworm, bookworm-updates, and bookworm-security.\n'

printf '\n===== FIX 2: REFRESH PACKAGE INDEXES ONLY =====\n'
timeout 300 apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 -o APT::Update::Error-Mode=any update

printf '\n===== FIX 3: INSTALL UFW =====\n'
if [ "$ufw_was_installed" -eq 0 ]; then
    plan=$(apt-get -s -o Debug::NoLocking=1 --no-install-recommends install ufw)
    printf '%s\n' "$plan" | awk '/^(Inst|Remv) / {print}'
    if printf '%s\n' "$plan" | grep -E '^Remv ' >/dev/null; then fail 'UFW installation would remove packages.'; fi
    if printf '%s\n' "$plan" | grep -E '^Inst [^ ]+ \[' >/dev/null; then
        fail 'UFW installation would upgrade existing packages, outside this batch.'
    fi
    printf '%s\n' "$plan" | awk '/^Inst / {print $2}' > "$backup_dir/new-package-plan.txt"
    ufw_install_attempted=1
    timeout 300 apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
        --no-install-recommends -y install ufw
else
    printf 'UFW is already installed; preserving existing rules and configuration.\n'
fi
for tool in ufw iptables-save iptables-restore ip6tables-save ip6tables-restore; do
    command -v "$tool" >/dev/null 2>&1 || fail "Firewall tool missing after installation: $tool"
done
grep -Eq '^IPV6=yes' /etc/default/ufw || fail 'IPv6 firewall support must be enabled before this batch continues.'
# Snapshot rules before UFW is enabled. Keep rule contents private on the VM.
iptables-save > "$backup_dir/iptables-before.rules"
ip6tables-save > "$backup_dir/ip6tables-before.rules"
if command -v nft >/dev/null 2>&1; then nft list ruleset > "$backup_dir/nft-before.rules"; fi

printf '\n===== FIX 4: ALLOW SSH, THEN ENABLE UFW =====\n'
firewall_changed=1
ufw allow 22/tcp comment 'Required SSH'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
firewall_status=$(ufw status verbose)
printf '%s\n' "$firewall_status"
printf '%s\n' "$firewall_status" | grep -x 'Status: active' >/dev/null || fail 'UFW is not active.'
printf '%s\n' "$firewall_status" | grep -E '^Default: deny \(incoming\), allow \(outgoing\)' >/dev/null || fail 'Unexpected firewall defaults.'
printf '%s\n' "$firewall_status" | grep -E '^22/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere' >/dev/null || fail 'IPv4 SSH rule is missing.'
if grep -Eq '^IPV6=yes' /etc/default/ufw; then
    printf '%s\n' "$firewall_status" | grep -E '^22/tcp \(v6\)[[:space:]]+ALLOW IN[[:space:]]+Anywhere \(v6\)' >/dev/null || fail 'IPv6 SSH rule is missing.'
fi

printf '\n===== FIX 5: STOP AND DISABLE UNREQUIRED FTP =====\n'
ftp_changed=1
systemctl disable --now vsftpd
if systemctl is-active --quiet vsftpd; then fail 'FTP is still running.'; fi
if [ "$(systemctl is-enabled vsftpd 2>/dev/null || true)" = enabled ]; then fail 'FTP is still enabled.'; fi

printf '\n===== POST-CHANGE VALIDATION =====\n'
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'SSH validation failed.'
for service in ssh lightdm ccsclient; do
    systemctl is-active --quiet "$service" || fail "Required service is inactive: $service"
done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled at boot.'
ss -tln | awk 'NR>1 && $4 ~ /:22$/ {found=1} END {exit !found}' || fail 'SSH is not listening on port 22.'
if ss -tln | awk 'NR>1 && $4 ~ /:21$/ {found=1} END {exit !found}'; then fail 'Something is still listening on FTP port 21.'; fi
printf 'SSH remains enabled, active, and listening. LightDM and CCS Client are active.\n'
printf 'UFW is active, SSH is allowed, and vsftpd is disabled and inactive.\n'
printf 'Sources remain pinned to Debian 12. No installed software was generally upgraded.\n'
printf 'Backups and initial service state: %s\n' "$backup_dir"
printf 'Undo: disable UFW, restore saved firewall rules and source configuration, remove newly installed UFW if appropriate, and restore FTP service state.\n'
printf 'Approved batch 2 completed. Check the scoring report for actual points.\n'
trap - ERR INT TERM
