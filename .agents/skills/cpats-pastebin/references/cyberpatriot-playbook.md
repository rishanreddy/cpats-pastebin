# CyberPatriot Linux playbook (Mint, Ubuntu, Debian)

How to find and fix what a practice image has wrong. These are patterns, not a guarantee: **the image's README decides what is authorized and what must keep running**, and the scoring engine is not visible to you. Everything here is published through the relay as Bash, so follow the autonomy levels in `AGENTS.md`. Reading is free after one approval. Every change needs a yes.

## Order of work

1. **Read the README and the forensics questions first** (`keep/recon.sh` prints them). Write down the authorized users, which are administrators, the required services and software, and any special rules. Do not change anything until you have this.
2. **Recon** with read-only scripts. List everything that looks wrong, then rank it.
3. **Fix in small batches**, one category at a time, each reversible. Highest value and lowest risk first.
4. **Verify** each batch with a read-only re-check, then move on.
5. **Forensics questions** need evidence from the image (files, logs, hashes). Find the answer with read-only commands. The user types answers into the answer file on the image, so do not guess.

Rough priority: README-named items, unauthorized users and admins, updates, passwords and account policy, firewall, SSH, services and ports, prohibited software and media, persistence and backdoors, file permissions, kernel and network settings.

## What to check, and what "wrong" looks like

| Area | Look at | Usually wrong when |
| --- | --- | --- |
| **Users** | `/etc/passwd` (UID 0, UID >= 1000, login shells), groups `sudo` and `admin` | An account is not in the README's authorized list. A user is an admin but should not be. A second UID 0 account exists. A system account has a login shell. |
| **Passwords** | `passwd -S -a` (status only), `/etc/login.defs`, `/etc/pam.d/common-password`, `common-auth` | An account has no password (`NP`). `PASS_MAX_DAYS` is huge. No complexity or history rules. `nullok` is set in PAM. |
| **Sudo** | `/etc/sudoers`, `/etc/sudoers.d/*` | `NOPASSWD` or `!authenticate` for people who should not have it. Unexpected users or groups. |
| **Login screen** | `/etc/lightdm/`, `/etc/gdm3/custom.conf` | Guest login is on (`allow-guest=true`). Automatic login is on. |
| **Updates** | `apt-get -s upgrade`, `/etc/apt/apt.conf.d/20auto-upgrades`, sources | Many packages are upgradable. Automatic updates are off. A strange repository is listed. |
| **SSH** | `sshd -T` or `/etc/ssh/sshd_config` | `PermitRootLogin yes`, `PermitEmptyPasswords yes`, `Protocol 1`, `X11Forwarding yes`, unlimited `MaxAuthTries`, when the README says SSH is needed. If SSH is not needed, it may need to be disabled instead. |
| **Firewall** | `ufw status verbose` | The firewall is inactive. |
| **Services and ports** | `ss -tulpn`, running and enabled services | Something listens that the README does not require: telnet, FTP, Samba, NFS, a web or database server, SNMP, a netcat listener. |
| **Software** | `dpkg -l`, `snap list`, recent installs in `/var/log/dpkg.log` | Hacking tools (nmap, john, hydra, netcat, wireshark, and so on), games, P2P clients, or other software the README forbids. **Check the README first**, because some of these are required. |
| **Media files** | audio and video under `/home` and elsewhere | Music or video files in user directories. |
| **Persistence** | cron, systemd timers, `/etc/rc.local`, autostart, running processes | Something calls out, starts a listener, or re-creates removed items. |
| **Permissions** | `/etc/shadow` (640 root:shadow), `/etc/passwd` (644), `/etc/sudoers` (440), setuid files, world-writable files | Looser than the usual modes. An unexpected setuid binary. |
| **Kernel and network** | `net.ipv4.ip_forward`, `tcp_syncookies`, `kernel.randomize_va_space`, `/etc/hosts` | IP forwarding on, syncookies off, ASLR off, odd `/etc/hosts` entries. |

## Fixing safely

- **Back up, change, validate, reload.** `cp -a FILE FILE.bak`, edit, then `sshd -t`, `visudo -c`, or the service's own config test, and only then reload.
- **Never lock yourself out.** Keep one known admin account working. Do not change a password without telling the user the new value, and remember it will sit in a public repo.
- **List first, then delete.** For files, users, and packages, publish a read-only script that lists the candidates. Delete only what the user approves. Prefer removing a user's access (lock the account, remove from `sudo`) over deleting data, unless the README calls for deletion.
- **Do not break required services.** Check the README before stopping, disabling, or removing anything. A penalty can cost more than the fix earns.
- **Small batches.** A batch that changes one category is easy to verify and easy to undo.
- **Say what you expect to score**, and be honest that you can't see the score. If the user can read the on-image score report, ask them to send it with `clipboard_upload.sh`.

## Useful read-only commands

```bash
getent passwd | awk -F: '$3>=1000 && $3<65534'      # regular users
getent group sudo admin                             # admin-like groups
sudo passwd -S -a                                   # password status, no hashes
sudo sshd -T | grep -Ei 'permitroot|passwordauth|emptypass|x11'
sudo ufw status verbose
ss -tulpn                                           # what is listening
apt-get -s upgrade | grep -c '^Inst'                # how many updates are pending
find /home -type f \( -iname '*.mp3' -o -iname '*.mp4' \)
find / -xdev -type f -perm -4000                    # setuid files
```

## Typical safe fixes (each is a change: ask first)

```bash
sudo gpasswd -d USER sudo                           # remove an unauthorized admin
sudo passwd -l USER                                 # lock an account without deleting it
sudo chage -M 90 -m 7 -W 14 USER                    # password aging for an existing user
sudo ufw enable                                     # turn the firewall on (allow SSH first if the README needs it)
sudo apt-get update && sudo apt-get -y upgrade      # install pending updates
sudo systemctl disable --now SERVICE                # stop a service the README does not need
```

## Mint, Ubuntu, Debian differences

- **Linux Mint** uses LightDM and Cinnamon. Guest login lives in `/etc/lightdm/`.
- **Ubuntu** uses GDM and `snap`. Debian may have no `sudo` group set up, so check who has root.
- All three use `apt`, `ufw` (sometimes not installed on Debian), and `systemd`. Read `/etc/os-release` before assuming.
- **Debian images** may have you run as root already. Say so in the script's header.

## When you are stuck

Say what you know, what you don't, and the cheapest read-only check that would settle it. Then publish that check, if the user has approved read-only publishing. Don't guess on anything that could cost points.
