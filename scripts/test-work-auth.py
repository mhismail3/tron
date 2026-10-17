#!/usr/bin/env python3
"""Agent GitHub access through the real CLI, a real isolated Keychain file and a process-level gh (#1168).

The fixture `gh` is found on PATH exactly as the real one is (no WORK_GH), and answers by the
GH_TOKEN it receives. It proves that every work command reads the agents' token from Keychain,
checks it before any GitHub request, fails early with the one setup command, and never depends
on the token an inherited environment or an interactive `gh auth` login carries.
Evidence: test-results/work-auth.json.
"""
from __future__ import annotations

import json
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "tools/work/cli.py"
SETUP = "scripts/tron work auth setup"


def fixture_gh() -> None:
    token = os.environ.get("GH_TOKEN", "")
    args = sys.argv[2:]
    with open(os.environ["AUTH_FIXTURE_LOG"], "a") as log:
        log.write(json.dumps({"args": args, "token": token}) + "\n")
    if args == ["api", "--include", "/user"]:
        if token == "ghp_revoked":
            print("HTTP/2.0 401 Unauthorized\r\nContent-Type: application/json\r\n\r\n{\"message\":\"Bad credentials\"}")
            print("gh: Bad credentials (HTTP 401)", file=sys.stderr)
            sys.exit(1)
        scopes = "repo, workflow" if token == "ghp_noproject" else "admin:public_key, project, repo, workflow"
        headers = ["HTTP/2.0 200 OK", f"X-Oauth-Scopes: {scopes}"]
        if token == "ghp_expiring":
            soon = datetime.now(timezone.utc) + timedelta(days=5)
            headers.append(f"Github-Authentication-Token-Expiration: {soon.strftime('%Y-%m-%d %H:%M:%S')} UTC")
        print("\r\n".join(headers) + "\r\n\r\n" + json.dumps({"login": "fixture-owner"}))
        return
    if args[:2] == ["issue", "comment"]:
        sys.stdin.read()
        return
    print(f"unexpected gh call {args}", file=sys.stderr)
    sys.exit(2)


