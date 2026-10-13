#!/usr/bin/env python3
"""Exercise verification build/reader ownership through real CLI and child processes."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def child() -> None:
    root = Path(os.environ["WORK_VERIFY_FIXTURE"])
    name = Path(sys.argv[0]).name
    state = root / "state"
    dependencies = root / "repo/packages/gateway/node_modules"
    if name == "xcodebuild":
        (state / "mac-start").touch()
        if os.environ.get("FAIL_MAC"):
            raise SystemExit(17)
        shutil.rmtree(dependencies)
        (state / "replacement-open").touch()
        # Hold a real missing-package window. A concurrent reader fails, while
        # an ordered reader only starts after publication. No host load needed.
        time.sleep(0.3)
        dependencies.mkdir()
        (dependencies / "package.json").write_text("{}")
        (state / "replacement-open").unlink()
        (state / "mac-done").touch()
    elif name == "npm":
        if sys.argv[1:2] == ["ci"]:
            (state / "install-start").touch()
            time.sleep(0.1)
            (state / "install-done").touch()
        else:
            (state / "gateway-start").touch()
            # The first canonical build owns the dependencies. The old parallel
            # plan starts this reader before/during that build.
            assert (state / "mac-done").exists(), "Gateway read before Mac dependency publication"
            assert not (state / "replacement-open").exists(), "Gateway read during replacement"
            assert (dependencies / "package.json").exists()
            (state / "gateway-done").touch()
    elif name == "npx":
        assert (state / "gateway-done").exists()
        (state / "related-ran").touch()
    else:
        assert name == "journey"
        assert (state / "gateway-done").exists(), "journey started before canonical Gateway check"
        assert (state / "install-done").exists(), "journey started before npm installation"
        assert (dependencies / "package.json").exists()
        (state / "journey-done").touch()


def run() -> None:
    artifact = ROOT / "test-results/work-verify.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix="tron-work-verify-") as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            for directory in ("home", "tmp", "bin", "state"):
                (root / directory).mkdir()
            env = {**os.environ, "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "TRON_HEAVY_DIR": str(root / "heavy"),
                   "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "WORK_VERIFY_FIXTURE": str(root),
                   "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
            for name in ("npm", "npx", "xcodebuild", "journey"):
                target = root / "bin" / name
                target.write_text(f"#!{sys.executable}\n" + Path(__file__).read_text().split("\n", 1)[1])
                target.chmod(0o755)
            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, env=env, check=True,
                                      text=True, capture_output=True).stdout.strip()
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (repo / ".github").mkdir()
            shutil.copy(ROOT / ".github/work.json", repo / ".github/work.json")
            shutil.copy(ROOT / ".node-version", repo / ".node-version")
            (repo / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/personal-info-guard.sh", repo / "scripts/personal-info-guard.sh")
            (repo / "scripts/tron").write_text("#!/bin/sh\nexit 0\n")
            (repo / "scripts/tron").chmod(0o755)
            (repo / ".gitignore").write_text("node_modules/\n")
            git("add", ".")
            git("commit", "-m", "fixture base")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            git("checkout", "-b", "feature")
            gateway = repo / "packages/gateway"
            (gateway / "node_modules").mkdir(parents=True)
            (gateway / "node_modules/package.json").write_text("{}")
            (gateway / "package-lock.json").write_text("{}")
            (gateway / "source.ts").write_text("export const fixture = true;\n")
            (repo / "packages/mac-app").mkdir()
            (repo / "packages/mac-app/Fixture.swift").write_text("// fixture\n")
            git("add", ".")
            git("commit", "-m", "build both products")
            command = [sys.executable, str(ROOT / "tools/work/cli.py"), "verify", "--tests", "journey"]
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            evidence.append({"case": "build publication precedes Gateway reads and explicit journey", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode == 0, evidence[-1]
            for check in ("privacy", "whitespace", "gateway", "test-1"):
                assert f"running: {check} (log: " in result.stdout, evidence[-1]
            assert (root / "state/related-ran").exists() and (root / "state/journey-done").exists()
            result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0 and "already passed" in result.stdout
            evidence.append({"case": "successful exact tree retains ordinary verification cache", "stdout": result.stdout})
            # A failed build must not admit its readers or mark the tree green.
            shutil.rmtree(root / "state")
            (root / "state").mkdir()
            (repo / "packages/mac-app/Fixture.swift").write_text("// failed build fixture\n")
            git("add", ".")
            git("commit", "-m", "failed build")
            result = subprocess.run(command, cwd=repo, env={**env, "FAIL_MAC": "1"},
                                    capture_output=True, text=True, timeout=30)
            evidence.append({"case": "failed publisher does not admit dependent readers", "exit": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            assert result.returncode != 0 and "exit 17" in result.stdout, evidence[-1]
            assert not (root / "state/gateway-start").exists()
            assert not (root / "state/journey-done").exists()
        print(f"Passed verification ownership journeys; evidence: {artifact}")
    finally:
        artifact.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    if os.environ.get("WORK_VERIFY_FIXTURE") and Path(sys.argv[0]).name in ("npm", "npx", "xcodebuild", "journey"):
        child()
    else:
        run()
