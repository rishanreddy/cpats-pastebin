#!/usr/bin/env python3
"""Prepare VM files using the teammate's own GitHub CLI login. No dependencies."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote


class SetupError(Exception):
    pass


def gh_output(*args):
    try:
        result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SetupError("GitHub CLI access failed. Accept the repo invitation and run gh auth login --hostname github.com first.") from error
    return result.stdout.strip()


def prepare(repo, branch, requested_user, output=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise SetupError("Repository must be owner/repo.")
    login = json.loads(gh_output("api", "--hostname", "github.com", "user"))["login"].lower()
    if requested_user and requested_user.lower() != login:
        raise SetupError(f"GitHub CLI is logged in as {login}, not {requested_user}. Run this helper on the teammate's computer using their own login.")
    repo_info = json.loads(gh_output("api", "--hostname", "github.com", f"repos/{repo}"))
    if not repo_info.get("permissions", {}).get("push"):
        raise SetupError("This GitHub account needs collaborator write access before preparing a VM.")
    # Verify that the selected branch's contents are readable with this login.
    gh_output("api", "--hostname", "github.com", f"repos/{repo}/contents/runner.sh?ref={quote(branch, safe='')}")
    if output is not None:
        output = output.expanduser().resolve()
        if output.exists():
            raise SetupError("Choose a new output directory; existing files will not be overwritten.")
        if any((parent / ".git").exists() for parent in (output, *output.parents)):
            raise SetupError("The VM folder contains a credential. Choose an output directory outside a Git checkout.")
    token = gh_output("auth", "token", "--hostname", "github.com", "--user", login)
    if not token:
        raise SetupError("GitHub CLI returned no credential. Run gh auth login first.")
    if output is None:
        output = Path(tempfile.mkdtemp(prefix=f"cpats-vm-{login}-"))
    else:
        output.mkdir(mode=0o700, parents=True)
    try:
        source_dir = Path(__file__).resolve().parent
        for name in ("runner.sh", "clipboard_upload.sh"):
            shutil.copyfile(source_dir / name, output / name)
            (output / name).chmod(0o700)
        config = {"GITHUB_REPO": repo, "GITHUB_TOKEN": token, "CPATS_USERNAME": login, "BRANCH": branch}
        config_path = output / ".cpats.env"
        with open(config_path, "x", encoding="utf-8", opener=lambda path, flags: os.open(path, flags, 0o600)) as handle:
            for key, value in config.items():
                handle.write(f"{key}={shlex.quote(value)}\n")
        (output / "START.txt").write_text(
            f"Copy this entire folder, including the hidden .cpats.env file, to your VM.\n"
            f"In its terminal, run: bash runner.sh --user {login} --upload-output --loop\n"
            "This folder contains your GitHub login credential. Keep it private and outside Git.\n"
            "No GitHub CLI, Git, uv, or package installation is needed on the VM.\n",
            encoding="utf-8",
        )
    except Exception:
        shutil.rmtree(output)
        raise
    return output, login


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="rishanreddy/cpats-pastebin")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--user", help="Expected GitHub login; refuses a different account")
    parser.add_argument("--output", type=Path, help="New private folder outside a Git checkout; default is a temporary folder")
    args = parser.parse_args()
    try:
        output, login = prepare(args.repo, args.branch, args.user, args.output)
    except (SetupError, OSError, ValueError) as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        return 1
    print(f"VM files prepared for {login}: {output}")
    print("Copy the entire folder, including hidden .cpats.env, to the VM.")
    print("The folder contains your GitHub credential. Keep it private; never upload it.")
    print(f"On the VM: bash runner.sh --user {login} --upload-output --loop")
    return 0


if __name__ == "__main__":
    sys.exit(main())
