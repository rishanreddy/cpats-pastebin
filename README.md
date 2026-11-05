# cpats-pastebin

Script relay for CyberPatriots competitions. Chat with an AI → it pushes scripts here → your VM runs them → output comes back here.

**No installs on the VM.** Just `curl` and `bash` (pre-installed on Ubuntu/Mint/Debian).

---

## First-time setup (do this once per competition)

### 1. Authenticate the developer machine

The developer machine should use GitHub CLI authentication instead of putting
a token in a project file:

```bash
gh auth login
gh auth status
```

Publish reviewed scripts with:

```bash
bash publish.sh --user rishanreddy --source /tmp/check.sh --name check
```

On Windows, use Git Bash or PowerShell:

```powershell
.\publish.ps1 -User rishanreddy -Source C:\work\check.sh -Name check
```

The developer machine can be Windows, macOS, or Linux. It needs the GitHub
CLI and an authenticated `gh auth status`; only the CyberPatriots VM needs to
be Ubuntu/Mint/Debian. Windows publishing requires Bash through Git Bash or
WSL so the Bash script can be syntax-checked.

### 2. Create your `.cpats.env`

```bash
cp .cpats.env.example .cpats.env
nano .cpats.env   # fill in your values
```

Minimum VM config:
```bash
GITHUB_REPO="rishanreddy/cpats-pastebin"
GITHUB_TOKEN="ghp_..."       # fine-grained PAT: Contents R/W on this repo
CPATS_USERNAME="yourname"    # your GitHub username
```

### 3. Download the runner to your VM

On the CyberPatriots VM (Ubuntu/Mint/Debian terminal):

```bash
# Public repo — no token needed to download
curl -fsSL https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main/runner.sh \
     -o runner.sh && chmod +x runner.sh

# Private repo — pass the token inline
curl -fsSL -H "Authorization: token ghp_YOUR_TOKEN" \
     https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main/runner.sh \
     -o runner.sh && chmod +x runner.sh

# Same for clipboard_upload.sh if you want it
curl -fsSL https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main/clipboard_upload.sh \
     -o clipboard_upload.sh && chmod +x clipboard_upload.sh
```

Create `.cpats.env` on the VM too (copy the contents from above).

---

## Running scripts

```bash
# Pull and run the latest script your teammate pushed
./runner.sh --user rishanreddy

# Run it AND upload the output back to GitHub so your AI can read it
./runner.sh --user rishanreddy --upload-output

# Keep watching — auto-runs within 30s whenever a new script is pushed
./runner.sh --user rishanreddy --upload-output --loop

# See what scripts are available
./runner.sh --list --user rishanreddy

# Run a local script you already have (no pull)
./runner.sh --file /path/to/script.sh
```

---

## Sharing text from the VM

```bash
# Upload whatever's in your clipboard
./clipboard_upload.sh -l auth-log

# Pipe a file or command output
cat /var/log/auth.log | ./clipboard_upload.sh -l auth-log
cat /etc/passwd       | ./clipboard_upload.sh -l passwd
ss -tlnp              | ./clipboard_upload.sh -l open-ports

# Upload text directly
./clipboard_upload.sh -l note -t "192.168.1.50 is suspicious"
```

Your AI agent reads these from `clipboard/<username>/` and can analyze them.

---

## Managing teammates (repo owner only)

```bash
# Add your partner as a collaborator (they can push scripts + upload outputs)
./collab.sh add partnerusername

# List current collaborators
./collab.sh list

# Remove someone
./collab.sh remove partnerusername
```

Each teammate needs their own `.cpats.env` with their own token.  
Scripts are organized by username: `scripts/alice/`, `scripts/bob/`.

---

## Between competitions

```bash
# See what would be cleared without touching anything
./reset_competition.sh --dry-run

# Wipe scripts/, outputs/, clipboard/ — keeps keep/ and all scripts
./reset_competition.sh
```

Anything in `keep/` is permanent — use it for reference scripts, checklists, notes.

---

## Repo structure

```
scripts/   ← AI pushes scripts here, organized by username
outputs/   ← VM uploads script results here
clipboard/ ← VM text pastes land here
keep/      ← permanent files, never cleared

runner.sh             ← run on VM to pull + execute scripts
clipboard_upload.sh   ← run on VM to upload clipboard/text
collab.sh             ← manage repo collaborators (owner only)
reset_competition.sh  ← wipe competition data between rounds
.cpats.env.example    ← config template
.skill/               ← AI agent skill (auto-loaded by this AI)
```

---

## Token setup

Go to **github.com/settings/tokens** → **Fine-grained tokens** → New token:
- Repository access: `rishanreddy/cpats-pastebin` only
- Permissions: **Contents → Read and write**

That's it. One scope, one repo. Much safer than a classic PAT.

For **public repos**: the VM runner doesn't need a token to *read* scripts — it only needs one for `--upload-output` or `clipboard_upload.sh`.

For **private repos**: everyone needs a token for everything (reads and writes).
