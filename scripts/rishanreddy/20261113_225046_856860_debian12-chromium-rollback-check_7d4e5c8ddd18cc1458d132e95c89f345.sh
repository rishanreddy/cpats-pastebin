#!/usr/bin/env bash
# PURPOSE: READ-ONLY check of rollback options for a proposed Chromium upgrade.
# No downloads, package changes, repository changes, or forensics work.
set -u
export LC_ALL=C
printf '===== CURRENT AND AVAILABLE CHROMIUM VERSIONS =====\n'
apt-cache policy chromium chromium-common chromium-sandbox 2>/dev/null |
    awk '/^[^[:space:]][^:]*:$/ || /^[[:space:]]*(Installed|Candidate):/ {print}'
printf '\n===== CHROMIUM UPGRADE PLAN, SIMULATION ONLY =====\n'
apt-get -s -o Debug::NoLocking=1 --no-install-recommends --only-upgrade install chromium chromium-common chromium-sandbox 2>/dev/null |
    awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
printf '\n===== CACHED CHROMIUM ROLLBACK PACKAGES =====\n'
found=0
for file in /var/cache/apt/archives/chromium_113.0.5672.126-1_*.deb /var/cache/apt/archives/chromium-common_113.0.5672.126-1_*.deb /var/cache/apt/archives/chromium-sandbox_113.0.5672.126-1_*.deb; do
    [ -f "$file" ] || continue
    found=1
    printf '%s\n' "$file"
done
if [ "$found" -eq 0 ]; then printf 'No original version-113 Chromium packages are cached in the standard APT archive.\n'; fi
printf '\n===== PRESERVED ORIGINAL SNAPSHOT SOURCE =====\n'
original=/root/afa-batch2-20261113T221719Z-43866/sources.list
if [ -r "$original" ]; then
    awk '
        $1=="deb" {
            for(i=2;i<=NF;i++) if($i ~ /:\/\//) {
                url=$i; sub(/^[^:]*:\/\//,"",url); sub(/^.*@/,"",url); sub(/[?#].*/,"",url)
                if(url ~ /^snapshot\.debian\.org\//) print "Preserved archive location:",url,"Suite:",$(i+1)
            }
        }
    ' "$original"
else printf 'Original snapshot-source backup is unavailable.\n'; fi
printf '\nRead-only rollback check complete.\n'
