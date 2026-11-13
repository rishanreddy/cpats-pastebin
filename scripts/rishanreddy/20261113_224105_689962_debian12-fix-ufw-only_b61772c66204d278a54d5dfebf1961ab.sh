#!/usr/bin/env bash
# PURPOSE: apply the explicitly approved UFW-only batch.
# CHANGES: install UFW if absent; allow SSH TCP/22; deny incoming and allow outgoing;
# enable persistent UFW protection. No repository edits, general upgrades, or forensics.
# Package installation/trigger processing has no short outer timeout.
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077
backup_dir=''
ufw_was_installed=0
ufw_was_active=0
install_attempted=0
firewall_changed=0
sources_before=''
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' ufw 2>/dev/null || true)" = installed ]; }
rollback() {
    local status="$?" ok=1
    trap - ERR INT TERM
    set +e
    printf '\nUFW batch failed or was interrupted. Restoring only its saved firewall state.\n'
    if [ "$firewall_changed" -eq 1 ]; then
        ufw --force disable || ok=0
        if [ -d "$backup_dir/ufw-before" ]; then cp -a "$backup_dir/ufw-before/." /etc/ufw/ || ok=0; fi
        if [ -f "$backup_dir/default-ufw" ]; then cp -a "$backup_dir/default-ufw" /etc/default/ufw || ok=0; fi
        if [ "$ufw_was_active" -eq 1 ]; then ufw --force enable || ok=0; fi
        if [ -f "$backup_dir/iptables-before.rules" ]; then iptables-restore < "$backup_dir/iptables-before.rules" || ok=0; fi
        if [ -f "$backup_dir/ip6tables-before.rules" ]; then ip6tables-restore < "$backup_dir/ip6tables-before.rules" || ok=0; fi
    fi
    if [ "$install_attempted" -eq 1 ] && [ "$ufw_was_installed" -eq 0 ] && installed; then
        apt-get -o DPkg::Lock::Timeout=120 -y remove ufw || ok=0
    fi
    printf 'Security-update sources were not edited and are not part of this rollback.\n'
    if [ "$ok" -eq 1 ]; then printf 'Firewall rollback completed.\n';
    else printf 'ROLLBACK NEEDS ATTENTION. Private backups: %s\n' "$backup_dir"; fi
    systemctl is-active ssh lightdm ccsclient 2>/dev/null || true
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== UFW-ONLY PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Use the root runner or sudo.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
for tool in apt-get dpkg dpkg-query systemctl ss iptables-save iptables-restore ip6tables-save ip6tables-restore sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required existing tool missing: $tool"
done
audit=$(dpkg --audit)
[ -z "$audit" ] || fail 'The package database has incomplete work; resolve that before installing UFW.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled.'
/usr/sbin/sshd -t >/dev/null 2>&1 || fail 'SSH configuration does not validate.'
ssh_settings=$(/usr/sbin/sshd -T 2>/dev/null)
printf '%s\n' "$ssh_settings" | grep -x 'port 22' >/dev/null || fail 'SSH port changed; review the firewall rule.'
ss -tln | awk 'NR>1 && $4 ~ /:22$/ {found=1} END {exit !found}' || fail 'SSH is not listening on port 22.'
grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null || fail 'Security-update source is missing.'
sources_before=$(sha256sum /etc/apt/sources.list)
if installed; then
    ufw_was_installed=1
    if ufw status 2>/dev/null | grep -x 'Status: active' >/dev/null; then ufw_was_active=1; fi
fi

printf '\n===== PRIVATE FIREWALL BACKUPS =====\n'
backup_dir="/root/afa-ufw-only-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
if [ -d /etc/ufw ]; then cp -a /etc/ufw "$backup_dir/ufw-before"; fi
if [ -f /etc/default/ufw ]; then cp -a /etc/default/ufw "$backup_dir/default-ufw"; fi
iptables-save > "$backup_dir/iptables-before.rules"
ip6tables-save > "$backup_dir/ip6tables-before.rules"
if command -v nft >/dev/null 2>&1; then nft list ruleset > "$backup_dir/nft-before.rules"; fi
printf 'ufw_was_installed=%s\nufw_was_active=%s\n' "$ufw_was_installed" "$ufw_was_active" > "$backup_dir/initial-state.txt"
printf 'Backup directory: %s\n' "$backup_dir"

printf '\n===== INSTALL UFW ONLY =====\n'
if [ "$ufw_was_installed" -eq 0 ]; then
    plan=$(apt-get -s -o Debug::NoLocking=1 --no-install-recommends install ufw)
    printf '%s\n' "$plan" | awk '/^(Inst|Remv) / {print}'
    if printf '%s\n' "$plan" | grep -E '^Remv ' >/dev/null; then fail 'UFW install would remove other packages.'; fi
    if printf '%s\n' "$plan" | grep -E '^Inst [^ ]+ \[' >/dev/null; then fail 'UFW install would upgrade existing packages; review first.'; fi
    install_attempted=1
    # Let dpkg and man-db complete. Only lock/network waits have bounded timeouts.
    apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 \
        --no-install-recommends -y install ufw
else printf 'UFW is already installed; no package operation is needed.\n'; fi
installed || fail 'UFW is not fully installed.'
grep -Eq '^IPV6=yes' /etc/default/ufw || fail 'IPv6 support is not enabled; inspect before enabling UFW.'

printf '\n===== ALLOW SSH BEFORE ENABLING FIREWALL =====\n'
firewall_changed=1
ufw allow 22/tcp comment 'Required SSH'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

printf '\n===== VERIFY ACTIVE AND PERSISTENT PROTECTION =====\n'
status=$(ufw status verbose)
printf '%s\n' "$status"
printf '%s\n' "$status" | grep -x 'Status: active' >/dev/null || fail 'UFW is not active.'
printf '%s\n' "$status" | grep -E '^Default: deny \(incoming\), allow \(outgoing\)' >/dev/null || fail 'Unexpected firewall defaults.'
printf '%s\n' "$status" | grep -E '^22/tcp[[:space:]]+ALLOW IN[[:space:]]+Anywhere' >/dev/null || fail 'IPv4 SSH allow rule missing.'
printf '%s\n' "$status" | grep -E '^22/tcp \(v6\)[[:space:]]+ALLOW IN[[:space:]]+Anywhere \(v6\)' >/dev/null || fail 'IPv6 SSH allow rule missing.'
grep -x 'ENABLED=yes' /etc/ufw/ufw.conf >/dev/null || fail 'Persistent UFW enablement is missing.'
[ "$(systemctl is-enabled ufw 2>/dev/null)" = enabled ] || fail 'UFW service is not enabled at boot.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
[ "$(systemctl is-enabled ssh 2>/dev/null)" = enabled ] || fail 'SSH is not enabled.'
ss -tln | awk 'NR>1 && $4 ~ /:22$/ {found=1} END {exit !found}' || fail 'SSH port 22 listener missing.'
[ "$(sha256sum /etc/apt/sources.list)" = "$sources_before" ] || fail 'The source file changed unexpectedly during this batch.'
printf 'UFW is active and persistent, with SSH allowed for IPv4 and IPv6.\n'
printf 'SSH, LightDM, and CCS Client remain active. Security sources are unchanged.\n'
printf 'Private backups: %s\n' "$backup_dir"
printf 'Undo: disable UFW, restore saved firewall/configuration state, and remove newly installed UFW if needed.\n'
printf 'UFW-only batch completed. Confirm actual points in the normal Desktop report.\n'
trap - ERR INT TERM
