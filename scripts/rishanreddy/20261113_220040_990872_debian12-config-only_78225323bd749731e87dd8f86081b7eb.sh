#!/usr/bin/env bash
# PURPOSE: read-only preflight for account privileges, SSH, and LightDM fixes.
# CHANGES: none. Does not read forensics questions or their answer files.
set -u
export LC_ALL=C
printf '===== CONFIGURATION-ONLY READ-ONLY CHECK =====\n'
printf 'Forensics is assigned to the user\047s colleague.\n'
printf '\nSudo group:\n'
getent group sudo
printf '\nSudo configuration validation:\n'
if command -v visudo >/dev/null 2>&1; then visudo -c 2>&1; fi
printf '\nAccount database tools:\n'
for tool in gpasswd sshd systemctl; do command -v "$tool" 2>/dev/null || true; done
printf '\nSSH global configuration, selected directives only:\n'
grep -HEi '^[[:space:]]*(Include|Match|PermitRootLogin|PermitEmptyPasswords|PasswordAuthentication|UsePAM|AllowUsers|AllowGroups|DenyUsers|DenyGroups|Port)[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
printf '\nLightDM seat headers and guest settings only:\n'
grep -HE '^[[:space:]]*(\[.*\]|allow-guest[[:space:]]*=)' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf /usr/share/lightdm/lightdm.conf.d/*.conf 2>/dev/null || true
printf '\nSSH active and enabled state:\n'
systemctl is-active ssh 2>/dev/null || true
systemctl is-enabled ssh 2>/dev/null || true
printf '\nRequired service state:\n'
systemctl is-active lightdm ccsclient 2>/dev/null || true
printf '\nConfiguration-only check complete. No changes applied.\n'
