#!/usr/bin/env bash
# PURPOSE: READ-ONLY check of LightDM guest configuration and Debian package suites.
# No forensics files or credentials are read or printed.
set -u
export LC_ALL=C
printf '===== LIGHTDM GUEST POLICY IN THE MAIN CONFIGURATION =====\n'
awk '
    /^[[:space:]]*\[/ {section=$0}
    /^[[:space:]]*allow-guest[[:space:]]*=/ {print section; print $0}
' /etc/lightdm/lightdm.conf
printf '\n===== LIGHTDM EXECUTABLE AND CONFIG-INSPECTION SUPPORT =====\n'
binary=$(command -v lightdm 2>/dev/null || true)
printf 'PATH lookup: %s\n' "${binary:-not found}"
if [ -x /usr/sbin/lightdm ]; then binary=/usr/sbin/lightdm; fi
if [ -n "$binary" ]; then
    output=$("$binary" --show-config 2>&1)
    status=$?
    printf 'show-config exit code: %s\n' "$status"
    printf '%s\n' "$output" | grep -Ei 'allow-guest|unknown option|unrecognized option|error|failed|not found' || true
    printf 'Config-related help options:\n'
    "$binary" --help 2>&1 | grep -Ei 'show-config|--config|--help' || true
fi
printf '\n===== ALL STANDARD LIGHTDM CONFIGURATION FILES =====\n'
for dir in /usr/share/lightdm/lightdm.conf.d /usr/local/share/lightdm/lightdm.conf.d /etc/xdg/lightdm/lightdm.conf.d /etc/lightdm/lightdm.conf.d; do
    for file in "$dir"/*.conf; do
        [ -r "$file" ] || continue
        printf '%s\n' "$file"
        awk '/^[[:space:]]*\[/ {section=$0} /^[[:space:]]*allow-guest[[:space:]]*=/ {print section; print $0}' "$file"
    done
done
printf '\n===== DEBIAN PACKAGE REPOSITORY HOSTS AND SUITES =====\n'
for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -r "$file" ] || continue
    printf '\n%s:\n' "$file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        /^(Suites|Components|Enabled):/ {print; next}
        /^URIs:/ {for(i=2;i<=NF;i++) host($i); next}
        $1 == "deb" || $1 == "deb-src" {
            for(i=2;i<=NF;i++) if ($i ~ /:\/\//) {
                host($i); if (i<NF) print "Suite:",$(i+1)
            }
        }
        function host(url) {
            sub(/^[^:]*:\/\//,"",url); sub(/\/.*/,"",url); sub(/^.*@/,"",url)
            print "Host:",url
        }
    ' "$file"
done
printf '\n===== UNREQUIRED FTP SERVICE STATUS =====\n'
systemctl is-active vsftpd 2>/dev/null || true
systemctl is-enabled vsftpd 2>/dev/null || true
printf '\nREAD-ONLY check complete.\n'
