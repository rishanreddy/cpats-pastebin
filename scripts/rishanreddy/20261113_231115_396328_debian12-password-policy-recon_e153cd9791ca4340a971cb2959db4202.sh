#!/usr/bin/env bash
# PURPOSE: READ-ONLY assessment of password-quality enforcement and account metadata.
# No password hashes, passwords, kernel settings, or forensics data are read.
set -u
export LC_ALL=C
printf '===== HHOGAN PASSWORD STATUS, NO HASHES =====\n'
passwd -S hhogan 2>/dev/null || true
chage -l hhogan 2>/dev/null || true
printf '\n===== PASSWORD QUALITY PACKAGES =====\n'
apt-cache policy libpam-pwquality libpwquality1 libpwquality-common 2>/dev/null |
    awk '/^[^[:space:]][^:]*:$/ || /^[[:space:]]*(Installed|Candidate):/ {print}'
printf '\n===== COMPLEXITY PACKAGE INSTALL PLAN, SIMULATION ONLY =====\n'
apt-get -s -o Debug::NoLocking=1 --no-install-recommends install libpam-pwquality 2>/dev/null |
    awk '/^(Inst|Remv|Conf) / || /^[0-9]+ upgraded,/ {print}'
printf '\n===== SAFE PAM PASSWORD AND AUTH MODULE DETAILS =====\n'
for file in /etc/pam.d/common-password /etc/pam.d/common-auth; do
    printf '%s:\n' "$file"
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            module=0
            for(i=1;i<=NF;i++) if($i ~ /(^|\/)pam_[[:alnum:]_]+\.so$/) module=i
            if (!module) {print "non-module directive at line",NR; next}
            printf "line=%d type=%s module=%s",NR,$1,$module
            for(i=module+1;i<=NF;i++) {
                if($i ~ /^(nullok|obscure|yescrypt|sha512|use_authtok|try_first_pass|enforce_for_root)$/ ||
                   $i ~ /^(minlen|remember|[duloc]credit|retry|difok)=-?[0-9]+$/) printf " %s",$i
            }
            printf "\n"
        }
    ' "$file"
done
printf '\n===== EXISTING PASSWORD QUALITY CONFIGURATION, SELECTED SETTINGS =====\n'
for file in /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf; do
    [ -r "$file" ] || continue
    printf '%s:\n' "$file"
    grep -E '^[[:space:]]*(minlen|minclass|[duloc]credit|difok|dictcheck|usercheck|enforcing|enforce_for_root|retry)[[:space:]=]' "$file" 2>/dev/null || true
done
printf '\n===== AVAILABLE PAM MANAGEMENT TOOL =====\n'
command -v pam-auth-update 2>/dev/null || true
printf '\nRead-only password assessment complete. No passwords or policies changed.\n'
