# Persistent files: kept across competition resets

`reset_competition.sh` never deletes anything in this folder. Put scripts, notes, and tools here that you want to reuse.

## `recon.sh`

A read-only baseline scan for a Linux practice image (Mint, Ubuntu, Debian). It prints the scenario README and forensics files, users, sudo rules, password policy, SSH settings, firewall, listening ports, services, packages that deserve a look, pending updates, scheduled tasks, audio and video files, setuid files, and key permissions.

It changes nothing, writes no files, and never prints password hashes or keys. For complete results, start the runner on the VM with `sudo`.

```bash
bash publish.sh --user NAME --source keep/recon.sh --name recon
bash results.sh --user NAME --script FILE.sh --wait 180     # use the file name publish.sh printed
```

The output goes to `outputs/NAME/` and is public, like everything in this repo.

## Ideas for what else to keep here

- Fix scripts you trust, one category each (users, SSH, firewall, updates)
- Checklists and notes from past rounds
