#!/usr/bin/env bash
# PURPOSE: prepare rollback package backups for the approved Chromium-only upgrade.
# CHANGES: create a root-only backup directory and download signed archive metadata
# and the original Chromium packages. No installed packages or global sources change.
set -euo pipefail
export LC_ALL=C
umask 077
printf '===== CHROMIUM ROLLBACK PACKAGE PREPARATION =====\n'
[ "$(id -u)" -eq 0 ] || { printf 'Root runner required.\n'; exit 1; }
grep -qx 'ID=debian' /etc/os-release
grep -Eq '^VERSION_ID="?12"?$' /etc/os-release
for tool in apt-get dpkg-query dpkg-deb sha256sum timeout; do command -v "$tool" >/dev/null; done
before=$(sha256sum /etc/apt/sources.list)
backup_dir="/root/afa-chromium-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
mkdir -m 700 "$backup_dir"
mkdir -m 700 "$backup_dir/packages" "$backup_dir/snapshot-lists"
mkdir -m 700 "$backup_dir/snapshot-lists/partial"
printf 'Backup directory: %s\n' "$backup_dir"
printf '%s\n' "$backup_dir" > "$backup_dir/backup-location.txt"
for package in chromium chromium-common chromium-sandbox; do
    version=$(dpkg-query -W -f='${Version}' "$package")
    state=$(dpkg-query -W -f='${db:Status-Status}' "$package")
    [ "$state" = installed ] && [ "$version" = 113.0.5672.126-1 ] || {
        printf 'Installed Chromium state changed. No upgrade performed; inspect first.\n'; exit 1;
    }
    printf '%s %s\n' "$package" "$version" >> "$backup_dir/original-versions.txt"
done
printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/20230611/ bookworm main' \
    > "$backup_dir/snapshot.list"
# The preserved historical repository has old metadata by design. Disable only
# metadata freshness checking for these isolated backup commands. Signature and
# package checksum verification remain enabled. Global APT configuration is untouched.
snapshot_opts=(
    -o "Dir::Etc::sourcelist=$backup_dir/snapshot.list"
    -o 'Dir::Etc::sourceparts=-'
    -o "Dir::State::lists=$backup_dir/snapshot-lists"
    -o "Dir::Cache::pkgcache=$backup_dir/snapshot-pkgcache.bin"
    -o "Dir::Cache::srcpkgcache=$backup_dir/snapshot-srcpkgcache.bin"
    -o 'Acquire::Check-Valid-Until=false'
    -o 'Acquire::Languages=none'
    -o 'Acquire::Retries=2'
    -o 'Acquire::https::Timeout=30'
    -o 'APT::Sandbox::User=root'
    -o 'APT::Update::Error-Mode=any'
)
printf '\nFetching isolated, signed historical repository metadata.\n'
timeout 300 apt-get "${snapshot_opts[@]}" update
printf '\nDownloading the original three packages for rollback only.\n'
(
    cd -- "$backup_dir/packages"
    for package in chromium chromium-common chromium-sandbox; do
        timeout 300 apt-get "${snapshot_opts[@]}" download "$package=113.0.5672.126-1"
    done
)
printf '\n===== VALIDATE ROLLBACK ARCHIVES =====\n'
for package in chromium chromium-common chromium-sandbox; do
    found=0
    for archive in "$backup_dir/packages/${package}_"*.deb; do
        [ -f "$archive" ] || continue
        [ "$(dpkg-deb -f "$archive" Package)" = "$package" ]
        [ "$(dpkg-deb -f "$archive" Version)" = 113.0.5672.126-1 ]
        found=$((found+1))
    done
    [ "$found" -eq 1 ] || { printf 'Rollback archive validation failed for %s\n' "$package"; exit 1; }
    printf 'Saved verified rollback archive: %s 113.0.5672.126-1\n' "$package"
done
sha256sum "$backup_dir/packages/"*.deb > "$backup_dir/SHA256SUMS"
[ "$(sha256sum /etc/apt/sources.list)" = "$before" ]
printf 'Global security sources are unchanged. No installed packages were changed.\n'
printf 'READY: %s\n' "$backup_dir"
printf 'Next: ensure Chromium is closed, back up profiles, and apply the approved upgrade.\n'
