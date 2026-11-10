#!/usr/bin/env python3
"""Offline integration tests. Run with uv run tests/test_workflow.py."""
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def fake_tool(tool):
    """Implement curl/gh against one locked file, without making any network calls."""
    args = sys.argv[1:]
    state_path = Path(os.environ["CPATS_TEST_API"])
    with state_path.open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        state = json.load(handle)
        if tool == "sleep":
            code = 0
            if args == ["30"]:
                state["polls"] = state.get("polls", 0) + 1
                if state["polls"] >= int(os.environ.get("CPATS_TEST_POLLS", "2")):
                    code = 99
            handle.seek(0)
            json.dump(state, handle)
            handle.truncate()
            return code
        if tool == "gh" and args[:2] == ["auth", "status"]:
            return 0
        if tool == "gh" and args[:2] == ["auth", "token"]:
            print("fake-bundle-credential")
            return 0
        if tool == "gh" and "user" in args:
            print(json.dumps({"login": state.get("login", "Sid1332")}))
            return 0
        if tool == "gh" and "repos/test/relay" in args:
            print(json.dumps({"permissions": {"push": state.get("push_access", True)}}))
            return 0
        method, url, payload, headers, dest, jq = "GET", "", None, [], None, None
        index = 0
        while index < len(args):
            arg = args[index]
            if arg in ("-X", "--method", "-H", "--input", "--data-binary", "-o", "--jq", "-w", "--connect-timeout", "--max-time"):
                value = args[index + 1]
                if arg in ("-X", "--method"):
                    method = value
                elif arg == "-H":
                    headers.append(value)
                elif arg in ("--input", "--data-binary"):
                    payload = json.loads(Path(value.removeprefix("@")).read_text())
                elif arg == "-o":
                    dest = Path(value)
                elif arg == "--jq":
                    jq = value
                index += 2
                continue
            if arg.startswith(("repos/", "https://")):
                url = arg
            index += 1
        parts = urlsplit(url)
        match = re.search(r"repos/([^/]+/[^/]+)/contents/(.*)", parts.path)
        if not match:
            raise RuntimeError(f"Unexpected test request: {url}")
        repo, path = match.group(1), unquote(match.group(2))
        branch = payload["branch"] if payload else parse_qs(parts.query).get("ref", ["main"])[0]
        key = f"{repo}|{branch}|{path}"
        files = state.setdefault("files", {})
        requests = state.setdefault("requests", [])
        requests.append({"method": method, "repo": repo, "branch": branch, "path": path, "payload": payload})
        status, body, lost = 200, {}, False
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
                status, body = forced, {"message": "simulated API conflict or rejection"}
            elif key in files:
                status, body = 422, {"message": 'Invalid request: "sha" was not supplied'}
            else:
                assert "sha" not in payload, "New uploads must not replace existing content"
                files[key] = payload["content"]
                status, body = 201, {"content": {"path": path, "sha": blob_sha(base64.b64decode(files[key]))}}
                lost = state.get("lost_response", False)
        elif key in files:
            data = base64.b64decode(files[key])
            if any("raw+json" in header for header in headers):
                body = b"echo changed-after-listing\n" if state.get("changed_download") else data
            else:
                body = {"path": path, "sha": blob_sha(data), "type": "file", "content": files[key]}
        else:
            prefix = f"{repo}|{branch}|{path}/"
            body = []
            for stored_key, content in files.items():
                if not stored_key.startswith(prefix):
                    continue
                name = stored_key[len(prefix):]
                if "/" not in name:
                    body.append({"name": name, "path": f"{path}/{name}", "sha": blob_sha(base64.b64decode(content)), "type": "file"})
            if state.get("bad_listing"):
                body = {"message": "not a directory"}
            elif not body and path not in state.get("empty_directories", []):
                status, body = 404, {"message": "Not Found"}
        handle.seek(0)
        json.dump(state, handle)
        handle.truncate()
    data = body if isinstance(body, bytes) else json.dumps(body).encode()
    if tool == "curl":
        if lost:
            return 28
        if dest:
            dest.write_bytes(data)
        sys.stdout.write(str(status))
        return 0
    if lost:
        return 1
    if "--include" in args:
        sys.stdout.buffer.write(f"HTTP/2.0 {status} Test\r\nContent-Type: application/json\r\n\r\n".encode() + data)
    elif jq == ".sha" and status == 200:
        print(body["sha"])
    else:
        sys.stdout.buffer.write(data)
    return 0 if status < 400 else 1


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cpats test 'quotes' ")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        for command in ("curl", "gh", "sleep"):
            (self.bin / command).symlink_to(Path(__file__).resolve())
        for file in ("runner.sh", "publish.sh", "publish.ps1", "clipboard_upload.sh", "prepare_vm.py"):
            shutil.copy2(ROOT / file, self.work / file)
        self.api = self.work / "api.json"
        self.api.write_text(json.dumps({"files": {}, "requests": []}))
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        GITHUB_REPO="test/relay", GITHUB_TOKEN="fake-test-token", GH_TOKEN="fake-cli-token",
                        CPATS_USERNAME="rishanreddy", BRANCH="main", CPATS_TEST_API=str(self.api),
                        CPATS_STATE_DIR=str(self.work / "state"), TMPDIR=str(self.work))
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

    def assert_ok(self, result, code=0):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)

    def upload_fixed(self, path="clipboard/rishanreddy/fixed.txt"):
        return self.command("bash", "-c", 'source ./runner.sh; GH_BACKEND=curl; gh_upload "$1" "$2" test',
                            "--", path, str(self.source))

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
            return self.bash("runner.sh", "--file", str(self.source), "--upload-output")
        with ThreadPoolExecutor(max_workers=2) as pool:
            for result in pool.map(run, range(2)):
                self.assert_ok(result, 7)
                self.assertIn("stdout: unset/unset", result.stdout)
        outputs = self.state()["files"]
        self.assertEqual(len(outputs), 2)
        for content in outputs.values():
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

    def test_large_clipboard_keeps_exact_text_and_newlines(self):
        text = "quotes ''' \" \\ $(ignored) café\n" * 10000 + "\n\n"
        self.configure(conflict_once=True)
        result = self.bash("clipboard_upload.sh", "-l", "auth-log", "-u", "Sid1332", input=text)
        self.assert_ok(result)
        files = self.state()["files"]
        self.assertEqual(len(files), 1)
        self.assertIn("/sid1332/", next(iter(files)))
        self.assertEqual(base64.b64decode(next(iter(files.values()))).decode(), text)

    def test_latest_script_isolated_by_user_and_loop_state_by_branch(self):
        script = b"#!/usr/bin/env bash\necho selected-user\n"
        self.seed("scripts/rishanreddy/20261110_000001_old.sh", b"echo old\n")
        self.seed("scripts/rishanreddy/20261110_000002_latest.sh", script)
        self.seed("scripts/sid1332/20261110_999999_other.sh", b"echo wrong-user\n")
        self.seed("scripts/rishanreddy/20261110_000002_latest.sh", script, branch="topic/race")
        for branch in ("main", "topic/race"):
            result = self.bash("runner.sh", "--user", "rishanreddy", "--branch", branch, "--loop", "--upload-output")
            self.assert_ok(result, 99)
            self.assertEqual(result.stdout.count("selected-user"), 1)
            self.assertIn("No new scripts", result.stdout)
            self.assertNotIn("wrong-user", result.stdout)
            self.configure(polls=0)
        self.assertEqual(len(list((self.work / "state").glob("*"))), 2)

    def test_pending_output_retries_without_rerunning_script(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo executed-once\n")
        self.configure(fail_first_n=5)
        result = self.bash("runner.sh", "--user", "rishanreddy", "--loop", "--upload-output")
        self.assert_ok(result, 99)
        self.assertEqual(result.stdout.count("executed-once"), 1)
        self.assertEqual(len([key for key in self.state()["files"] if "|outputs/" in key]), 1)
        self.assertEqual(list(self.state()["attempts"].values()), [6])
        self.assertEqual(list((self.work / "state").glob("*.pending")), [])

    def test_modified_script_same_name_runs_with_new_blob(self):
        path = "scripts/rishanreddy/20261110_check.sh"
        self.seed(path, b"echo version-one\n")
        self.assert_ok(self.bash("runner.sh", "--user", "rishanreddy"))
        self.seed(path, b"echo version-two\n")
        result = self.bash("runner.sh", "--user", "rishanreddy", "--loop")
        self.assert_ok(result, 99)
        self.assertEqual(result.stdout.count("version-two"), 1)

    def test_script_changed_during_download_is_not_executed(self):
        self.seed("scripts/rishanreddy/20261110_check.sh", b"echo should-not-run\n")
        self.configure(changed_download=True)
        result = self.bash("runner.sh", "--user", "rishanreddy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during download", result.stderr)
        self.assertNotIn("Running", result.stdout)

    def test_empty_list_and_malformed_json_are_distinct(self):
        self.configure(empty_directories=["scripts/rishanreddy"])
        self.assert_ok(self.bash("runner.sh", "--user", "rishanreddy", "--list"))
        self.configure(bad_listing=True)
        self.assertNotEqual(self.bash("runner.sh", "--user", "rishanreddy", "--list").returncode, 0)

    def test_source_with_quotes_and_invalid_options_do_not_publish(self):
        for content in ("#!/bin/bash\nif\n", "#!/bin/bash\r\necho CRLF\r\n"):
            self.source.write_bytes(content.encode())
            result = self.bash("publish.sh", "--user", "sid1332", "--source", str(self.source), "--name", "check")
            self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.bash("runner.sh", "--user").returncode, 0)
        self.assertEqual(self.state()["files"], {})

    def test_collaborator_can_prepare_vm_with_own_login(self):
        self.seed("runner.sh", b"# remote runner\n")
        output = self.work / "private vm folder"
        result = self.command(sys.executable, str(self.work / "prepare_vm.py"), "--repo", "test/relay",
                              "--user", "sid1332", "--output", str(output))
        self.assert_ok(result)
        self.assertNotIn("fake-bundle-credential", result.stdout + result.stderr)
        self.assertIn("fake-bundle-credential", (output / ".cpats.env").read_text())
        self.assertIn("CPATS_USERNAME=sid1332", (output / ".cpats.env").read_text())
        self.assertEqual((output / ".cpats.env").stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((output / "runner.sh").read_bytes(), (self.work / "runner.sh").read_bytes())

    def test_vm_setup_refuses_owner_credentials_for_teammate(self):
        self.configure(login="rishanreddy")
        output = self.work / "refused"
        result = self.command(sys.executable, str(self.work / "prepare_vm.py"), "--repo", "test/relay",
                              "--user", "sid1332", "--output", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not sid1332", result.stderr)
        self.assertFalse(output.exists())

    def test_vm_setup_requires_write_access(self):
        self.configure(push_access=False)
        output = self.work / "refused"
        result = self.command(sys.executable, str(self.work / "prepare_vm.py"), "--repo", "test/relay",
                              "--user", "sid1332", "--output", str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("write access", result.stderr)
        self.assertFalse(output.exists())

    @unittest.skipUnless(os.environ.get("CPATS_TEST_PWSH"), "Set CPATS_TEST_PWSH to test PowerShell")
    def test_powershell_publish_retries_and_checks_syntax(self):
        self.configure(conflict_once=True)
        command = [os.environ["CPATS_TEST_PWSH"], "-NoProfile", "-File", str(self.work / "publish.ps1"),
                   "-Repo", "test/relay", "-User", "Sid1332", "-Source", str(self.source), "-Name", "check"]
        self.assert_ok(self.command(*command))
        self.assertEqual(list(self.state()["attempts"].values()), [2])
        self.source.write_text("#!/bin/bash\nif\n")
        self.assertNotEqual(self.command(*command).returncode, 0)
        self.assertEqual(len(self.state()["files"]), 1)


if __name__ == "__main__":
    command_name = Path(sys.argv[0]).name
    if command_name in ("curl", "gh", "sleep"):
        sys.exit(fake_tool(command_name))
    unittest.main(verbosity=2)
