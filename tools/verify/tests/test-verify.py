#!/usr/bin/env python3
"""CLI tests for `scripts/tron verify` (tools/verify/README.md).

Each case copies the real `scripts/tron`, `tools/verify` and the checkers it runs
(`tools/ownership`, `tools/metrics`, `tools/layers`, `tools/work`,
the documentation policy and privacy guard) into a disposable Git repository whose
modules own real Python tests, and runs verify as a worker would:

1. A change inside one module selects only that module's tests, and a failing one
   fails the run after its log tail is printed; the static checks ran first.
2. A change in a kernel-layer (L0-L2) module or an unowned path widens to every lock.
3. A change whose modules own no test fails as a zero-test run.
4. An uncommitted tree is refused, the report records the selection and steps, and
   two runs of the same commit have the same result digest.
5. The iOS lane: an iOS-only change selects the UI locks of the module whose dynamic
   edge reaches it, builds once (a stand-in `scripts/tron-ios-test` compiles a real
   index store with `swiftc` and stamps it with the real identity script), runs the
   real `layers ios` on it, runs the locks by `--only-testing` owner, and reuses the
   build on the next run with an identical digest; a failing or empty XCTest summary
   fails the run.
6. `scripts/tron mutate` over a fake Gateway runner: a mutant whose locks hang is
   stopped at the per-mutant deadline with its whole process group while runs that
   are all slower than `--timeout` still measure; an interrupted run restores the
   source and keeps the mutants it finished, and one interrupted during the unbounded
   unmutated run stops that run's group and removes its HOME.

The last run's output is kept in `test-results/verify-cli/`.
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "test-results" / "verify-cli"
COPIED = ["scripts/tron", "scripts/check-documentation-policy.py", "scripts/check-agent-policy.sh", "scripts/personal-info-guard.sh",
          "scripts/ios-test-build-identity.py", "tools/work/work.json",
          *[str(p.relative_to(ROOT)) for d in ("tools/verify", "tools/ownership", "tools/metrics", "tools/layers", "tools/work", "tools/docs", "tools/home-layout")
            for p in (ROOT / d).glob("*.py")]]
PASSING = "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(True)\nunittest.main()\n"
AGENTS = "# Charter\n\nNever SIGSTOP Gateway-owned work. Never bypass simulator leases via XcodeBuildMCP.\n"
FAILING = "import unittest\nclass T(unittest.TestCase):\n    def test_broken(self):\n        self.assertEqual(1, 2)\nunittest.main()\n"


class Repo:
    def __init__(self, base: Path):
        self.path = base / "repo"
        self.path.mkdir()
        home = base / "home"
        home.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(base), "GIT_CONFIG_GLOBAL": os.devnull,
                    "GIT_CONFIG_NOSYSTEM": "1", "WORK_GH": "/nonexistent-gh",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.git("init", "-q", "-b", "main")
        for relative in COPIED:
            (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, self.path / relative)
        self.lock = base / "full-gateway.lock"
        host_lock = self.path / "tools/verify/host_lock.py"
        host_lock.write_text(host_lock.read_text().replace("'/tmp/tron-full-gateway.lock'", repr(str(self.lock))))
        self.write(".gitignore", "test-results/\n")
        self.write("packages/gateway/src/foundation/tron-home-layout.json", '{"version": 1, "paths": {}}\n')
        self.write("README.md", "# Fixture\n")
        self.write("AGENTS.md", AGENTS)
        self.write(".agents/README.md", "# Guidance\n\n[tron-ios](skills/tron-ios/SKILL.md)\n")
        self.write(".agents/skills/NOTICE.md", "# Notice\n")
        self.write(".agents/skills/tron-ios/SKILL.md", "---\nname: tron-ios\ndescription: iOS work.\n---\n\n"
                   "Tron Device on LocalDevice. Never install Release or DevicePerformance; signed artifacts are evidence.\n"
                   "Agent simulator paths (xcrun mcpbridge) take the same leases.\n")
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/tron", "scripts/check-documentation-policy.py", "scripts/check-agent-policy.sh", "scripts/personal-info-guard.sh",
            "scripts/ios-test-build-identity.py", ".agents/**", "tools/**", "README.md", "AGENTS.md", ".gitignore",
            "packages/gateway/src/foundation/tron-home-layout.json",
            "tooling.module.json"]}))
        for name, layer in (("alpha", "L3"), ("beta", "L3"), ("core", "L1"), ("untested", "L5")):
            self.write(f"mods/{name}/{name}.module.json", json.dumps({"layer": layer, "owns": ["**"]}))
            self.write(f"mods/{name}/{name}.py", f"VALUE = '{name}'\n")
        self.write("mods/alpha/test-alpha.py", PASSING)
        self.write("mods/beta/test-beta.py", PASSING)
        self.write("mods/core/test-core.lock.py", PASSING)
        self.commit("base")
        self.git("branch", "base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.path, env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, text: str) -> None:
        (self.path / relative).parent.mkdir(parents=True, exist_ok=True)
        (self.path / relative).write_text(text)

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def verify(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run([str(self.path / "scripts/tron"), "verify", "--base", "base", *args], cwd=self.path,
                                env=self.env, capture_output=True, text=True)
        ARTIFACTS.mkdir(parents=True, exist_ok=True)
        with (ARTIFACTS / "runs.txt").open("a") as log:
            log.write(f"$ scripts/tron verify {' '.join(args)}\nexit {result.returncode}\n{result.stdout}{result.stderr}\n")
        return result

    def report(self) -> dict:
        sha = self.git("rev-parse", "HEAD")
        return json.loads((self.path / "test-results" / "verify" / f"{sha}.json").read_text())


class VerifyCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        shutil.rmtree(ARTIFACTS, ignore_errors=True)

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="tron-verify-")
        self.repo = Repo(Path(self.temp.name))

    def tearDown(self) -> None:
        self.temp.cleanup()


class ExternalVerificationTests(VerifyCase):
    def external(self, name: str, body: str | None = None, path: str | None = None) -> str:
        r = self.repo
        path = path or f"scripts/test-{name}.py"
        r.write(path, body if body is not None else
                f"from pathlib import Path\np=Path('test-results/{name}')\np.parent.mkdir(exist_ok=True)\n"
                "with p.open('a') as stream: stream.write('executed\\n')\n")
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"].append(path)
        r.write("tooling.module.json", json.dumps(tooling))
        return f"scripts/tron test tooling {path}"

    def declare(self, module: str, commands: list[str], **fields) -> None:
        path = f"mods/{module}/{module}.module.json"
        data = json.loads((self.repo.path / path).read_text())
        self.repo.write(path, json.dumps({**data, "verify": commands, **fields}))

    def test_a_change_runs_its_own_declarations_once_and_all_runs_every_declaration(self) -> None:
        r = self.repo
        direct, dependent = self.external("direct"), self.external("dependent")
        self.declare("alpha", [direct])
        self.declare("beta", [direct, dependent], dependsOn=["repo/alpha"])
        r.commit("external consumers")
        r.git("branch", "-f", "base")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("producer changes")
        for mode in (("--changed",), ("--module", "repo/alpha")):
            with self.subTest(mode=mode):
                for name in ("direct", "dependent"):
                    (r.path / "test-results" / name).unlink(missing_ok=True)
                result = r.verify(*mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                witness = r.path / "test-results" / "direct"
                self.assertTrue(witness.exists(), f"the declared direct process never ran: {result.stdout}")
                self.assertEqual(witness.read_text().splitlines(), ["executed"], "a declaration ran twice")
                self.assertFalse((r.path / "test-results" / "dependent").exists(), f"a dependent's declaration ran: {result.stdout}")
                self.assertNotIn("repo/beta", json.dumps(r.report()["selection"]["reasons"]))
                self.assertEqual(r.report()["passingTests"], 2)
        r.git("branch", "-f", "base")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed again'\n")
        r.write("mods/beta/beta.py", "VALUE = 'changed'\n")
        r.commit("producer and consumer change")
        for name in ("direct", "dependent"):
            (r.path / "test-results" / name).unlink(missing_ok=True)
        both = r.verify("--changed")
        self.assertEqual(both.returncode, 0, both.stdout + both.stderr)
        for name in ("direct", "dependent"):
            witness = r.path / "test-results" / name
            self.assertTrue(witness.exists(), f"declared {name} process never ran: {both.stdout}")
            self.assertEqual(witness.read_text().splitlines(), ["executed"], "duplicate declarations ran twice")
        self.assertEqual(r.report()["passingTests"], 4)
        planned = r.verify("--all", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        selection = json.loads(planned.stdout[planned.stdout.index("{"):])["selection"]["tests"]
        self.assertEqual(selection, ["scripts/test-dependent.py", "scripts/test-direct.py"])
        for relative, content in (("mods/alpha/README.md", "# Alpha\n"), ("mods/alpha/test-alpha.py", PASSING + "EDITED = True\n")):
            r.git("branch", "-f", "base")
            r.write(relative, content)
            r.commit("narrow change")
            for name in ("direct", "dependent"):
                (r.path / "test-results" / name).unlink(missing_ok=True)
            result = r.verify("--changed")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((r.path / "test-results/direct").exists())
            self.assertFalse((r.path / "test-results/dependent").exists())

    def test_a_tool_suite_beside_its_tool_is_a_declarable_consumer(self) -> None:
        r = self.repo
        declared = self.external("tool", path="tools/fixture/tests/test-tool.py")
        self.declare("alpha", [declared])
        r.commit("tool-owned consumer")
        planned = r.verify("--all", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        selection = json.loads(planned.stdout[planned.stdout.index("{"):])["selection"]["tests"]
        self.assertIn("tools/fixture/tests/test-tool.py", selection)
        self.declare("alpha", ["scripts/tron test tooling tools/fixture/helper.py"])
        r.write("tools/fixture/helper.py", "VALUE = 1\n")
        r.commit("undeclarable helper")
        refused = r.verify("--all", "--plan")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("unsupported verify declaration", refused.stdout + refused.stderr)

    def test_gateway_declarations_keep_existing_runner_classification(self) -> None:
        r = self.repo
        files = ["src/main.integration.test.ts", "src/nested.integration.test.ts", "src/mac.integration.test.ts",
                 "scripts/contract.test.mjs"]
        for path in files + ["scripts/outside.test.ts"]:
            r.write(f"packages/gateway/{path}", "export const selectionOnly = true;\n")
        r.write("packages/gateway/consumer.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/vitest.nested.config.ts", 'const nestedTestFiles = ["src/nested.integration.test.ts"];\n')
        r.write("packages/gateway/vitest.mac-terminal.config.ts", 'const macTerminalTestFiles = ["src/mac.integration.test.ts"];\n')
        python = self.external("pooled")
        self.declare("alpha", ["scripts/tron test gateway " + " ".join(files), python])
        r.commit("Gateway consumer declarations")
        planned = r.verify("--module", "repo/alpha", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        groups = json.loads(planned.stdout[planned.stdout.index("{"):])["groups"]
        for group, path in zip(("gateway", "gateway-nested", "mac-terminal", "node-gateway"), files):
            self.assertEqual(groups[group], [f"packages/gateway/{path}"])
        ssh = Path(self.temp.name) / "bin" / "ssh"
        ssh.parent.mkdir()
        ssh.write_text('#!/bin/bash\nfor word in "$@"; do [[ "$word" == mini.invalid ]] && { echo "ssh: Could not resolve hostname mini.invalid" >&2; exit 255; }; done\n'
                       'echo \'{"busy": false, "ready": true, "load": 1.5}\'\n')
        ssh.chmod(0o755)
        r.env["PATH"] = f"{ssh.parent}{os.pathsep}{r.env['PATH']}"
        for mini_host, options, runner, reason in (
                ("mini.test", [], "mini.py", "reachable and idle, load 1.5"),
                ("mini.invalid", [], "gateway.py", "the mini mini.invalid is unreachable: ssh: Could not resolve hostname mini.invalid"),
                ("mini.invalid", ["--gateway-host", "mini"], "mini.py", "--gateway-host mini"),
                ("mini.test", ["--gateway-host", "local"], "gateway.py", "--gateway-host local")):
            r.git("config", "tron.verify.mini", mini_host)
            planned = r.verify("--module", "repo/alpha", "--plan", *options)
            plan = json.loads(planned.stdout[planned.stdout.index("{"):])
            self.assertEqual({c["name"]: Path(c["command"][1]).name for c in plan["commands"] if c["name"].startswith("tests: gateway")},
                             {"tests: gateway": runner, "tests: gateway-nested": runner}, options)
            local_python = " && ".join(f"echo '### verify file: {path}' && python3 {path}"
                                       for path in ("mods/alpha/test-alpha.py", "scripts/test-pooled.py"))
            python_command = next(c["command"] for c in plan["commands"] if c["name"] == "tests: python")
            self.assertEqual([python_command[0], Path(python_command[1]).name, *python_command[2:]] if runner == "mini.py"
                             else python_command, ["python3", "mini.py", "python", local_python] if runner == "mini.py"
                             else local_python, options)
            self.assertEqual(plan["gatewayHost"], {"host": runner.removesuffix(".py").replace("gateway", "local"), "reason": reason})
            self.assertIn(f"gateway and python lanes: on {'the Mac mini' if runner == 'mini.py' else 'this Mac'} ({reason})", planned.stdout)
            self.assertIn("mac-terminal lane: on this Mac (it needs this host's tailnet sshd)", planned.stdout)
        r.git("config", "tron.verify.mini", "mini.test")
        self.declare("alpha", [python])
        r.commit("Python-only consumer")
        planned = r.verify("--module", "repo/alpha", "--plan")
        plan = json.loads(planned.stdout[planned.stdout.index("{"):])
        python_command = next(c["command"] for c in plan["commands"] if c["name"] == "tests: python")
        self.assertEqual((Path(python_command[1]).name, python_command[2]), ("mini.py", "python"), planned.stdout)
        self.assertIn("gateway and python lanes: on the Mac mini (reachable and idle, load 1.5)", planned.stdout)
        r.git("config", "--unset", "tron.verify.mini")
        self.declare("alpha", ["scripts/tron test gateway scripts/outside.test.ts"])
        r.commit("unsupported Gateway input")
        refused = r.verify("--module", "repo/alpha", "--plan")
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertIn("unsupported verify declaration", refused.stderr)
        self.declare("alpha", ["scripts/tron test gateway " + " ".join(files)])
        r.write("packages/gateway/vitest.nested.config.ts",
                'const nestedTestFiles = ["src/nested.integration.test.ts", "src/deleted.e2e.test.ts"];\n')
        r.commit("stale nested entry")
        stale = r.verify("--module", "repo/alpha", "--plan")
        self.assertEqual(stale.returncode, 2, stale.stdout + stale.stderr)
        self.assertIn("serial runner config lists untracked packages/gateway/src/deleted.e2e.test.ts", stale.stderr)

    def test_declared_ios_class_uses_existing_lane_and_explicit_skip(self) -> None:
        r = self.repo
        path = "packages/ios-app/UITests/ExternalUITests.swift"
        r.write(path, "class ExternalUITests: XCTestCase {}\n")
        r.write("packages/ios-app/UITests/external.module.json", json.dumps({"layer": "L4", "owns": ["**"]}))
        self.declare("alpha", ["scripts/tron test ios run --only-testing TronMobileUITests/ExternalUITests"])
        r.commit("declared UI consumer")
        result = r.verify("--module", "repo/alpha", "--skip", "ios")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = r.report()
        self.assertIn(path, report["selection"]["tests"])
        self.assertEqual(report["passingTests"], 1)
        self.assertEqual(next(step for step in report["steps"] if step["name"] == "tests: ios")["status"], "skipped")
        self.assertNotIn("ios build", [step["name"] for step in report["steps"]])
        r.write("packages/ios-app/UITests/TronMacTerminalUITests.swift",
                "class TronMacTerminalUITests: XCTestCase {}\n")
        self.declare("alpha", ["scripts/tron test ios run --only-testing TronMobileUITests/TronMacTerminalUITests"])
        r.commit("harness-only consumer")
        incomplete = r.verify("--module", "repo/alpha")
        self.assertEqual(incomplete.returncode, 1, incomplete.stdout + incomplete.stderr)
        self.assertEqual(r.report()["verdict"], "incomplete")
        skipped = r.verify("--module", "repo/alpha", "--skip", "ios")
        self.assertEqual(skipped.returncode, 0, skipped.stdout + skipped.stderr)
        self.assertEqual(r.report()["groups"]["ios-lanes"], ["packages/ios-app/UITests/TronMacTerminalUITests.swift"])

    def test_external_failure_empty_and_unsupported_commands_cannot_pass(self) -> None:
        r = self.repo
        command = self.external("external", "raise SystemExit(7)\n")
        self.declare("alpha", [command])
        r.commit("external failure")
        failed = r.verify("--module", "repo/alpha")
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("tests: python FAILED", failed.stdout)
        r.write("scripts/test-external.py", "import unittest\nunittest.main()\n")
        r.commit("external empty suite")
        empty = r.verify("--module", "repo/alpha")
        self.assertEqual(empty.returncode, 1, empty.stdout + empty.stderr)
        self.assertIn("zero passing tests", empty.stdout)
        for command in ("scripts/tron verify --all", "scripts/tron test tooling scripts/absent.py",
                        "scripts/tron test tooling scripts/test-external.py ; touch forbidden",
                        "scripts/tron test ios build",
                        "scripts/tron test ios run --only-testing TronMobileUITests/UnknownUITests"):
            self.declare("alpha", [command])
            r.commit("unsupported declaration")
            result = r.verify("--module", "repo/alpha")
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertFalse((r.path / "forbidden").exists())
        self.declare("alpha", [None])
        r.commit("malformed declaration")
        malformed = r.verify("--module", "repo/alpha")
        self.assertEqual(malformed.returncode, 1, malformed.stdout + malformed.stderr)
        self.assertIn("ownership FAILED", malformed.stdout)
        self.assertNotIn("Traceback", malformed.stderr)


class GatewayFailureTests(VerifyCase):
    """Real verify CLI/process boundary consuming the Vitest JSON protocol, without skipping tests."""

    def fixture(self):
        r = self.repo
        path = "packages/gateway/src/sample.integration.test.ts"
        r.write(path, "export const reportProtocol = true;\n")
        r.write("packages/gateway/src/sample.ts", "export const value = 1;\n")
        r.write("packages/gateway/sample.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/package.json", json.dumps({"devDependencies": {"typescript": "7.0.2"}}))
        r.write("packages/gateway/node_modules/typescript/package.json", '{"version":"7.0.2"}')
        r.write("packages/gateway/node_modules/typescript/bin/tsc", "#!/bin/sh\nexit 0\n")
        (r.path / "packages/gateway/node_modules/typescript/bin/tsc").chmod(0o755)
        (r.path / "packages/gateway/node_modules/.bin").mkdir()
        (r.path / "packages/gateway/node_modules/.bin/tsc").symlink_to("../typescript/bin/tsc")
        r.write(".gitignore", "test-results/\npackages/gateway/node_modules/\n")
        r.write("scripts/tron-node", "#!/bin/sh\necho src/sample.ts\n")
        (r.path / "scripts/tron-node").chmod(0o755)
        manifest = json.loads((r.path / "tooling.module.json").read_text())
        manifest["owns"].append("scripts/tron-node")
        manifest["owns"].remove("packages/gateway/src/foundation/tron-home-layout.json")
        r.write("tooling.module.json", json.dumps(manifest))
        r.write("tools/verify/gateway.py", "import json,pathlib,sys\n"
                "out=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--outputFile.json='))\n"
                "report=json.loads(pathlib.Path('report-input.json').read_text())\n"
                "pathlib.Path(out).write_text(json.dumps(report))\n"
                "pathlib.Path('test-results').mkdir(exist_ok=True)\n"
                "pathlib.Path('test-results/executed').write_text('executed')\n"
                "print(report.get('diagnostic', ''))\n"
                "sys.exit(1)\n")
        r.write("packages/gateway/report-input.json", json.dumps({"numPassedTests": 1, "numFailedTests": 1,
            "numFailedTestSuites": 1, "testResults": [{"name": str(r.path / path), "status": "failed",
            "assertionResults": [{"fullName": "sample known failure", "status": "failed", "failureMessages": ["Error: original defect"]},
                                 {"fullName": "sample passes", "status": "passed"}]}]}))
        r.write(".gitignore", "test-results/\npackages/gateway/node_modules/\n")
        r.commit("report protocol producer")
    def test_every_gateway_case_failure_is_raw_red_without_exemption(self):
        r = self.repo
        self.fixture()
        original = (r.path / "packages/gateway/report-input.json").read_text()
        for change in ("exact", "unknown", "suite-error", "missing-report"):
            with self.subTest(change=change):
                raw = json.loads(original)
                if change == "unknown":
                    raw["testResults"][0]["assertionResults"][0]["fullName"] = "different failure"
                elif change == "suite-error":
                    raw["numFailedTestSuites"] = 2
                    raw["testResults"].append({"name": "broken suite", "status": "failed", "message": "setup error", "assertionResults": []})
                elif change == "missing-report":
                    r.write("tools/verify/gateway.py", "import sys\nsys.exit(1)\n")
                if change != "exact":
                    r.write("packages/gateway/report-input.json", json.dumps(raw))
                    r.commit(change)
                (r.path / "packages/gateway/test-results/executed").unlink(missing_ok=True)
                result = r.verify("--module", "gateway/sample")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                report = r.report()
                self.assertEqual(report["verdict"], "failed")
                self.assertNotIn("expiredEntries", report)
                if change != "missing-report":
                    self.assertTrue((r.path / "packages/gateway/test-results/executed").exists())


    def test_an_unreachable_mini_leaves_the_gateway_lane_without_a_result_and_never_runs_it_here(self):
        r = self.repo
        self.fixture()
        r.git("config", "tron.verify.mini", "nobody@mini.invalid")
        stub = Path(self.temp.name) / "bin"
        stub.mkdir()
        (stub / "ssh").write_text("#!/bin/sh\necho 'ssh: connect to host mini.invalid port 22: Connection refused' >&2\nexit 255\n")
        (stub / "ssh").chmod(0o755)
        r.env["PATH"] = f"{stub}:{r.env['PATH']}"
        result = r.verify("--module", "gateway/sample", "--gateway-host", "mini")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("gateway and python lanes: on the Mac mini", result.stdout)
        report = r.report()
        step = next(step for step in report["steps"] if step["name"] == "tests: gateway")
        self.assertEqual((report["verdict"], step["status"], step["exit"]), ("incomplete", "no result", 75))
        self.assertIn("the mini gave no result: could not push", report["message"])
        self.assertIn("Connection refused", step["reason"])
        self.assertIn("could not push", (r.path / step["log"]).read_text())
        self.assertIn("Connection refused", (r.path / step["log"]).read_text())
        self.assertFalse((r.path / "packages/gateway/test-results/executed").exists(), "the local lane never ran")


class GatewayDependenciesTests(VerifyCase):
    def test_gateway_requires_local_pinned_compiler_before_running_checks(self) -> None:
        r = self.repo
        r.write("packages/gateway/compiler.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/package.json", json.dumps({"devDependencies": {"typescript": "7.0.2"},
                                                              "scripts": {"check": "tsc --version"}}))
        shutil.copy2(ROOT / "scripts/tron-node", r.path / "scripts/tron-node")
        r.write(".node-version", (ROOT / ".node-version").read_text())
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"].extend(["scripts/tron-node", ".node-version"])
        r.write("tooling.module.json", json.dumps(tooling))
        r.env["TRON_NODE_BIN"] = subprocess.check_output([str(ROOT / "scripts/tron-node")], text=True).strip()
        r.write("packages/gateway/test-compiler.py", PASSING)
        r.write(".gitignore", "test-results/\npackages/gateway/node_modules/\n")
        r.commit("Gateway compiler consumer")
        global_bin = Path(self.temp.name) / "bin"
        global_bin.mkdir()
        compiler = global_bin / "tsc"
        compiler.write_text("#!/bin/sh\necho global-compiler-was-used\nexit 0\n")
        compiler.chmod(0o755)
        r.env["PATH"] = str(global_bin) + os.pathsep + r.env["PATH"]
        missing = r.verify("--module", "gateway/compiler")
        self.assertEqual(missing.returncode, 2, missing.stdout + missing.stderr)
        self.assertIn("Gateway TypeScript", missing.stderr)
        self.assertIn("scripts/tron-node exec npm --prefix packages/gateway ci --include=dev", missing.stderr)
        self.assertNotIn("global-compiler-was-used", missing.stdout + missing.stderr)
        r.write("packages/gateway/node_modules/typescript/package.json", json.dumps({"version": "0.0.0"}))
        stale = r.verify("--module", "gateway/compiler")
        self.assertEqual(stale.returncode, 2, stale.stdout + stale.stderr)
        self.assertIn("installed 0.0.0, pinned 7.0.2", stale.stderr)
        r.write("packages/gateway/node_modules/typescript/package.json", json.dumps({"version": "7.0.2"}))
        broken = r.verify("--module", "gateway/compiler")
        self.assertEqual(broken.returncode, 2, broken.stdout + broken.stderr)
        self.assertIn("local executable", broken.stderr)
        planned = r.verify("--module", "gateway/compiler", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)

    def test_any_test_step_refuses_before_step_one_while_the_gateway_install_differs_from_its_lockfile(self) -> None:
        r = self.repo
        lock = {"lockfileVersion": 3, "packages": {"": {"name": "gateway"},
                "node_modules/ws": {"version": "8.18.0", "integrity": "sha512-ws"},
                "node_modules/@oxlint/binding-win32-x64-msvc": {"version": "1.0.0", "optional": True}}}
        r.write("packages/gateway/package-lock.json", json.dumps(lock))
        r.write("packages/gateway/lock.module.json", json.dumps({"layer": "L3", "owns": ["package-lock.json", "lock.module.json"]}))
        r.write(".gitignore", "test-results/\npackages/gateway/node_modules/\n")
        r.commit("Gateway lockfile")
        r.git("branch", "-f", "base")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("python-only change")
        hint = "scripts/tron-node exec npm --prefix packages/gateway ci --include=dev"
        installed = r.path / "packages/gateway/node_modules/.package-lock.json"
        for case, packages, named in (("missing", None, "not installed"),
                                      ("stale", {"node_modules/ws": {"version": "8.17.0", "integrity": "sha512-old"}}, "node_modules/ws"),
                                      ("extraneous", {"node_modules/ws": lock["packages"]["node_modules/ws"],
                                                      "node_modules/left-over": {"version": "1.0.0"}}, "node_modules/left-over")):
            with self.subTest(case=case):
                if packages is not None:
                    installed.parent.mkdir(parents=True, exist_ok=True)
                    installed.write_text(json.dumps({"lockfileVersion": 3, "packages": packages}))
                refused = r.verify("--changed")
                self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
                self.assertIn(hint, refused.stderr)
                self.assertIn(named, refused.stderr)
                self.assertNotIn("[1/", refused.stdout, "a step ran before the refusal")
                self.assertFalse((r.path / "test-results/verify").exists(), "a refused run wrote a report")
        installed.write_text(json.dumps({"lockfileVersion": 3, "packages": {"node_modules/ws": lock["packages"]["node_modules/ws"]}}))
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)

    def test_a_relay_test_runs_in_the_relay_lane_on_its_installed_lockfile(self) -> None:
        r = self.repo
        relay = "packages/push-relay"
        lock = {"lockfileVersion": 3, "packages": {"": {"name": "push-relay"}, "node_modules/vitest": {"version": "5.0.5", "integrity": "sha512-v"}}}
        r.write(f"{relay}/package-lock.json", json.dumps(lock))
        r.write(f"{relay}/relay.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write(f"{relay}/src/registry.ts", "export const value = 1;\n")
        r.write(f"{relay}/tests/worker.integration.test.ts", "export const relayVitest = true;\n")
        r.write(".gitignore", f"test-results/\n{relay}/node_modules/\n")
        r.write("scripts/tron-node", '#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        (r.path / "scripts/tron-node").chmod(0o755)
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"].append("scripts/tron-node")
        r.write("tooling.module.json", json.dumps(tooling))
        npm = Path(self.temp.name) / "bin" / "npm"
        npm.parent.mkdir()
        npm.write_text("#!/usr/bin/env python3\nimport json,pathlib,sys\n"
                       "out=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--outputFile.json='))\n"
                       "pathlib.Path('ran').write_text(' '.join(sys.argv[1:]))\n"
                       "pathlib.Path(out).write_text(json.dumps({'numPassedTests':3,'numFailedTests':0,'testResults':[]}))\n")
        npm.chmod(0o755)
        r.env["PATH"] = str(npm.parent) + os.pathsep + r.env["PATH"]
        r.commit("relay")
        r.git("branch", "-f", "base")
        r.write(f"{relay}/src/registry.ts", "export const value = 2;\n")
        r.commit("relay-only change")
        missing = r.verify("--changed")
        self.assertEqual(missing.returncode, 2, missing.stdout + missing.stderr)
        self.assertIn(f"Relay dependencies are not installed; prepare this worktree with: scripts/tron-node exec npm --prefix {relay} ci --include=dev", missing.stderr)
        self.assertNotIn("[1/", missing.stdout, "a step ran before the refusal")
        r.write(f"{relay}/node_modules/.package-lock.json", json.dumps({"lockfileVersion": 3, "packages": {"node_modules/vitest": lock["packages"]["node_modules/vitest"]}}))
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        self.assertEqual((r.path / relay / "ran").read_text().split()[:2], ["test", "--"])
        self.assertTrue((r.path / relay / "ran").read_text().endswith("tests/worker.integration.test.ts"))
        report = r.report()
        self.assertEqual((report["verdict"], report["passingTests"]), ("passed", 3))

    def test_a_mac_change_runs_the_mac_integration_tests(self) -> None:
        r = self.repo
        mac = "packages/mac-app"
        r.write(f"{mac}/Sources/Server/server.module.json", json.dumps({"layer": "L3", "owns": ["**"], "verify": ["scripts/tron test mac"]}))
        r.write(f"{mac}/Sources/Server/GatewayProcess.swift", "let value = 1\n")
        r.write(f"{mac}/Tests/tests.module.json", json.dumps({"layer": "L5", "owns": ["**"]}))
        r.write(f"{mac}/Tests/Integration/SubprocessTests.swift", "struct SubprocessTests {}\n")
        r.write(f"{mac}/Tests/Integration/WizardTests.swift", "struct WizardTests {}\n")
        r.write(f"{mac}/Tests/Integration/TestTempDir.swift", "enum TestTempDir {}\n")
        r.write("tools/verify/mac.py", "import pathlib,sys\npathlib.Path('test-results/mac-ran').write_text(' '.join(sys.argv[1:]))\n"
                "print(\"Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\")\n"
                "print(f'Test run with {2 * (len(sys.argv) - 1)} tests in 1 suite passed after 1.0 seconds.')\n")
        r.commit("mac app")
        r.git("branch", "-f", "base")
        r.write(f"{mac}/Sources/Server/GatewayProcess.swift", "let value = 2\n")
        r.commit("mac source change")
        source = r.verify("--changed")
        self.assertEqual(source.returncode, 0, source.stdout + source.stderr)
        self.assertEqual((r.path / "test-results/mac-ran").read_text(), "SubprocessTests WizardTests")
        report = r.report()
        self.assertEqual((report["verdict"], report["passingTests"]), ("passed", 4))
        r.git("branch", "-f", "base")
        r.write(f"{mac}/Tests/Integration/WizardTests.swift", "struct WizardTests { let changed = true }\n")
        r.commit("mac test change")
        tests = r.verify("--changed")
        self.assertEqual(tests.returncode, 0, tests.stdout + tests.stderr)
        self.assertEqual((r.path / "test-results/mac-ran").read_text(), "WizardTests")
        self.assertEqual(r.report()["passingTests"], 2)


class SelectionTests(VerifyCase):
    def test_one_module_change_runs_only_its_tests_and_a_failure_fails_loudly(self) -> None:
        r = self.repo
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("alpha change")
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        report = r.report()
        self.assertEqual(report["selection"]["modules"], ["repo/alpha"])
        self.assertEqual(report["selection"]["tests"], ["mods/alpha/test-alpha.py"])
        self.assertEqual(report["verdict"], "passed")
        self.assertEqual(report["delta"], {"sourceLines": {"added": 1, "removed": 1}, "testLines": {"added": 0, "removed": 0},
                                           "docLines": {"added": 0, "removed": 0},
                                           "addedTestFiles": [], "deletedTestFiles": [], "besideExistingOwner": {}, "compatAdditions": []})
        self.assertEqual([step["name"] for step in report["steps"]][:8],
                         ["ownership", "worktree residue", "documentation policy", "generated docs", "agent policy",
                          "home layout", "privacy guard", "git diff --check"])
        self.assertIn("[1/", passed.stdout)
        r.write("mods/alpha/test-alpha.py", FAILING)
        r.commit("break alpha")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("tests: python FAILED", failed.stdout)
        self.assertIn("AssertionError: 1 != 2", failed.stdout)
        self.assertNotIn("mods/beta/test-beta.py", json.dumps(r.report()["selection"]["tests"]))
        r.git("reset", "-q", "--hard", "base")
        r.write("mods/alpha/test-alpha.edge.py", "import sys, unittest\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).parent))\n"
                "import alpha\nclass Edge(unittest.TestCase):\n    def test_value(self):\n        self.assertEqual(alpha.VALUE, 'alpha')\nunittest.main()\n")
        r.git("rm", "-q", "mods/beta/test-beta.py")
        r.write("mods/alpha/alpha.py", "VALUE = 'alpha'\nOLD = VALUE  # legacy alias\n")
        r.commit("parallel proof and a compat alias")
        parallel = r.verify("--changed")
        self.assertIn("delta: new mods/alpha/test-alpha.edge.py beside existing owner mods/alpha/test-alpha.py", parallel.stdout)
        self.assertIn("delta: compatibility wording added in mods/alpha/alpha.py: OLD = VALUE  # legacy alias", parallel.stdout)
        change = r.report()["delta"]
        self.assertEqual((change["addedTestFiles"], change["deletedTestFiles"], change["testLines"]["removed"]),
                         (["mods/alpha/test-alpha.edge.py"], ["mods/beta/test-beta.py"], PASSING.count("\n")))

    def test_a_source_change_also_runs_the_tests_of_modules_that_import_it(self) -> None:
        """#2364: 39cc6a39f changed a tools/ownership return shape; the importing modules' tests went red
        on main because the change's selection ran only the owner's tests."""
        r = self.repo
        r.write("mods/alpha/alpha.py", "def pair():\n    return ('a', 'b')\n")
        r.write("mods/beta/beta.py", "import sys\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).parents[1] / 'alpha'))\n"
                "from alpha import pair  # noqa: E402\n\ndef first():\n    left, _ = pair()\n    return left\n")
        r.write("mods/beta/test-beta.py", "import sys, unittest\nfrom pathlib import Path\nsys.path.insert(0, str(Path(__file__).parent))\n"
                "import beta\nclass T(unittest.TestCase):\n    def test_first(self):\n        self.assertEqual(beta.first(), 'a')\nunittest.main()\n")
        r.write("mods/untested/reader.mjs", "import { VALUE } from '../core/core.mjs';\nexport const seen = VALUE;\n")
        r.write("mods/core/core.mjs", "export const VALUE = 1;\n")
        r.commit("beta imports alpha")
        r.git("branch", "-f", "base")
        r.write("mods/alpha/alpha.py", "def pair():\n    return ('a', 'b', 'c')\n")
        r.commit("alpha widens its tuple")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("too many values to unpack", failed.stdout, failed.stderr)
        selection = r.report()["selection"]
        self.assertEqual(selection["tests"], ["mods/alpha/test-alpha.py", "mods/beta/test-beta.py"])
        self.assertIn("repo/beta: imports changed mods/alpha/alpha.py; its 1 owned test file(s)", selection["reasons"])
        r.git("branch", "-f", "base")
        r.write("mods/core/core.mjs", "export const VALUE = 2;\n")
        r.write("mods/alpha/test-alpha.py", PASSING.replace("test_ok", "test_still_ok"))
        r.commit("core and alpha's test change")
        planned = r.verify("--changed", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        self.assertIn("repo/untested: imports changed mods/core/core.mjs", planned.stdout)
        self.assertNotIn("repo/beta", planned.stdout)
        r.git("branch", "-f", "base")
        r.git("rm", "-q", "mods/alpha/alpha.py")
        r.commit("delete alpha")
        deleted = r.verify("--changed", "--plan")
        self.assertIn("repo/beta: imports changed mods/alpha/alpha.py; its 1 owned test file(s)", deleted.stdout)

    def test_ignored_residue_with_no_named_writer_fails_the_run(self) -> None:
        r = self.repo
        r.write(".gitignore", "test-results/\n*.log\n")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("ignore logs")
        r.write("mods/alpha/probe-output.log", "left behind\n")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("tidy: residue: mods/alpha/probe-output.log — ignored path with no named writer", failed.stdout)
        self.assertEqual(next(step for step in r.report()["steps"] if step["name"] == "worktree residue")["status"], "failed")
        (r.path / "mods/alpha/probe-output.log").unlink()
        self.assertEqual(r.verify("--changed").returncode, 0)

    def test_kernel_layer_or_unowned_change_widens_to_every_lock(self) -> None:
        r = self.repo
        r.write("mods/core/core.py", "VALUE = 'kernel change'\n")
        r.commit("kernel change")
        result = r.verify("--changed", "--plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("widened to every lock", result.stdout)
        self.assertIn("repo/core (L1)", result.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("stray/notes.py", "VALUE = 1\n")
        r.commit("unowned change")
        stray = r.verify("--changed", "--plan")
        self.assertIn("widened to every lock", stray.stdout)
        self.assertIn("unowned stray/notes.py", stray.stdout)
        self.assertIn("ownership FAILED", r.verify("--changed").stdout)

    def test_a_selection_without_tests_fails_as_zero_test(self) -> None:
        r = self.repo
        r.write("mods/untested/untested.py", "VALUE = 'code without tests'\n")
        r.commit("code change")
        result = r.verify("--changed")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("zero tests ran: an empty selection is not evidence", result.stdout)
        self.assertEqual(r.report()["verdict"], "failed")


class FastPathTests(VerifyCase):
    """A change runs the checks that can catch a regression in it, and still fails when it breaks one."""

    def test_markdown_selects_no_test_and_a_docs_only_change_passes_on_the_documentation_checks(self) -> None:
        r = self.repo
        r.write("mods/core/README.md", "# Core\n\nThe kernel module.\n")
        r.write("AGENTS.md", AGENTS + "\nA new rule.\n")
        r.commit("docs")
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        report = r.report()
        self.assertEqual((report["selection"]["tests"], report["selection"]["modules"], report["passingTests"]), ([], [], 0))
        self.assertIn("documentation-only change", report["message"])
        self.assertEqual({step["name"]: step["status"] for step in report["steps"]}["agent policy"], "ok")
        r.write("AGENTS.md", "# Charter\n")
        r.commit("drop the stop rule")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("agent policy FAILED", failed.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("mods/core/README.md", "# Core\n")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("docs and code")
        mixed = r.verify("--changed")
        self.assertEqual(mixed.returncode, 0, mixed.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/alpha/test-alpha.py"])

    def test_the_privacy_guard_reads_the_change_except_its_own_needles_and_still_fails_a_leak(self) -> None:
        r = self.repo
        handle = "mhis" + "mail3"
        guard = (r.path / "scripts/personal-info-guard.sh").read_text()
        r.write("scripts/personal-info-guard.sh", guard + f"# {handle}\n")
        r.commit("guard names its needle")
        r.git("branch", "-f", "base")
        r.write("scripts/personal-info-guard.sh", guard)
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("guard needle removed")
        own = r.verify("--changed")
        self.assertEqual({step["name"]: step["status"] for step in r.report()["steps"]}["privacy guard"], "ok", own.stdout)
        r.write("mods/alpha/alpha.py", f"VALUE = '{handle}'\n")
        r.commit("leak")
        leaked = r.verify("--changed")
        self.assertEqual(leaked.returncode, 1, leaked.stdout)
        self.assertIn("privacy guard FAILED", leaked.stdout)

    def test_a_new_comment_fails_the_run_and_directives_or_strings_do_not(self) -> None:
        r = self.repo
        r.write("mods/alpha/alpha.py", "import os  # noqa: F401\nVALUE = '# not a comment'\n")
        r.write("mods/alpha/tool.sh", "#!/usr/bin/env bash\n# shellcheck disable=SC2034\nx='# quoted'\ncat <<EOF\n# heredoc\nEOF\n")
        r.write("mods/alpha/View.swift", 'let url = "https://example.test" // view-local: reason\nlet s = #"// raw"#\n')
        r.write("mods/alpha/view.ts", "// @ts-nocheck\nconst a = `${'//'}` + '/*' + /\\/\\//.source;\n")
        r.write("tools/fixture/tool.py", "# Fixture tool that a test runs to prove one rule.\nVALUE = 1\n")
        r.commit("directives and strings")
        clean = r.verify("--changed")
        self.assertEqual({step["name"]: step["status"] for step in r.report()["steps"]}["no new comments"], "ok", clean.stdout)
        r.git("branch", "-f", "base")
        for path, text, line in (("mods/alpha/alpha.py", "VALUE = 'alpha'  # why\n", 1),
                                 ("mods/alpha/tool.sh", "#!/usr/bin/env bash\necho hi # why\n", 2),
                                 ("mods/alpha/View.swift", "let a = 1\n/* why\n */\n", 2),
                                 ("mods/alpha/view.ts", "export const a = 1 / 2; // why\n", 1),
                                 ("mods/alpha/after.ts", "let y = 1;\nexport const x = y++ / 2; // why\n", 2),
                                 ("mods/alpha/here.sh", "cat <<< word\n# why\n", 2),
                                 ("mods/alpha/page.css", 'a { content: "\\""; }\n/* why */\n', 2),
                                 ("mods/alpha/alpha.py", "VALUE = 1  # we keep the noqa flag on purpose\n", 1),
                                 ("tools/fixture/tool.py", "# An opinion added above the purpose line.\n"
                                                           "# Fixture tool that a test runs to prove one rule.\nVALUE = 1\n", 1),
                                 ("tools/fixture/new.py", "VALUE = 1\n# An opinion below the code of a new tool.\n", 2)):
            with self.subTest(path=path):
                r.git("reset", "-q", "--hard", "base")
                r.write(path, text)
                r.commit("a comment")
                failed = r.verify("--changed")
                self.assertEqual(failed.returncode, 1, failed.stdout)
                self.assertIn("no new comments FAILED", failed.stdout)
                self.assertIn(f"{path}:{line}: new comment", failed.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("tools/fixture/tool.py", "# Fixture tool that a test runs to prove the comment rule.\nVALUE = 1\n")
        r.commit("a reworded purpose line")
        reworded = r.verify("--changed")
        self.assertEqual({step["name"]: step["status"] for step in r.report()["steps"]}["no new comments"], "ok", reworded.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("tools/fixture/tool.py", "# Fixture tool that a test runs to prove\n# one rule across two lines.\nVALUE = 1\n")
        r.commit("a wrapped purpose header")
        r.git("branch", "-f", "base")
        r.write("tools/fixture/tool.py", "# Fixture tool that a test runs to prove one rule across two lines.\nVALUE = 1\n")
        r.commit("the wrapped header joined into one purpose line")
        reworded = r.verify("--changed")
        self.assertEqual({step["name"]: step["status"] for step in r.report()["steps"]}["no new comments"], "ok", reworded.stdout)
        old_purpose = "Run the fixture tool to exercise its source boundary."
        new_purpose = "Run the fixture tool and expose its command help."
        for path, prefix, body in (
                ("tools/fixture/tool.sh", "#!/usr/bin/env bash\n", f"cat <<'HELP'\n{old_purpose}\nHELP\n"),
                ("tools/fixture/tool.py", "", f"VALUE = {old_purpose!r}\n")):
            with self.subTest(purpose_path=path):
                original = prefix + f"# {old_purpose}\n" + body
                r.write(path, original)
                r.commit("a tool whose help repeats its purpose")
                r.git("branch", "-f", "base")
                r.write(path, prefix + f"# {new_purpose}\n" + body)
                r.commit("reword the purpose without changing help")
                help_text = r.verify("--changed")
                self.assertEqual({step["name"]: step["status"] for step in r.report()["steps"]}["no new comments"],
                                 "ok", help_text.stdout)
                r.git("reset", "-q", "--hard", "base")
                r.write(path, prefix + f"# {new_purpose}\n# {old_purpose}\n" + body)
                r.commit("a new comment above a retained purpose")
                retained = r.verify("--changed")
                self.assertEqual(retained.returncode, 1, retained.stdout)
                self.assertIn("no new comments FAILED", retained.stdout)
                self.assertIn(f"{path}:{prefix.count(chr(10)) + 1}: new comment", retained.stdout)
                r.git("reset", "-q", "--hard", "base")

    def test_a_gateway_golden_change_selects_only_the_lock_that_reads_it(self) -> None:
        r = self.repo
        base = "packages/gateway/src/e2e"
        r.write(f"{base}/e2e.module.json", '{"layer":"L5","owns":["**"]}\n')
        r.write(f"{base}/one/locks/state.golden.json", "{}\n")
        r.write(f"{base}/one/one.lock.integration.test.ts", 'import { lockPaths } from "../../test-support/scenario-lock.js";\nlockPaths(import.meta.url, "state");\n')
        r.write(f"{base}/two/locks/other.golden.json", "{}\n")
        r.write(f"{base}/two/two.lock.integration.test.ts", 'import { lockPaths } from "../../test-support/scenario-lock.js";\nconst trace = { lock: "other" };\nlockPaths(import.meta.url, trace.lock);\n')
        r.commit("gateway locks")
        r.git("branch", "-f", "base")
        r.write(f"{base}/one/locks/state.golden.json", '{"changed":true}\n')
        r.commit("one golden")
        planned = r.verify("--changed", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        selection = json.loads(planned.stdout[planned.stdout.index("{\n"):])["selection"]
        self.assertEqual(selection["tests"], [f"{base}/one/one.lock.integration.test.ts"], planned.stdout)
        r.git("branch", "-f", "base")
        r.write(f"{base}/two/locks/other.golden.json", '{"changed":true}\n')
        r.commit("computed-name golden")
        computed = r.verify("--changed", "--plan")
        self.assertEqual(computed.returncode, 0, computed.stdout + computed.stderr)
        self.assertEqual(json.loads(computed.stdout[computed.stdout.index("{\n"):])["selection"]["tests"],
                         [f"{base}/two/two.lock.integration.test.ts"], computed.stdout)
        r.write(f"{base}/two/locks/unread.golden.json", "{}\n")
        r.commit("unread golden")
        refused = r.verify("--changed", "--plan")
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("no lock beside packages/gateway/src/e2e/two/locks/unread.golden.json reads it", refused.stdout + refused.stderr)
        r.git("reset", "-q", "--hard", "base")
        r.git("rm", "-q", f"{base}/one/locks/state.golden.json")
        r.write(f"{base}/one/one.lock.integration.test.ts", "export const inlineChecks = true;\n")
        r.commit("one lock converted")
        converted = r.verify("--changed", "--plan")
        self.assertEqual(converted.returncode, 0, converted.stdout + converted.stderr)
        self.assertEqual(json.loads(converted.stdout[converted.stdout.index("{\n"):])["selection"]["tests"],
                         [f"{base}/one/one.lock.integration.test.ts"], converted.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.git("rm", "-q", f"{base}/one/locks/state.golden.json")
        r.commit("one golden deleted, lock unchanged")
        orphaned = r.verify("--changed", "--plan")
        self.assertEqual(orphaned.returncode, 0, orphaned.stdout + orphaned.stderr)
        self.assertEqual(json.loads(orphaned.stdout[orphaned.stdout.index("{\n"):])["selection"]["tests"],
                         [f"{base}/one/one.lock.integration.test.ts"], orphaned.stdout)

    def test_a_change_to_only_tests_or_goldens_runs_those_tests_and_the_goldens_locks(self) -> None:
        r = self.repo
        r.write("mods/core/test-core-other.py", PASSING)
        r.write("mods/core/locks/state.golden.json", "{}\n")
        r.commit("more core tests")
        r.git("branch", "-f", "base")
        r.write("mods/core/test-core-other.py", PASSING + "REWORDED = True\n")
        r.commit("core test")
        only = r.verify("--changed")
        self.assertEqual(only.returncode, 0, only.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/core/test-core-other.py"])
        r.write("mods/core/locks/state.golden.json", "{\"recorded\": true}\n")
        r.write("mods/core/test-core.lock.py", FAILING)
        r.commit("golden and its lock")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/core/test-core-other.py", "mods/core/test-core.lock.py"])
        self.assertIn("AssertionError: 1 != 2", failed.stdout)
        r.git("reset", "-q", "--hard", "base")
        r.write("mods/core/test-core-other.py", PASSING + "REWORDED = True\n")
        r.write("mods/core/core.py", "VALUE = 'kernel change'\n")
        r.commit("core code and test")
        widened = r.verify("--changed", "--plan")
        self.assertIn("widened to every lock", widened.stdout)
        self.assertIn("repo/core: owns a changed path; its 2 owned test file(s)", widened.stdout)


class ContractTests(VerifyCase):
    def test_one_run_names_every_red_step_with_the_first_first(self) -> None:
        r = self.repo
        r.write("mods/alpha/alpha.py", "VALUE = 'alpha' \n")
        r.write("mods/alpha/test-alpha.py", FAILING)
        r.commit("a whitespace red and a test red")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("verify: FAILED — git diff --check failed; tests: python failed", failed.stdout)
        steps = {step["name"]: step["status"] for step in r.report()["steps"]}
        self.assertEqual((steps["git diff --check"], steps["tests: python"]), ("failed", "failed"))

    def test_a_runner_group_that_runs_zero_tests_fails(self) -> None:
        r = self.repo
        r.write("mods/beta/test-beta.py", "import unittest\nunittest.main()\n")
        r.commit("empty beta tests")
        result = r.verify("--module", "repo/beta")
        self.assertEqual(result.returncode, 1, result.stdout)
        report = r.report()
        self.assertEqual(report["verdict"], "failed")
        self.assertEqual(report["passingTests"], 0)
        runner = next(step for step in report["steps"] if step["name"] == "tests: python")
        self.assertEqual(runner["status"], "failed")
        self.assertIn(runner["exit"], (0, 5))
        self.assertEqual(runner["tests"], 0 if runner["exit"] == 0 else None)

    def test_uncommitted_tree_is_refused_and_results_are_reproducible(self) -> None:
        r = self.repo
        r.write("mods/beta/beta.py", "VALUE = 'beta change'\n")
        refused = r.verify("--changed")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("commit first", refused.stderr)
        r.commit("beta change")
        digests = []
        for _ in range(2):
            self.assertEqual(r.verify("--module", "repo/beta").returncode, 0)
            digests.append(r.report()["resultDigest"])
        self.assertEqual(digests[0], digests[1])
        self.assertEqual(r.report()["passingTests"], 1)


IOS_TEST_STUB = r"""#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >>"$FIXTURE_IOS_CALLS"
if [[ "${FIXTURE_IOS_BUSY:-}" == "$1" && "$*" == *"${FIXTURE_IOS_BUSY_IN:-}"* ]]; then echo 'host slot wait expired; deferred'; exit 73; fi
# A run's wall-clock span, for proving that shards on different lanes overlap.
if [[ "$1" == run && -n "${FIXTURE_IOS_PIDS:-}" ]]; then echo "$$" >>"$FIXTURE_IOS_PIDS"; fi
if [[ "$1" == run && -n "${FIXTURE_IOS_SECONDS:-}" ]]; then
  begun="$(python3 -c 'import time; print(time.time())')"; sleep "$FIXTURE_IOS_SECONDS"
  echo "$begun $(python3 -c 'import time; print(time.time())') $*" >>"$FIXTURE_IOS_SPANS"
