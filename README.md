# cpats-pastebin

A GitHub repo that moves scripts and text between your computer and a CyberPatriot practice or competition VM, and brings the results back.

You (or a coding agent) publish a Bash script to this repo. A runner on the VM downloads the newest script, runs it, and uploads everything it printed. You can also send text from the VM, such as a log or a clipboard paste, back to the repo and read it from your own computer.

- **Nothing to install on the VM, and no Python.** The VM only runs commands. It needs `bash` and either `curl` or `wget`, plus ordinary utilities (`sed`, `awk`, `grep`, `base64`, `sha1sum`) that Linux Mint, Ubuntu, and Debian already include.
- **No config files.** There is no `.env` file. Every setting is a command-line flag.
- **Two people, no conflicts.** Each teammate has a folder named after their GitHub username. Uploads never overwrite anything, so you can both publish at the same time.
- **Public repo.** The VM can download scripts without any credentials. Only *uploading* from the VM needs a token. Because the repo is public, **anyone can read everything in it**. See [Security](#security).

## Contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Everyday use](#everyday-use)
- [Command reference](#command-reference)
- [Details worth knowing](#details-worth-knowing)
- [Security](#security)
- [Between competitions](#between-competitions)
- [Troubleshooting](#troubleshooting)
- [Using a coding agent](#using-a-coding-agent)
- [Repo layout, tests, and forking](#repo-layout-tests-and-forking)

## How it works

```
 Your computer or agent               GitHub repo (public)                  Competition VM
 ──────────────────────               ────────────────────                  ──────────────
 publish.sh --user sid1332  ───────►  scripts/sid1332/<newest>.sh  ───────►  runner.sh --user sid1332
                                                                              downloads it and runs it
 read results with gh api   ◄───────  outputs/sid1332/<run>.txt    ◄───────  --upload-output
 read pastes with gh api    ◄───────  clipboard/sid1332/<paste>.txt ◄──────  clipboard_upload.sh
```

| Where | What it needs |
| --- | --- |
| **Your computer** (publish, read results) | macOS, Windows, or Linux. The [GitHub CLI](https://cli.github.com/) signed in with `gh auth login`, plus Bash (built in on macOS and Linux, Git Bash on Windows) or PowerShell on Windows. No Python. |
| **The VM** (run, upload) | Linux Mint, Ubuntu, or Debian with `bash` and `curl` or `wget`. **No Python, nothing installed.** A GitHub token, **only** to upload output or pastes. |

### Supported systems

| Machine | System | Tools to use | Setup |
| --- | --- | --- | --- |
| **VM** | Linux Mint, Ubuntu, Debian, or similar | `runner.sh`, `clipboard_upload.sh` | None. It needs `bash` and `curl` or `wget`. The runner prints a clear message if a standard tool is missing, and never installs anything. |
| **Your computer** | macOS | `publish.sh`, `collab.sh`, `reset_competition.sh` | `brew install gh`, then `gh auth login`. The built-in Bash 3.2 works. |
| **Your computer** | Windows | `publish.ps1` in PowerShell. Git Bash for `collab.sh` and `reset_competition.sh`. | `winget install GitHub.cli` and `winget install Git.Git`, then `gh auth login`. Git provides Bash for the syntax check. |
| **Your computer** | Linux | `publish.sh`, `collab.sh`, `reset_competition.sh` | Install `gh` from <https://cli.github.com/>, then `gh auth login`. |

Scripts you publish must be **Bash**. The VM is for running commands, so the runner runs `.sh` files with `bash`, and ignores everything else, including `.py` files. A script should use only what is already on the VM.

A **username** (for example `sid1332`) names a teammate's folders: `scripts/sid1332/`, `outputs/sid1332/`, and `clipboard/sid1332/`. Each person's VM watches their own username. Usernames are always lowercased.

## Quick start

About ten minutes, once per person.

### 1. Get access to the repo

The owner (`rishanreddy`) invites each teammate, and the teammate accepts:

```bash
bash collab.sh add sid1332
```

Sid then accepts the email invitation, or the invitation at <https://github.com/rishanreddy/cpats-pastebin/invitations>.

Anyone can *read* this public repo. Being a collaborator is what allows *writing* to it: publishing from your computer and uploading from the VM.

### 2. Make a token for the VM (only to upload)

Skip this step if the VM will only run scripts and you don't need its output back in GitHub. Make a fresh token for each practice session or competition. Nothing needs to be saved: you type it into the VM's terminal, and you can delete it on GitHub afterwards at <https://github.com/settings/tokens>.

**Classic token (works for every collaborator):**

1. Open <https://github.com/settings/tokens/new?scopes=public_repo&description=cpats-pastebin>. This is *Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)*.
2. Tick only **`public_repo`**. It is all a public repo needs.
3. **Make it expire in one day.** Under *Expiration* choose **Custom** and pick tomorrow's date. If you only see presets, take **7 days**, the shortest, and delete the token yourself when you finish. A forgotten or leaked token then stops working on its own.
4. Click **Generate token** and copy it. GitHub shows it once.

**Fine-grained token (only the repo owner can use this):** at <https://github.com/settings/personal-access-tokens/new> choose *Only select repositories → cpats-pastebin* and set **Contents: Read and write**. GitHub currently does not let collaborators create fine-grained tokens for someone else's personal repo. See [Choosing a token](#choosing-a-token).

### 3. Set up the VM

Open a terminal on the VM. Download the two tools. This needs no token because the repo is public:

```bash
base=https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main
curl -fsSL -O "$base/runner.sh" -O "$base/clipboard_upload.sh"
```

If the VM doesn't have `curl`, use `wget`, which does the same job:

```bash
wget -q "$base/runner.sh" "$base/clipboard_upload.sh"
```

The runner itself works with either tool.

Store your token in a shell variable once per terminal. Nothing is written to disk, and the token stays out of your shell history:

```bash
read -rsp 'GitHub token: ' T; echo
```

Check that everything is wired up:

```bash
bash runner.sh --check --token "$T"
```

You should see the repo, the branch, and your token reported as working. `--check` also shows when the token expires. If it says GitHub reports no expiration date, make a new token that expires in a day. Then start watching your folder:

```bash
bash runner.sh --user sid1332 --token "$T" --upload-output --loop
```

Replace `sid1332` with your own GitHub username. The runner now checks for new scripts, runs each new one once, and uploads its output. Leave this terminal open. `Ctrl+C` stops it.

You can run `read -rsp ...` again in any new terminal. If you don't use a token at all, leave out `--token` and `--upload-output`: scripts still run, but their output stays on the VM.

### 4. Publish a script

On your computer, sign in to GitHub CLI once, then publish.

macOS, Linux, or Git Bash:

```bash
gh auth login
printf '#!/usr/bin/env bash\nid; uname -a\n' > /tmp/check.sh
bash publish.sh --user sid1332 --source /tmp/check.sh --name check
```

Windows PowerShell (this writes the file with Unix line endings, which Bash needs):

```powershell
gh auth login
[IO.File]::WriteAllText("$env:TEMP\check.sh", "#!/usr/bin/env bash`nid; uname -a`n")
.\publish.ps1 -User sid1332 -Source "$env:TEMP\check.sh" -Name check
```

The VM picks it up within the check interval (30 seconds with a token), runs it, and uploads the output.

### 5. Read the result

`publish.sh` printed a `Next:` line. Run it on your computer. It waits for that script's output and prints it:

```bash
bash results.sh --user sid1332 --script FILENAME.sh --wait 180
bash results.sh --user sid1332                      # or just the newest output right now
```

`results.sh` uses your `gh` login, so it needs no token. It runs in macOS, Linux, or Git Bash on Windows. See the [reference](#resultssh-on-your-computer). You can also fetch files with `gh` directly:

```bash
# newest output from sid1332's VM
f=$(gh api 'repos/rishanreddy/cpats-pastebin/contents/outputs/sid1332' \
      --jq '[.[] | select(.type=="file")] | sort_by(.name) | last | .path')
gh api -H 'Accept: application/vnd.github.raw+json' "repos/rishanreddy/cpats-pastebin/contents/$f"
```

On Windows PowerShell:

```powershell
$f = gh api 'repos/rishanreddy/cpats-pastebin/contents/outputs/sid1332' | ConvertFrom-Json |
       Where-Object type -eq file | Sort-Object name | Select-Object -Last 1 -ExpandProperty path
gh api -H 'Accept: application/vnd.github.raw+json' "repos/rishanreddy/cpats-pastebin/contents/$f"
```

You can also browse `outputs/sid1332/` on github.com. File names begin with the run's UTC timestamp, so the newest is last.

## Everyday use

### Publish a script from your computer

Write a Bash script. It must start with a shebang (`#!/usr/bin/env bash` or `#!/bin/bash`), use Unix (LF) line endings, and pass `bash -n`. Then run one of these:

```bash
# macOS, Linux, or Git Bash on Windows
bash publish.sh --user sid1332 --source ./fix-ssh.sh --name fix-ssh
```

```powershell
# Windows PowerShell. It still needs Bash (Git Bash or WSL) for the syntax check.
.\publish.ps1 -User sid1332 -Source C:\work\fix-ssh.sh -Name fix-ssh
```

`--user` picks **whose VM runs the script**, so use the teammate whose VM should receive it. The publisher uses your `gh` login. You do not pass a token, and the file lands at `scripts/sid1332/<timestamp>_fix-ssh_<id>.sh`. Keep `runner.sh` next to `publish.sh`, because it provides the upload code.

### Run scripts on the VM

```bash
# One-shot: run the newest script and upload its output
bash runner.sh --user sid1332 --token "$T" --upload-output

# Watch: run each newly published script once, forever
bash runner.sh --user sid1332 --token "$T" --upload-output --loop

# See what is available without running anything
bash runner.sh --user sid1332 --list

# Run a script you already have on the VM (no GitHub needed)
bash runner.sh --file ./fix.sh

# Run a local script and still upload its output
bash runner.sh --file ./fix.sh --user sid1332 --token "$T" --upload-output
```

Scripts run with `bash` as the account that started the runner. If a script needs root, start the runner with `sudo`, or put `sudo` in the script. Only `.sh` files are run: there is no Python on the VM side, and the runner ignores `.py` files.

### Send text from the VM

```bash
# Pipe anything in
cat /var/log/auth.log | bash clipboard_upload.sh --user sid1332 --token "$T" --label auth-log
ss -tlnp | bash clipboard_upload.sh --user sid1332 --token "$T" --label open-ports

# Upload a short note directly
bash clipboard_upload.sh --user sid1332 --token "$T" --label note --text 'Check the ssh config'

# Upload whatever is on the VM clipboard (needs xclip, xsel, or wl-paste to be installed)
bash clipboard_upload.sh --user sid1332 --token "$T" --label from-clipboard
```

The paste appears in `clipboard/sid1332/` on GitHub. Piped text is uploaded exactly as it is, including trailing blank lines, and can be large.

Reading the VM clipboard works only if the VM has one of those tools installed, and a stock image may not. Piping and `--text` always work. To get text *into* the VM from your computer, publish it as a script.

### Read pastes and outputs from your computer

```bash
gh api 'repos/rishanreddy/cpats-pastebin/contents/clipboard/sid1332' --jq '.[].path'
gh api -H 'Accept: application/vnd.github.raw+json' \
  'repos/rishanreddy/cpats-pastebin/contents/clipboard/sid1332/EXACT_FILENAME'
```

## Command reference

Every setting is a flag. `--repo` defaults to `rishanreddy/cpats-pastebin` and `--branch` to `main`. Each tool also has `--help`.

### `runner.sh` (on the VM)

| Flag | Meaning |
| --- | --- |
| `--user NAME` | Whose folder to use: run the newest script from `scripts/NAME/` and put output in `outputs/NAME/`. |
| `--file PATH` | Run a local script instead of downloading one. Add `--user NAME --upload-output` to also upload its output. |
| `--list` | With `--user`: list that user's scripts and exit. |
| `--check` | Test the repo, branch, and token, then exit. No `--user` needed. |
| `--upload-output` | Upload the output to `outputs/NAME/`. Needs `--token` and `--user`. |
| `--loop` | Keep running, and run each new script once. |
| `--interval SECONDS` | Time between checks with `--loop`, 5 to 86400. Default 30 with a token, 120 without. |
| `--token TOKEN` | GitHub token. Required only to upload. It also raises the API limit from 60 to 5,000 requests per hour. |
| `--repo OWNER/REPO` | Use a different repo. |
| `--branch NAME` | Use a different branch. |
| `--state-dir PATH` | Where `--loop` remembers what it has run. Default `~/.local/state/cpats-pastebin`. |

### `clipboard_upload.sh` (on the VM)

| Flag | Meaning |
| --- | --- |
| `-u`, `--user NAME` | Required. Chooses `clipboard/NAME/`. |
| `--token TOKEN` | Required. |
| `-l`, `--label LABEL` | Required. A short name used in the file name. |
| `-t`, `--text TEXT` | Upload this text. Otherwise it reads stdin, then the clipboard. |
| `--repo`, `--branch` | As above. |

### `publish.sh` and `publish.ps1` (on your computer)

| Bash flag | PowerShell | Meaning |
| --- | --- | --- |
| `--user NAME` | `-User` | Whose VM should run the script. |
| `--source PATH` | `-Source` | The script to publish. |
| `--name SLUG` | `-Name` | A label (lowercase letters, digits, `_`, `-`, up to 40 characters) used in the file name. |
| `--repo`, `--branch` | `-Repo`, `-Branch` | Optional overrides. |

### `results.sh` (on your computer)

Fetches what the VM sent back, and can wait for it. It uses your `gh` login, so it takes no token.

| Flag | Meaning |
| --- | --- |
| `--user NAME` | Required. Whose VM. |
| `--kind outputs\|clipboard` | Script output (default) or pasted text. |
| `--script FILE` | Only the output of this published script (the file name `publish.sh` printed). |
| `--wait SECONDS` | Keep checking every 10 seconds for up to this long, 0 to 3600. Without `--script`, it waits for a file newer than the newest one now. |
| `--list` | List the file names, oldest first, and exit. |
| `--repo`, `--branch` | As above. |

Exit codes: `0` printed a result, `3` timed out waiting, `4` nothing exists yet, `1` an error.

### `collab.sh` (on your computer, never the VM)

```bash
bash collab.sh add sid1332                      # invite with write access
bash collab.sh add sid1332 --permission admin   # push (default), maintain, or admin
bash collab.sh list                             # collaborators and pending invitations
bash collab.sh remove sid1332
```

Uses your `gh` login (no token flag) and needs repo admin rights.

### `reset_competition.sh` (on your computer, never the VM)

```bash
bash reset_competition.sh --dry-run   # list what would be deleted
bash reset_competition.sh             # type RESET to confirm
bash reset_competition.sh --yes       # skip the confirmation
```

It uses the GitHub CLI login that is already on your computer. Nothing runs on the VM, and the VM needs no GitHub login for a reset. See [Between competitions](#between-competitions).

## Details worth knowing

**Which script runs?** The one with the greatest filename in `scripts/NAME/`. Names start with a UTC timestamp, so that is the most recently published one. If you publish several scripts between two checks, only the newest runs. Scripts from other users are never touched.

**Once per script.** In `--loop` mode the runner remembers the newest script it has run (by repo, branch, user, and file contents). It runs a script once and then waits for something new. Restarting the runner does not re-run it, because the memory lives in `--state-dir`.

**Output files** look like this. The exit code is real, even if the script fails:

```
script:    20261110_173302_123456_check_<id>.sh
timestamp: 2026-11-10T17:33:10Z
host:      cp-vm-01
user:      cyberpatriot
---
...everything the script printed to stdout and stderr...

---
exit code: 0
```

**Nothing is overwritten.** Every upload creates a new file named `<UTC timestamp>_<label>_<unique id>`. Outputs also include the VM's hostname. Uploads retry up to five times when two people write at once, and a retry reuses the same file name and contents. If a file somehow already exists with different contents, the upload refuses and tells you.

**Failed uploads aren't lost.** The local log or paste is kept and its path printed. In `--loop` mode a failed upload stays pending and is retried before the runner looks for another script. The script is not run again.

**Safe downloads.** The runner checks that the bytes it downloaded are the exact version it listed, and runs nothing otherwise.

**The script's environment** has `GITHUB_TOKEN`, `GH_TOKEN`, and the enterprise variants removed, so a published script can't pick up credentials from its parent shell.

### Rate limits and polling

GitHub limits API requests by who is asking:

| Mode | Limit | Default check interval | Requests per hour while idle |
| --- | --- | --- | --- |
| No `--token` | 60 per hour **per IP address** | 120 s | 30 |
| With `--token` | 5,000 per hour **per account** | 30 s | 120 |

Two VMs behind the same router share one IP address, so the 60 is shared between them. If you only run `--loop` without a token, keep `--interval` at 120 or more. The runner warns you if you set it lower than 90. If GitHub refuses a request because the limit is used up, the runner does not retry in a loop. It waits until GitHub says the limit resets, prints how long, and carries on. Using a token avoids the problem, and you need one to upload anyway.

### Choosing a token

| Option | Reach if it leaks | Who can use it | Notes |
| --- | --- | --- | --- |
| **Classic token with `public_repo`** (recommended) | Write access to **every public repo that account can push to** | Any collaborator | Make it expire in **one day** (a Custom date) and delete it when you finish. |
| **Fine-grained token** for this repo | Only this repo | Only the **repo owner** | GitHub currently doesn't let collaborators create fine-grained tokens for another person's personal repo. |
| **GitHub organization** | Only this repo, per person | Every member | Move the repo to an organization where both teammates are members and each can make their own repo-limited fine-grained token. Worth it if you will use this for several seasons. |

Never share a token in chat or commit it. Make a new one-day token for each practice session or competition.

## Security

This repo is **public**, so please read this section.

- **Anything you publish or upload can be read by anyone**, including other teams. That covers scripts, outputs, and pastes. Don't put credentials, scoring-engine details, or anything you wouldn't want an opponent to see in a script or an output. Outputs include the VM's hostname and username. Make sure your round's rules allow using a tool like this.
- **Git history is permanent.** [Resetting](#between-competitions) deletes the files, but old commits still show them. If you need a truly clean slate, start a fresh repo.
- **Write access means code execution.** Whoever can write to `scripts/<user>/` can run commands on that user's VM. Only add collaborators you trust, use tokens that expire in a day, and delete them afterwards at <https://github.com/settings/tokens>.
- **Scripts aren't sandboxed.** They run with the rights of whoever started the runner. `publish.sh` checks syntax only. It doesn't judge whether a script is safe, so read scripts before you publish them.
- **A token on the command line** is visible to other users on the same machine while the command runs. The `read -rsp ... T` and `--token "$T"` pattern keeps it out of your shell history and out of any file. Don't paste a literal token into a command, and don't write one into a script or a file.
- **A leaked token** should be revoked immediately at <https://github.com/settings/tokens>.

## Between competitions

Run these on **your own computer**, using your `gh` login. A reset never runs on the VM. Stop all runners and publishers first:

```bash
bash reset_competition.sh --dry-run
bash reset_competition.sh
```

This deletes every file under `scripts/`, `outputs/`, and `clipboard/` (folder placeholders stay) and keeps `keep/`, the tools, and the docs. Put anything you want to reuse, such as hardening scripts and checklists, in `keep/`.

Reset removes files from the repo, not from its history, and the history is public. For a fully clean start (or when outputs contained anything sensitive), make a new repo from a copy of this one:

```bash
git clone https://github.com/rishanreddy/cpats-pastebin.git season-2
cd season-2 && rm -rf .git && git init -b main && git add . && git commit -m 'Fresh start'
gh repo create YOUR-NAME/season-2 --public --source . --push
```

Then pass `--repo YOUR-NAME/season-2` to every tool, or change the default once (see [forking](#repo-layout-tests-and-forking)).

## Troubleshooting

Start with `bash runner.sh --check --token "$T"`. It tests the repo, the branch, and the token and says what's wrong.

| You see | Why | Fix |
| --- | --- | --- |
| `--upload-output needs --token` | Uploading requires a credential. | Add `--token "$T"` ([step 2](#2-make-a-token-for-the-vm-only-to-upload)). |
| `GitHub rejected --token` (HTTP 401) | The token is mistyped, expired, or revoked. | Make a new token. Paste only the token, with nothing else. |
| `This token cannot write to the repo` (HTTP 403 or 404) | The account isn't a collaborator, or a classic token lacks `public_repo`, or a fine-grained token lacks **Contents: Read and write**. | Accept the invitation. Recreate the token with the right permission. `--check` shows the scopes. |
| `GitHub's rate limit is used up` | Too many requests without a token. | Add `--token`, or use a longer `--interval`. The runner waits on its own. |
| `No scripts found for NAME yet` | Nothing is published under that username, or the username is wrong. | Publish a script for `NAME`. Compare `--user` with the name you published to. `--list` shows what exists. |
| Published, but the VM does nothing | Wrong `--user`, the loop is waiting out its interval, or a newer script exists. | Run `--list`. Wait one interval. Only the **newest** script runs. |
| `Repo ... was not found` | Wrong `--repo`, or it's private and you passed no token. | Fix the repo name. |
| `Branch ... was not found` | Wrong `--branch`. | Use `--branch main`. |
| `Script changed during download` | Someone published at the same moment. | Run it again. `--loop` retries on the next check. |
| `Bash syntax check failed` or `Save Bash scripts with LF line endings` | The published script is invalid or has Windows (CRLF) line endings. | Fix the script. Save it with LF endings. |
| `Script must begin with a Bash shebang` | The first line is not `#!/usr/bin/env bash` or `#!/bin/bash`. | Add it. |
| `curl or wget is needed to reach GitHub` | The VM has neither. | Linux Mint, Ubuntu, and Debian normally have one. Check with `command -v curl wget`. |
| `These standard tools are missing: ...` | A basic utility such as `base64` or `sed` is absent. | Use a normal Linux image. These come with the base system. |
| PowerShell says `running scripts is disabled on this system` | Windows' script policy blocks `publish.ps1`. | Run `powershell -ExecutionPolicy Bypass -File .\publish.ps1 -User ...`, or `Unblock-File .\publish.ps1` once. |
| `gh` is not recognized, or `Bash is required for the syntax check` (Windows) | GitHub CLI or Git Bash is not installed. | `winget install GitHub.cli` and `winget install Git.Git`, then open a new terminal. |
| `$'\r': command not found` in Git Bash | A Windows checkout converted the scripts to CRLF line endings. | Run `git config core.autocrlf input`, then `git checkout -- .` (the repo's `.gitattributes` keeps new clones correct). |
| `Upload failed ... Local file retained` | A network or GitHub problem. | The path of the saved file is printed. In `--loop` mode the runner retries by itself. |
| An old `.cpats.env` file exists | It came from an earlier version. | It's ignored now. Delete it, because it may contain a token. |
| `runner.sh` seems out of date | GitHub caches raw files for up to 5 minutes. | Re-download it and wait a few minutes. |

## Using a coding agent

The repo is set up so an agent can run a whole practice round with you, and move on its own instead of waiting for each instruction. Open your agent **in this folder**. It loads [`AGENTS.md`](AGENTS.md) automatically, and Claude Code also loads [`CLAUDE.md`](CLAUDE.md).

What those files teach it:

- **The context.** You are practicing CyberPatriot: harden a Linux VM image, guided by its README, without breaking what must keep working. It can't touch the VM. This repo is its only bridge, and everything in it is public.
- **How to start by itself.** When you say "let's start", it checks your `gh` login, looks at what the repo already holds, and sends one message with a plan and a few questions, each with a recommended default.
- **The loop.** It publishes read-only recon (`keep/recon.sh`), waits for the output with `results.sh`, works out what is wrong, proposes fixes, applies the ones you approve, checks that they worked, and repeats, without you saying "next".
- **When to ask.**

| What the agent wants to do | Does it ask you? |
| --- | --- |
| Read GitHub, plan, write scripts locally, read outputs | No |
| Publish **read-only** scripts (recon, checks) | Once per session, then no |
| Publish anything that **changes** the VM | Yes, for every batch, with a plain-language summary and an undo plan |
| Reset the repo, manage collaborators, change this repo's code | Only when you ask |

A good first message is enough: *"We're doing a CyberPatriot practice round on my Mint VM. Let's start."*

The agent never needs a token. It publishes and reads with your `gh` login, and you type the token only into the VM's terminal. It recommends a one-day token. The detailed instructions are in [`.agents/skills/cpats-pastebin/SKILL.md`](.agents/skills/cpats-pastebin/SKILL.md) and its [CyberPatriot playbook](.agents/skills/cpats-pastebin/references/cyberpatriot-playbook.md). To use the skill from any folder in Claude Code, copy it once: `mkdir -p ~/.claude/skills && cp -r .agents/skills/cpats-pastebin ~/.claude/skills/`. Outside this repo the skill carries a short version of the rules.

`keep/recon.sh` is a read-only baseline scan of a Linux image. It prints the scenario README, users, sudo rules, password policy, SSH settings, firewall, listening ports, services, risky packages, updates, scheduled tasks, media files, setuid files, and key permissions. It changes nothing and never prints password hashes. You can also run it yourself: `bash publish.sh --user NAME --source keep/recon.sh --name recon`.

## Repo layout, tests, and forking

| Path | Purpose |
| --- | --- |
| `runner.sh` | The VM runner. It also holds the shared GitHub helpers that the other scripts use. |
| `clipboard_upload.sh` | Uploads piped or clipboard text. Keep it next to `runner.sh`. |
| `publish.sh`, `publish.ps1` | Publish a script from your computer, in Bash or PowerShell. |
| `results.sh` | Fetch and wait for what the VM sent back. |
| `.gitattributes` | Keeps the shell scripts on Unix line endings in Windows checkouts. |
| `collab.sh` | Invite and remove collaborators. |
| `reset_competition.sh` | Clear competition data between events. |
| `scripts/<user>/`, `outputs/<user>/`, `clipboard/<user>/` | Published scripts, run output, and pastes. |
| `keep/` | Files that survive a reset. It holds `recon.sh`, the read-only baseline scan. |
| `AGENTS.md`, `CLAUDE.md` | What an agent reads first: the CyberPatriot context and how proactive to be. |
| `.agents/skills/cpats-pastebin/` | The agent skill, with its CyberPatriot playbook. `.skill/` and `.agents/skills/cpats-pastebin.md` are pointers to it. |
| `tests/test_workflow.py` | Offline integration tests. |

Run the tests with `uv run tests/test_workflow.py`, or `python3 tests/test_workflow.py`. Python is only needed here, to run the tests. The tools themselves never use it.

The tests use fake `curl`, `wget`, and `gh` commands and never contact GitHub. They cover concurrent publishing, retries, lost responses, flag-only configuration, rate limits and polling, `--check`, loop behavior, collaborator management, and reset. Set `CPATS_TEST_PWSH` to a PowerShell executable to include the Windows publisher test.

**The VM tools are tested with a `PATH` that has only standard utilities.** The tests hand the scripts a `PATH` holding `bash`, `sed`, `awk`, `grep`, `base64`, and similar tools. It has no `python3`, `jq`, or `git`, and a run with `wget` but no `curl`. A script that reaches for anything else fails its test. The tools also target Bash 3.2, which is what macOS ships, with BSD `sed`, `awk`, and `date`, so they work on macOS, and Linux's GNU tools are more permissive.

To fork the project, pass `--repo` to every tool, or change the default repo in four places: `DEFAULT_REPO` at the top of `runner.sh` (`publish.sh` and `clipboard_upload.sh` reuse it), `DEFAULT_REPO` in `collab.sh` and in `reset_competition.sh`, and the `-Repo` default in `publish.ps1`. Keep commits to the *tools* ordinary Git commits. Publish *scripts* only through `publish.sh` or `publish.ps1`, so two people never need to merge.

### Keep your copy current

If you cloned this repo earlier, for example into Downloads, run `git pull` in that folder. `git status -sb` shows `behind N` when updates are waiting. Your own local files are left alone. The VMs are separate: re-download `runner.sh` and `clipboard_upload.sh` there to get the same updates.

### Upgrading from the `.env` version

Earlier versions read `.cpats.env` and `prepare_vm.py` generated it. Both are gone. Delete any `.cpats.env` you have, since it may hold a token, and re-download `runner.sh` and `clipboard_upload.sh` on your VMs. Then pass `--token`, `--user`, `--repo`, and the other settings as flags as shown above.
