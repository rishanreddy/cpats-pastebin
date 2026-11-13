#!/usr/bin/env bash
# Find the source of the duck sound, then offer the Debian 12 package upgrades.
set -euo pipefail

find_duck_sound() {
    local session uid root parent pid account executable
    local -a search_roots=(/home /opt /usr/local /var/tmp /tmp /etc)
    local -a startup_roots=(/etc/xdg/autostart /etc/systemd/system /etc/cron.d /var/spool/cron)

    printf '\n%s\n' '== Audio players and matching processes =='
    while read -r pid parent account executable; do
        [[ -n "$pid" ]] || continue
        printf 'PID %s, parent %s, account %s, process %s\n' "$pid" "$parent" "$account" "$executable"
        printf 'Executable: %s\n' "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
        ps -p "$parent" -o comm= 2>/dev/null || true
    done < <(ps -eo pid=,ppid=,user=,comm= | grep -Ei '[[:space:]](.*(duck|quack).*|aplay|paplay|pw-play|play|sox|mpv|vlc|mplayer|ffplay|canberra-gtk-play|speaker-test)$' || true)

    if command -v pactl >/dev/null && command -v runuser >/dev/null; then
        printf '\n%s\n' '== Current desktop audio streams =='
        for session in /run/user/[0-9]*/pulse/native; do
            [[ -S "$session" ]] || continue
            uid="${session#/run/user/}"
            uid="${uid%%/*}"
            account=$(id -nu "$uid" 2>/dev/null) || continue
            printf 'Audio session: %s\n' "$account"
            timeout 4 runuser -u "$account" -- env "PULSE_SERVER=unix:$session" pactl list sink-inputs \
                | grep -E 'Sink Input #|application\.(name|process\.id|process\.binary) =|media\.name =' || true
        done
    fi

    printf '\n%s\n' '== Installed package names containing duck or quack =='
    dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' \
        | awk '$1 == "ii" && tolower($2) ~ /(duck|quack)/ { print $2 }'

    printf '\n%s\n' '== Matching filenames in user and local software directories =='
    timeout 20 find "${search_roots[@]}" -xdev \
        \( -name .cache -o -name node_modules -o -name .git \) -prune -o \
        -type f \( -iname '*duck*' -o -iname '*quack*' \) -print \
        || printf '%s\n' 'Filename search ended early; results may be partial.'

    printf '\n%s\n' '== Startup entries that mention duck sounds or audio players =='
    for root in "${startup_roots[@]}" /home/*/.config/autostart /home/*/.config/systemd/user /home/*/.config/xfce4/xfconf/xfce-perchannel-xml; do
        [[ -d "$root" ]] || continue
        timeout 4 grep -rEil 'quack|duck.*\.(wav|mp3|ogg|flac|opus)|(^|[[:space:]=/])(paplay|aplay|pw-play|canberra-gtk-play|ffplay|mpv|sox)([[:space:]]|$)' -- "$root" 2>/dev/null || true
    done
    printf '\n%s\n' 'Review the evidence before choosing an application to remove.'
}

run_upgrades() (
    local answer apt_dir stage plan tty_fd
    if (( EUID != 0 )); then
        printf '%s\n' 'Package upgrades require sudo.'
        return 1
    fi
    . /etc/os-release
    if [[ "$ID" != debian || "$VERSION_ID" != 12 || "$VERSION_CODENAME" != bookworm ]]; then
        printf '%s\n' 'Package upgrades require Debian 12 (bookworm).'
        return 1
    fi
    if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        printf '%s\n' 'Package upgrades need an interactive VM terminal. Run this script there with sudo and --upgrade.'
        return 0
    fi
    printf '\n%s' 'Refresh official Debian 12 indexes and proceed to the APT upgrade prompts? Type UPGRADE within 45 seconds: '
    if ! IFS= read -r -t 45 -u "$tty_fd" answer || [[ "$answer" != UPGRADE ]]; then
        printf '\n%s\n' 'Package upgrades skipped.'
        return 0
    fi

    apt_dir=$(mktemp -d)
    trap 'rm -f -- "$apt_dir/sources.list"; rmdir -- "$apt_dir"' EXIT
    chmod 755 "$apt_dir"
    cat > "$apt_dir/sources.list" <<'SOURCES'
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
SOURCES
    chmod 644 "$apt_dir/sources.list"
    local -a apt=(apt-get -o "Dir::Etc::sourcelist=$apt_dir/sources.list" -o Dir::Etc::sourceparts=- -o APT::Get::Assume-Yes=false)
    export LC_ALL=C
    printf '\n%s\n' '== apt-get update (official Debian 12) =='
    "${apt[@]}" -o APT::Update::Error-Mode=any update <&"$tty_fd"
    for stage in upgrade dist-upgrade; do
        printf '\n== apt-get %s ==\n' "$stage"
        if [[ "$stage" == dist-upgrade ]]; then
            plan=$("${apt[@]}" -s dist-upgrade)
            if grep -Eq '^Remv (openssh-server|lightdm|chromium|ufw|[^[:space:]]*ccs[^[:space:]]*)(:|[[:space:]]|$)' <<< "$plan"; then
                printf '%s\n' "$plan"
                printf '%s\n' 'Stopped: the upgrade plan would remove a required package.'
                return 1
            fi
        fi
        "${apt[@]}" "$stage" <&"$tty_fd"
    done
)

case "${1:-}" in
    '') find_duck_sound; run_upgrades ;;
    --scan-only) find_duck_sound ;;
    --upgrade) run_upgrades ;;
    *) printf 'Usage: bash %s [--scan-only | --upgrade]\n' "$0" >&2; exit 2 ;;
esac
