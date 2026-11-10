# cpats-pastebin

A shared GitHub repo for sending scripts to Ubuntu, Mint, and Debian VMs and collecting their output. Each teammate publishes into their own username folder.

The VM needs Bash, curl, and Python 3 already available. It does not need Git, GitHub CLI, uv, or Python packages. Scripts run as the account that starts the runner.

## Publish from your computer

Authenticate GitHub CLI on the developer machine:

```bash
gh auth login
gh auth status
```

On macOS, Linux, or Git Bash, use the Bash publisher. It also needs Python 3:

```bash
bash publish.sh --user rishanreddy --source /tmp/check.sh --name check
bash publish.sh --user sid1332 --source /tmp/check.sh --name check
```

On Windows, use the native PowerShell publisher:

```powershell
.\publish.ps1 -User sid1332 -Source C:\work\check.sh -Name check
```

Windows also needs Bash through Git Bash or WSL for the syntax check. Save Bash scripts with LF line endings. Both publishers require a Bash shebang, check syntax, and use the authenticated GitHub CLI. Keep `runner.sh` beside `publish.sh` because it contains the shared upload helpers.

Publishing makes a script available to any VM watching that username. The agent workflow is in [.agents/skills/cpats-pastebin/SKILL.md](.agents/skills/cpats-pastebin/SKILL.md).

## Work together without push conflicts

Publish scripts through the helpers instead of committing them in a local clone. Each upload creates a new file through the Contents API, so neither teammate needs to pull or merge the other's scripts before publishing.

Files use a UTC timestamp with microseconds and a random UUID. Outputs also include the VM hostname. Even two uploads from the same username, host, and second get separate paths. Usernames are normalized to lowercase, including `Sid1332` becoming `sid1332`.

GitHub writes can still conflict while the branch changes. Uploads retry conflicts with increasing delays, up to five attempts. A retry uses the same path and bytes. If the file already exists, matching bytes count as success and different bytes cause an error. The helpers never overwrite an existing script, output, or paste.

Keep normal Git commits for changes to the tools themselves. Stop all runners and publishers before a competition reset. GitHub documents the conflict between simultaneous creates and deletes in its [Contents API reference](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents).

## Set up the VM

### Teammate setup using their own login

Sid first accepts the repo invitation. Then he runs these commands on his own computer from this checkout:

```bash
gh auth login --hostname github.com
uv run prepare_vm.py --user sid1332
```

The helper checks the signed-in username and collaborator write access. It creates a private folder outside the checkout containing the runner, clipboard uploader, and a configured `.cpats.env` using that account's CLI credential. It never prints the credential. It refuses to package the owner's login for a different teammate.

Copy the entire generated folder, including hidden `.cpats.env`, onto Sid's VM. In that folder on the VM, run:

```bash
bash runner.sh --user sid1332 --upload-output --loop
```

These commands work with Python 3 on Windows, macOS, and Linux. If uv is unavailable on the developer computer, run `python prepare_vm.py --user sid1332` using Python 3. Nothing needs to be installed on the VM.

