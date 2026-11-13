#!/usr/bin/env bash
# Classify effective sudo policy on this host. Writes findings to a private local report.
set -euo pipefail
export LC_ALL=C
(( EUID == 0 )) || { echo 'Run as root to query other users.' >&2; exit 1; }

umask 077
report_dir=$(mktemp -d /var/tmp/cpats-sudo-review.XXXXXXXX)
report="$report_dir/report.txt"

# Capture both stdout and stderr locally. The relay receives only a status.
(
printf '%s\n' '== Effective sudo policy for README standard users =='
for user in bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
    if ! groups=$(id -nG "$user" 2>/dev/null); then
        printf '%s: account unavailable\n' "$user"
        continue
    fi
    printf '\n%s\n' "$user"
    case " $groups " in
        *" sudo "*) printf '%s\n' '  Member of sudo group.' ;;
    esac

    status=0
    listing=$(sudo -n -ll -U "$user" 2>&1) || status=$?
    if (( status != 0 )); then
        if [[ "$listing" == *"is not allowed to run sudo"* || "$listing" == *"is not in the sudoers file"* ]]; then
            printf '%s\n' '  No sudo grant on this host.'
        else
            printf '  Sudo policy query failed (exit %s). Review locally.\n' "$status"
        fi
        continue
    fi

    # Parse the verbose entries. Omit raw arguments, regexes, and Defaults.
    awk '
        /^Sudoers entry:/ { entries++; users = ""; options = ""; commands = 0; next }
        /^[[:space:]]+RunAsUsers:/ {
            users = $0; sub(/^[[:space:]]*RunAsUsers:[[:space:]]*/, "", users); next
        }
        /^[[:space:]]+Options:/ { options = $0; next }
        /^[[:space:]]+Commands:[[:space:]]*$/ { commands = 1; next }
        commands && /^[[:space:]]+[^[:space:]]/ {
            item = $0; sub(/^[[:space:]]+/, "", item)
            root = (users == "" || users ~ /(^|[ ,])(ALL|root|#0)([ ,]|$)/)
            denied = (item ~ /^!/)
            if (denied) type = "negated command"
            else if (item == "ALL" && root) type = "ALL commands as root or any user"
            else if (item == "ALL") type = "ALL commands as specified non-root user(s)"
            else type = "command-specific rule"
            password = (options ~ /(^|[ ,])!authenticate([ ,]|$)/) ? " [passwordless]" : ""
            printf "  Entry %d: %s%s\n", entries, type, password
            rules++
        }
        END {
            if (!rules) print "  No command entries recognized in sudo listing. Review locally."
        }
    ' <<< "$listing"

    # A policy-only probe confirms whether the user could start a root shell.
    if sudo -n -l -U "$user" -u root -- /bin/sh >/dev/null 2>&1; then
        printf '%s\n' '  CONFIRMED: sudo policy permits /bin/sh as root.'
    else
        printf '%s\n' '  The root-shell probe did not find permission for /bin/sh.'
    fi
done

) >"$report" 2>&1 || {
    printf 'Sudo review failed. For local details run: sudo cat %q\n' "$report" >&2
    exit 1
}
printf 'Sudo review complete. Read the private report on the VM: sudo cat %q\n' "$report"
