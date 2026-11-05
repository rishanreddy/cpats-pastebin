# cpats-pastebin Agent Skill

You are connected to **cpats-pastebin** — a GitHub repo that relays scripts to CyberPatriots VMs.

When asked to write a script: **write it, then push it to GitHub immediately**. The user's VM is watching and will auto-run it.

---

## What you need (ask user if missing)

| Variable | Example | Where |
|---|---|---|
| `GITHUB_REPO` | `rishanreddy/cpats-pastebin` | In env or ask user |
| `GITHUB_TOKEN` | `ghp_...` | In env or ask user |
| `CPATS_USERNAME` | `rishanreddy` | Whose `scripts/` folder to push to |

---

## Push a script — the right way

Always push via the **GitHub Contents API PUT**. Use Python to build the payload — never build JSON by hand (it will break on scripts containing quotes or backslashes).

```python
#!/usr/bin/env python3
# /// script
# dependencies = ["requests"]
# ///
"""Push a script to cpats-pastebin. Run with: uv run push_script.py"""
import os, base64, json, requests
from datetime import datetime, timezone

REPO    = os.environ["GITHUB_REPO"]    # e.g. "rishanreddy/cpats-pastebin"
TOKEN   = os.environ["GITHUB_TOKEN"]
USER    = os.environ["CPATS_USERNAME"] # whose scripts/ subfolder

# ── Put your script content here ──────────────────────────────────────────
SCRIPT = """\
#!/usr/bin/env bash
echo "Hello from the VM!"
"""
DESC = "hello_world"  # short label, no spaces
EXT  = "sh"
# ──────────────────────────────────────────────────────────────────────────

ts   = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
path = f"scripts/{USER}/{ts}_{DESC}.{EXT}"
url  = f"https://api.github.com/repos/{REPO}/contents/{path}"

resp = requests.put(url,
    headers={
        "Authorization": f"token {TOKEN}",
        "Accept": "application/vnd.github.v3+json",
    },
    json={
        "message": f"script: {DESC} [{USER}]",
        "content": base64.b64encode(SCRIPT.encode()).decode(),
        "branch":  "main",
    }
)
resp.raise_for_status()
print(f"✅ Pushed: {path}")
print(f"   https://github.com/{REPO}/blob/main/{path}")
```

After pushing, tell the user:
```
✅ Script pushed to: scripts/<user>/<filename>

On your VM, run:
  ./runner.sh --user <user> --upload-output

Already in loop mode? It will auto-run within 30s.
```

---

## File naming

```
scripts/<username>/<YYYYMMDD_HHMMSS>_<short-label>.<ext>
```

**Always use a UTC timestamp prefix** — the runner sorts by filename to find the newest script.

---

## Read output back from the VM

After `--upload-output`, results appear at `outputs/<user>/<script>_<timestamp>.txt`.

Fetch the latest output:
```python
import requests, base64, json, os

REPO  = os.environ["GITHUB_REPO"]
TOKEN = os.environ["GITHUB_TOKEN"]
USER  = "rishanreddy"

r = requests.get(
    f"https://api.github.com/repos/{REPO}/contents/outputs/{USER}",
    headers={"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github.v3+json"},
)
files = sorted(r.json(), key=lambda f: f["name"], reverse=True)
if not files:
    print("No outputs yet.")
else:
    latest = files[0]
    content = base64.b64decode(
        requests.get(latest["url"],
            headers={"Authorization": f"token {TOKEN}",
                     "Accept": "application/vnd.github.v3+json"}).json()["content"]
    ).decode()
    print(f"=== {latest['name']} ===\n{content}")
```

---

## Read clipboard pastes from the VM

When the user pastes something with `clipboard_upload.sh`, read it like this:

```python
import requests, base64, os

REPO  = os.environ["GITHUB_REPO"]
TOKEN = os.environ["GITHUB_TOKEN"]
USER  = "rishanreddy"

r = requests.get(
    f"https://api.github.com/repos/{REPO}/contents/clipboard/{USER}",
    headers={"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github.v3+json"},
)
files = sorted(r.json(), key=lambda f: f["name"], reverse=True)
latest = files[0]
content = base64.b64decode(
    requests.get(latest["url"],
        headers={"Authorization": f"token {TOKEN}",
                 "Accept": "application/vnd.github.v3+json"}).json()["content"]
).decode()
print(content)
```

---

## Repo layout

```
scripts/
  <username>/
    20241105_143022_fix_ssh.sh      ← newest = run this
    20241105_120000_check_users.sh
outputs/
  <username>/
    fix_ssh_20241105_143055.txt     ← VM output
clipboard/
  <username>/
    auth-log_20241105_150000.txt    ← pasted from VM
keep/
  common_fixes.sh                   ← never cleared
```

---

## Common CyberPatriots snippets

**Enumerate users & sudoers**
```bash
#!/usr/bin/env bash
echo "=== All users ===" && cut -d: -f1 /etc/passwd
echo "=== UID 0 ===" && awk -F: '$3==0' /etc/passwd
echo "=== Sudoers ===" && cat /etc/sudoers
echo "=== Sudo group ===" && getent group sudo
echo "=== Last logins ===" && last | head -20
```

**Harden SSH**
```bash
#!/usr/bin/env bash
set -e
CFG=/etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'         "$CFG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$CFG"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'             "$CFG"
systemctl restart ssh && echo "SSH hardened."
```

**Listening ports**
```bash
#!/usr/bin/env bash
ss -tlnp 2>/dev/null || netstat -tlnp
```

**Update & upgrade**
```bash
#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
echo "Done."
```
