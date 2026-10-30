#!/usr/bin/env python3
"""CLI tests for `scripts/tron verify` (tools/verify/README.md).

Each case copies the real `scripts/tron`, `tools/verify` and the checkers it runs
(`tools/ownership`, `tools/budgets`, `tools/metrics`, `tools/layers`, `tools/work`,
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
   stopped at the per-mutant timeout with its whole process group, and an
   interrupted run restores the source and keeps the mutants it finished.

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
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "test-results" / "verify-cli"
HEALTH_ARTIFACTS = ROOT / "test-results" / "health-cli"
COPIED = ["scripts/tron", "scripts/check-documentation-policy.py", "scripts/check-agent-policy.sh", "scripts/personal-info-guard.sh",
          "scripts/ios-test-build-identity.py", ".github/work.json",
          *[str(p.relative_to(ROOT)) for d in ("tools/verify", "tools/ownership", "tools/budgets", "tools/metrics", "tools/layers", "tools/work", "tools/docs")
            for p in (ROOT / d).glob("*.py")]]
PASSING = "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self):\n        self.assertTrue(True)\nunittest.main()\n"
AGENTS = "# Charter\n\nNever SIGSTOP Gateway-owned work.\n"
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
        self.write(".gitignore", "test-results/\n")
        self.write("tools/verify/known-failures.json", "[]\n")
        self.write("README.md", "# Fixture\n")
        self.write("AGENTS.md", AGENTS)
        # The least guidance the real agent policy accepts: a catalog naming the iOS skill it reads.
        self.write(".agents/README.md", "# Guidance\n\n[tron-ios](skills/tron-ios/SKILL.md)\n")
        self.write(".agents/skills/NOTICE.md", "# Notice\n")
        self.write(".agents/skills/tron-ios/SKILL.md", "---\nname: tron-ios\ndescription: iOS work.\n---\n\n"
                   "Tron Device on LocalDevice. Never install Release or DevicePerformance; signed artifacts are evidence.\n")
        self.write("tooling.module.json", json.dumps({"layer": "L5", "owns": [
            "scripts/tron", "scripts/check-documentation-policy.py", "scripts/check-agent-policy.sh", "scripts/personal-info-guard.sh",
            "scripts/ios-test-build-identity.py", ".github/**", ".agents/**", "tools/**", "README.md", "AGENTS.md", ".gitignore",
            "tooling.module.json"]}))
        for name, layer in (("alpha", "L3"), ("beta", "L3"), ("core", "L1"), ("docs", "L5")):
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

    def health(self, *args: str) -> dict:
        result = subprocess.run([str(self.path / 'scripts/tron'), 'health', '--sha', 'HEAD', *args],
                                cwd=self.path, env=self.env, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return json.loads(result.stdout)

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
    def external(self, name: str, body: str | None = None) -> str:
        r = self.repo
        path = f"scripts/test-{name}.py"
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

    def test_external_consumers_execute_once_for_changed_module_and_all(self) -> None:
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
                for name in ("direct", "dependent"):
                    witness = r.path / "test-results" / name
                    self.assertTrue(witness.exists(), f"declared {name} process never ran: {result.stdout}")
                    self.assertEqual(witness.read_text().splitlines(), ["executed"], "duplicate declarations ran twice")
                self.assertEqual(r.report()["passingTests"], 3)
        # --all's declaration selection is checked without its milestone Gateway/iOS builds.
        planned = r.verify("--all", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        selection = json.loads(planned.stdout[planned.stdout.index("{"):])["selection"]["tests"]
        self.assertEqual(selection, ["scripts/test-dependent.py", "scripts/test-direct.py"])
        # A Markdown-only or test-only change must not run unrelated declarations.
        for relative, content in (("mods/alpha/README.md", "# Alpha\n"), ("mods/alpha/test-alpha.py", PASSING + "# Test-only edit.\n")):
            r.git("branch", "-f", "base")
            r.write(relative, content)
            r.commit("narrow change")
            for name in ("direct", "dependent"):
                (r.path / "test-results" / name).unlink(missing_ok=True)
            result = r.verify("--changed")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((r.path / "test-results/direct").exists())
            self.assertFalse((r.path / "test-results/dependent").exists())

    def test_gateway_declarations_keep_existing_runner_classification(self) -> None:
        r = self.repo
        files = ["src/main.integration.test.ts", "src/nested.integration.test.ts", "src/mac.integration.test.ts",
                 "scripts/contract.test.mjs"]
        for path in files + ["scripts/outside.test.ts"]:
            r.write(f"packages/gateway/{path}", "// Selection-only fixture: never executed as a Gateway test.\n")
        r.write("packages/gateway/consumer.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/vitest.nested.config.ts", 'const nestedTestFiles = ["src/nested.integration.test.ts"];\n')
        r.write("packages/gateway/vitest.mac-terminal.config.ts", 'const macTerminalTestFiles = ["src/mac.integration.test.ts"];\n')
        self.declare("alpha", ["scripts/tron test gateway " + " ".join(files)])
        r.commit("Gateway consumer declarations")
        # Plan-only: classify inputs without running Gateway checks or installing dependencies.
        planned = r.verify("--module", "repo/alpha", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)
        groups = json.loads(planned.stdout[planned.stdout.index("{"):])["groups"]
        for group, path in zip(("gateway", "gateway-nested", "mac", "node-gateway"), files):
            self.assertEqual(groups[group], [f"packages/gateway/{path}"])
        self.declare("alpha", ["scripts/tron test gateway scripts/outside.test.ts"])
        r.commit("unsupported Gateway input")
        refused = r.verify("--module", "repo/alpha", "--plan")
        self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertIn("unsupported verify declaration", refused.stderr)

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
        # A harness-only declaration must remain incomplete unless explicitly skipped.
        r.write("packages/ios-app/UITests/RealGatewayPairAndChatUITests.swift",
                "class RealGatewayPairAndChatUITests: XCTestCase {}\n")
        self.declare("alpha", ["scripts/tron test ios run --only-testing TronMobileUITests/RealGatewayPairAndChatUITests"])
        r.commit("harness-only consumer")
        incomplete = r.verify("--module", "repo/alpha")
        self.assertEqual(incomplete.returncode, 1, incomplete.stdout + incomplete.stderr)
        self.assertEqual(r.report()["verdict"], "incomplete")
        self.assertEqual(r.health()['fields']['mainReds']['verifierOutcomes'], {'incomplete': 1})
        skipped = r.verify("--module", "repo/alpha", "--skip", "ios")
        self.assertEqual(skipped.returncode, 0, skipped.stdout + skipped.stderr)
        self.assertEqual(r.report()["groups"]["ios-lanes"], ["packages/ios-app/UITests/RealGatewayPairAndChatUITests.swift"])

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


class QuarantineTests(VerifyCase):
    """Real verify CLI/process boundary consuming the Vitest JSON protocol, without skipping tests."""

    def fixture(self):
        r = self.repo
        path = "packages/gateway/src/sample.integration.test.ts"
        r.write(path, "// Report-protocol fixture executed by the child below.\n")
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
        r.write("tooling.module.json", json.dumps(manifest))
        # The spawned producer writes the actual runner's reporting protocol. It always
        # executes; quarantine must classify the output, never suppress the invocation.
        r.write("tools/verify/gateway.py", "import json,pathlib,sys\n"
                "out=next(a.split('=',1)[1] for a in sys.argv if a.startswith('--outputFile.json='))\n"
                "report=json.loads(pathlib.Path('report-input.json').read_text())\n"
                "pathlib.Path(out).write_text(json.dumps(report))\n"
                "pathlib.Path('test-results-executed').write_text('executed')\n"
                "print(report.get('diagnostic', ''))\n"
                "sys.exit(1)\n")
        r.write("packages/gateway/report-input.json", json.dumps({"numPassedTests": 1, "numFailedTests": 1,
            "numFailedTestSuites": 1, "testResults": [{"name": str(r.path / path), "status": "failed",
            "assertionResults": [{"fullName": "sample known failure", "status": "failed", "failureMessages": ["Error: original defect"]},
                                 {"fullName": "sample passes", "status": "passed"}]}]}))
        r.write(".gitignore", "test-results/\npackages/gateway/node_modules/\npackages/gateway/test-results-executed\n")
        r.commit("report protocol producer")
        entry = {"testId": path + "::sample known failure", "evidence": {"command": "scripts/tron test gateway src/sample.integration.test.ts",
                 "commit": r.git("rev-parse", "HEAD"), "failureDigest": hashlib.sha256(json.dumps(["Error: original defect"]).encode()).hexdigest()}, "issue": 2128, "expires": "2099-01-01"}
        return entry

    def test_exact_quarantine_is_qualified_and_unknown_or_suite_errors_fail(self):
        r = self.repo
        entry = self.fixture()
        r.write("tools/verify/known-failures.json", json.dumps([entry]))
        r.commit("quarantine exact case")
        result = r.verify("--module", "gateway/sample")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = r.report()
        self.assertEqual(report["verdict"], "quarantined")
        step = next(s for s in report["steps"] if s["name"] == "tests: gateway")
        self.assertEqual(step["quarantined"], [{"testId": entry["testId"], "expires": entry["expires"], "issue": 2128}])
        self.assertEqual(report["passingTests"], 1)
        self.assertTrue((r.path / "packages/gateway/test-results-executed").exists())
        self.assertIn(entry["expires"], result.stdout)
        card = r.health()['fields']
        self.assertEqual(card['mainReds']['verifierOutcomes'], {'quarantined': 1})
        self.assertEqual(card['mainReds']['quarantinedCases'], 1)
        self.assertIsNone(card['flakeRate']['rate'], 'one attempt is unknown, never zero')
        self.assertEqual((card['flakeRate']['failingAttempts'], card['flakeRate']['totalAttempts']), (1, 2))
        original = (r.path / "packages/gateway/report-input.json").read_text()
        # All executed cases may be quarantined; zero passing is not zero executed.
        raw = json.loads(original)
        raw["numPassedTests"] = 0
        raw["testResults"][0]["assertionResults"] = raw["testResults"][0]["assertionResults"][:1]
        r.write("packages/gateway/report-input.json", json.dumps(raw))
        r.commit("only executed case is quarantined")
        result = r.verify("--module", "gateway/sample")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(r.report()["verdict"], "quarantined")
        self.assertEqual(r.report()["passingTests"], 0)
        for change in ("unknown", "same-case-new-failure", "coexisting-suite-error", "unhandled-error", "nested-hook-error", "suite-error", "missing-report"):
            with self.subTest(change=change):
                raw = json.loads(original)
                if change == "unknown":
                    raw["testResults"][0]["assertionResults"][0]["fullName"] = "different failure"
                elif change == "same-case-new-failure":
                    raw["testResults"][0]["assertionResults"][0]["failureMessages"] = ["Error: a new regression in this same case"]
                elif change == "coexisting-suite-error":
                    raw["testResults"][0]["message"] = "afterAll hook failed after the known assertion"
                elif change == "unhandled-error":
                    raw["diagnostic"] = "Vitest caught 1 unhandled error during the test run."
                elif change == "nested-hook-error":
                    raw["diagnostic"] = "Failed Suites 1"
                elif change == "suite-error":
                    raw["numFailedTestSuites"] = 2
                    raw["testResults"].append({"name": "broken suite", "status": "failed", "message": "setup error", "assertionResults": []})
                else:
                    r.write("tools/verify/gateway.py", "import sys\nsys.exit(1)\n")
                r.write("packages/gateway/report-input.json", json.dumps(raw))
                r.commit(change)
                result = r.verify("--module", "gateway/sample")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(r.report()["verdict"], "failed")
                card = r.health()['fields']['mainReds']
                self.assertEqual(card['verifierOutcomes'], {'failed': 1})
                self.assertNotEqual(card['status'], 'available')

    def test_expired_duplicate_and_malformed_entries_fail_loudly(self):
        r = self.repo
        entry = self.fixture()
        for entries in ([{**entry, "expires": "2000-01-01"}], [entry, entry], [{**entry, "evidence": {}}],
                        [{**entry, "evidence": {**entry["evidence"], "commit": "0" * 40}}]):
            with self.subTest(entries=entries):
                r.write("tools/verify/known-failures.json", json.dumps(entries))
                r.commit("invalid registry")
                result = r.verify("--module", "repo/alpha")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("known-failures", result.stdout + result.stderr)
                self.assertFalse((r.path / "packages/gateway/test-results-executed").exists())
                card = r.health()['fields']['mainReds']
                self.assertEqual(card['verifierOutcomes'], {'failed': 1})
                expected = 'registry-expired' if entries[0].get('expires') == '2000-01-01' else 'registry-invalid'
                self.assertEqual(card['sourceRefusals'], {expected: 1})
                self.assertIsNone(card['numerator'])

    def test_health_repeated_attempts_privacy_identity_and_owned_cleanup(self):
        r = self.repo
        self.fixture()
        # Environmental producer input is ignored: SHA/config stay identical.
        r.write('.gitignore', (r.path / '.gitignore').read_text() + 'packages/gateway/report-input.json\n')
        r.git('rm', '--cached', 'packages/gateway/report-input.json')
        r.commit('external report producer inputs')
        raw = json.loads((r.path / 'packages/gateway/report-input.json').read_text())
        self.assertEqual(r.verify('--module', 'gateway/sample').returncode, 1)
        first = r.report()
        r.write('test-results/first.json', json.dumps(first))
        raw['numPassedTests'], raw['numFailedTests'] = 2, 0
        raw['testResults'][0]['status'] = 'passed'
        raw['testResults'][0]['assertionResults'][0].update(status='passed', failureMessages=[])
        r.write('packages/gateway/report-input.json', json.dumps(raw))
        # Producer exit remains an observed harness failure, not a clean pass.
        r.verify('--module', 'gateway/sample')
        second = r.report()
        self.assertEqual(first['commit'], second['commit'])
        self.assertEqual(first['configDigest'], second['configDigest'])
        r.write('test-results/second.json', json.dumps(second))
        args = ('--verify-report', 'test-results/first.json', '--verify-report', 'test-results/second.json')
        card = r.health(*args)
        flake = card['fields']['flakeRate']
        self.assertEqual((flake['numerator'], flake['denominator']), (1, 2))
        self.assertEqual((flake['failingAttempts'], flake['totalAttempts']), (1, 4))
        duplicate = r.health('--verify-report', 'test-results/first.json', '--verify-report', 'test-results/first.json')
        self.assertIsNone(duplicate['fields']['flakeRate']['rate'])
        r.write('test-results/identities.json', json.dumps({'sourceRevision': first['commit'], 'payloadFingerprint': 'a' * 64, 'protocolVersion': '1',
            'query': 'PRIVATE_SENTINEL', 'prompt': 'PRIVATE_SENTINEL', 'credentials': 'PRIVATE_SENTINEL'}))
        card = r.health(*args, '--mac-identity', 'test-results/identities.json')
        self.assertEqual(card['fields']['deployLag']['status'], 'partial')
        self.assertEqual(card['fields']['deployLag']['denominator'], 2)
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        rows = [
            {'event': 'home.task.history-summary', 'taskHash': 'a' * 16,
             'counts': {'lineages': 1, 'operations': 3, 'resumes': 2, 'complete': 1, 'rootCreatedAtMs': int(now.timestamp() * 1000)}},
            {'event': 'home.task.history-summary', 'taskHash': 'b' * 16,
             'counts': {'lineages': 1, 'operations': 2, 'resumes': 1, 'complete': 0, 'rootCreatedAtMs': int(now.timestamp() * 1000)}},
            {'event': 'home.response-timing', 'counts': {'calls': 1, 'complete': 1, 'firstVisibleMs': 20, 'terminalMs': 50, 'queueMs': 5, 'modelMs': 20, 'toolMs': 10}},
            *[{'event': 'capability.usage', 'step': 'read', 'outcome': status, 'stage': 'unknown', 'counts': {'calls': 1}} for status in ('ok', 'refused', 'error', 'unknown')],
        ]
        # Repeated history pages contain the same source-owned root summary.
        rows.append(rows[0])
        r.write('test-results/owner.json', json.dumps({'records': [{**row, 'timestamp': now.isoformat(), 'prompt': 'PRIVATE_SENTINEL', 'arguments': {'query': 'PRIVATE_SENTINEL'}} for row in rows]}))
        card = r.health(*args, '--owner-summary', 'test-results/owner.json')
        lineage = card['fields']['resumesPerTask']
        self.assertEqual((lineage['numerator'], lineage['denominator'], lineage['status']), (2, 1, 'partial'))
        self.assertEqual(lineage['observedLineages'], 2)
        self.assertEqual(card['supplemental']['homeResponseTiming']['firstVisibleMs']['median'], 20)
        self.assertEqual(len(card['supplemental']['capabilityUsage']), 4)
        # A new failure signature at the same SHA/config is not merged into a
        # flaky case. The unchanged repeatedly-passing case remains comparable.
        raw['numPassedTests'], raw['numFailedTests'] = 1, 1
        raw['testResults'][0]['assertionResults'][0].update(status='failed', failureMessages=['Error: different signature'])
        r.write('packages/gateway/report-input.json', json.dumps(raw))
        r.verify('--module', 'gateway/sample')
        r.write('test-results/third.json', json.dumps(r.report()))
        changed = r.health(*args, '--verify-report', 'test-results/third.json')['fields']['flakeRate']
        self.assertEqual(changed['changedSignatureCases'], 1)
        self.assertEqual((changed['numerator'], changed['denominator']), (0, 1))
        self.assertEqual(changed['status'], 'partial')
        directory = r.path / 'test-results/health'
        old = {**card, 'runId': 'expired', 'expiresAt': '2000-01-01T00:00:00+00:00'}
        r.write('test-results/health/aggregate-expired.json', json.dumps(old))
        r.write('test-results/health/foreign.json', json.dumps(old))
        r.write('test-results/health/aggregate-foreign.json', '{"schema":"foreign"}')
        r.health('--cleanup')
        self.assertFalse((directory / 'aggregate-expired.json').exists())
        self.assertTrue((directory / 'foreign.json').exists())
        self.assertTrue((directory / 'aggregate-foreign.json').exists())
        for path in directory.glob('aggregate-*.json'):
            text = path.read_text()
            for forbidden in ('PRIVATE_SENTINEL', 'failureMessages', 'fullName', 'arguments', 'prompt', 'credentials', str(r.path), 'packages/gateway/src/'):
                self.assertNotIn(forbidden, text)
        HEALTH_ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (HEALTH_ARTIFACTS / 'health-sample.json').write_text(json.dumps(card, indent=2))


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
        # A global compiler must not satisfy a checkout with no dependencies.
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
        # Stale package metadata must not masquerade as the repository pin.
        r.write("packages/gateway/node_modules/typescript/package.json", json.dumps({"version": "0.0.0"}))
        stale = r.verify("--module", "gateway/compiler")
        self.assertEqual(stale.returncode, 2, stale.stdout + stale.stderr)
        self.assertIn("installed 0.0.0, pinned 7.0.2", stale.stderr)
        # A matching package without its npm executable link is still unusable.
        r.write("packages/gateway/node_modules/typescript/package.json", json.dumps({"version": "7.0.2"}))
        broken = r.verify("--module", "gateway/compiler")
        self.assertEqual(broken.returncode, 2, broken.stdout + broken.stderr)
        self.assertIn("local executable", broken.stderr)
        # Planning is read-only and does not require an installed toolchain.
        planned = r.verify("--module", "gateway/compiler", "--plan")
        self.assertEqual(planned.returncode, 0, planned.stdout + planned.stderr)


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
        self.assertEqual([step["name"] for step in report["steps"]][:7],
                         ["ownership", "budgets", "documentation policy", "generated docs", "agent policy", "privacy guard",
                          "git diff --check"])
        self.assertIn("[1/", passed.stdout)
        moved = next(step for step in report["steps"] if step["name"] == "moved-lines (advisory)")
        self.assertEqual(moved["status"], "ok")
        self.assertEqual(len(list((r.path / "test-results/measure").glob("*.json"))), 1)
        # A measurement failure remains visible, without becoming a gate.
        # --changed still compares against base, so alpha's test stays selected.
        r.write("tools/metrics/moved.py", "raise SystemExit(2)\n")
        r.commit("unavailable measurement")
        advisory = r.verify("--changed")
        self.assertEqual(advisory.returncode, 0, advisory.stdout + advisory.stderr)
        self.assertEqual(next(step for step in r.report()["steps"] if step["name"] == "moved-lines (advisory)")["status"], "advisory")
        r.write("mods/alpha/test-alpha.py", FAILING)
        r.commit("break alpha")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1)
        self.assertIn("tests: python FAILED", failed.stdout)
        self.assertIn("AssertionError: 1 != 2", failed.stdout)
        self.assertNotIn("mods/beta/test-beta.py", json.dumps(r.report()["selection"]["tests"]))

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
        # The run itself refuses at the ownership step, before any test.
        self.assertIn("ownership FAILED", r.verify("--changed").stdout)

    def test_a_selection_without_tests_fails_as_zero_test(self) -> None:
        r = self.repo
        r.write("mods/docs/docs.py", "VALUE = 'prose'\n")
        r.commit("docs change")
        result = r.verify("--changed")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("zero tests ran: an empty selection is not evidence", result.stdout)
        self.assertEqual(r.report()["verdict"], "failed")


class FastPathTests(VerifyCase):
    """A change runs the checks that can catch a regression in it, and still fails when it breaks one."""

    def test_markdown_selects_no_test_and_a_docs_only_change_passes_on_the_documentation_checks(self) -> None:
        r = self.repo
        r.write("mods/core/README.md", "# Core\n\nThe kernel module.\n")  # an L1 module: code here would widen
        r.write("AGENTS.md", AGENTS + "\nA new rule.\n")
        r.commit("docs")
        passed = r.verify("--changed")
        self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
        report = r.report()
        self.assertEqual((report["selection"]["tests"], report["selection"]["modules"], report["passingTests"]), ([], [], 0))
        self.assertIn("Markdown-only change", report["message"])
        self.assertEqual({step["name"]: step["status"] for step in report["steps"]}["agent policy"], "ok")
        # Known-bad: prose that breaks a documentation rule fails the run.
        r.write("AGENTS.md", "# Charter\n")
        r.commit("drop the stop rule")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertIn("agent policy FAILED", failed.stdout)
        # Markdown beside code selects only the code's module.
        r.git("reset", "-q", "--hard", "base")
        r.write("mods/core/README.md", "# Core\n")
        r.write("mods/alpha/alpha.py", "VALUE = 'changed'\n")
        r.commit("docs and code")
        mixed = r.verify("--changed")
        self.assertEqual(mixed.returncode, 0, mixed.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/alpha/test-alpha.py"])

    def test_a_change_to_only_tests_or_goldens_runs_those_tests_and_the_goldens_locks(self) -> None:
        r = self.repo
        r.write("mods/core/test-core-other.py", PASSING)
        r.write("mods/core/locks/state.golden.json", "{}\n")
        r.commit("more core tests")
        r.git("branch", "-f", "base")
        # A test-only change in a kernel module runs that test, not every lock.
        r.write("mods/core/test-core-other.py", PASSING + "# reworded\n")
        r.commit("core test")
        only = r.verify("--changed")
        self.assertEqual(only.returncode, 0, only.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/core/test-core-other.py"])
        # A golden runs its module's locks; a broken lock still fails.
        r.write("mods/core/locks/state.golden.json", "{\"recorded\": true}\n")
        r.write("mods/core/test-core.lock.py", FAILING)
        r.commit("golden and its lock")
        failed = r.verify("--changed")
        self.assertEqual(failed.returncode, 1, failed.stdout)
        self.assertEqual(r.report()["selection"]["tests"], ["mods/core/test-core-other.py", "mods/core/test-core.lock.py"])
        self.assertIn("AssertionError: 1 != 2", failed.stdout)
        # Known-bad: code beside the tests selects as before, here widening to every lock.
        r.git("reset", "-q", "--hard", "base")
        r.write("mods/core/test-core-other.py", PASSING + "# reworded\n")
        r.write("mods/core/core.py", "VALUE = 'kernel change'\n")
        r.commit("core code and test")
        widened = r.verify("--changed", "--plan")
        self.assertIn("widened to every lock", widened.stdout)
        self.assertIn("repo/core: owns a changed path; its 2 owned test file(s)", widened.stdout)


class ContractTests(VerifyCase):
    def test_a_runner_group_that_runs_zero_tests_fails(self) -> None:
        r = self.repo
        r.write("mods/beta/test-beta.py", "import unittest\nunittest.main()\n")  # a unittest file with no test
        r.commit("empty beta tests")
        result = r.verify("--module", "repo/beta")
        self.assertEqual(result.returncode, 1, result.stdout)
        report = r.report()
        self.assertEqual(report["verdict"], "failed")
        self.assertEqual(report["passingTests"], 0)
        runner = next(step for step in report["steps"] if step["name"] == "tests: python")
        self.assertEqual(runner["status"], "failed")
        # unittest >= 3.14 exits 5 for no tests; older versions exit 0 and report a zero count.
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


# A stand-in for scripts/tron-ios-test with its real output contract: `build` writes a real index store
# and the real build stamp; `run` writes an xcresult-style summary.json and names its run directory.
IOS_TEST_STUB = r"""#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >>"$FIXTURE_IOS_CALLS"
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
    passed="${FIXTURE_IOS_PASSED:-1}"
    if [[ -n "${FIXTURE_IOS_FAIL:-}" ]]; then
      printf '{"passedTests":0,"failedTests":1,"testFailures":[{"testIdentifierString":"%s","failureText":"a11y differs"}]}' "$FIXTURE_IOS_FAIL" >"$dir/summary.json"
      echo "iOS test run failed with status 65: $dir" >&2; exit 65
    fi
    printf '{"passedTests":%s,"failedTests":0}' "$passed" >"$dir/summary.json"
    echo "iOS test run complete: $dir" ;;
