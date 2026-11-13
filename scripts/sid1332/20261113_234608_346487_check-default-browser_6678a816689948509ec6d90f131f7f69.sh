#!/usr/bin/env bash
# Read-only check of the default browser for the Debian MATE desktop user.
set -euo pipefail

account=pparker
uid=$(id -u "$account")
runtime="/run/user/$uid"
[[ -S "$runtime/bus" ]] || { printf '%s\n' 'The pparker desktop session is unavailable.' >&2; exit 1; }

browser=$(runuser -l "$account" -s /bin/sh -c "env XDG_CURRENT_DESKTOP=MATE XDG_RUNTIME_DIR='$runtime' DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime/bus' xdg-settings get default-web-browser")
if [[ "$browser" == chromium.desktop ]]; then
    printf '%s\n' 'PASS: Chromium is the default browser for pparker.'
else
    printf 'CHECK: pparker default browser is %q (expected chromium.desktop).\n' "$browser"
fi
