#!/usr/bin/env bash
# Diagnose a key-triggered sound on the Debian MATE desktop. Read-only.
set -euo pipefail
export LC_ALL=C

account=pparker
uid=$(id -u "$account")
runtime="/run/user/$uid"
session=(runuser -u "$account" -- env "XDG_RUNTIME_DIR=$runtime" "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime/bus")
pulse=("${session[@]}" "PULSE_SERVER=unix:$runtime/pulse/native" pactl)

printf '%s\n' '== MATE sound and bell settings =='
if [[ -S "$runtime/bus" ]] && command -v gsettings >/dev/null; then
    for pair in \
        org.mate.sound:event-sounds org.mate.sound:input-feedback-sounds \
        org.mate.sound:theme-name org.mate.Marco.general:audible-bell \
        org.mate.Marco.general:visual-bell org.mate.peripherals-keyboard:bell-mode; do
        schema="${pair%:*}"
        key="${pair#*:}"
        if value=$(timeout 2 "${session[@]}" gsettings get "$schema" "$key" 2>/dev/null); then
            printf '%s %s = %s\n' "$schema" "$key" "$value"
        fi
    done
fi

printf '\n%s\n' '== Bell, duck, and quack sound files =='
for dir in /usr/share/sounds /usr/local/share/sounds /home/pparker/.local/share/sounds /home/pparker/.sounds; do
    [[ -d "$dir" ]] || continue
    timeout 4 find "$dir" -maxdepth 5 \( -type f -o -type l \) \
        \( -iname '*bell*' -o -iname '*duck*' -o -iname '*quack*' \) \
        -printf '%p -> %l\n' || true
done

if [[ ! -S "$runtime/pulse/native" ]] || ! command -v pactl >/dev/null; then
    printf '%s\n' 'No PulseAudio-compatible socket or pactl for pparker. Playback could not be observed.'
    exit 0
fi
if ! timeout 3 "${pulse[@]}" info >/dev/null; then
    printf '%s\n' 'Could not connect to the desktop audio server.'
    exit 1
fi

playback() {
    timeout 2 "${pulse[@]}" list sink-inputs |
        awk '
            /^Sink Input #[0-9]+/ { stream = $3 }
            /^[[:space:]]*Corked:/ { corked = $2 }
            /^[[:space:]]*(application\.process\.(binary|id)|event\.id|media\.role)[[:space:]]*=/ {
                sub(/^[[:space:]]+/, "")
                printf "%s corked=%s %s\n", stream, corked, $0
            }
        '
}

printf '\n%s\n' 'WATCHING FOR 90 SECONDS. Trigger the duck sound several times in the affected app now.'
previous=''
seen=no
end=$((SECONDS + 90))
while (( SECONDS < end )); do
    current=$(playback 2>/dev/null) || current=''
    if [[ -n "$current" && "$current" != "$previous" ]]; then
        printf '\n[%s UTC]\n%s\n' "$(date -u +%T)" "$current"
        seen=yes
    fi
    previous="$current"
    sleep 0.15
done
if [[ "$seen" == no ]]; then
    printf '%s\n' 'No application playback stream was captured during the window.'
fi
printf '%s\n' 'Playback observation complete.'