fi
case "$1" in
  build)
    mkdir -p "$TRON_IOS_TEST_DERIVED_DATA/Build/Products"
    find "$root/packages/ios-app" -name '*.swift' | sort | xargs xcrun swiftc -module-name App -parse-as-library \
      -emit-library -o "$TRON_IOS_TEST_DERIVED_DATA/App.dylib" -index-store-path "$TRON_IOS_TEST_DERIVED_DATA/Index.noindex/DataStore"
    python3 "$root/scripts/ios-test-build-identity.py" show --worktree "$root" \
      | python3 "$root/scripts/ios-test-build-identity.py" write --worktree "$root" --derived-data "$TRON_IOS_TEST_DERIVED_DATA"
    echo "Reusable iOS test products ready" ;;
  run)
    dir="$(mktemp -d "$TMPDIR/ios-run.XXXXXX")"
    selected=$(grep -o -- '--only-testing' <<<"$*" | wc -l | tr -d ' ')
    passed="${FIXTURE_IOS_PASSED:-$selected}"
    if [[ -n "${FIXTURE_IOS_FAIL:-}" && "$*" == *"${FIXTURE_IOS_FAIL_IN:-}"* ]]; then
      printf '{"passedTests":0,"failedTests":1,"testFailures":[{"testIdentifierString":"%s","failureText":"a11y differs"}]}' "$FIXTURE_IOS_FAIL" >"$dir/summary.json"
      echo "iOS test run failed with status 65: $dir" >&2; exit 65
    fi
    printf '{"passedTests":%s,"failedTests":0}' "$passed" >"$dir/summary.json"
    echo "iOS test run complete: $dir" ;;