esac
"""


class IosLaneTests(VerifyCase):
    def ios_fixture(self) -> Path:
        """An app module, a UI-tests module whose spawn edge reaches it, and the stand-in lane; returns its call log."""
        r = self.repo
        products = Path(self.temp.name) / "products"
        calls = Path(self.temp.name) / "ios-calls.txt"
        r.env.update(TRON_IOS_TEST_DERIVED_DATA=str(products), FIXTURE_IOS_CALLS=str(calls))
        tooling = json.loads((r.path / "tooling.module.json").read_text())
        tooling["owns"].append("scripts/tron-ios-test")
        r.write("tooling.module.json", json.dumps(tooling))
        r.write("scripts/tron-ios-test", IOS_TEST_STUB)
        (r.path / "scripts/tron-ios-test").chmod(0o755)
        ios = "packages/ios-app"
        r.write(f"{ios}/package.module.json", json.dumps({"layer": "L5", "owns": ["*.json"]}))
        r.write(f"{ios}/Sources/UI/Chat/chat.module.json", json.dumps({"layer": "L4", "owns": ["**"]}))
        r.write(f"{ios}/Sources/UI/Chat/ChatView.swift", "struct ChatView {}\n")
        r.write(f"{ios}/UITests/ui-tests.module.json", json.dumps({"layer": "L5", "owns": ["**"], "dynamicEdges": [
            {"to": "ios-app/chat", "kind": "spawn", "via": f"{ios}/package.module.json", "why": "launches the app"}]}))
        r.write(f"{ios}/UITests/Locks/FixtureLockTests.swift", "class FixtureLockTests {}\n")
        r.write(f"{ios}/UITests/FixtureJourneyUITests.swift", "class FixtureJourneyUITests {}\n")
        r.write(f"{ios}/UITests/TronMacTerminalUITests.swift", "class TronMacTerminalUITests {}\n")  # harnessed
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
            self.assertEqual((steps["ios build"]["status"], steps["layers ios"]["status"], steps["tests: ios"]["tests"]),
                             ("ok", "ok", 1))
        self.assertEqual(digests[0], digests[1])
        self.assertIn("already stamped for this commit", steps["ios build"]["detail"])
        self.assertEqual(calls.read_text().splitlines(), ["build", "run --only-testing TronMobileUITests/FixtureLockTests",
                                                          "run --only-testing TronMobileUITests/FixtureLockTests"])

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
        # The module's own journeys run in the lane, except the harnessed one, which its harness runs.
        calls.write_text("")
        module = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(module.returncode, 1, module.stdout)
        self.assertIn("selected tests were not run: ios-lanes", module.stdout)
        self.assertEqual(calls.read_text().splitlines(), [
            "run --only-testing TronMobileUITests/FixtureJourneyUITests --only-testing TronMobileUITests/FixtureLockTests"])

    def test_source_module_baseline_reaches_transitive_consumers_locks_without_widening(self) -> None:
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app"
        r.write(f"{ios}/Sources/State/state.module.json", json.dumps({"layer": "L2", "owns": ["**"]}))
        r.write(f"{ios}/Sources/State/SessionState.swift", "struct SessionState {}\n")
        r.write(f"{ios}/Sources/UI/Chat/chat.module.json", json.dumps({
            "layer": "L4", "owns": ["**"], "dependsOn": ["ios-app/state"]}))
        r.commit("source-only kernel module consumed by hosted chat")

        baseline = r.verify("--module", "ios-app/state")
        self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)
        report = r.report()
        self.assertEqual(report["selection"]["tests"], [f"{ios}/UITests/Locks/FixtureLockTests.swift"])
        self.assertEqual(report["passingTests"], 1)
        self.assertEqual(calls.read_text().splitlines(), [
            "build", "run --only-testing TronMobileUITests/FixtureLockTests"])
        # Module baselines add consumer locks, not their journeys or unrelated kernel locks.
        self.assertNotIn("widened to every lock", baseline.stdout)
        # Recording remains confined to the explicitly named owner's locks.
        recording = r.verify("--update-locks", "ios-app/state", "--plan")
        self.assertEqual(recording.returncode, 0, recording.stderr)
        self.assertIn('"tests": []', recording.stdout)
        # An actual runner failure must fail the same source-only module command.
        r.env["FIXTURE_IOS_FAIL"] = "TronMobileUITests/FixtureLockTests/testChat()"
        failed = r.verify("--module", "ios-app/state")
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertIn("failed: TronMobileUITests/FixtureLockTests/testChat(): a11y differs", failed.stdout)

    def test_an_extension_file_runs_as_the_class_it_extends(self) -> None:
        """#1522: a file that extends another file's XCTestCase class runs as that class, in that class's lane."""
        r = self.repo
        calls = self.ios_fixture()
        ios = "packages/ios-app/UITests"
        r.write(f"{ios}/FixtureJourneyMoreUITests.swift", "extension FixtureJourneyUITests {}\n")
        r.write(f"{ios}/TronMacTerminalMoreUITests.swift", "extension TronMacTerminalUITests {}\n")  # harnessed class
        r.commit("extension files")
        module = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(module.returncode, 1, module.stdout + module.stderr)
        self.assertIn("ios-lanes: 2 file(s)", module.stdout)
        self.assertEqual(calls.read_text().splitlines()[-1],
                         "run --only-testing TronMobileUITests/FixtureJourneyUITests --only-testing TronMobileUITests/FixtureLockTests")
        # A file that names no XCTestCase class fails loudly, unless the run skips iOS.
        r.write(f"{ios}/StrayUITests.swift", "struct Helper {}\n")
        r.commit("stray")
        refused = r.verify("--module", "ios-app/ui-tests")
        self.assertEqual(refused.returncode, 2)
        self.assertIn("StrayUITests.swift declares or extends no XCTestCase class", refused.stderr)
        skipped = r.verify("--module", "ios-app/ui-tests", "--skip", "ios", "--plan")
        self.assertEqual(skipped.returncode, 0, skipped.stderr)


