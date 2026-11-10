#!/usr/bin/env python3
"""Offline integration tests. Run with uv run tests/test_workflow.py.

The tools under test run with a PATH that holds only standard utilities plus fake
curl, wget, gh, and sleep. There is no python3, jq, or git on that PATH, so a tool
that reaches for one fails its test. That is how this suite proves the VM needs
nothing beyond bash, curl or wget, and ordinary Linux utilities.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ("runner.sh", "publish.sh", "publish.ps1", "clipboard_upload.sh", "collab.sh", "reset_competition.sh", "results.sh")
# Everything the shell tools are allowed to use. Linux Mint, Ubuntu, and Debian all ship these.
STANDARD_TOOLS = ("bash", "env", "cat", "tee", "tr", "sed", "grep", "awk", "cut", "sort", "head", "tail", "wc", "date",
                  "base64", "od", "mktemp", "rm", "mv", "mkdir", "uname", "id", "basename", "dirname", "sha1sum", "shasum")

# A real directory listing from GitHub's contents API, pretty-printed exactly as GitHub sends it.
REAL_GITHUB_LISTING = """[
  {
    "name": "20261110_173302_runner-smoke_5eab.sh",
    "path": "scripts/sid1332/20261110_173302_runner-smoke_5eab.sh",
    "sha": "49c42d9951e2231a41ee91b2e5ca5ac6be54663d",
    "size": 58,
    "url": "https://api.github.com/repos/rishanreddy/cpats-pastebin/contents/scripts/sid1332/20261110_173302_runner-smoke_5eab.sh?ref=main",
    "html_url": "https://github.com/rishanreddy/cpats-pastebin/blob/main/scripts/sid1332/20261110_173302_runner-smoke_5eab.sh",
    "git_url": "https://api.github.com/repos/rishanreddy/cpats-pastebin/git/blobs/49c42d9951e2231a41ee91b2e5ca5ac6be54663d",
    "download_url": "https://raw.githubusercontent.com/rishanreddy/cpats-pastebin/main/scripts/sid1332/20261110_173302_runner-smoke_5eab.sh",
    "type": "file",
    "_links": {
      "self": "https://api.github.com/repos/rishanreddy/cpats-pastebin/contents/scripts/sid1332/20261110_173302_runner-smoke_5eab.sh?ref=main",
      "git": "https://api.github.com/repos/rishanreddy/cpats-pastebin/git/blobs/49c42d9951e2231a41ee91b2e5ca5ac6be54663d",
      "html": "https://github.com/rishanreddy/cpats-pastebin/blob/main/scripts/sid1332/20261110_173302_runner-smoke_5eab.sh"
    }
  }
]
"""


def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def respond(state, method, repo, rest, payload, headers, query):
    """Answer one GitHub API request against the stored state: (status, body, lost_response)."""
    files = state.setdefault("files", {})
    if rest == "":
        if state.get("missing_repo"):
            return 404, {"message": "Not Found"}, False
        return 200, {"permissions": {"push": state.get("push_access", True)}}, False
    if rest.startswith("branches/"):
        if rest.removeprefix("branches/") in state.get("branches", ["main"]):
            return 200, {"name": rest.removeprefix("branches/")}, False
        return 404, {"message": "Branch not found"}, False
    if rest == "invitations":
        return 200, state.get("invitations", []), False
    if rest.startswith("git/trees/"):
        prefix = f"{repo}|{rest.removeprefix('git/trees/')}|"
        tree = [{"type": "blob", "path": key[len(prefix):], "sha": blob_sha(base64.b64decode(data))}
                for key, data in sorted(files.items()) if key.startswith(prefix)]
        return 200, {"tree": tree, "truncated": state.get("truncated", False)}, False
    if rest.startswith("collaborators"):
        login = rest.removeprefix("collaborators").lstrip("/")
        people = state.setdefault("collaborators", {"rishanreddy": "admin"})
        if method == "GET":
            return 200, [{"login": name, "role_name": role} for name, role in people.items()], False
        if method == "PUT":
            if login in people:
                return 204, b"", False
            people[login] = payload["permission"]
            return 201, {"invitee": {"login": login}}, False
        if login in people:
            del people[login]
            return 204, b"", False
        return 404, {"message": "Not Found"}, False

    path = rest.removeprefix("contents/")
    branch = payload["branch"] if payload else query.get("ref", ["main"])[0]
    key = f"{repo}|{branch}|{path}"
    if method == "PUT":
        counts = state.setdefault("attempts", {})
        counts[key] = counts.get(key, 0) + 1
        put_count = sum(counts.values())
        forced = state.get("put_status")
        if state.get("fail_first_n", 0) >= put_count:
            forced = 409
        if state.get("conflict_once") and counts[key] == 1:
            forced = 409
        if forced:
            return forced, {"message": "simulated API conflict or rejection"}, False
        if key in files:
            return 422, {"message": 'Invalid request: "sha" was not supplied'}, False
        assert "sha" not in payload, "New uploads must not replace existing content"
        files[key] = payload["content"]
        state["last_message"] = payload["message"]
        body = {"content": {"path": path, "sha": blob_sha(base64.b64decode(files[key]))}}
        return 201, body, state.get("lost_response", False)
    if method == "DELETE":
        if key in files and blob_sha(base64.b64decode(files[key])) == payload["sha"]:
            del files[key]
            return 200, {"commit": {}}, False
        return 404, {"message": "Not Found"}, False
    if key in files:
        data = base64.b64decode(files[key])
        if any("raw+json" in header for header in headers):
            return 200, (b"echo changed-after-listing\n" if state.get("changed_download") else data), False
        return 200, {"path": path, "sha": blob_sha(data), "type": "file", "content": files[key]}, False
    prefix = f"{repo}|{branch}|{path}/"
    listing = []
    for stored_key, content in sorted(files.items()):
        name = stored_key[len(prefix):]
        if stored_key.startswith(prefix) and "/" not in name:
            # Key order and pretty printing below match what GitHub really sends.
            listing.append({"name": name, "path": f"{path}/{name}", "sha": blob_sha(base64.b64decode(content)),
                            "size": len(base64.b64decode(content)), "type": "file",
                            "_links": {"self": f"https://api.github.com/{path}/{name}"}})
    if state.get("bad_listing"):
        return 200, {"message": "not a directory"}, False
    if not listing and path not in state.get("empty_directories", []):
        return 404, {"message": "Not Found"}, False
    return 200, listing, False


def parse_request(tool, args):
    """Pull the method, URL, payload, headers, and output paths out of a curl, wget, or gh command line."""
    method, url, payload, headers, dest, header_dest, jq = "GET", "", None, [], None, None, None
    fields = {}
    index = 0
    while index < len(args):
        arg = args[index]
        if tool == "wget" and arg.startswith("--method="):
            method = arg.partition("=")[2]
        elif tool == "wget" and arg.startswith("--header="):
            headers.append(arg.partition("=")[2])
        elif tool == "wget" and arg.startswith("--body-file="):
            payload = json.loads(Path(arg.partition("=")[2]).read_text())
        elif arg in ("-X", "--method", "-H", "--input", "--data-binary", "-o", "-O", "-D", "--jq", "-w",
                     "--connect-timeout", "--max-time", "-f", "--raw-field", "-F", "--field"):
            value = args[index + 1]
            if arg in ("-X", "--method"):
                method = value
            elif arg == "-H":
                headers.append(value)
            elif arg in ("--input", "--data-binary"):
                payload = json.loads(Path(value.removeprefix("@")).read_text())
            elif arg in ("-o", "-O"):
                dest = Path(value)
            elif arg == "-D":
                header_dest = Path(value)
            elif arg == "--jq":
                jq = value
            elif arg in ("-f", "--raw-field", "-F", "--field"):
                name, _, field_value = value.partition("=")
                fields[name] = field_value
            index += 1
        elif arg.startswith(("repos/", "https://")):
            url = arg
        index += 1
    return method, url, payload or fields or None, headers, dest, header_dest, jq


def fake_tool(tool, args):
    """Implement curl, wget, gh, and sleep against one locked file, without any network calls."""
    state_path = Path(os.environ["CPATS_TEST_API"])
    with state_path.open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        state = json.load(handle)

        def save():
            handle.seek(0)
            json.dump(state, handle)
            handle.truncate()

        if tool == "sleep":
            code = 0
            if re.fullmatch(r"\d+", args[0]):
                state.setdefault("sleeps", []).append(int(args[0]))
                state["polls"] = state.get("polls", 0) + 1
                arrival = state.get("arrives_after_sleeps")
                if arrival and state["polls"] >= arrival["n"]:
                    state["files"][arrival["key"]] = arrival["data"]
                    state["arrives_after_sleeps"] = None
                if state["polls"] >= int(os.environ.get("CPATS_TEST_POLLS", "2")):
                    code = 99
            save()
            return code
        if tool == "gh" and args[:2] == ["auth", "status"]:
            return 0 if not state.get("gh_signed_out") else 1
        method, url, payload, headers, dest, header_dest, jq = parse_request(tool, args)
        parts = urlsplit(url)
        match = re.fullmatch(r"repos/([^/]+/[^/]+)(?:/(.*))?", parts.path.lstrip("/"))
        if not match:
            raise RuntimeError(f"Unexpected test request: {url}")
        repo, rest = match.group(1), unquote(match.group(2) or "")
        auth = next((header for header in headers if header.lower().startswith("authorization:")), None)
        state.setdefault("requests", []).append({"method": method, "repo": repo, "path": rest, "auth": auth, "tool": tool})
        response_headers = {"x-ratelimit-limit": "5000" if auth else "60",
                            "x-ratelimit-remaining": str(state.get("rate_remaining", 57))}
        if state.get("scopes") is not None and auth:
            response_headers["x-oauth-scopes"] = state["scopes"]
        if state.get("expires") and auth:
            response_headers["github-authentication-token-expiration"] = state["expires"]
        lost = False
        if tool in ("curl", "wget") and method == "GET" and state.get("rate_limited_requests", 0) > 0:
            state["rate_limited_requests"] -= 1
            status, body = 403, {"message": "API rate limit exceeded"}
            response_headers.update({"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(time.time()) + 600)})
        else:
            status, body, lost = respond(state, method, repo, rest, payload, headers, parse_qs(parts.query))
        save()
    data = body if isinstance(body, bytes) else json.dumps(body, indent=2).encode()
    if tool == "curl":
        if lost:
            return 28
        if dest:
            dest.write_bytes(data)
        if header_dest:
            header_dest.write_text(f"HTTP/2 {status}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in response_headers.items()) + "\r\n")
        sys.stdout.write(str(status))
        return 0
    if tool == "wget":
        if lost:
            return 4
        if dest:
            dest.write_bytes(data)
        # Like the real wget -q -S: indented response headers on stderr, exit 8 for HTTP errors.
        sys.stderr.write(f"  HTTP/1.1 {status} Test\n" + "".join(f"  {k}: {v}\n" for k, v in response_headers.items()))
        return 0 if status < 400 else 8
    if lost:
        return 1
    if "--include" in args:
        sys.stdout.buffer.write(f"HTTP/2.0 {status} Test\r\nContent-Type: application/json\r\n\r\n".encode() + data)
        return 0 if status < 400 else 1
    if jq == ".sha" and status == 200:
        print(body["sha"])
    elif jq and isinstance(body, list) and "map(.name)" in jq:
        # Stand-in for the jq filter in results.sh: file names, oldest first.
        for name in sorted(item["name"] for item in body if item["type"] == "file"):
            print(name)
    elif jq and rest.startswith("git/trees/"):
        # Stand-in for the jq filter in reset_competition.sh.
        if body["truncated"]:
            print("TRUNCATED")
        for item in body["tree"]:
            if item["path"].startswith(("scripts/", "outputs/", "clipboard/")) and not item["path"].endswith(".gitkeep"):
                print(f"{item['path']}|{item['sha']}")
    else:
        sys.stdout.buffer.write(data)
    if status >= 400:
        message = body.get("message", "error") if isinstance(body, dict) else "error"
        sys.stderr.write(f"gh: {message} (HTTP {status})\n")
        return 1
    return 0


def has_gnu_date():
    out = subprocess.run(["date", "-u", "+%N"], capture_output=True, text=True).stdout.strip()
    return bool(re.fullmatch(r"\d{9}", out))


class WorkflowTests(unittest.TestCase):
    def make_bin(self, name, fakes):
        """A PATH directory with fake network tools and symlinks to the standard utilities only."""
        directory = self.work / name
        directory.mkdir()
        for tool in fakes:
            wrapper = directory / tool
            wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} "
                               f'--fake {tool} "$@"\n')
            wrapper.chmod(0o755)
        wanted = list(STANDARD_TOOLS) + ([] if has_gnu_date() else ["perl"])  # BSD date has no %N; macOS ships perl
        for tool in wanted:
            found = shutil.which(tool)
            if found:
                (directory / tool).symlink_to(found)
        return directory

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cpats test 'quotes' ")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.make_bin("bin", ("curl", "gh", "sleep"))
        for file in TOOLS:
            shutil.copy2(ROOT / file, self.work / file)
        self.api = self.work / "api.json"
        self.api.write_text(json.dumps({"files": {}, "requests": []}))
        # Decoy settings that the tools must ignore: only flags configure them.
        self.env = {"PATH": str(self.bin), "HOME": str(self.work), "TMPDIR": str(self.work),
                    "GITHUB_REPO": "wrong/env-repo", "GITHUB_TOKEN": "env-token", "GH_TOKEN": "fake-cli-token",
                    "CPATS_USERNAME": "env-user", "BRANCH": "env-branch", "CPATS_STATE_DIR": str(self.work / "env-state"),
                    "CPATS_TEST_API": str(self.api)}
        (self.work / ".cpats.env").write_text('GITHUB_REPO="wrong/file-repo"\nGITHUB_TOKEN="file-token"\n')
        self.source = self.work / "check.sh"
        self.source.write_text('#!/usr/bin/env bash\nprintf "hello stdout\\n"\nprintf "hello stderr\\n" >&2\n')

    def state(self):
        return json.loads(self.api.read_text())

    def configure(self, **kwargs):
        state = self.state()
        state.update(kwargs)
        self.api.write_text(json.dumps(state))

    def seed(self, path, data, repo="test/relay", branch="main"):
        state = self.state()
        state["files"][f"{repo}|{branch}|{path}"] = base64.b64encode(data).decode()
        self.api.write_text(json.dumps(state))

    def command(self, *args, input=None, env=None):
        return subprocess.run(args, cwd=self.work, env=env or self.env, input=input,
                              capture_output=True, text=True, timeout=25)

    def bash(self, script, *args, **kwargs):
        return self.command("bash", str(self.work / script), *args, **kwargs)

    def runner(self, *args, token=True, **kwargs):
        flags = ["--repo", "test/relay", "--state-dir", str(self.work / "state")]
        if token:
            flags += ["--token", "fake-test-token"]
        return self.bash("runner.sh", *flags, *args, **kwargs)

    def assert_ok(self, result, code=0):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def upload_fixed(self, path="clipboard/rishanreddy/fixed.txt", message="test"):
        return self.command("bash", "-c",
                            'source ./runner.sh; GITHUB_REPO=test/relay; GITHUB_TOKEN=fake-test-token; gh_upload "$1" "$2" "$3"',
                            "--", path, str(self.source), message)

    # ── The VM needs nothing installed ──

    def test_vm_tools_use_no_python_jq_or_git(self):
        for tool in ("python3", "python", "jq", "git"):
            self.assertIsNone(shutil.which(tool, path=str(self.bin)), tool)
        for script in ("runner.sh", "clipboard_upload.sh", "publish.sh", "collab.sh", "reset_competition.sh"):
            code = "\n".join(line for line in (ROOT / script).read_text().splitlines() if not line.lstrip().startswith("#"))
            for forbidden in ("python", "jq ", " git "):
                if forbidden == "jq " and script in ("collab.sh", "reset_competition.sh"):
                    continue  # gh's built-in --jq filter, not a separate jq program
                self.assertTrue(forbidden not in code, f"{script} uses {forbidden!r}, which the VM does not have")

    def test_full_vm_flow_runs_with_only_standard_utilities(self):
        self.seed("scripts/rishanreddy/20261110_000001_check.sh", b"#!/usr/bin/env bash\necho ran-on-vm\n")
        result = self.runner("--user", "rishanreddy", "--upload-output")
        self.assert_ok(result)
        self.assertIn("ran-on-vm", result.stdout)
        pasted = self.bash("clipboard_upload.sh", "--repo", "test/relay", "--token", "fake-test-token",
                           "-u", "rishanreddy", "-l", "note", "-t", "pasted text")
        self.assert_ok(pasted)
        paths = sorted(key.split("|", 2)[2] for key in self.state()["files"])
        self.assertEqual([path.split("/")[0] for path in paths], ["clipboard", "outputs", "scripts"])
        for path in paths[:2]:  # every uploaded name carries a timestamp and a 32-hex unique id
            self.assertRegex(path, r"^[a-z]+/rishanreddy/\d{8}_\d{6}_\d{6}_.+_[0-9a-f]{32}\.txt$")

    def test_works_with_wget_when_curl_is_missing(self):
        wget_bin = self.make_bin("wget-bin", ("wget", "gh", "sleep"))
        self.assertIsNone(shutil.which("curl", path=str(wget_bin)))
        env = dict(self.env, PATH=str(wget_bin))
        self.seed("scripts/rishanreddy/20261110_000001_check.sh", b"#!/usr/bin/env bash\necho ran-with-wget\n")
        checked = self.runner("--check", env=env)
        self.assert_ok(checked)
        self.assertIn("can push", checked.stdout)
        self.assertIn("57 of 5000", checked.stdout)
        result = self.runner("--user", "rishanreddy", "--upload-output", env=env)
        self.assert_ok(result)
        self.assertIn("ran-with-wget", result.stdout)
        self.assertEqual(len([key for key in self.state()["files"] if "|outputs/" in key]), 1)
        pasted = self.bash("clipboard_upload.sh", "--repo", "test/relay", "--token", "t", "-u", "rishanreddy",
                           "-l", "n", "-t", "x", env=env)
        self.assert_ok(pasted)
        self.assertEqual({request["tool"] for request in self.state()["requests"]}, {"wget"})

    def test_wget_reports_http_errors_and_rate_limits(self):
        wget_bin = self.make_bin("wget-bin", ("wget", "gh", "sleep"))
        env = dict(self.env, PATH=str(wget_bin))
        self.configure(put_status=403)
        result = self.command("bash", "-c",
                              'source ./runner.sh; GITHUB_REPO=test/relay; GITHUB_TOKEN=t; gh_upload "$1" "$2" test',
                              "--", "clipboard/rishanreddy/x.txt", str(self.source), env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public_repo", result.stderr)
        self.configure(rate_limited_requests=1)
        limited = self.runner("--user", "rishanreddy", "--list", token=False, env=env)
        self.assertNotEqual(limited.returncode, 0)
        self.assertIn("rate limit is used up", limited.stderr)

    def test_neither_curl_nor_wget_is_a_clear_error(self):
        bare = self.make_bin("bare-bin", ("gh", "sleep"))
        result = self.runner("--user", "rishanreddy", env=dict(self.env, PATH=str(bare)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("curl or wget", result.stderr)
        local = self.runner("--file", str(self.source), token=False, env=dict(self.env, PATH=str(bare)))
        self.assert_ok(local)
        self.assertIn("hello stdout", local.stdout)

    def test_missing_standard_tool_is_named(self):
        sparse = self.make_bin("sparse-bin", ("curl", "gh", "sleep"))
        (sparse / "base64").unlink()
        result = self.runner("--user", "rishanreddy", env=dict(self.env, PATH=str(sparse)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing: base64", result.stderr)

    def test_listing_parser_reads_githubs_real_pretty_printed_json(self):
        pretty = self.work / "listing.json"
        pretty.write_text(REAL_GITHUB_LISTING)
        entries = [{"name": name, "path": f"scripts/sid1332/{name}", "sha": "a" * 40, "type": kind, "_links": {"self": "x"}}
                   for name, kind in (("20261110_000001_old.sh", "file"), ("20261110_000009_new.sh", "file"),
                                      ("20261110_000099_notes.py", "file"), ("README.md", "file"),
                                      ("20261110_999999_folder.sh", "dir"), ("bad name$.sh", "file"))]
        mixed = self.work / "mixed.json"
        mixed.write_text(json.dumps(entries, indent=2))
        compact = self.work / "compact.json"
        compact.write_text(json.dumps(entries, separators=(",", ":")))
        parse = 'source ./runner.sh; parse_script_listing < "$1"'
        real = self.command("bash", "-c", parse, "--", str(pretty))
        self.assert_ok(real)
        self.assertEqual(real.stdout.strip(), "scripts/sid1332/20261110_173302_runner-smoke_5eab.sh|49c42d9951e2231a41ee91b2e5ca5ac6be54663d")
        expected = ["scripts/sid1332/20261110_000009_new.sh|" + "a" * 40, "scripts/sid1332/20261110_000001_old.sh|" + "a" * 40]
        for path in (mixed, compact):
            result = self.command("bash", "-c", parse, "--", str(path))
            self.assert_ok(result)
            self.assertEqual(result.stdout.split(), expected, path.name)
        empty = self.work / "empty.json"
        empty.write_text("[]\n")
        self.assertEqual(self.command("bash", "-c", parse, "--", str(empty)).stdout, "")
        broken = self.work / "broken.json"
        broken.write_text('{"message": "Not Found"}')
        self.assertNotEqual(self.command("bash", "-c", parse, "--", str(broken)).returncode, 0)

    def test_only_bash_scripts_run_and_python_files_are_ignored(self):
        self.seed("scripts/rishanreddy/20261110_000001_first.sh", b"echo bash-ran\n")
        self.seed("scripts/rishanreddy/20261110_000002_newer.py", b"print('python must not run')\n")
        listed = self.runner("--list", "--user", "rishanreddy")
        self.assertNotIn(".py", listed.stdout)
        result = self.runner("--user", "rishanreddy")
        self.assert_ok(result)
        self.assertIn("bash-ran", result.stdout)
        self.assertNotIn("python must not run", result.stdout)

    def test_generated_names_sort_in_creation_order_and_are_safe(self):
        names = self.command("bash", "-c",
                             'source ./runner.sh; for i in 1 2 3 4 5 6; do new_repo_path scripts sid1332 check sh; echo; done')
        self.assert_ok(names)
        paths = names.stdout.split()
        self.assertEqual(len(set(paths)), 6)
        self.assertEqual(paths, sorted(paths))
        for path in paths:
            self.assertRegex(path, r"^scripts/sid1332/\d{8}_\d{6}_\d{6}_check_[0-9a-f]{32}\.sh$")
        weird = self.command("bash", "-c", 'source ./runner.sh; new_repo_path outputs sid1332 "  Weird LABEL!! ../x " txt')
        self.assertRegex(weird.stdout, r"^outputs/sid1332/\d{8}_\d{6}_\d{6}_weird-label-+x_[a-z0-9_-]+_[0-9a-f]{32}\.txt$")

    def test_hostile_commit_messages_still_produce_valid_json(self):
        result = self.upload_fixed(message='quote " back\\slash $(x) `y` \tnl')
        self.assert_ok(result)
        self.assertNotRegex(self.state()["last_message"], r'["\\$`\t]')

    # ── Publishing and uploading ──

    def test_simultaneous_publishers_retry_without_overwriting(self):
        self.configure(conflict_once=True)
        def publish(user):
            return self.bash("publish.sh", "--repo", "test/relay", "--user", user,
                             "--source", str(self.source), "--name", "check")
        with ThreadPoolExecutor(max_workers=4) as pool:
            for result in pool.map(publish, ["rishanreddy", "Sid1332", "rishanreddy", "Sid1332"]):
                self.assert_ok(result)
        state = self.state()
        self.assertEqual(len(state["files"]), 4)
        self.assertEqual(set(state["attempts"].values()), {2})
        self.assertEqual(sum("/sid1332/" in path for path in state["files"]), 2)
        self.assertTrue(all(base64.b64decode(data) == self.source.read_bytes() for data in state["files"].values()))

    def test_simultaneous_outputs_include_failure_and_strip_tokens(self):
        self.source.write_text('#!/usr/bin/env bash\necho "stdout: ${GITHUB_TOKEN-unset}/${GH_TOKEN-unset}"\necho stderr >&2\nexit 7\n')
        def run(_):
            return self.runner("--file", str(self.source), "--user", "rishanreddy", "--upload-output")
        with ThreadPoolExecutor(max_workers=2) as pool:
            for result in pool.map(run, range(2)):
                self.assert_ok(result, 7)
                self.assertIn("stdout: unset/unset", result.stdout)
        outputs = self.state()["files"]
        self.assertEqual(len(outputs), 2)
        for path, content in outputs.items():
            self.assertIn("|outputs/rishanreddy/", path)
            text = base64.b64decode(content).decode()
            self.assertIn("stdout: unset/unset", text)
            self.assertIn("stderr\n", text)
            self.assertIn("exit code: 7", text)
        self.assertTrue(self.source.exists())

    def test_idempotent_retries_and_collision_refusal(self):
        self.assert_ok(self.upload_fixed())
        self.assert_ok(self.upload_fixed())
        original = dict(self.state()["files"])
        self.source.write_text("different bytes\n")
        result = self.upload_fixed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to overwrite", result.stderr)
        self.assertEqual(self.state()["files"], original)

    def test_lost_success_response_is_reconciled(self):
        self.configure(lost_response=True)
        self.assert_ok(self.upload_fixed())
        self.assertEqual(list(self.state()["attempts"].values()), [1])

    def test_retries_are_bounded_and_keep_local_file(self):
        self.configure(put_status=409)
        result = self.upload_fixed()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.state()["attempts"].values()), [5])
        self.assertTrue(self.source.exists())

    def test_permanent_errors_are_not_retried(self):
        for status in (403, 422):
            with self.subTest(status=status):
                self.configure(put_status=status, attempts={})
                self.assertNotEqual(self.upload_fixed().returncode, 0)
                self.assertEqual(list(self.state()["attempts"].values()), [1])

    def test_upload_failures_explain_the_token_problem(self):
        for status, hint in ((401, "rejected --token"), (403, "public_repo"), (404, "Contents: Read and write")):
            with self.subTest(status=status):
                self.configure(put_status=status, attempts={})
                result = self.upload_fixed()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(hint, result.stderr)

    def test_large_clipboard_keeps_exact_text_and_newlines(self):
        text = "quotes ''' \" \\ $(ignored) café\n" * 10000 + "\n\n"
        self.configure(conflict_once=True)
        result = self.bash("clipboard_upload.sh", "--repo", "test/relay", "--token", "fake-test-token",
                           "-l", "auth-log", "-u", "Sid1332", input=text)
        self.assert_ok(result)
        files = self.state()["files"]
        self.assertEqual(len(files), 1)
        self.assertIn("/sid1332/", next(iter(files)))
        self.assertEqual(base64.b64decode(next(iter(files.values()))).decode(), text)

    def test_clipboard_requires_token_user_and_label(self):
        base = ["--repo", "test/relay"]
        for extra, message in ((["-u", "sid1332", "-l", "x", "-t", "hi"], "needs --token"),
                               (["--token", "t", "-l", "x", "-t", "hi"], "--user"),
                               (["--token", "t", "-u", "sid1332", "-t", "hi"], "--label")):
            with self.subTest(message=message):
                result = self.bash("clipboard_upload.sh", *base, *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        self.assertEqual(self.state()["files"], {})

    # ── Running scripts ──

    def test_latest_script_isolated_by_user_and_loop_state_by_branch(self):
        script = b"#!/usr/bin/env bash\necho selected-user\n"
        self.seed("scripts/rishanreddy/20261110_000001_old.sh", b"echo old\n")
        self.seed("scripts/rishanreddy/20261110_000002_latest.sh", script)
        self.seed("scripts/sid1332/20261110_999999_other.sh", b"echo wrong-user\n")
        self.seed("scripts/rishanreddy/20261110_000002_latest.sh", script, branch="topic/race")
        for branch in ("main", "topic/race"):
            result = self.runner("--user", "rishanreddy", "--branch", branch, "--loop", "--upload-output")
            self.assert_ok(result, 99)
            self.assertEqual(result.stdout.count("selected-user"), 1)
            self.assertIn("No new scripts", result.stdout)
            self.assertNotIn("wrong-user", result.stdout)
            self.configure(polls=0)
        self.assertEqual(len(list((self.work / "state").glob("*"))), 2)

    def test_pending_output_retries_without_rerunning_script(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo executed-once\n")
        self.configure(fail_first_n=5)
        result = self.runner("--user", "rishanreddy", "--loop", "--upload-output")
        self.assert_ok(result, 99)
        self.assertEqual(result.stdout.count("executed-once"), 1)
        self.assertEqual(len([key for key in self.state()["files"] if "|outputs/" in key]), 1)
        self.assertEqual(list(self.state()["attempts"].values()), [6])
        self.assertEqual(list((self.work / "state").glob("*.pending")), [])

    def test_modified_script_same_name_runs_with_new_blob(self):
        path = "scripts/rishanreddy/20261110_check.sh"
        self.seed(path, b"echo version-one\n")
        self.assert_ok(self.runner("--user", "rishanreddy"))
        self.seed(path, b"echo version-two\n")
        result = self.runner("--user", "rishanreddy", "--loop")
        self.assert_ok(result, 99)
        self.assertEqual(result.stdout.count("version-two"), 1)

    def test_script_changed_during_download_is_not_executed(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo should-not-run\n")
        self.configure(changed_download=True)
        result = self.runner("--user", "rishanreddy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during download", result.stderr)
        self.assertNotIn("Running", result.stdout)

    def test_empty_missing_and_malformed_listings_are_distinct(self):
        self.configure(empty_directories=["scripts/rishanreddy"])
        self.assert_ok(self.runner("--list", "--user", "rishanreddy"))
        missing = self.runner("--list", "--user", "newcomer")
        self.assert_ok(missing)
        self.assertIn("No scripts found for newcomer", missing.stdout)
        self.configure(bad_listing=True)
        self.assertNotEqual(self.runner("--list", "--user", "rishanreddy").returncode, 0)

    def test_loop_waits_quietly_before_the_first_script_exists(self):
        result = self.runner("--user", "newcomer", "--loop")
        self.assert_ok(result, 99)
        self.assertIn("No scripts found for newcomer yet", result.stdout)
        self.assertNotIn("failed", result.stderr)

    def test_invalid_flags_are_rejected_without_publishing(self):
        for content in ("#!/bin/bash\nif\n", "#!/bin/bash\r\necho CRLF\r\n"):
            self.source.write_bytes(content.encode())
            result = self.bash("publish.sh", "--user", "sid1332", "--source", str(self.source), "--name", "check")
            self.assertNotEqual(result.returncode, 0)
        source = str(self.source)
        cases = [(["--user"], True, "Missing value"),
                 (["--user", "sid1332", "--upload-output"], False, "needs --token"),
                 (["--file", source, "--upload-output"], True, "needs --user"),
                 (["--file", source, "--user", "sid1332"], True, "--upload-output"),
                 (["--user", "sid1332", "--interval", "30"], True, "only applies with --loop"),
                 (["--user", "sid1332", "--loop", "--interval", "2"], True, "5 to 86400"),
                 (["--user", "sid1332", "--token", "bad token!"], False, "unexpected characters"),
                 (["--bogus"], True, "Unknown argument"),
                 ([], True, "Specify --user")]
        for flags, token, message in cases:
            with self.subTest(flags=flags):
                result = self.runner(*flags, token=token)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        self.assertEqual(self.state()["files"], {})

    def test_settings_come_only_from_flags(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo flag-run\n")
        result = self.bash("runner.sh", "--repo", "test/relay", "--branch", "main", "--token", " flag-token \n",
                           "--state-dir", str(self.work / "state"), "--user", "rishanreddy")
        self.assert_ok(result)
        self.assertIn("flag-run", result.stdout)
        requests = self.state()["requests"]
        self.assertTrue(requests)
        self.assertEqual({request["repo"] for request in requests}, {"test/relay"})
        self.assertEqual({request["auth"] for request in requests}, {"Authorization: Bearer flag-token"})
        self.assertEqual(list((self.work / "env-state").glob("*")), [])

    def test_runs_without_a_token_use_no_credentials(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo public-run\n")
        result = self.runner("--user", "rishanreddy", token=False)
        self.assert_ok(result)
        self.assertIn("public-run", result.stdout)
        self.assertEqual({request["auth"] for request in self.state()["requests"]}, {None})

    def test_loop_interval_depends_on_token_and_can_be_set(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo hi\n")
        for flags, token, expected in ((["--loop"], False, 120), (["--loop"], True, 30),
                                       (["--loop", "--interval", "45"], True, 45),
                                       (["--loop", "--interval", "200"], False, 200)):
            with self.subTest(flags=flags, token=token):
                self.configure(polls=0, sleeps=[])
                shutil.rmtree(self.work / "state", ignore_errors=True)
                result = self.runner("--user", "rishanreddy", *flags, token=token)
                self.assert_ok(result, 99)
                self.assertEqual(self.state()["sleeps"], [expected, expected])
                if not token:
                    self.assertIn("60 requests per hour", result.stdout)
        short = self.runner("--user", "rishanreddy", "--loop", "--interval", "30", token=False)
        self.assertIn("probably hit that limit", short.stderr)

    def test_rate_limit_pauses_until_reset_then_recovers(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo after-limit\n")
        self.configure(rate_limited_requests=1)
        result = self.runner("--user", "rishanreddy", "--loop", token=False)
        self.assert_ok(result, 99)
        self.assertIn("rate limit is used up", result.stderr)
        self.assertIn("60 requests per hour", result.stderr)
        self.assertEqual(result.stdout.count("after-limit"), 1)
        first, second = self.state()["sleeps"]
        self.assertTrue(595 <= first <= 605, first)
        self.assertEqual(second, 120)

    def test_check_reports_repo_branch_and_token_problems(self):
        ok_result = self.runner("--check")
        self.assert_ok(ok_result)
        self.assertIn("can push", ok_result.stdout)
        self.assertIn("57 of 5000", ok_result.stdout)
        self.configure(scopes="public_repo")
        self.assertIn("public_repo", self.runner("--check").stdout)
        anonymous = self.runner("--check", token=False)
        self.assert_ok(anonymous)
        self.assertIn("No --token", anonymous.stdout)
        self.configure(scopes="read:org")
        bad_scope = self.runner("--check")
        self.assertNotEqual(bad_scope.returncode, 0)
        self.assertIn("do not include public_repo", bad_scope.stderr)
        self.configure(scopes=None, push_access=False)
        self.assertIn("cannot push", self.runner("--check").stderr)
        self.configure(push_access=True)
        self.assertIn("Branch nope was not found", self.runner("--check", "--branch", "nope").stderr)
        self.configure(missing_repo=True)
        self.assertIn("was not found", self.runner("--check").stderr)

    def test_check_reports_when_the_token_expires(self):
        self.configure(expires="2026-11-11 22:00:00 UTC")
        for fakes, name in (("curl", "curl-bin"), ("wget", "wget-bin")):
            with self.subTest(tool=fakes):
                env = dict(self.env, PATH=str(self.make_bin(name, (fakes, "gh", "sleep"))))
                result = self.runner("--check", env=env)
                self.assert_ok(result)
                self.assertIn("expires: 2026-11-11 22:00:00 UTC", result.stdout)
        self.configure(expires=None)
        undated = self.runner("--check")
        self.assertIn("no expiration date", undated.stdout)
        self.assertNotIn("expires:", self.runner("--check", token=False).stdout)

    # ── Developer-side tools ──

    def seed_output(self, name, script, body="hello\n", kind="outputs", user="sid1332"):
        header = f"script:    {script}\ntimestamp: 2026-11-10T00:00:00Z\nhost:      vm\nuser:      u\n---\n"
        self.seed(f"{kind}/{user}/{name}", (header + body).encode() if kind == "outputs" else body.encode())

    def results(self, *args, **kwargs):
        env = dict(self.env, CPATS_TEST_POLLS="1000")
        return self.bash("results.sh", "--repo", "test/relay", *args, env=env, **kwargs)

    def test_results_prints_the_newest_output_and_lists_files(self):
        self.seed_output("20261110_000001_a.txt", "one.sh", "first run\n")
        self.seed_output("20261110_000002_b.txt", "two.sh", "second run\n")
        newest = self.results("--user", "Sid1332")
        self.assert_ok(newest)
        self.assertIn("==> outputs/sid1332/20261110_000002_b.txt", newest.stdout)
        self.assertIn("second run", newest.stdout)
        self.assertNotIn("first run", newest.stdout)
        listing = self.results("--user", "sid1332", "--list")
        self.assertEqual(listing.stdout.split(), ["20261110_000001_a.txt", "20261110_000002_b.txt"])

    def test_results_finds_the_output_for_one_published_script(self):
        self.seed_output("20261110_000001_a.txt", "wanted.sh", "wanted output\n")
        self.seed_output("20261110_000002_b.txt", "other.sh", "newer but different script\n")
        result = self.results("--user", "sid1332", "--script", "scripts/sid1332/wanted.sh")
        self.assert_ok(result)
        self.assertIn("wanted output", result.stdout)
        self.assertNotIn("different script", result.stdout)

    def test_results_exit_codes_distinguish_nothing_yet_from_a_timeout(self):
        nothing = self.results("--user", "sid1332")
        self.assertEqual(nothing.returncode, 4, nothing.stderr)
        self.assertIn("No outputs found", nothing.stderr)
        timed_out = self.results("--user", "sid1332", "--script", "missing.sh", "--wait", "20")
        self.assertEqual(timed_out.returncode, 3, timed_out.stderr)
        self.assertIn("runner may not be running", timed_out.stderr)

    def test_results_waits_for_a_file_to_arrive(self):
        self.seed_output("20261110_000001_old.txt", "old.sh", "old\n")
        arrival = {"n": 2, "key": "test/relay|main|outputs/sid1332/20261110_000009_new.txt",
                   "data": base64.b64encode(b"script:    new.sh\n---\narrived\n").decode()}
        self.configure(arrives_after_sleeps=arrival)
        waited = self.results("--user", "sid1332", "--wait", "60")
        self.assert_ok(waited)
        self.assertIn("arrived", waited.stdout)
        self.assertNotIn("old\n", waited.stdout.replace("==> ", ""))
        self.configure(arrives_after_sleeps=None, sleeps=[], polls=0)
        arrival["n"] = 1
        arrival["key"] = "test/relay|main|outputs/sid1332/20261110_000010_script.txt"
        arrival["data"] = base64.b64encode(b"script:    target.sh\n---\ntarget arrived\n").decode()
        self.configure(arrives_after_sleeps=arrival)
        targeted = self.results("--user", "sid1332", "--script", "target.sh", "--wait", "60")
        self.assert_ok(targeted)
        self.assertIn("target arrived", targeted.stdout)

    def test_results_reads_clipboard_pastes_and_validates_flags(self):
        self.seed_output("20261110_000001_note.txt", "", "pasted from the VM\n", kind="clipboard")
        paste = self.results("--user", "sid1332", "--kind", "clipboard")
        self.assert_ok(paste)
        self.assertIn("pasted from the VM", paste.stdout)
        for flags, message in ((["--user", "sid1332", "--kind", "scripts"], "outputs or clipboard"),
                               (["--user", "sid1332", "--script", "x.sh", "--kind", "clipboard"], "only applies to --kind outputs"),
                               (["--user", "sid1332", "--script", "x.py"], ".sh file name"),
                               (["--user", "sid1332", "--wait", "99999"], "0 to 3600"),
                               ([], "Missing --user")):
            with self.subTest(flags=flags):
                result = self.results(*flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_publishers_print_the_matching_results_command(self):
        published = self.bash("publish.sh", "--repo", "test/relay", "--user", "Sid1332", "--source", str(self.source), "--name", "check")
        self.assert_ok(published)
        name = re.search(r"/(\d{8}_\d{6}_\d{6}_check_[0-9a-f]{32}\.sh)", published.stdout).group(1)
        self.assertIn(f"Next: bash results.sh --user sid1332 --script {name} --wait 180", published.stdout)

    def test_recon_script_is_read_only_and_valid(self):
        recon = ROOT / "keep" / "recon.sh"
        text = recon.read_text()
        self.assertTrue(text.startswith("#!/usr/bin/env bash\n"))
        self.assertNotIn("\r", text)
        self.assertEqual(subprocess.run(["bash", "-n", str(recon)]).returncode, 0)
        # Drop comments and quoted strings, then look for anything that could change the VM.
        code = "\n".join(line.split(" #")[0] for line in text.splitlines() if not line.lstrip().startswith("#"))
        code = re.sub(r"'[^']*'|\"[^\"]*\"", "''", code)
        code = re.sub(r"\bhave\s+\S+", "have", code)  # "have tool" only checks that a tool exists
        forbidden = {
            "a file write": r"(?<![0-9&-])>>?(?!\s*(/dev/null|&))",
            "a file or account command": r"\b(rm|mv|cp|ln|touch|mkdir|chmod|chown|chgrp|tee|dd|kill|pkill|killall|shutdown|reboot|halt|"
                                         r"useradd|userdel|usermod|groupadd|groupdel|gpasswd|chpasswd|newusers|visudo|crontab\s+-[er])\b",
            "passwd that is not -S": r"(?<![\w/.-])passwd\b(?!\s+-S)",
            "apt that is not a simulation": r"(?<![\w/.-])apt(-get)?\b(?!\s+-s\b)",
            "dpkg that is not dpkg-query": r"(?<![\w/.-])dpkg\b(?!-query)(?![.])",
            "systemctl that is not a list": r"(?<![\w/.-])systemctl\s+(?!list-)",
            "ufw that is not status": r"(?<![\w/.-])ufw\s+(?!status)",
            "snap that is not list": r"(?<![\w/.-])snap\s+(?!list)",
            "sysctl that is not a read": r"(?<![\w/.-])sysctl\s+(?!-n)",
            "find that deletes or executes": r"-(delete|exec|execdir|ok)\b",
            "an in-place edit": r"\bsed\s+-i",
            "a download": r"\b(curl|wget)\b",
            "a read of a secret file": r"\b(cat|head|tail|grep|sed|awk|less|more|strings|base64)\b[^\n|;]*(/etc/shadow|/etc/gshadow|id_rsa|id_ed25519|\.ssh/)",
        }
        for what, pattern in forbidden.items():
            self.assertIsNone(re.search(pattern, code), f"recon.sh contains {what}")

    def test_collaborator_management_uses_the_gh_login(self):
        self.assertIn("Invitation sent", self.bash("collab.sh", "add", "sid1332", "--repo", "test/relay").stdout)
        self.assertEqual(self.state()["collaborators"]["sid1332"], "push")
        self.assertIn("already has access", self.bash("collab.sh", "add", "sid1332", "--repo", "test/relay").stdout)
        self.assertIn("sid1332", self.bash("collab.sh", "list", "--repo", "test/relay").stdout)
        self.assertIn("Removed sid1332", self.bash("collab.sh", "remove", "sid1332", "--repo", "test/relay").stdout)
        self.assertNotEqual(self.bash("collab.sh", "remove", "sid1332", "--repo", "test/relay").returncode, 0)
        self.assertNotEqual(self.bash("collab.sh", "add", "bad user", "--repo", "test/relay").returncode, 0)
        self.configure(gh_signed_out=True)
        self.assertIn("gh auth login", self.bash("collab.sh", "list", "--repo", "test/relay").stderr)

    def test_reset_clears_only_competition_data(self):
        for path in ("scripts/.gitkeep", "scripts/rishanreddy/a.sh", "outputs/sid1332/o.txt", "clipboard/sid1332/c.txt",
                     "keep/notes.md", "runner.sh"):
            self.seed(path, b"data\n")
        env = dict(self.env, CPATS_TEST_POLLS="1000")
        before = dict(self.state()["files"])
        dry = self.bash("reset_competition.sh", "--dry-run", "--repo", "test/relay", env=env)
        self.assert_ok(dry)
        self.assertIn("would delete: scripts/rishanreddy/a.sh", dry.stderr)
        self.assertEqual(self.state()["files"], before)
        cancelled = self.bash("reset_competition.sh", "--repo", "test/relay", input="nope\n", env=env)
        self.assert_ok(cancelled)
        self.assertEqual(self.state()["files"], before)
        done = self.bash("reset_competition.sh", "--repo", "test/relay", input="RESET\n", env=env)
        self.assert_ok(done)
        self.assertEqual(sorted(key.split("|", 2)[2] for key in self.state()["files"]),
                         ["keep/notes.md", "runner.sh", "scripts/.gitkeep"])
        self.assertIn("Nothing to delete", self.bash("reset_competition.sh", "--yes", "--repo", "test/relay", env=env).stdout)

    def test_reset_warns_when_github_truncates_the_file_list(self):
        self.seed("scripts/rishanreddy/a.sh", b"data\n")
        self.configure(truncated=True)
        result = self.bash("reset_competition.sh", "--dry-run", "--repo", "test/relay")
        self.assert_ok(result)
        self.assertIn("truncated", result.stderr)
        self.assertIn("would delete: scripts/rishanreddy/a.sh", result.stderr)

    def test_every_tool_documents_its_flags(self):
        for script, flag in (("runner.sh", "--token"), ("clipboard_upload.sh", "--user"), ("publish.sh", "--source"),
                             ("collab.sh", "--permission"), ("reset_competition.sh", "--dry-run")):
            with self.subTest(script=script):
                result = self.bash(script, "--help")
                self.assert_ok(result)
                self.assertIn(flag, result.stdout)

    # ── The instructions an agent reads ──

    DOCS = ("README.md", "AGENTS.md", "CLAUDE.md", ".agents/skills/cpats-pastebin/SKILL.md",
            ".agents/skills/cpats-pastebin/references/cyberpatriot-playbook.md", "keep/README.md")

    def test_every_flag_in_the_docs_exists_in_a_tool(self):
        known = set()
        for script in ("runner.sh", "clipboard_upload.sh", "publish.sh", "collab.sh", "reset_competition.sh", "results.sh"):
            known |= set(re.findall(r"(?<![\w-])--[a-z][a-z-]*", self.bash(script, "--help").stdout))
        # Flags of other programs that the docs show in example commands: gh, git, and systemctl.
        known |= {"--jq", "--public", "--push", "--help", "--now"}
        for name in self.DOCS:
            text = (ROOT / name).read_text()
            for flag in sorted(set(re.findall(r"(?<![\w-])--[a-z][a-z-]*", text)) - known):
                self.fail(f"{name} mentions {flag}, which no tool documents. Fix the doc or the tool.")

    def test_doc_links_and_referenced_files_exist(self):
        for name in self.DOCS:
            base = (ROOT / name).parent
            text = (ROOT / name).read_text()
            for target in re.findall(r"\]\((?!https?:|#)([^)#\s]+)", text):
                self.assertTrue((base / target).exists(), f"{name} links to missing {target}")
            for path in re.findall(r"`((?:keep|\.agents|tests)/[\w./-]+\.(?:sh|md|py))`", text):
                self.assertTrue((ROOT / path).exists(), f"{name} mentions missing {path}")

    def test_agent_instructions_carry_the_context_and_the_proactive_rules(self):
        agents = (ROOT / "AGENTS.md").read_text()
        claude = (ROOT / "CLAUDE.md").read_text()
        self.assertEqual(claude.splitlines()[0], "@AGENTS.md", "CLAUDE.md must import AGENTS.md")
        for phrase in ("CyberPatriot", "practice round", "scoring engine", "README", "PUBLIC", "keep/recon.sh",
                       "results.sh", "Never ask the user whether a script finished", "read-only", "one day",
                       "They never run on the VM"):
            self.assertIn(phrase, agents, f"AGENTS.md lost: {phrase!r}")
        for rule in ("Never create an env file", "settings are flags", "Read-only means", "Ask every time"):
            self.assertIn(rule.lower(), agents.lower(), f"AGENTS.md lost: {rule!r}")
        skill = (ROOT / ".agents/skills/cpats-pastebin/SKILL.md").read_text()
        self.assertTrue(skill.startswith("---\nname: cpats-pastebin\ndescription: "))
        for phrase in ("proactive", "keep/recon.sh", "expires in one day", "never run on the VM"):  # skill wording
            self.assertIn(phrase, skill, f"SKILL.md lost: {phrase!r}")
        readme = (ROOT / "README.md").read_text()
        for phrase in ("expire in one day", "never the VM", "AGENTS.md", "results.sh"):
            self.assertIn(phrase, readme, f"README.md lost: {phrase!r}")
        for name in ("AGENTS.md", ".agents/skills/cpats-pastebin/SKILL.md"):
            text = (ROOT / name).read_text()
            self.assertNotIn(".cpats.env", text, f"{name} must not tell anyone to use an env file")

    @unittest.skipUnless(os.environ.get("CPATS_TEST_PWSH"), "Set CPATS_TEST_PWSH to test PowerShell")
    def test_powershell_publish_retries_and_checks_syntax(self):
        self.configure(conflict_once=True)
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", CPATS_TEST_API=str(self.api))
        command = [os.environ["CPATS_TEST_PWSH"], "-NoProfile", "-File", str(self.work / "publish.ps1"),
                   "-Repo", "test/relay", "-User", "Sid1332", "-Source", str(self.source), "-Name", "check"]
        self.assert_ok(self.command(*command, env=env))
        self.assertEqual(list(self.state()["attempts"].values()), [2])
        self.source.write_text("#!/bin/bash\nif\n")
        self.assertNotEqual(self.command(*command, env=env).returncode, 0)
        self.assertEqual(len(self.state()["files"]), 1)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    unittest.main(verbosity=2)
