#!/usr/bin/env bash
# Read-only kernel status using the VM's existing APT package lists.
set -euo pipefail
export LC_ALL=C

printf '%s\n' '== Running kernel =='
uname -r
printf '\n%s\n' '== Debian kernel package (local APT cache) =='
apt-cache policy linux-image-amd64