# The Gateway runner `mutate` drives, faked at `scripts/tron-node`: a flipped comparison
# fails the lock, a flipped flag hangs it (with a child the timeout must also stop).
FAKE_RUNNER = """#!/usr/bin/env python3
import json, pathlib, subprocess, sys, time
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--outputFile="))
source = pathlib.Path("src/store/store.ts").read_text()
if "hang = false" in source:
    child = subprocess.Popen(["sleep", "300"])
    pathlib.Path("hung.pid").write_text(f"{child.pid}\\n")
    time.sleep(300)
failed = 0 if "1 === 1" in source else 1
pathlib.Path(out).write_text(json.dumps({"numFailedTests": failed, "numFailedTestSuites": 0, "numPassedTests": 1 - failed}))
"""
SOURCE = "export const kill = 1 === 1;\nexport const hang = true;\n"


class MutateTests(VerifyCase):
    def setUp(self) -> None:
        super().setUp()
        r = self.repo
        r.write("scripts/tron-node", FAKE_RUNNER)
        (r.path / "scripts/tron-node").chmod(0o755)
        r.write("packages/gateway/src/store/store.module.json", json.dumps({"layer": "L3", "owns": ["**"]}))
        r.write("packages/gateway/src/store/store.ts", SOURCE)
        r.write("packages/gateway/src/store/store.lock.integration.test.ts", "// faked by scripts/tron-node\n")
        r.write(".gitignore", "test-results/\npackages/gateway/hung.pid\n")
        manifest = json.loads((r.path / "tooling.module.json").read_text())
        manifest["owns"].append("scripts/tron-node")
        r.write("tooling.module.json", json.dumps(manifest))
        r.commit("gateway store")
        # The seed that samples the failing mutant first: candidates are in line order.
        self.seed = next(seed for seed in range(100) if (lambda pool: (random.Random(seed).shuffle(pool), pool)[1])([0, 1]) == [0, 1])

    def mutate(self, *args: str) -> subprocess.Popen:
        return subprocess.Popen([str(self.repo.path / "scripts/tron"), "mutate", "packages/gateway/src/store/store.ts",
                                 "--seed", str(self.seed), *args], cwd=self.repo.path, env=self.repo.env,
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
        process = self.mutate("--timeout", "3")
        output, _ = process.communicate(timeout=120)
        self.assertEqual(process.returncode, 0, output)
        self.assertLess(time.time() - started, 60, output)
        report = self.report()
        self.assertEqual([(m["line"], m["outcome"]) for m in report["mutants"]], [(1, "killed"), (2, "timeout")])
        self.assertEqual((report["killed"], report["timeouts"], report["rate"], report["complete"]), (2, 1, 1.0, True))
        self.assertIn("TIMEOUT", output)
        self.assertEqual((self.repo.path / "packages/gateway/src/store/store.ts").read_text(), SOURCE)
        self.assert_hung_child_stopped()

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