esac
"""


E2E_STUB = r"""#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ui_owned_journeys=(
  'TronMobileUITests/RealGatewayPairAndChatUITests/testPairLight'
  'TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsDark'
)
echo "$* lanes=${TRON_IOS_E2E_UI_LANES:-1}" >>"$FIXTURE_E2E_CALLS"
[[ "$1" == run-ui ]] || exit 2
shift
revision="${FIXTURE_E2E_REVISION:-$(git -C "$root" rev-parse HEAD)}"
status=0
while (($#)); do
  journey="$2"; shift 2
  dir="$(mktemp -d "$TMPDIR/e2e-ui.XXXXXX")"
  code=0; [[ "$journey" == *"${FIXTURE_E2E_FAIL:-none}" ]] && code=65
  python3 - "$dir" "$journey" "$code" "$revision" <<'PY'
import hashlib, json, sys
from pathlib import Path
directory, journey, code, revision = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
report = {"schema": "tron.ios-e2e-ui-journey.v1", "journey": journey, "journey_status": code, "journey_seconds": 1,
          "evidence_complete": True, "source": {"revision": revision, "dirty": False}, "artifacts": []}
(directory / "report.json").write_text(json.dumps(report))
digest = hashlib.sha256((directory / "report.json").read_bytes()).hexdigest()
(directory / "report.sha256").write_text(f"{digest}  report.json\n")
PY
  echo "Real-UI journey $journey completed in 1s (status $code); evidence: $dir"
  ((code == 0)) || status=$code
done
exit "$status"
"""


class IosLaneTests(VerifyCase):
    def ios_fixture(self) -> Path:
        """An app module, a UI-tests module whose spawn edge reaches it, and the stand-in lane; returns its call log."""
        r = self.repo
        products = Path(self.temp.name) / "products"
        calls = Path(self.temp.name) / "ios-calls.txt"
        (Path(self.temp.name) / "ios-runs").mkdir()
        r.env.update(TRON_IOS_TEST_DERIVED_DATA=str(products), FIXTURE_IOS_CALLS=str(calls),
                     TRON_IOS_TEST_RESULTS_DIR=str(Path(self.temp.name) / "ios-runs"))
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"] += ["scripts/tron-ios-test", "scripts/ios-test-lock.py"]
        r.write("tooling.module.json", json.dumps(tooling))
        slots = next(line for line in (ROOT / "scripts/ios-test-lock.py").read_text().splitlines() if line.startswith("HOST_SLOTS = "))
        r.write("scripts/ios-test-lock.py", slots + "\n")
        r.write("packages/ios-app/scripts/test-source-policy.sh", "#!/bin/sh\nexit ${FIXTURE_IOS_POLICY_EXIT:-0}\n")
        (r.path / "packages/ios-app/scripts/test-source-policy.sh").chmod(0o755)
        r.write("scripts/tron-ios-test", IOS_TEST_STUB)
        (r.path / "scripts/tron-ios-test").chmod(0o755)
        ios = "packages/ios-app"
        r.write(f"{ios}/package.module.json", json.dumps({"layer": "L5", "owns": ["*.json", "scripts/**"]}))
        r.write(f"{ios}/Sources/UI/Chat/chat.module.json", json.dumps({"layer": "L4", "owns": ["**"]}))
        r.write(f"{ios}/Sources/UI/Chat/ChatView.swift", "struct ChatView {}\n")
        r.write(f"{ios}/UITests/ui-tests.module.json", json.dumps({"layer": "L5", "owns": ["**"], "dynamicEdges": [
            {"to": "ios-app/chat", "kind": "spawn", "via": f"{ios}/package.module.json", "why": "launches the app"}]}))
        r.write(f"{ios}/UITests/Locks/FixtureLockTests.swift", "class FixtureLockTests {}\n")
        r.write(f"{ios}/UITests/FixtureJourneyUITests.swift", "class FixtureJourneyUITests {}\n")
        r.write(f"{ios}/UITests/TronMacTerminalUITests.swift", "class TronMacTerminalUITests {}\n")
        r.commit("ios fixture")
        r.git("branch", "-f", "base")
        return calls

    def test_ios_change_builds_once_checks_references_and_runs_only_the_ui_locks(self) -> None:
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app"
        r.write(f"{ios}/Sources/UI/Chat/ChatView.swift", "struct ChatView { let title = \"Chat\" }\n")
        r.commit("chat change")

        digests = []
        for _ in range(2):
            result = r.verify("--changed")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = r.report()
            digests.append(report["resultDigest"])
            self.assertEqual(report["selection"]["tests"], [f"{ios}/UITests/Locks/FixtureLockTests.swift"])
            steps = {step["name"]: step for step in report["steps"]}
            self.assertEqual((steps["ios source policy"]["status"], steps["ios build"]["status"], steps["layers ios"]["status"],
                              steps["tests: ios"]["tests"]), ("ok", "ok", "ok", 1))
        self.assertEqual(digests[0], digests[1])
        self.assertIn("already stamped for this commit", steps["ios build"]["detail"])
        self.assertEqual(calls.read_text().splitlines(), ["build --host-slot-wait-seconds 30", "run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureLockTests",
                                                          "run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureLockTests"])

        failed = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                                env={**r.env, "FIXTURE_IOS_FAIL": "TronMobileUITests/FixtureLockTests/testChat()"},
                                capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("tests: ios FAILED", failed.stdout)
        self.assertIn("failed: TronMobileUITests/FixtureLockTests/testChat(): a11y differs", failed.stdout)
        empty = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                               env={**r.env, "FIXTURE_IOS_PASSED": "0"}, capture_output=True, text=True)
        self.assertEqual(empty.returncode, 1, empty.stdout)
        self.assertIn("tests: ios ran zero passing tests", empty.stdout)
        calls.write_text("")
        policy = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                                env={**r.env, "FIXTURE_IOS_POLICY_EXIT": "1"}, capture_output=True, text=True)
        self.assertEqual(policy.returncode, 1, policy.stdout)
        self.assertIn("verify: FAILED — ios source policy failed", policy.stdout)
        self.assertEqual(calls.read_text().splitlines(), ["run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureLockTests"],
                         "a static red still runs the selected tests, so one run names every red")
        calls.write_text("")
        module = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(module.returncode, 1, module.stdout)
        self.assertIn("selected tests were not run: ios-lanes", module.stdout)
        self.assertEqual(calls.read_text().splitlines(), [
            "run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureJourneyUITests --only-testing TronMobileUITests/FixtureLockTests"])

    def test_source_module_baseline_runs_the_ui_locks_that_launch_it_not_its_consumers(self) -> None:
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app"
        r.write(f"{ios}/Sources/State/state.module.json", json.dumps({"layer": "L2", "owns": ["**"]}))
        r.write(f"{ios}/Sources/State/SessionState.swift", "struct SessionState {}\n")
        r.write(f"{ios}/Sources/UI/Chat/chat.module.json", json.dumps({
            "layer": "L4", "owns": ["**"], "dependsOn": ["ios-app/state"]}))
        r.commit("source-only kernel module consumed by hosted chat")
        unlaunched = r.verify("--module", "ios-app/state")
        self.assertEqual(unlaunched.returncode, 1, unlaunched.stdout)
        self.assertIn("zero tests ran: an empty selection is not evidence", unlaunched.stdout)
        self.assertEqual(r.report()["selection"]["tests"], [])
        calls.write_text("")
        manifest = json.loads((r.path / f"{ios}/UITests/ui-tests.module.json").read_text())
        manifest["dynamicEdges"].append({"to": "ios-app/state", "kind": "spawn", "via": f"{ios}/package.module.json", "why": "launches the app"})
        r.write(f"{ios}/UITests/ui-tests.module.json", json.dumps(manifest))
        r.commit("the UI tests launch the state module")

        baseline = r.verify("--module", "ios-app/state")
        self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)
        report = r.report()
        self.assertEqual(report["selection"]["tests"], [f"{ios}/UITests/Locks/FixtureLockTests.swift"])
        self.assertEqual(report["passingTests"], 1)
        self.assertEqual(calls.read_text().splitlines(), [
            "build --host-slot-wait-seconds 30", "run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureLockTests"])
        self.assertNotIn("widened to every lock", baseline.stdout)
        recording = r.verify("--update-locks", "ios-app/state", "--plan")
        self.assertEqual(recording.returncode, 0, recording.stderr)
        self.assertIn('"tests": []', recording.stdout)
        r.env["FIXTURE_IOS_FAIL"] = "TronMobileUITests/FixtureLockTests/testChat()"
        failed = r.verify("--module", "ios-app/state")
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("failed: TronMobileUITests/FixtureLockTests/testChat(): a11y differs", failed.stdout)

    def test_a_real_gateway_journey_change_runs_its_journeys_through_their_harness(self) -> None:
        """#2365: a changed real-UI journey runs, by exact selector, through `ios-gateway-e2e-test
        run-ui`; each journey's report.json for this commit is the step's evidence."""
        r = self.repo
        self.ios_fixture()
        calls = Path(self.temp.name) / "e2e-calls.txt"
        r.env["FIXTURE_E2E_CALLS"] = str(calls)
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"] += ["scripts/ios-gateway-e2e-test"]
        r.write("tooling.module.json", json.dumps(tooling))
        r.write("scripts/ios-gateway-e2e-test", E2E_STUB)
        (r.path / "scripts/ios-gateway-e2e-test").chmod(0o755)
        journeys = "packages/ios-app/UITests/RealGateway"
        r.write(f"{journeys}/RealGatewayPairAndChatUITests.swift",
                "class RealGatewayPairAndChatUITests {\n    func testPairLight() {}\n    func launch() {}\n}\n")
        r.write(f"{journeys}/RealGatewayBuildsUITests.swift",
                "extension RealGatewayPairAndChatUITests {\n    func testBuildsDark() {}\n}\n")
        r.commit("journeys")
        r.git("branch", "-f", "base")
        r.write(f"{journeys}/RealGatewayBuildsUITests.swift",
                "extension RealGatewayPairAndChatUITests {\n    func testBuildsDark() { _ = 1 }\n}\n")
        r.commit("one journey changes")
        sha = r.git("rev-parse", "HEAD").strip()

        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        report = r.report()
        self.assertEqual(report["verdict"], "passed")
        step = next(step for step in report["steps"] if step["name"] == "tests: ios-journeys")
        self.assertEqual((step["status"], step["tests"]), ("ok", 1))
        [evidence] = step["journeyReports"]
        self.assertEqual((evidence["journey"], evidence["status"], evidence["revision"]),
                         ("TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsDark", 0, sha))
        self.assertEqual(evidence["sha256"], hashlib.sha256(Path(evidence["report"]).read_bytes()).hexdigest())
        self.assertEqual(calls.read_text().splitlines(),
                         ["run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsDark lanes=1"])

        failed = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                                env={**r.env, "FIXTURE_E2E_FAIL": "testBuildsDark"}, capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1, failed.stdout)
        step = next(step for step in r.report()["steps"] if step["name"] == "tests: ios-journeys")
        self.assertEqual(step["failedTests"], ["TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsDark"])
        stale = subprocess.run([str(r.path / "scripts/tron"), "verify", "--base", "base", "--changed"], cwd=r.path,
                               env={**r.env, "FIXTURE_E2E_REVISION": "0" * 40}, capture_output=True, text=True)
        self.assertEqual(stale.returncode, 1, stale.stdout)
        self.assertIn("no passing report for this commit", stale.stdout)

        calls.write_text("")
        r.write(f"{journeys}/RealGatewayPairAndChatUITests.swift",
                "class RealGatewayPairAndChatUITests {\n    func testPairLight() {}\n    func launch() { _ = 2 }\n}\n")
        r.commit("shared helper changes")
        every = r.verify("--changed")
        self.assertEqual(every.returncode, 0, every.stdout + every.stderr)
        self.assertEqual(calls.read_text().splitlines(), [
            "run-ui --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testBuildsDark"
            " --only-testing TronMobileUITests/RealGatewayPairAndChatUITests/testPairLight lanes=2"])
        calls.write_text("")
        r.write(f"{journeys}/RealGatewayHelpersUITests.swift", "extension RealGatewayPairAndChatUITests {\n    func reveal() {}\n}\n")
        r.commit("shared extension helper")
        helpers = r.verify("--changed")
        self.assertEqual(helpers.returncode, 0, helpers.stdout + helpers.stderr)
        self.assertEqual(calls.read_text().splitlines()[-1].rsplit(" ", 1)[-1], "lanes=2")
        skipped = r.verify("--changed", "--skip", "ios")
        self.assertEqual(r.report()["steps"][-1]["status"], "skipped", skipped.stdout)
        calls.write_text("")
        r.write(f"{journeys}/RealGatewayHelpersUITests.swift", "extension RealGatewayPairAndChatUITests {\n    func reveal( {}\n}\n")
        r.commit("a journey helper that does not compile")
        broken = r.verify("--changed")
        self.assertEqual(broken.returncode, 1, broken.stdout)
        self.assertIn("verify: FAILED — ios build failed", broken.stdout)
        steps = {step["name"]: step for step in r.report()["steps"]}
        self.assertEqual((steps["tests: ios-journeys"]["status"], steps["tests: ios-journeys"]["reason"]), ("skipped", "ios build failed"))
        self.assertEqual(calls.read_text(), "", "no journey runs on a source that does not build")

    def test_an_extension_file_runs_as_the_class_it_extends(self) -> None:
        """#1522: a file that extends another file's XCTestCase class runs as that class, in that class's lane."""
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app/UITests"
        r.write(f"{ios}/FixtureJourneyMoreUITests.swift", "extension FixtureJourneyUITests {}\n")
        r.write(f"{ios}/TronMacTerminalMoreUITests.swift", "extension TronMacTerminalUITests {}\n")
        r.commit("extension files")
        module = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(module.returncode, 1, module.stdout + module.stderr)
        self.assertIn("ios-lanes: 2 file(s)", module.stdout)
        self.assertEqual(calls.read_text().splitlines()[-1],
                         "run --host-slot-wait-seconds 30 --only-testing TronMobileUITests/FixtureJourneyUITests --only-testing TronMobileUITests/FixtureLockTests")
        r.write(f"{ios}/StrayUITests.swift", "struct Helper {}\n")
        r.commit("stray")
        refused = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("StrayUITests.swift declares or extends no XCTestCase class", refused.stderr)
        skipped = r.verify("--module", "ios-app/ui-tests", "--skip", "ios", "--plan")
        self.assertEqual(skipped.returncode, 0, skipped.stderr)

    def test_ipad_only_methods_run_in_their_own_shards_on_the_worktrees_ipad_lane(self) -> None:
        """#2331: a test that skips unless on an iPad (in itself, its class's setUp or a helper it
        calls) runs on this worktree's iPad lane, never alone on the iPhone lane where its shard
        passes nothing; iPhone methods stay on the default lane."""
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app/UITests"
        gate = "try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, \"iPad\")"
        r.write(f"{ios}/FixtureJourneyUITests.swift", "final class FixtureJourneyUITests: XCTestCase {\n"
                f"    @MainActor func testPadReturn() throws {{\n        {gate}\n    }}\n"
                "    @MainActor func testPhoneReturn() throws {\n        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, \"iPhone\")\n    }\n"
                "    func testWindowed() throws {\n        try windowed()\n    }\n"
                f"    private func windowed() throws {{\n        {gate}\n    }}\n}}\n")
        r.write(f"{ios}/FixturePadUITests.swift", "final class FixturePadUITests: XCTestCase {\n"
                f"    override func setUpWithError() throws {{\n        {gate}\n    }}\n"
                "    func testColumn() {}\n}\n")
        r.commit("ipad-only journeys")
        planned = r.verify("--module", "ios-app/ui-tests", "--plan")
        plan = json.loads(planned.stdout[planned.stdout.index("{"):])
        commands = {c["name"]: " ".join(c["command"][1:]) for c in plan["commands"] if c["name"].startswith("tests: ios") and "command" in c}
        journey, pad = "TronMobileUITests/FixtureJourneyUITests", "TronMobileUITests/FixturePadUITests"
        lane = "--lane verify-ipad-" + hashlib.sha256(str(r.path.resolve()).encode()).hexdigest()[:12] + " --device-type iPad Pro 13-inch (M5)"
        iphone = [command for command in commands.values() if f"{journey}/testPhoneReturn" in command]
        self.assertEqual(len(iphone), 1, commands)
        self.assertNotIn("--lane", iphone[0])
        for method in (f"{journey}/testPadReturn", f"{journey}/testWindowed", f"{pad}/testColumn"):
            owning = [command for command in commands.values() if method in command]
            self.assertEqual(len(owning), 1, commands)
            self.assertIn(lane, owning[0], f"{method} must run on the iPad lane: {owning[0]}")
            self.assertNotIn(f"{journey}/testPhoneReturn", owning[0])

    def test_a_class_larger_than_one_shard_runs_every_method_in_bounded_processes_on_concurrent_lanes(self) -> None:
        """#2173: a selected class runs as method shards, each its own runner process under the
        unchanged deadline, packed by the longest time this Mac's runner logs record for each method
        (unmeasured methods three to a process), on one lane per host slot at once. A red shard does
        not stop the rest; a lane refused a slot beside the run's others requeues its shard, only a
        refusal with nothing else in flight defers it and the rest, and SIGTERM stops every lane."""
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app/UITests"
        import importlib.util
        spec = importlib.util.spec_from_file_location("shipped_verify", ROOT / "tools/verify/verify.py")
        shipped = importlib.util.module_from_spec(spec); spec.loader.exec_module(shipped)
        methods = [f"testCase{index}" for index in range(5)]
        split = 2
        body = "\n".join(f"    @MainActor func {name}() {{}}" for name in methods[:split])
        r.write(f"{ios}/FixtureJourneyUITests.swift", "final class FixtureJourneyUITests {\n"
                + body + "\n    private func testHelper() {}\n    func testWithArgument(_ value: Int) {}\n}\n")
        r.write(f"{ios}/FixtureJourneyMoreUITests.swift", "extension FixtureJourneyUITests {\n"
                + "\n".join(f"    func {name}() {{}}" for name in methods[split:]) + "\n}\nstruct Other {\n    func testNotAMethodOfTheClass() {}\n}\n")
        (r.path / f"{ios}/TronMacTerminalUITests.swift").unlink()
        r.commit("a large class")
        owner, lock = "TronMobileUITests/FixtureJourneyUITests", "TronMobileUITests/FixtureLockTests"
        ordered = methods[split:] + methods[:split]
        selectors = lambda names: " ".join(f"--only-testing {owner}/{name}" for name in names)  # noqa: E731
        lane = lambda kind: f"verify-{kind}-" + hashlib.sha256(str(r.path.resolve()).encode()).hexdigest()[:12]  # noqa: E731

        def planned_shards() -> list[str]:
            planned = r.verify("--module", "ios-app/ui-tests", "--plan")
            plan = json.loads(planned.stdout[planned.stdout.index("{"):])
            return [" ".join(c["command"][2:]) for c in plan["commands"] if c["name"].startswith("tests: ios") and "command" in c]

        self.assertEqual(planned_shards(), [f"--host-slot-wait-seconds 30 {selectors(ordered[:3])}",
                                            f"--host-slot-wait-seconds 30 {selectors(ordered[3:])}",
                                            f"--host-slot-wait-seconds 30 --only-testing {lock}"])

        spans = Path(self.temp.name) / "spans.txt"
        red = ordered[0]
        r.env.update(FIXTURE_IOS_SECONDS="2", FIXTURE_IOS_SPANS=str(spans),
                     FIXTURE_IOS_FAIL=f"{owner}/{red}()", FIXTURE_IOS_FAIL_IN=f"{owner}/{red} ")
        result = r.verify("--module", "ios-app/ui-tests", "--skip", "mac")
        runs = [line for line in calls.read_text().splitlines() if line.startswith("run ")]
        self.assertEqual(sorted(runs), sorted([
            f"run --host-slot-wait-seconds 30 {selectors(ordered[:3])}",
            f"run --lane {lane('iphone2')} --host-slot-wait-seconds 0 --only-testing {lock}",
            f"run --lane {lane('iphone3')} --host-slot-wait-seconds 0 {selectors(ordered[3:])}"]), result.stdout)
        bounds = [line.split()[:2] for line in spans.read_text().splitlines()]
        self.assertLess(max(float(begun) for begun, _ in bounds), min(float(ended) for _, ended in bounds),
                        f"the three shards must overlap: {bounds}")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tests: ios 1/3 FAILED", result.stdout)
        self.assertIn(f"failed: {owner}/{red}(): a11y differs", result.stdout)
        self.assertIn("tests: ios 2/3 OK", result.stdout)
        self.assertIn("tests: ios 3/3 OK", result.stdout)
        self.assertEqual([step["name"] for step in r.report()["steps"] if step["name"].startswith("tests: ios")],
                         ["tests: ios 1/3", "tests: ios 2/3", "tests: ios 3/3"])
        r.env.pop("FIXTURE_IOS_FAIL"); r.env.pop("FIXTURE_IOS_FAIL_IN")

        calls.write_text("")
        r.env.update(FIXTURE_IOS_BUSY="run", FIXTURE_IOS_BUSY_IN=lane("iphone2"))
        requeued = r.verify("--module", "ios-app/ui-tests", "--skip", "mac")
        self.assertEqual(requeued.returncode, 0, requeued.stdout + requeued.stderr)
        self.assertIn("requeued", requeued.stdout)
        self.assertEqual(r.report()["verdict"], "passed")
        self.assertEqual(r.report()["passingTests"], len(methods) + 1)
        locks = [line for line in calls.read_text().splitlines() if line.endswith(f"--only-testing {lock}")]
        self.assertIn(f"--lane {lane('iphone2')} --host-slot-wait-seconds 0", locks[0], calls.read_text())
        self.assertNotIn(lane("iphone2"), locks[-1], calls.read_text())

        r.env.update(FIXTURE_IOS_BUSY_IN=f"{owner}/{ordered[3]} ")
        deferred = r.verify("--module", "ios-app/ui-tests", "--skip", "mac")
        steps = {step["name"]: step["status"] for step in r.report()["steps"]}
        self.assertEqual([steps[f"tests: ios {index}/3"] for index in (1, 2, 3)], ["ok", "deferred", "ok"], deferred.stdout)
        self.assertEqual(r.report()["verdict"], "deferred", deferred.stdout)

        results = Path(self.temp.name) / "ios-runs"
        case = lambda name, outcome, seconds: f"Test Case '-[TronMobileUITests.FixtureJourneyUITests {name}]' {outcome} ({seconds} seconds).\n"  # noqa: E731
        (results / "a-run.1").mkdir()
        (results / "a-run.1/test.log").write_text(case(ordered[0], "passed", "0.5") + case(ordered[1], "passed", "0.5")
                                                 + case(ordered[2], "passed", shipped.IOS_SHARD_SECONDS + 100))
        (results / "b-run.2").mkdir()
        (results / "b-run.2/test.log").write_text(case(ordered[1], "failed", shipped.IOS_SHARD_SECONDS) + case(ordered[3], "passed", "0.5"))
        self.assertEqual(planned_shards(), [f"--host-slot-wait-seconds 30 {selectors(ordered[:1])}",
                                            f"--host-slot-wait-seconds 30 {selectors(ordered[1:2])}",
                                            f"--host-slot-wait-seconds 30 {selectors(ordered[2:3])}",
                                            f"--host-slot-wait-seconds 30 {selectors(ordered[3:])}",
                                            f"--host-slot-wait-seconds 30 --only-testing {lock}"])
        calls.write_text("")
        r.env.update(FIXTURE_IOS_BUSY_IN="")
        refused = r.verify("--module", "ios-app/ui-tests", "--skip", "mac")
        self.assertEqual(refused.returncode, 0, refused.stdout + refused.stderr)
        self.assertEqual(r.report()["verdict"], "deferred", refused.stdout)
        self.assertEqual({step["status"] for step in r.report()["steps"] if step["name"].startswith("tests: ios")}, {"deferred"})
        self.assertEqual(len([step for step in r.report()["steps"] if step["name"].startswith("tests: ios")]), 5)
        r.env.pop("FIXTURE_IOS_BUSY"); r.env.pop("FIXTURE_IOS_BUSY_IN")
        for item in results.iterdir():
            shutil.rmtree(item)

        pids = Path(self.temp.name) / "pids.txt"
        calls.write_text("")
        r.env.update(FIXTURE_IOS_SECONDS="120", FIXTURE_IOS_PIDS=str(pids))
        process = subprocess.Popen([str(r.path / "scripts/tron"), "verify", "--base", "base", "--module", "ios-app/ui-tests",
                                    "--skip", "mac"], cwd=r.path, env=r.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 60
            while (not pids.exists() or len(pids.read_text().split()) < 3) and time.monotonic() < deadline:
                time.sleep(.05)
            started = [int(pid) for pid in pids.read_text().split()]
            self.assertEqual(len(started), 3, "every lane's shard must start before the signal")
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertEqual(process.returncode, 130, output)
        self.assertEqual(r.report()["verdict"], "interrupted", output)
        self.assertEqual(sorted(step["status"] for step in r.report()["steps"] if step["name"].startswith("tests: ios")),
                         ["interrupted"] * 3, output)
        for pid in started:
            with self.assertRaises(ProcessLookupError, msg=f"shard runner {pid} outlived verify"):
                os.kill(pid, 0)
        self.assertEqual(len([line for line in calls.read_text().splitlines() if line.startswith("run ")]), 3)
        r.env.pop("FIXTURE_IOS_SECONDS"); r.env.pop("FIXTURE_IOS_PIDS")

        r.env.update(FIXTURE_IOS_PASSED="2")
        short = r.verify("--module", "ios-app/ui-tests", "--skip", "mac")
        self.assertEqual(short.returncode, 1, short.stdout)
        self.assertIn("tests: ios 1/3 passed 2 of its 3 named test(s)", short.stdout)
        r.env.pop("FIXTURE_IOS_PASSED")

        r.write(f"{ios}/FixtureJourneyMoreUITests.swift", "extension FixtureJourneyUITests {\n    let text = \"\"\"\nunplaced\n    \"\"\"\n"
                + "\n".join(f"    func {name}() {{}}" for name in methods[split:]) + "\n}\n")
        r.commit("an unreadable extension")
        planned = r.verify("--module", "ios-app/ui-tests", "--plan")
        plan = json.loads(planned.stdout[planned.stdout.index("{"):])
        self.assertEqual([step for step in plan["steps"] if step.startswith("tests: ios")], ["tests: ios"])
        self.assertIn(f"--only-testing {owner} ", " ".join(next(c["command"] for c in plan["commands"] if c["name"] == "tests: ios")) + " ")
        r.write(f"{ios}/FixtureJourneyMoreUITests.swift", "extension FixtureJourneyUITests {\n"
                + "\n".join(f"    func {name}() {{}}" for name in methods[split:]) + "\n    nonisolated func testSpelledDifferently() {}\n}\n")
        r.commit("a differently spelled test")
        planned = r.verify("--module", "ios-app/ui-tests", "--plan")
        plan = json.loads(planned.stdout[planned.stdout.index("{"):])
        self.assertEqual([step for step in plan["steps"] if step.startswith("tests: ios")], ["tests: ios"])


FAKE_RUNNER = """#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--outputFile="))
with open("runs.jsonl", "a") as runs:
    runs.write(json.dumps({"home": os.environ["HOME"], "held": os.environ.get("TRON_FULL_GATEWAY_LOCK_HELD"),
                           "pid": os.getpid()}) + "\\n")
if os.environ.get("FIXTURE_IGNORE_TERM"):
    import signal
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
source = pathlib.Path("src/store/store.ts").read_text()
if "hang = false" in source:
    child = subprocess.Popen(["sleep", "300"])
    pathlib.Path("hung.pid").write_text(f"{child.pid}\\n")
    time.sleep(300)
time.sleep(float(os.environ.get("FIXTURE_RUN_SECONDS", "0")))
failed = 0 if "1 === 1" in source else 1
pathlib.Path(out).write_text(json.dumps({"numFailedTests": failed, "numFailedTestSuites": 0, "numPassedTests": 1 - failed}))
"""
SOURCE = "export const kill = 1 === 1;\nexport const hang = true;\n"


class StepStopTests(unittest.TestCase):
    def test_stopping_a_step_that_exited_before_it_was_reaped_settles_it_interrupted(self) -> None:
        """#2389: macOS answers killpg on a group whose members all exited but are not yet reaped
        with EPERM; an interrupt in that window still settles the step instead of crashing verify."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("shipped_verify", ROOT / "tools/verify/verify.py")
        shipped = importlib.util.module_from_spec(spec); spec.loader.exec_module(shipped)
        run = shipped.Run(f"step-stop-{os.getpid()}-{time.time_ns()}", 1)
        self.addCleanup(shutil.rmtree, run.logs, ignore_errors=True)
        launched = run.launch(1, "exits", ["true"])
        self.addCleanup(launched.process.wait)
        deadline = time.monotonic() + 30
        while not subprocess.run(["ps", "-o", "stat=", "-p", str(launched.process.pid)], capture_output=True,
                                 text=True).stdout.startswith("Z"):
            self.assertLess(time.monotonic(), deadline, "the step never exited")
            time.sleep(0.05)
        run.stop([launched])
        self.assertEqual(launched.result["status"], "interrupted")


class MutateTests(VerifyCase):
    def setUp(self) -> None:
        super().setUp()
        r = self.repo
        r.write("scripts/tron-node", '#!/bin/bash\n[[ $# == 0 ]] && { echo /usr/bin/true; exit 0; }\nshift; exec "$@"\n')
        (r.path / "scripts/tron-node").chmod(0o755)
        r.write("packages/gateway/node_modules/.bin/vitest", FAKE_RUNNER)
        (r.path / "packages/gateway/node_modules/.bin/vitest").chmod(0o755)
        r.write("packages/gateway/src/store/store.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/src/store/store.ts", SOURCE)
        r.write("packages/gateway/src/store/store.lock.integration.test.ts", "export const fakedByTronNode = true;\n")
        r.write(".gitignore", "test-results/\npackages/gateway/hung.pid\npackages/gateway/runs.jsonl\n"
                "packages/gateway/node_modules/\n")
        manifest = json.loads((r.path / "tooling.module.json").read_text())
        manifest["owns"].append("scripts/tron-node")
        r.write("tooling.module.json", json.dumps(manifest))
        r.commit("gateway store")
        self.seed = next(seed for seed in range(100) if (lambda pool: (random.Random(seed).shuffle(pool), pool)[1])([0, 1]) == [0, 1])

    def mutate(self, *args: str, env: dict | None = None) -> subprocess.Popen:
        return subprocess.Popen([str(self.repo.path / "scripts/tron"), "mutate", "packages/gateway/src/store/store.ts",
                                 "--seed", str(self.seed), *args], cwd=self.repo.path, env={**self.repo.env, **(env or {})},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def report(self) -> dict:
        return json.loads((self.repo.path / "test-results/mutate/packages__gateway__src__store__store.ts.json").read_text())

    def assert_hung_child_stopped(self) -> None:
        pid = int((self.repo.path / "packages/gateway/hung.pid").read_text())
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.1)
        self.fail(f"the hung lock's child {pid} outlived its mutant")

    def test_a_hanging_mutant_times_out_and_counts_as_detected(self) -> None:
        started = time.time()
        process = self.mutate("--timeout", "1", env={"FIXTURE_RUN_SECONDS": "2"})
        output, _ = process.communicate(timeout=120)
        self.assertEqual(process.returncode, 0, output)
        self.assertLess(time.time() - started, 60, output)
        report = self.report()
        self.assertEqual([(m["line"], m["outcome"]) for m in report["mutants"]], [(1, "killed"), (2, "timeout")])
        self.assertEqual((report["killed"], report["timeouts"], report["rate"], report["complete"]), (2, 1, 1.0, True))
        self.assertIn("TIMEOUT", output)
        self.assertEqual((self.repo.path / "packages/gateway/src/store/store.ts").read_text(), SOURCE)
        self.assert_hung_child_stopped()
        runs = [json.loads(line) for line in (self.repo.path / "packages/gateway/runs.jsonl").read_text().splitlines()]
        self.assertEqual([run["home"] for run in runs if Path(run["home"]).exists()], [])

    def test_an_interrupted_run_restores_the_source_and_keeps_finished_mutants(self) -> None:
        process = self.mutate("--timeout", "120")
        pid_file = self.repo.path / "packages/gateway/hung.pid"
        deadline = time.time() + 60
        while not pid_file.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(pid_file.exists(), "the hanging mutant never started")
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        self.assertEqual((self.repo.path / "packages/gateway/src/store/store.ts").read_text(), SOURCE)
        report = self.report()
        self.assertEqual(([(m["line"], m["outcome"]) for m in report["mutants"]], report["complete"]), ([(1, "killed")], False))
        self.assert_hung_child_stopped()

    def test_an_interrupt_during_the_unmutated_run_stops_its_group(self) -> None:
        process = self.mutate("--timeout", "1", env={"FIXTURE_RUN_SECONDS": "300"})
        runs = self.repo.path / "packages/gateway/runs.jsonl"
        deadline = time.time() + 60
        while not runs.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(runs.exists(), "the unmutated run never started")
        run = json.loads(runs.read_text().splitlines()[0])
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        for _ in range(100):
            try:
                os.kill(run["pid"], 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(run["pid"], signal.SIGKILL)
            self.fail(f"the unmutated run {run['pid']} outlived mutate:\n{output}")
        self.assertFalse(Path(run["home"]).exists(), output)
        self.assertEqual(len(runs.read_text().splitlines()), 1, "no mutant may run after the interrupt")

    def test_a_second_interrupt_during_the_stop_grace_still_kills_the_group(self) -> None:
        process = self.mutate("--timeout", "1", env={"FIXTURE_RUN_SECONDS": "300", "FIXTURE_IGNORE_TERM": "1"})
        runs = self.repo.path / "packages/gateway/runs.jsonl"
        deadline = time.time() + 60
        while not runs.exists() and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(runs.exists(), "the unmutated run never started")
        run = json.loads(runs.read_text().splitlines()[0])
        process.send_signal(signal.SIGTERM)
        time.sleep(2)
        os.kill(run["pid"], 0)
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=60)
        self.assertNotEqual(process.returncode, 0, output)
        for _ in range(100):
            try:
                os.kill(run["pid"], 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(run["pid"], signal.SIGKILL)
            self.fail(f"the unmutated run {run['pid']} outlived a second interrupt during the stop grace:\n{output}")

    def test_mutants_run_through_the_gateway_runner_under_the_host_lock(self) -> None:
        import fcntl
        process = self.mutate("--count", "1", "--timeout", "60")
        output, _ = process.communicate(timeout=120)
        self.assertEqual(process.returncode, 0, output)
        runs = [json.loads(line) for line in (self.repo.path / "packages/gateway/runs.jsonl").read_text().splitlines()]
        self.assertEqual(len(runs), 2, output)
        for run in runs:
            self.assertNotEqual(run["home"], self.repo.env["HOME"])
            self.assertTrue(run["home"].startswith("/tmp/tron-gateway-tests-"), run)
            self.assertEqual(run["held"], "1")
        self.assertIn(f'"purpose": "mutate packages/gateway/src/store/store.ts"', self.repo.lock.read_text())
        with self.repo.lock.open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == "__main__":
    unittest.main(verbosity=2)