The generated folder contains a real login credential. Keep it private and outside Git. GitHub CLI's browser login can use the account's `repo` access, which is broader than a fine-grained token restricted to this one repository. This makes the existing collaborator setup work; it does not turn that credential into a repo-limited token. See the [CLI login documentation](https://cli.github.com/manual/gh_auth_login) and [credential export command](https://cli.github.com/manual/gh_auth_token).

The owner can use the same helper with `--user rishanreddy`. To use a token restricted to this repo instead, follow the manual setup below with an appropriate token. Shared ownership is available through a GitHub organization, where both people can be members and create fine-grained tokens for permitted organization repos. A personally owned repo has owner and collaborator roles. Moving this repo to an organization would be a separate change; see [GitHub account permissions](https://docs.github.com/en/get-started/learning-about-github/access-permissions-on-github).

### Manual token setup

This repository is private. Download the tools using a token that can read it:

```bash
read -rsp 'GitHub token: ' GITHUB_TOKEN
printf '\n'
export GITHUB_TOKEN

for file in runner.sh clipboard_upload.sh .cpats.env.example; do
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main/${file}" \
        -o "$file" || break
done
chmod 700 runner.sh clipboard_upload.sh
cp .cpats.env.example .cpats.env
chmod 600 .cpats.env
nano .cpats.env
```

Set these values in `.cpats.env`:

```bash
GITHUB_REPO="rishanreddy/cpats-pastebin"
GITHUB_TOKEN="YOUR_TOKEN"
CPATS_USERNAME="sid1332"
BRANCH="main"
```

Keep `runner.sh`, `clipboard_upload.sh`, and `.cpats.env` in the same directory. Re-download both shell files together when updating them.

The repo owner can use a fine-grained token limited to this repo with Contents read and write access. Repository collaborators such as `sid1332` currently need a classic personal access token with the `repo` scope, or a GitHub App token with Contents access. GitHub lists repository collaborators among the [fine-grained token limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations). Each teammate should authenticate with their own account and token.

## Run scripts

```bash
# Run your latest published script and send its output back
bash runner.sh --user rishanreddy --upload-output

# Sid's VM watches his folder
bash runner.sh --user sid1332 --upload-output --loop

# List available scripts without running them
bash runner.sh --list --user sid1332

# Run a local script, without GitHub access
bash runner.sh --file /path/to/script.sh
```

The runner picks the script with the greatest timestamp filename in the selected username's folder. Loop mode checks every 30 seconds and runs only the latest script, so intermediate scripts can be skipped when several arrive between checks.

Stdout and stderr stream to the terminal and a unique local log. The log includes the script's exit code, including failures. `--upload-output` creates a file under `outputs/<username>/`. A one-time run returns the script's exit code after saving and uploading its log.

Loop state includes the repo, branch, username, and script blob hash. It lives under `~/.local/state/cpats-pastebin`, or `CPATS_STATE_DIR` when configured. If an output upload fails, the loop keeps it pending and retries it before checking for another script. It does not rerun the script just to retry the upload. Failed uploads retain the local log or paste and print its path.

Python scripts run with system `python3`. The runner does not install dependencies. It removes GitHub token environment variables before starting a script.

## Share text from the VM

```bash
# Use an existing clipboard tool, if available
bash clipboard_upload.sh -l auth-log

# Pipe text without installing a clipboard tool
cat /var/log/auth.log | bash clipboard_upload.sh -l auth-log
ss -tlnp | bash clipboard_upload.sh -l open-ports

# Supply text directly
bash clipboard_upload.sh -u sid1332 -l note -t 'Check this service'
```

Pastes appear at `clipboard/<username>/` with unique timestamped names. Piped text keeps its trailing newlines and can exceed the shell's command argument size limit.

## Manage teammates

The repo owner can invite and list collaborators with the authenticated GitHub CLI:

```bash
gh api --method PUT repos/rishanreddy/cpats-pastebin/collaborators/sid1332 -f permission=push
gh api repos/rishanreddy/cpats-pastebin/invitations
gh api repos/rishanreddy/cpats-pastebin/collaborators --jq '.[].login'
```

The invited teammate must accept on GitHub before accessing the private repo. `collab.sh` also supports add, list, and remove operations when configured with a repo administration token.

## Between competitions

Stop all runners and publishers first. Preview the reset, then clear the competition data:

```bash
bash reset_competition.sh --dry-run
bash reset_competition.sh
```

A reset clears `scripts/`, `outputs/`, and `clipboard/` while preserving `keep/`, placeholders, and the tools. It does not erase Git history.

## Repo layout

| Path | Purpose |
| --- | --- |
| `scripts/<username>/` | Published scripts |
| `outputs/<username>/` | Script logs |
| `clipboard/<username>/` | Text from the VM |
| `keep/` | Files preserved across resets |
| `publish.sh`, `publish.ps1` | Developer publishers |
| `prepare_vm.py` | Prepare VM files with the signed-in teammate's credential |
| `runner.sh` | Standalone VM runner and shared API helpers |
| `clipboard_upload.sh` | Clipboard and stdin uploader |
| `.agents/skills/cpats-pastebin/SKILL.md` | Agent workflow |

## Development checks

```bash
uv run tests/test_workflow.py
```

The integration suite runs on macOS or Linux with fake `curl` and `gh` commands and never contacts GitHub. It covers concurrent publishing, conflicts, lost responses, output capture, pending uploads, username isolation, and collaborator VM setup. Set `CPATS_TEST_PWSH` to a PowerShell executable to include the native publisher test.