def run() -> None:
    evidence: list[dict] = []
    base = Path(tempfile.mkdtemp(prefix="work-auth-"))
    keychain = base / "agents.keychain-db"
    try:
        home, tmp, bin_dir, repo = base / "home", base / "tmp", base / "bin", base / "repo"
        for directory in (home, tmp, bin_dir, repo / ".github"):
            directory.mkdir(parents=True)
        log = base / "gh.jsonl"
        gh = bin_dir / "gh"
        gh.write_text(f"#!/bin/sh\nexec {sys.executable} -B {Path(__file__).resolve()} fixture-gh \"$@\"\n")
        gh.chmod(0o755)
        (repo / ".github/work.json").write_text(json.dumps({"verify": {"scrubCommand": "cat >/dev/null"}}))
        (repo / "comment.md").write_text("Fixture comment\n")
        env = {key: value for key, value in os.environ.items() if key not in ("WORK_GH", "GH_TOKEN", "GITHUB_TOKEN")}
        env.update({"HOME": str(home), "TMPDIR": str(tmp), "PATH": f"{bin_dir}{os.pathsep}/usr/bin:/bin",
                    "AUTH_FIXTURE_LOG": str(log), "TRON_WORK_KEYCHAIN": str(keychain), "WORK_SESSION_ID": "fixture-session",
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "PYTHONDONTWRITEBYTECODE": "1"})
        subprocess.run(["git", "init", "-q", str(repo)], check=True, env=env)
        # A real, isolated keychain file; the isolated HOME keeps the user's search list untouched.
        subprocess.run(["/usr/bin/security", "create-keychain", "-p", "unlock-secret", str(keychain)], check=True, env=env)
        subprocess.run(["/usr/bin/security", "unlock-keychain", "-p", "unlock-secret", str(keychain)], check=True, env=env)

        def calls() -> list[dict]:
            return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

        def stored() -> str | None:
            found = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "tron-work-github", "-w", str(keychain)],
                                   capture_output=True, text=True, env=env)
            return found.stdout.strip() if found.returncode == 0 else None

        def store(token: str) -> None:
            subprocess.run(["/usr/bin/security", "add-generic-password", "-U", "-s", "tron-work-github", "-a", "fixture-owner",
                            "-w", token, str(keychain)], check=True, env=env)

        def work(*args: str, extra: dict | None = None) -> subprocess.CompletedProcess:
            log.unlink(missing_ok=True)
            return subprocess.run([sys.executable, str(CLI), *args], cwd=repo, env={**env, **(extra or {})},
                                  capture_output=True, text=True, timeout=60)

        def comment(extra: dict | None = None) -> subprocess.CompletedProcess:
            return work("comment", "1", "--body-file", str(repo / "comment.md"), extra=extra)

        def setup(token: str, unlock: str | None = None) -> tuple[int, str]:
            log.unlink(missing_ok=True)
            pid, fd = pty.fork()
            if pid == 0:
                os.chdir(repo)
                os.execve(sys.executable, [sys.executable, str(CLI), "auth", "setup"], env)
            output, sent, unlocked, deadline = b"", False, 0, time.monotonic() + 60
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], 1)
                if not ready:
                    continue
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
                if not sent and b"Token (hidden):" in output:
                    os.write(fd, token.encode() + b"\n")
                    sent = True
                if unlock and output.count(b"password to unlock") > unlocked:
                    os.write(fd, unlock.encode() + b"\n")
                    unlocked += 1
            if time.monotonic() >= deadline:
                os.kill(pid, 9)
            _, status = os.waitpid(pid, 0)
            os.close(fd)
            text = output.decode(errors="replace")
            assert token not in text, "the pasted token is never echoed"
            return os.waitstatus_to_exitcode(status), text

        # 1. Never set up: refused before any GitHub request, naming the one setup command.
        result = comment()
        evidence.append({"case": "not set up", "exit": result.returncode, "stderr": result.stderr.strip(), "gh": calls()})
        assert result.returncode == 1 and "not set up" in result.stderr and SETUP in result.stderr and calls() == [], result.stderr

        # 2. Setup refuses an under-scoped token and stores nothing.
        code, text = setup("ghp_noproject")
        evidence.append({"case": "setup refuses missing scope", "exit": code, "output": text.strip()[-400:]})
        assert code == 1 and "lacks scope project" in text and stored() is None, text

        # 3. Setup stores a valid token, read back the way agents read it; status names login and scopes.
        code, text = setup("ghp_full")
        evidence.append({"case": "setup stores a valid token", "exit": code, "output": text.strip()[-400:]})
        assert code == 0 and "fixture-owner" in text and stored() == "ghp_full", text
        # 3b. A keychain locked in this shell (SSH, a detached tmux) is unlocked by `security`'s own
        # password prompt, then the token is stored; replacing a token is the same command.
        subprocess.run(["/usr/bin/security", "lock-keychain", str(keychain)], check=True, env=env)
        code, text = setup("ghp_full", unlock="unlock-secret")
        evidence.append({"case": "setup unlocks a locked keychain", "exit": code, "output": text.strip()[-400:]})
        assert code == 0 and "locked in this shell" in text and "unlock-secret" not in text and stored() == "ghp_full", text
        status = work("auth", "status")
        evidence.append({"case": "status", "exit": status.returncode, "stdout": status.stdout.strip()})
        assert status.returncode == 0 and json.loads(status.stdout) == {"source": "keychain", "login": "fixture-owner",
            "scopes": ["admin:public_key", "project", "repo", "workflow"]}, status.stdout

        # 4. Every request uses the Keychain token, even with a stale token inherited from the shell.
        result = comment({"GH_TOKEN": "ghp_revoked"})
        made = calls()
        evidence.append({"case": "keychain token wins over an inherited GH_TOKEN", "exit": result.returncode, "gh": made})
        assert result.returncode == 0, result.stderr
        assert [call["args"][:2] for call in made] == [["api", "--include"], ["issue", "comment"]]
        assert {call["token"] for call in made} == {"ghp_full"}

        # 5-6. A revoked or under-scoped token fails at the check, before any write.
        for token, message in (("ghp_revoked", "invalid, revoked or expired"), ("ghp_noproject", "lacks scope project")):
            store(token)
            result = comment()
            made = calls()
            evidence.append({"case": f"refused {token}", "exit": result.returncode, "stderr": result.stderr.strip(), "gh": made})
            assert result.returncode == 1 and message in result.stderr and SETUP in result.stderr, result.stderr
            assert [call["args"] for call in made] == [["api", "--include", "/user"]], made

        # 7. A token close to expiry still works and warns once with the fix.
        store("ghp_expiring")
        result = comment()
        evidence.append({"case": "expiring token warns", "exit": result.returncode, "stderr": result.stderr.strip()})
        assert result.returncode == 0 and "expires" in result.stderr and SETUP in result.stderr, result.stderr
    finally:
        subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)], capture_output=True,
                       env={**os.environ, "HOME": str(base / "home")})
        shutil.rmtree(base, ignore_errors=True)
        output = ROOT / "test-results/work-auth.json"
        output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"work auth: {len(evidence)} cases passed; evidence {output.relative_to(ROOT)}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["fixture-gh"]:
        fixture_gh()
    else:
        run()
