#!/usr/bin/env bash
# Inventory installed applications and desktop launch entries. Read-only.
set -euo pipefail
export LC_ALL=C

printf '%s\n' '== Installed application packages =='
dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Section}\t${binary:Summary}\n' |
    awk -F '\t' '
        $1 ~ /^ii/ && $3 !~ /(^|\/)(libs|oldlibs|debug|libdevel|doc|fonts|localization|kernel)$/ {
            text = tolower($2 " " $3 " " $4)
            flag = text ~ /(audio|sound|music|media player|game|browser|notification|speech|quack|duck|synth|vlc|mpv|ffmpeg|sox)/ ? "[possible audio] " : ""
            printf "%s%s [%s] - %s\n", flag, $2, $3, $4
        }'

desktop_inventory() {
    local dir file
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        for file in "$dir"/*.desktop; do
            [[ -f "$file" && -r "$file" ]] || continue
            # Print labels and categories only. Exec arguments can contain secrets.
            awk -v path="$file" '
                /^\[/ { section = ($0 ~ /^\[Desktop Entry\]\r?$/) }
                section && /^Name=/ { name = substr($0, 6) }
                section && /^Categories=/ { categories = substr($0, 12) }
                section && /^Hidden=true\r?$/ { hidden = " [disabled]" }
                END {
                    text = tolower(path " " name " " categories)
                    flag = text ~ /(audio|sound|music|player|video|game|browser|notification|speech|quack|duck)/ ? "[possible audio] " : ""
                    printf "%s%s%s | %s | %s\n", flag, path, hidden, name, categories
                }' "$file"
        done
    done
}

printf '\n%s\n' '== Desktop applications =='
desktop_inventory /usr/share/applications /usr/local/share/applications \
    /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications \
    /home/*/.local/share/applications /home/*/.local/share/flatpak/exports/share/applications

printf '\n%s\n' '== Desktop autostart entries =='
desktop_inventory /etc/xdg/autostart /home/*/.config/autostart

printf '\n%s\n' '== Local software and portable application locations =='
for dir in /opt /usr/local/bin /home/*/.local/bin /home/*/Applications; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 2 -mindepth 1 \
        \( -type d -o -type l -o \( -type f \( -executable -o -iname '*.appimage' \) \) \) \
        -printf '%p\n'
done
