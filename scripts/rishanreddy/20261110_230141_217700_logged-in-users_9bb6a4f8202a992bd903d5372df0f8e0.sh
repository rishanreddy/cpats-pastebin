#!/usr/bin/env bash
# READ-ONLY: report users with active login sessions.
if command -v who >/dev/null 2>&1; then
    who | awk '{print $1}' | sort -u
else
    printf '%s\n' 'Cannot determine logged-in users: who is unavailable.' >&2
    exit 1
fi
