#!/usr/bin/env bash
# PURPOSE: apply the approved Chromium-only update after verified rollback downloads.
# CHANGES: back up closed-browser profiles; upgrade Chromium/common/sandbox and
# install their required libharfbuzz-subset0 dependency. No sources or hacking tools change.
set -Eeuo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
umask 077
backup_dir=/root/afa-chromium-20261113T225851Z-54894
old_version=113.0.5672.126-1
target_version=156.0.8078.79-1~deb12u1
authorized='pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter'
upgrade_started=0
rollback_debs=()
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
browser_open() { ps -eo comm= | awk '$1=="chromium" {found=1} END {exit !found}'; }
rollback() {
    local status="$?"
    trap - ERR INT TERM
    set +e
    if [ "$upgrade_started" -eq 1 ]; then
        printf '\nUpgrade validation failed. Reinstalling the three saved original packages.\n'
        if apt-get -o DPkg::Lock::Timeout=120 --no-install-recommends --allow-downgrades -y install "${rollback_debs[@]}"; then
            printf 'Original Chromium packages restored. Saved profile backups remain available.\n'
        else
            printf 'PACKAGE RESTORE NEEDS ATTENTION. Backups: %s\n' "$backup_dir"
        fi
    else printf '\nStopped before upgrading installed packages. Backups: %s\n' "$backup_dir"; fi
    printf 'Global repositories and security-update configuration were not changed.\n'
    [ "$status" -ne 0 ] || status=1
    exit "$status"
}
trap rollback ERR INT TERM

printf '===== CHROMIUM-ONLY UPGRADE PREFLIGHT =====\n'
[ "$(id -u)" -eq 0 ] || fail 'Root runner required.'
grep -qx 'ID=debian' /etc/os-release || fail 'Debian is required.'
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release || fail 'Debian 12 is required.'
if browser_open; then
    printf 'ACTION REQUIRED: Save tabs and close all Chromium windows.\n'
    printf 'Chromium is still running. No profiles or installed packages changed by this script.\n'
    printf 'Verified rollback packages are already saved at %s\n' "$backup_dir"
    exit 10
fi
[ -d "$backup_dir/packages" ] && [ -f "$backup_dir/SHA256SUMS" ] || fail 'Verified rollback directory is missing.'
sha256sum -c "$backup_dir/SHA256SUMS"
for package in chromium chromium-common chromium-sandbox; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$package")" = installed ] || fail "Package not fully installed: $package"
    [ "$(dpkg-query -W -f='${Version}' "$package")" = "$old_version" ] || fail "Installed version changed: $package"
    found=0
    for archive in "$backup_dir/packages/${package}_"*.deb; do
        [ -f "$archive" ] || continue
        [ "$(dpkg-deb -f "$archive" Package)" = "$package" ] || fail 'Rollback package-name mismatch.'
        [ "$(dpkg-deb -f "$archive" Version)" = "$old_version" ] || fail 'Rollback package-version mismatch.'
        rollback_debs+=("$archive")
        found=$((found+1))
    done
    [ "$found" -eq 1 ] || fail "Expected exactly one rollback package: $package"
done
audit=$(dpkg --audit)
[ -z "$audit" ] || fail 'Package database has incomplete package work.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service is inactive: $service"; done
ufw status | grep -x 'Status: active' >/dev/null || fail 'UFW is not active.'
grep -E '^[[:space:]]*deb[[:space:]].*[[:space:]]bookworm-security[[:space:]]' /etc/apt/sources.list >/dev/null || fail 'Security-update source is missing.'
sources_before=$(sha256sum /etc/apt/sources.list)
default_before=$(update-alternatives --query x-www-browser 2>/dev/null | awk '/^Value:/ {print $2}')
apt-cache madison chromium | awk -F'|' -v version="$target_version" '
    {v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)}
    v==version && $3 ~ /security\.debian\.org\/debian-security[[:space:]]+bookworm-security\/main/ {found=1}
    END {exit !found}
' || fail 'Expected target version is not offered by official bookworm-security.'
plan=$(apt-get -s -o Debug::NoLocking=1 --no-install-recommends --only-upgrade install \
    "chromium=$target_version" "chromium-common=$target_version" "chromium-sandbox=$target_version")
printf '%s\n' "$plan" | awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
if printf '%s\n' "$plan" | grep -E '^Remv ' >/dev/null; then fail 'Unexpected package removals in the upgrade plan.'; fi
while IFS= read -r package; do
    case "${package%%:*}" in chromium|chromium-common|chromium-sandbox|libharfbuzz-subset0) ;;
        *) fail "Unexpected package change in the plan: $package" ;;
    esac
done < <(printf '%s\n' "$plan" | awk '/^Inst / {print $2}')

printf '\n===== BACK UP CLOSED-BROWSER PROFILES =====\n'
[ ! -e "$backup_dir/profiles" ] || fail 'A profile backup already exists; inspect before replacing it.'
mkdir -m 700 "$backup_dir/profiles"
for name in $authorized; do
    profile="/home/$name/.config/chromium"
    [ -d "$profile" ] || continue
    [ ! -L "$profile" ] || fail "Profile is a symlink; inspect its target before backing up: $name"
    mkdir -m 700 "$backup_dir/profiles/$name"
    cp -a "$profile" "$backup_dir/profiles/$name/chromium"
    printf 'Private profile backup saved for %s; contents omitted.\n' "$name"
done
if browser_open; then fail 'Chromium was reopened during backup; close it before proceeding.'; fi

printf '\n===== INSTALL ONLY THE APPROVED CHROMIUM UPDATE =====\n'
upgrade_started=1
apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 --no-install-recommends --only-upgrade -y install \
    "chromium=$target_version" "chromium-common=$target_version" "chromium-sandbox=$target_version"

printf '\n===== VALIDATE UPGRADED BROWSER AND REQUIRED SETTINGS =====\n'
for package in chromium chromium-common chromium-sandbox; do
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$package")" = installed ] || fail "Incomplete upgraded package: $package"
    [ "$(dpkg-query -W -f='${Version}' "$package")" = "$target_version" ] || fail "Unexpected upgraded version: $package"
done
dpkg-query -W -f='${Package} ${db:Status-Status} ${Version}\n' chromium chromium-common chromium-sandbox libharfbuzz-subset0
if version_output=$(/usr/bin/chromium --version 2>/dev/null); then printf '%s\n' "$version_output"; fi
audit=$(dpkg --audit)
[ -z "$audit" ] || fail 'Package database is not clean after upgrade.'
default_after=$(update-alternatives --query x-www-browser 2>/dev/null | awk '/^Value:/ {print $2}')
[ "$default_after" = "$default_before" ] || fail 'System browser default changed unexpectedly.'
[ "$(sha256sum /etc/apt/sources.list)" = "$sources_before" ] || fail 'Repository configuration changed unexpectedly.'
for service in ssh lightdm ccsclient; do systemctl is-active --quiet "$service" || fail "Required service inactive: $service"; done
ufw status | grep -x 'Status: active' >/dev/null || fail 'UFW became inactive.'
printf 'Chromium update validated. Browser default, security sources, and required services are preserved.\n'
printf 'Private rollback packages and pre-upgrade profiles: %s\n' "$backup_dir"
printf 'Undo if necessary: close Chromium, reinstall the saved old packages with --allow-downgrades, then restore the saved profile rather than opening a migrated profile with the old browser.\n'
printf 'The required new dependency may remain installed after package rollback.\n'
printf 'No hacking tools, forensics files, or user passwords were changed.\n'
trap - ERR INT TERM
