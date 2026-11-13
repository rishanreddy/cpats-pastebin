#!/usr/bin/env bash
# PURPOSE: read Desktop questions and inspect SSH policy before proposing fixes.
# CHANGES: READ-ONLY. Writes only stdout/stderr. No README or process arguments.
set -u
export LC_ALL=C
printf '===== DESKTOP FORENSICS QUESTIONS =====\n'
for file in '/home/pparker/Desktop/Forensics Question 1.txt' '/home/pparker/Desktop/Forensics Question 2.txt'; do
    [ -r "$file" ] || continue
    printf '\n--- %s ---\n' "$file"
    # Omit answer areas and credential-bearing assignments if already filled in.
    awk '
        BEGIN {key=0; answers=0}
        /-----BEGIN .*PRIVATE KEY-----/ {key=1; print "[key content omitted]"; next}
        /-----END .*PRIVATE KEY-----/ {key=0; next}
        key {next}
        {
            lower=tolower($0)
            if (lower ~ /^[[:space:]]*answer[[:space:]:=]/) {
                print "[answer field and following contents omitted]"; answers=1
            }
            if (answers) next
            if (lower ~ /^[[:space:]]*(password|passphrase|token|secret)[[:space:]:=]/ ||
                $0 ~ /gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+/ ||
                $0 ~ /\$(1|5|6|y)\$[^[:space:]]+/) {
                print "[credential-bearing line omitted]"; next
            }
            if (NR <= 200) print
        }
    ' "$file"
done

printf '\n===== SELECTED SSH CONFIGURATION DIRECTIVES =====\n'
grep -HEi '^[[:space:]]*(Include|Match|PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication|UsePAM|AllowUsers|AllowGroups|DenyUsers|DenyGroups|AuthenticationMethods|Port)[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true

printf '\n===== EFFECTIVE SSH ACCESS SETTINGS BY AUTHORIZED USER =====\n'
sshd_bin=$(command -v sshd 2>/dev/null || true)
[ -n "$sshd_bin" ] || { [ ! -x /usr/sbin/sshd ] || sshd_bin=/usr/sbin/sshd; }
if [ -n "$sshd_bin" ] && [ "$(id -u)" -eq 0 ]; then
    for name in pparker tstark ppotts hhogan nfury mhill pcoulson bbanner swilson sstrange slang cdanvers okoye kbishop ybelova jfoster nleeds mjwatson jtorres pcarter; do
        printf '\n%s:\n' "$name"
        "$sshd_bin" -T -C "user=$name,host=debian,addr=127.0.0.1,laddr=127.0.0.1,lport=22" 2>/dev/null |
            grep -E '^(permitrootlogin|permitemptypasswords|passwordauthentication|usepam|allowusers|allowgroups|denyusers|denygroups|authenticationmethods) ' || true
    done
fi

printf '\n===== UNAUTHORIZED ACCOUNT STATUS AND GROUPS =====\n'
for name in brumlow azola; do
    id "$name" 2>/dev/null || true
    if [ "$(id -u)" -eq 0 ]; then passwd -S "$name" 2>/dev/null || true; fi
done
printf '\nActive session usernames and terminals, remote addresses omitted:\n'
who 2>/dev/null | awk '{print $1,$2}'

printf '\n===== INSTALLED REPOSITORY CONFIGURATION FILENAMES =====\n'
for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -r "$file" ] || continue
    printf '\n%s, suite and host summary without URLs or credentials:\n' "$file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        /^(Suites|Components|Enabled):/ {print; next}
        /^(URIs):/ {for(i=2;i<=NF;i++) host($i); next}
        $1 == "deb" || $1 == "deb-src" {
            for(i=2;i<=NF;i++) {
                if ($i ~ /:\/\//) {host($i); if (i<NF) print "Suite:",$(i+1)}
            }
        }
        function host(url,authority) {
            if (url !~ /:\/\//) return
            sub(/^[^:]*:\/\//,"",url)
            sub(/\/.*/,"",url)
            sub(/^.*@/,"",url)
            authority=url
            print "Repository host:",authority
        }
    ' "$file"
done
printf '\nREAD-ONLY follow-up complete. No fixes applied.\n'
