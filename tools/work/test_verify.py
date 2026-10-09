"""Isolated checks for verify failure modes 12-19 and 63 in README.md.

Real temporary repositories with a local bare remote; GitHub is a fake `gh`
(WORK_GH) that records every call so posting order can be asserted.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import os
import subprocess
import shlex
import signal
import time
import sys
import tempfile
import textwrap
import unittest
from unittest import mock
from pathlib import Path

import verify
from gh import Gh
from repo_template import clone_with_identity, copy_template

REMOTE = "origin"
BASE = "main"
BRANCH = "feat/7-thing"

FAKE_GH = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    stdin = sys.stdin.read() if "--input" in args else ""
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"args": args, "stdin": stdin}) + "\\n")
    fail = os.environ.get("FAKE_GH_FAIL")
    if fail and fail == " ".join(args[:2]):
        print("gh: injected failure", file=sys.stderr)
        sys.exit(1)
    if args[0] == "repo":
        print("acme/widget")
    elif args[0] == "pr":
        # FAKE_GH_PR: the open pull requests for the head branch, as JSON.
        print(os.environ.get("FAKE_GH_PR") or "[]")
    elif args[0] == "api":
        method, path = args[args.index("-X") + 1], args[3]
        if fail and fail in path:
            print("gh: injected failure (HTTP 500)", file=sys.stderr)
            sys.exit(1)
        if method == "GET" and "/contents/" in path:
            print("gh: Not Found (HTTP 404)", file=sys.stderr)
            sys.exit(1)
        if method == "GET" and path == "repos/acme/widget-evidence":
            print(json.dumps({"private": not os.environ.get("FAKE_GH_EVIDENCE_PUBLIC")}))
            sys.exit(0)
        if method == "POST" and path.endswith("/comments"):
            print(json.dumps({"html_url": "https://example.invalid/comment/1"}))
        else:
            print("{}")
    """
)


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class EnvironmentAndSelectorTests(unittest.TestCase):
    # These need no fixture repository, so they run once rather than once per fixture subclass.
    def test_live_home_environment_fails_before_check_selection(self):
        root = Path(__file__).resolve().parents[2]
        live_home = Path.home() / ".tron"
        with mock.patch.dict(os.environ, {"PI_SESSION_FILE": str(live_home / "sessions" / "guard.jsonl")}):
            with self.assertRaisesRegex(verify.VerifyError, "Tron-home environment"):
                verify.verify(root, {})

    def test_home_name_selector_fails_before_check_selection(self):
        root = Path(__file__).resolve().parents[2]
        node_bin = str(Path(subprocess.check_output(["which", "node"], text=True).strip()).parent)
        with mock.patch.dict(os.environ, {"TRON_HOME_NAME": ".tron-dev", "PATH": node_bin}, clear=True):
            with self.assertRaisesRegex(verify.VerifyError, "Tron-home environment"):
                verify.verify(root, {})

    def test_tron_home_path_entries_are_allowed_but_data_roots_are_rejected(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as home:
            user_home = Path(home) / "user-home"
            agent_bin = user_home / ".tron" / "agent" / "bin"
            policy = root / "packages/gateway/src/tron-home-environment-policy.mjs"
            environment = {"HOME": str(user_home), "PATH": str(agent_bin)}
            node = subprocess.check_output(["which", "node"], text=True).strip()
            allowed = subprocess.run(
                [node, str(policy)],
                env=environment, capture_output=True, text=True,
            )
            self.assertEqual(allowed.returncode, 0, allowed.stderr)

            rejected = subprocess.run(
                [allowed.args[0], str(policy)],
                env={**environment, "PI_CODING_AGENT_DIR": str(user_home / ".tron" / "agent")},
                capture_output=True, text=True,
            )
            self.assertNotEqual(rejected.returncode, 0, rejected.stdout)
            self.assertIn("PI_CODING_AGENT_DIR=", rejected.stderr)

    def test_node_test_runner_rejects_home_name_selector(self):
        root = Path(__file__).resolve().parents[2]
        node_bin = str(Path(subprocess.check_output(["which", "node"], text=True).strip()).parent)
        environment = {"PATH": os.pathsep.join((node_bin, "/usr/bin", "/bin")), "TRON_HOME_NAME": ".tron-dev"}
        gateway = root / "packages/gateway"
        result = subprocess.run(
            [
                str(Path(node_bin) / "node"), "--import", "./test-support/tron-home-environment-preflight.mjs",
                "--test", "scripts/check-pi-sdk.test.mjs", "scripts/update-pi-sdk.test.mjs",
                "scripts/compare-pi-sdk-graph.test.mjs",
            ], cwd=gateway, env=environment, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("TRON_HOME_NAME=/", result.stderr + result.stdout)

    def test_pi_subagents_selector_covers_pin_packages_and_artifacts_not_runtime_sources(self):
        root = Path(__file__).resolve().parents[2]
        config = json.loads((root / ".github/work.json").read_text())
        checks = verify.load_checks(config["verify"])
        provider = next((check for check in checks if check.name == "pi-subagents"), None)
        self.assertIsNotNone(provider, "provider pin changes must select offline verification")
        for path in (
            "packages/gateway/package.json",
            "packages/gateway/package-lock.json",
            "packages/gateway/pi-subagents-pin.json",
            "packages/gateway/artifacts/pi-subagents-0.76.1-tron.3.tgz",
            "packages/gateway/artifacts/pi-subagents-0.76.1-tron.3-package-lock.json",
            "packages/gateway/scripts/update-pi-subagents.mjs",
            "packages/gateway/scripts/build-pi-subagents-closure.py",
            ".node-version",
        ):
            with self.subTest(path=path):
                self.assertTrue(provider.matches(path))
        for path in (
            "packages/gateway/src/sessions/session-manager.ts",
            "packages/gateway/README.md",
            "packages/gateway/scripts/update-pi-sdk.mjs",
            "packages/gateway/artifacts/unrelated.tgz",
        ):
            with self.subTest(path=path):
                self.assertFalse(provider.matches(path))

    def test_scale_suite_selector_is_narrow(self):
        root = Path(__file__).resolve().parents[2]
        config = json.loads((root / ".github/work.json").read_text())
        checks = verify.load_checks(config["verify"])
        scale = next(check for check in checks if check.name == "gateway-scale")
        for path in (
            "packages/gateway/src/knowledge/knowledge-catalog.scale.test.ts",
            "packages/gateway/src/knowledge/paid-budget-ledger.ts",
            "packages/gateway/src/knowledge/knowledge-curation.ts",
            "packages/gateway/vitest.scale.config.ts",
        ):
            with self.subTest(path=path):
                self.assertTrue(scale.matches(path))
        self.assertFalse(scale.matches("packages/gateway/src/sessions/session-manager.ts"))

def _build_verify_template(root: Path) -> None:
    """The history every VerifyFixture copies: a remote whose base holds three files, and a clone on BRANCH."""
    remote = root / "remote.git"
    git(root, "init", "-q", "--bare", "-b", BASE, str(remote))
    seed = clone_with_identity(remote, root / "seed")
    for relative in ("app/a.txt", "lib/b.txt", "README.md"):
        VerifyFixture.write(seed, relative, "one\n")
    git(seed, "add", "-A")
    git(seed, "commit", "-q", "-m", "base")
    git(seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
    repo = clone_with_identity(remote, root / "repo")
    git(repo, "checkout", "-q", "-b", BRANCH)


_verify_template_root: Path


def setUpModule():
    # Built once per module; each VerifyFixture copies it.
    global _verify_template_root
    template = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(template.cleanup)
    _verify_template_root = Path(template.name).resolve()
    _build_verify_template(_verify_template_root)


class VerifyFixture(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stdout(io.StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name).resolve()
        self.remote = self.tmp / "remote.git"
        self.seed = self.tmp / "seed"
        self.repo = self.tmp / "repo"
        copy_template(_verify_template_root, self.tmp, [self.seed, self.repo], REMOTE, self.remote)
        self.counts = self.tmp / "counts"
        self.counts.mkdir()
        self.fail_flag = self.tmp / "fail-app"
        self.config = {
            "claim": {"remote": REMOTE, "baseBranch": BASE},
            "verify": {
                "prelude": "export VERIFY_FIXTURE=1",
                "statusContext": "test/verify",
                "scrubCommand": "! grep -q FORBIDDEN",
                "evidenceRepositorySuffix": "-evidence",
                "excerptLines": 5,
                "checks": [
                    {"name": "app", "paths": ["app/**"],
                     "command": self._counting("app") + f" && ! test -e {self.fail_flag}"},
                    {"name": "lib", "paths": ["lib/**"], "command": self._counting("lib")},
                    {"name": "docs", "paths": ["**/*.md"], "command": self._counting("docs")},
                    {"name": "policy", "paths": [], "always": True, "command": self._counting("policy")},
                ],
            },
        }

    def tearDown(self):
        self._tmp.cleanup()

    def _counting(self, name: str) -> str:
        return f"echo run >> {self.counts / name}"

    def runs(self, name: str) -> int:
        path = self.counts / name
        return len(path.read_text().splitlines()) if path.exists() else 0

    @staticmethod
    def write(repo: Path, relative: str, content: str) -> None:
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self, repo: Path, relative: str, content: str) -> str:
        self.write(repo, relative, content)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", f"change {relative}")
        return git(repo, "rev-parse", "HEAD")

    def advance_base(self, relative: str) -> None:
        git(self.seed, "pull", "-q", REMOTE, BASE)
        self.commit(self.seed, relative, f"base change {relative}\n")
        git(self.seed, "push", "-q", REMOTE, f"HEAD:{BASE}")

    def verify(self, config=None) -> dict:
        return verify.verify(self.repo, config or self.config)

    def receipts(self) -> Path:
        return Path(git(self.repo, "rev-parse", "--absolute-git-dir")) / "work" / "receipts"


class ReceiptBindingTests(VerifyFixture):
    # Failure mode 12: a receipt is named by and records exactly one head.
    def test_receipt_records_its_head_in_the_git_dir(self):
        head = self.commit(self.repo, "app/a.txt", "two\n")
        receipt = self.verify()
        self.assertEqual(receipt["head"], head)
        stored = json.loads((self.receipts() / f"{head}.json").read_text())
        self.assertEqual(stored["head"], head)
        self.assertTrue(stored["passed"])
        self.assertEqual(git(self.repo, "status", "--porcelain", "--untracked-files=all"), "")


class CheckSetTests(VerifyFixture):
    # Failure mode 13: the required set comes from the whole branch diff, and
    # carry-over keeps a check required without running it.
    def test_later_commit_does_not_narrow_the_required_set(self):
        first = self.commit(self.repo, "app/a.txt", "two\n")
        self.verify()
        self.commit(self.repo, "README.md", "two\n")
        receipt = self.verify()
        self.assertEqual(receipt["required"], ["app", "docs", "policy"])
        self.assertEqual(receipt["checks"]["app"]["carriedFrom"], first)
        self.assertEqual(self.runs("app"), 1)
        self.assertEqual(self.runs("docs"), 1)
        self.assertTrue(receipt["passed"])

    def test_always_checks_rerun_on_every_verify(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.verify()
        receipt = self.verify()
        self.assertEqual(self.runs("policy"), 2)
        self.assertIsNone(receipt["checks"]["policy"]["carriedFrom"])
        self.assertEqual(self.runs("app"), 1)

    def test_failed_check_fails_the_receipt_and_is_rerun(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.fail_flag.write_text("")
        receipt = self.verify()
        self.assertFalse(receipt["passed"])
        self.assertNotEqual(receipt["checks"]["app"]["exitCode"], 0)
        self.fail_flag.unlink()
        receipt = self.verify()
        self.assertTrue(receipt["passed"])
        self.assertIsNone(receipt["checks"]["app"]["carriedFrom"])
        self.assertEqual(self.runs("app"), 2)

    def test_paths_placeholder_passes_every_matched_existing_file(self):
        out = self.tmp / "paths"
        config = json.loads(json.dumps(self.config))
        config["verify"]["checks"][0]["command"] = f"printf '%s\\n' {{paths}} > {out}; echo {{merge_base}} >> {out}"
        self.commit(self.repo, "app/new file.txt", "x\n")
        git(self.repo, "rm", "-q", "app/a.txt")
        git(self.repo, "commit", "-q", "-m", "remove")
        merge_base = git(self.repo, "merge-base", f"{REMOTE}/{BASE}", "HEAD")
        verify.verify(self.repo, config)
        lines = out.read_text().splitlines()
        self.assertEqual(lines, [str(self.repo / "app" / "new file.txt"), merge_base])


class ParallelCheckTests(VerifyFixture):
    """Scheduling oracles are events the checks record, never wall time or the host's size.

    Overlap is proven by a rendezvous: a check with `peers=n` waits until n checks
    of the same run have started, so it can only finish when the scheduler really
    ran them together. Order and non-overlap come from one append-only event log.
    The rendezvous and hold waits are bounded only so a broken scheduler fails
    instead of hanging; a passing run never waits on them.
    """

    def prepare_checks(self, groups=(None, None, None), codes=(0, 0, 0), peers=(1, 1, 1), hold=False):
        if (self.repo / "app/a.txt").read_text() != "two\n":
            self.commit(self.repo, "app/a.txt", "two\n")
        checks = []
        for name, group, code, need in zip(("first", "second", "third"), groups, codes, peers):
            script = self.tmp / f"{name}.py"
            script.write_text(textwrap.dedent(f"""\
                import os, pathlib, sys, time
                counts = pathlib.Path({str(self.counts)!r})
                def event(kind):
                    fd = os.open(counts / 'events.log', os.O_WRONLY | os.O_APPEND | os.O_CREAT)
                    os.write(fd, f'{{kind}} {name}\\n'.encode())
                    os.close(fd)
                def wait(condition, what):
                    deadline = time.monotonic() + 60
                    while not condition():
                        if time.monotonic() > deadline:
                            print('timed out waiting for ' + what)
                            sys.exit(99)
                        time.sleep(0.01)
                (counts / '{name}.pid').write_text(str(os.getpid()))
                (counts / '{name}.group').write_text(str(os.getpgrp()))
                event('start')
                (counts / '{name}.started').touch()
                wait(lambda: len(list(counts.glob('*.started'))) >= {need}, 'peers')
                if {hold!r}:
                    wait(lambda: False, 'release')
                event('end')
                print({name!r})
                sys.exit({code})
            """))
            check = {"name": name, "paths": ["app/**"],
                     "command": f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}"}
            if group:
                check["exclusiveGroup"] = group
            checks.append(check)
        self.config["verify"]["checks"] = checks

    def reset_events(self):
        for path in list(self.counts.glob("*.started")) + [self.counts / "events.log"]:
            path.unlink(missing_ok=True)

    def events(self):
        return [tuple(line.split()) for line in (self.counts / "events.log").read_text().splitlines()]

    def before(self, first, second):
        """Whether `first` ended before `second` started."""
        events = self.events()
        return events.index(("end", first)) < events.index(("start", second))

    def test_default_concurrency_is_bounded_by_cpu_and_physical_memory(self):
        popen, launched, live_at_launch = subprocess.Popen, [], []

        def launch(*args, **kwargs):
            # Check processes still running when the scheduler starts another one;
            # poll() reaps, so a check the scheduler already settled never counts.
            if kwargs.get("start_new_session"):
                live_at_launch.append(sum(process.poll() is None for process in launched))
            process = popen(*args, **kwargs)
            if kwargs.get("start_new_session"):
                launched.append(process)
            return process

        for cpus, gib, expected in ((1, 64, 1), (18, 16, 2), (18, 36, 3), (18, 0, 1)):
            with self.subTest(cpus=cpus, gib=gib), \
                    mock.patch.object(verify.os, "cpu_count", return_value=cpus), \
                    mock.patch.object(verify, "_physical_memory", return_value=gib * 1024 ** 3), \
                    mock.patch.object(verify.subprocess, "Popen", side_effect=launch):
                # Each check needs `expected` running peers, so a lower bound never
                # finishes; no launch may find `expected` checks still running.
                self.prepare_checks(peers=(expected,) * 3)
                for raw in self.config["verify"]["checks"]:
                    raw["always"] = True
                self.reset_events()
                launched.clear()
                live_at_launch.clear()
                self.assertTrue(self.verify()["passed"])
                self.assertEqual(len(live_at_launch), 3)
                self.assertLess(max(live_at_launch), expected)

    def test_jobs_one_serializes_in_configuration_order(self):
        self.prepare_checks()
        verify.verify(self.repo, self.config, jobs=1)
        self.assertEqual(self.events(), [(kind, name) for name in ("first", "second", "third")
                                         for kind in ("start", "end")])

    def test_failure_and_admission_refusal_do_not_cancel_passing_check(self):
        self.prepare_checks(codes=(73, 9, 0), peers=(3, 3, 3))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            receipt = verify.verify(self.repo, self.config, jobs=3)
        self.assertFalse(receipt["passed"])
        self.assertEqual(list(receipt["checks"]), ["first", "second", "third"])
        self.assertEqual([entry["exitCode"] for entry in receipt["checks"].values()], [73, 9, 0])
        final_lines = [line.strip().split(":")[0] for line in output.getvalue().splitlines()
                       if "in " in line]
        self.assertEqual(final_lines, ["first", "second", "third"])
        for name, entry in receipt["checks"].items():
            self.assertIn(name, Path(entry["log"]).read_text())
            self.assertGreaterEqual(entry["seconds"], 0)
        stored = json.loads((self.receipts() / f"{receipt['head']}.json").read_text())
        self.assertEqual(stored, receipt)

    def test_exclusive_pair_does_not_overlap_but_independent_check_runs(self):
        # first and third can only finish together; second must wait for first.
        self.prepare_checks(groups=("shared-tree", "shared-tree", None), peers=(2, 1, 2))
        self.assertTrue(verify.verify(self.repo, self.config, jobs=2)["passed"])
        self.assertTrue(self.before("first", "second"))

    def test_conditional_group_only_serializes_selected_gateway_fixture_paths(self):
        # Unselected, first and second must run together (two peers). Selected,
        # third stands in as first's peer and second must wait for first.
        self.prepare_checks(groups=("gateway-source-tree", "gateway-source-tree", None), peers=(2, 2, 1))
        for raw in self.config["verify"]["checks"]:
            raw["always"] = True
        second = self.config["verify"]["checks"][1]
        second["paths"].append("lib/**")
        second["exclusivePaths"] = ["lib/**"]
        self.assertTrue(verify.verify(self.repo, self.config, jobs=2)["passed"])
        self.assertFalse(self.before("first", "second"))
        self.reset_events()
        self.commit(self.repo, "lib/b.txt", "fixture selected\n")
        self.assertTrue(verify.verify(self.repo, self.config, jobs=2)["passed"])
        self.assertTrue(self.before("first", "second"))

    def test_ios_exclusive_paths_track_the_selection_owner(self):
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location("ios_selection", root / "scripts/ios_verify_test_selection.py")
        owner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(owner)
        settings = json.loads((root / ".github/work.json").read_text())["verify"]
        ios = next(raw for raw in settings["checks"] if raw["name"] == "ios")
        self.assertEqual(set(ios["exclusivePaths"]),
                         {path for path, (runner, _) in owner.FIXTURE_RUNNER_INPUTS.items()
                          if runner == "scripts/ios-gateway-e2e-test"})

    def test_invalid_jobs_and_groups_refuse_before_launch(self):
        self.prepare_checks()
        for jobs in (0, -1, True, 1.5):
            with self.subTest(jobs=jobs), self.assertRaises(verify.VerifyError):
                verify.verify(self.repo, self.config, jobs=jobs)
        for group in ("", "Bad group", 3, []):
            self.config["verify"]["checks"][0]["exclusiveGroup"] = group
            with self.subTest(group=group), self.assertRaises(verify.VerifyError):
                self.verify()
        self.config["verify"]["checks"][0]["exclusiveGroup"] = "shared-tree"
        for paths in ([], "app/**", [3], [""]):
            self.config["verify"]["checks"][0]["exclusivePaths"] = paths
            with self.subTest(paths=paths), self.assertRaises(verify.VerifyError):
                self.verify()
        del self.config["verify"]["checks"][0]["exclusiveGroup"]
        self.config["verify"]["checks"][0]["exclusivePaths"] = ["app/**"]
        with self.assertRaises(verify.VerifyError):
            self.verify()
        self.assertEqual(list(self.counts.iterdir()), [])

    def test_abort_retires_all_running_process_groups_without_receipt(self):
        self.prepare_checks(hold=True)
        processes = []
        popen = subprocess.Popen

        def dispose(process):
            if process.poll() is not None:
                return
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)

        def launch(*args, **kwargs):
            process = popen(*args, **kwargs)
            if kwargs.get("start_new_session"):
                processes.append(process)
                self.addCleanup(dispose, process)
            return process

        sleep = time.sleep
        interrupted = False

        def interrupt(seconds):
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                raise KeyboardInterrupt
            sleep(seconds)

        with mock.patch.object(verify.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(verify.time, "sleep", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                verify.verify(self.repo, self.config, jobs=2)
        self.assertEqual(len(processes), 2)
        self.assertTrue(all(process.poll() is not None for process in processes))
        self.assertEqual(list(self.receipts().glob("*.json")), [])

    def test_termination_retires_check_groups_before_exiting(self):
        self.prepare_checks(hold=True)
        config = self.tmp / "config.json"
        config.write_text(json.dumps(self.config))
        code = (f"import sys, json; sys.path.insert(0, {str(Path(verify.__file__).parent)!r}); "
                f"from pathlib import Path; import verify; "
                f"verify.verify(Path({str(self.repo)!r}), json.loads(Path({str(config)!r}).read_text()), jobs=2)")
        process = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
        try:
            # Bounded only so a broken launch fails instead of hanging.
            deadline = time.monotonic() + 60
            while not all((self.counts / f"{name}.started").exists() for name in ("first", "second")):
                self.assertLess(time.monotonic(), deadline, "checks never started")
                time.sleep(0.02)
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            for name in ("first", "second"):
                pid = int((self.counts / f"{name}.pid").read_text())
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            self.assertEqual(list(self.receipts().glob("*.json")), [])
        finally:
            # Own cleanup even for the negative control, which deliberately
            # leaves the independently-sessioned checks alive.
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            for name in ("first", "second"):
                path = self.counts / f"{name}.group"
                if path.exists():
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(int(path.read_text()), signal.SIGKILL)

    def test_carried_result_survives_unrelated_merge_with_original_provenance(self):
        first = self.commit(self.repo, "app/a.txt", "two\n")
        self.verify()
        self.commit(self.repo, "README.md", "two\n")
        self.verify()  # app is already carried here
        self.advance_base("lib/c.txt")
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "merge", "-q", "--no-edit", f"{REMOTE}/{BASE}")
        receipt = self.verify()
        self.assertEqual(receipt["checks"]["app"]["carriedFrom"], first)
        self.assertEqual(self.runs("app"), 1)
        self.assertTrue(receipt["passed"])

    def test_bundle_rebuild_selection_preserves_fast_script_scope(self):
        root = Path(__file__).resolve().parents[2]
        settings = json.loads((root / ".github/work.json").read_text())["verify"]
        checks = verify.load_checks(settings)
        fast = next(check for check in checks if check.name == "mac-scripts")
        rebuild = next(check for check in checks if check.name == "mac-bundle-rebuild")
        for path in ("scripts/gateway-payload-deploy.test.mjs", "scripts/tron-dev",
                     "packages/mac-app/scripts/test-push-product-config.sh"):
            with self.subTest(path=path):
                self.assertTrue(fast.matches(path))
                self.assertFalse(rebuild.matches(path))
        for path in ("packages/mac-app/scripts/bundle-gateway.sh",
                     "packages/mac-app/scripts/test-bundle-gateway-rebuild.sh",
                     "packages/mac-app/scripts/stage-gateway-app.sh",
                     "packages/mac-app/scripts/ensure-gateway-bundle.sh",
                     "packages/mac-app/scripts/verify-gateway-payload.sh",
                     "packages/mac-app/scripts/tron-gateway-launcher.c",
                     "packages/mac-app/scripts/verify-macho-architectures.sh",
                     "scripts/hash-npm-runtime.py", "scripts/gateway-install-inputs.mjs",
                     "packages/gateway/scripts/install-pi-subagents.mjs",
                     "packages/gateway/scripts/check-pi-subagents.mjs",
                     "packages/gateway/scripts/ensure-node-pty-helper.mjs",
                     "packages/gateway/pi-subagents-pin.json",
                     "packages/gateway/artifacts/pi-subagents-current.tgz",
                     "packages/gateway/package-lock.json", "packages/gateway/package.json",
                     "config/GatewayProtocol.json", "config/PushService.xcconfig",
                     "scripts/gateway-payload-deploy.mjs", "scripts/install-ci-tools.sh",
                     "scripts/verify-gateway-protocol-contract.py", "scripts/gateway_protocol_contract.py",
                     ".node-version", "config/ci-toolchain.env"):
            with self.subTest(path=path):
                self.assertTrue(rebuild.matches(path), path)
        self.assertFalse(rebuild.matches("packages/gateway/src/sessions/session-manager.ts"))
        # Exercise selected commands, not just globs: deployment-only edits must
        # still run fast scripts but never launch the real rebuild script.
        calls = self.tmp / "selected"
        # Keep the actual fast/rebuild command chains and substitute executable
        # fixtures at their boundaries. Selecting fast must not secretly build.
        for command in [*fast.command.split(" && "), rebuild.command]:
            args = shlex.split(command)
            path = args[-1]
            label = "mac-bundle-rebuild" if path.endswith("test-bundle-gateway-rebuild.sh") else "fast-script"
            if args[:2] == ["node", "--test"]:
                content = ("import { appendFileSync } from 'node:fs';\n"
                           f"appendFileSync({json.dumps(str(calls))}, 'fast-script\\n');\n")
            else:
                content = f"#!/bin/sh\necho {label} >> {shlex.quote(str(calls))}\n"
            self.write(self.seed, path, content)
            (self.seed / path).chmod(0o755)
        git(self.seed, "add", "-A")
        git(self.seed, "commit", "-q", "-m", "script fixture base")
        git(self.seed, "push", "-q", REMOTE, f"HEAD:{BASE}")
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "merge", "-q", "--ff-only", f"{REMOTE}/{BASE}")
        for raw in settings["checks"]:
            if raw["name"] not in ("mac-scripts", "mac-bundle-rebuild"):
                raw["command"] = f"echo {raw['name']} >> {calls}"
        config = {"claim": self.config["claim"], "verify": settings}
        self.commit(self.repo, "scripts/gateway-payload-deploy.test.mjs", "// test\n")
        receipt = verify.verify(self.repo, config)
        self.assertTrue(receipt["passed"])
        self.assertIn("mac-scripts", receipt["required"])
        self.assertIn("fast-script", calls.read_text().splitlines())
        self.assertNotIn("mac-bundle-rebuild", calls.read_text().splitlines())
        self.commit(self.repo, "packages/mac-app/scripts/stage-gateway-app.sh", "# stage\n")
        receipt = verify.verify(self.repo, config)
        self.assertTrue(receipt["passed"])
        self.assertIn("mac-bundle-rebuild", receipt["required"])
        self.assertIn("mac-bundle-rebuild", calls.read_text().splitlines())


class PostFixture(VerifyFixture):
    def setUp(self):
        super().setUp()
        self.gh_log = self.tmp / "gh.jsonl"
        fake = self.tmp / "gh"
        fake.write_text(FAKE_GH.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        fake.chmod(0o755)
        self._env = {k: os.environ.get(k) for k in ("WORK_GH", "FAKE_GH_LOG", "FAKE_GH_FAIL", "FAKE_GH_PR",
                                                 "FAKE_GH_EVIDENCE_PUBLIC")}
        os.environ.update(WORK_GH=str(fake), FAKE_GH_LOG=str(self.gh_log))
        for key in ("FAKE_GH_FAIL", "FAKE_GH_PR", "FAKE_GH_EVIDENCE_PUBLIC"):
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        super().tearDown()

    def calls(self) -> list:
        if not self.gh_log.exists():
            return []
        return [json.loads(line) for line in self.gh_log.read_text().splitlines()]

    def api_calls(self) -> list:
        return [(c["args"][c["args"].index("-X") + 1], c["args"][3], json.loads(c["stdin"] or "null"))
                for c in self.calls() if c["args"][0] == "api"]

    def statuses(self) -> list:
        return [body["state"] for method, path, body in self.api_calls() if "/statuses/" in path]

    def comment_bodies(self) -> list:
        return [body["body"] for method, path, body in self.api_calls() if path.endswith("/comments")]

    def push(self) -> None:
        git(self.repo, "push", "-q", REMOTE, f"HEAD:refs/heads/{BRANCH}")

    def post(self, receipt: dict) -> str:
        return verify.post(Gh(self.repo), self.repo, self.config, receipt)


class PostBindingTests(PostFixture):
    # Failure mode 12: only a head the remote branch holds can be posted.
    def test_post_refuses_when_remote_branch_is_elsewhere(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        receipt = self.verify()
        with self.assertRaises(verify.VerifyError):
            self.post(receipt)  # branch not pushed
        self.push()
        self.commit(self.repo, "app/a.txt", "three\n")
        with self.assertRaises(verify.VerifyError):
            self.post(self.verify())  # remote still holds the older head
        self.assertEqual(self.statuses(), [])

    def test_post_refuses_a_receipt_for_an_older_head(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        stale = self.verify()
        self.commit(self.repo, "app/a.txt", "three\n")
        self.push()
        with self.assertRaises(verify.VerifyError):
            self.post(stale)
        self.assertEqual(self.statuses(), [])

    def test_open_pull_request_is_preferred_over_the_issue(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        os.environ["FAKE_GH_PR"] = json.dumps([{"number": 42, "isCrossRepository": False}])
        self.post(self.verify())
        comment_paths = [path for _, path, _ in self.api_calls() if path.endswith("/comments")]
        self.assertEqual(comment_paths, ["repos/acme/widget/issues/42/comments"])
        uploads = [path for method, path, _ in self.api_calls() if method == "PUT"]
        self.assertTrue(uploads)
        self.assertTrue(all(p.startswith("repos/acme/widget-evidence/contents/7/") for p in uploads), uploads)

    # Failure mode 63: claim branch names are public, so a fork can open a pull
    # request with the same head name; it never receives the evidence.
    def test_fork_pull_request_with_the_branch_name_is_ignored(self):
        fork, own = {"number": 41, "isCrossRepository": True}, {"number": 42, "isCrossRepository": False}
        for pulls, target in (([fork], 7), ([fork, own], 42)):
            with self.subTest(pulls=pulls):
                self.gh_log.unlink(missing_ok=True)
                self.commit(self.repo, "app/a.txt", f"to {target}\n")
                self.push()
                os.environ["FAKE_GH_PR"] = json.dumps(pulls)
                self.post(self.verify())
                comment_paths = [path for _, path, _ in self.api_calls() if path.endswith("/comments")]
                self.assertEqual(comment_paths, [f"repos/acme/widget/issues/{target}/comments"])


class PostStatusTests(PostFixture):
    # Failure mode 14: pending first, success only after the comment and only
    # for a passing receipt, failure on any error.
    def test_passing_receipt_posts_comment_before_success(self):
        head = self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        self.post(self.verify())
        order = [("status:" + body["state"]) if "/statuses/" in path else method + ":" + path.split("/")[-1]
                 for method, path, body in self.api_calls() if method != "GET"]
        self.assertEqual(order[0], "status:pending")
        self.assertEqual(order[-1], "status:success")
        self.assertLess(order.index("POST:comments"), order.index("status:success"))
        status_paths = {path for _, path, _ in self.api_calls() if "/statuses/" in path}
        self.assertEqual(status_paths, {f"repos/acme/widget/statuses/{head}"})
        self.assertIn(head, self.comment_bodies()[0])

    def test_failing_receipt_posts_failure(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        self.fail_flag.write_text("")
        self.post(self.verify())
        self.assertEqual(self.statuses(), ["pending", "failure"])

    def test_error_while_posting_never_leaves_success(self):
        for failing in ("pr list", "/comments", "/contents/"):
            with self.subTest(failing=failing):
                self.gh_log.unlink(missing_ok=True)
                self.commit(self.repo, "app/a.txt", failing)
                self.push()
                receipt = self.verify()
                os.environ["FAKE_GH_FAIL"] = failing
                try:
                    with self.assertRaises(Exception):
                        self.post(receipt)
                finally:
                    os.environ.pop("FAKE_GH_FAIL")
                self.assertEqual(self.statuses(), ["pending", "failure"])


class EvidencePrivacyTests(PostFixture):
    # Failure mode 15: public text is scrubbed and redacted; full logs go only
    # to the private evidence repository.
    def _failing_app(self, output: str) -> None:
        config = self.config["verify"]["checks"][0]
        config["command"] = f"{output}; exit 3"

    def test_scrub_finding_refuses_the_comment(self):
        self._failing_app("echo FORBIDDEN detail")
        self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        with self.assertRaises(verify.VerifyError):
            self.post(self.verify())
        self.assertEqual(self.comment_bodies(), [])
        self.assertEqual(self.statuses(), ["pending", "failure"])

    def test_public_evidence_repository_is_refused(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        receipt = self.verify()
        os.environ["FAKE_GH_EVIDENCE_PUBLIC"] = "1"
        with self.assertRaises(verify.VerifyError):
            self.post(receipt)
        self.assertEqual([path for method, path, _ in self.api_calls() if method == "PUT"], [])
        self.assertEqual(self.comment_bodies(), [])
        self.assertEqual(self.statuses(), ["pending", "failure"])

    def test_excerpt_is_redacted_and_bounded(self):
        self._failing_app('for i in 1 2 3 4 5 6 7 8; do echo "early-line-$i"; done; echo "at $PWD in $HOME/x"')
        self.commit(self.repo, "app/a.txt", "two\n")
        self.push()
        self.post(self.verify())
        body = self.comment_bodies()[0]
        self.assertNotIn(str(self.repo), body)
        self.assertNotIn(os.environ["HOME"], body)
        self.assertIn("at <repo> in ~/x", body)
        self.assertNotIn("early-line-1", body)  # only the last excerptLines lines
        uploads = {path: body for method, path, body in self.api_calls() if method == "PUT"}
        log = next(b for p, b in uploads.items() if p.endswith("/app.log"))
        import base64
        self.assertIn("early-line-1", base64.b64decode(log["content"]).decode())
        self.assertNotIn("](http", body.replace("](https://example.invalid", ""))


class CarryOverTests(VerifyFixture):
    # Failure mode 16: incoming base changes count against carry-over.
    def test_merged_base_change_reruns_the_matching_check(self):
        first = self.commit(self.repo, "app/a.txt", "two\n")
        self.commit(self.repo, "lib/b.txt", "two\n")
        self.verify()
        self.advance_base("app/c.txt")
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "merge", "-q", "--no-edit", f"{REMOTE}/{BASE}")
        receipt = self.verify()
        self.assertIsNone(receipt["checks"]["app"]["carriedFrom"])
        self.assertIsNotNone(receipt["checks"]["lib"]["carriedFrom"])
        self.assertEqual((self.runs("app"), self.runs("lib")), (2, 1))
        self.assertNotEqual(first, receipt["head"])

    def test_rebase_carries_nothing(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.verify()
        self.advance_base("lib/other.txt")
        git(self.repo, "fetch", "-q", REMOTE)
        git(self.repo, "rebase", "-q", f"{REMOTE}/{BASE}")
        receipt = self.verify()
        self.assertIsNone(receipt["checks"]["app"]["carriedFrom"])
        self.assertEqual(self.runs("app"), 2)

    def test_unmerged_base_movement_does_not_change_the_check_set(self):
        self.commit(self.repo, "README.md", "two\n")
        self.advance_base("app/c.txt")
        receipt = self.verify()
        self.assertEqual(receipt["required"], ["docs", "policy"])


class CoverageTests(VerifyFixture):
    # Failure mode 17: every changed path needs a check.
    def test_unmapped_path_refuses_without_running_or_writing(self):
        head = self.commit(self.repo, "other/x.bin", "x")
        self.commit(self.repo, "app/a.txt", "two\n")
        with self.assertRaises(verify.VerifyError) as raised:
            self.verify()
        self.assertIn("other/x.bin", str(raised.exception))
        self.assertEqual(self.runs("app") + self.runs("policy"), 0)
        self.assertFalse(self.receipts().exists() and any(self.receipts().iterdir()), head)

    def test_single_star_stays_within_one_segment(self):
        config = json.loads(json.dumps(self.config))
        config["verify"]["checks"][0]["paths"] = ["app/*"]
        self.commit(self.repo, "app/deep/x.txt", "x\n")
        with self.assertRaises(verify.VerifyError):
            verify.verify(self.repo, config)


class ConfigChangeTests(VerifyFixture):
    # Failure mode 18: a different configuration carries nothing.
    def test_changed_configuration_reruns_everything(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        self.verify()
        self.commit(self.repo, "README.md", "two\n")
        changed = json.loads(json.dumps(self.config))
        changed["verify"]["checks"][1]["command"] += " # changed"
        receipt = verify.verify(self.repo, changed)
        self.assertIsNone(receipt["checks"]["app"]["carriedFrom"])
        self.assertEqual(self.runs("app"), 2)


class CommittedContentTests(VerifyFixture):
    # Failure mode 19: the receipt describes the committed head only.
    def test_dirty_worktree_is_refused(self):
        self.commit(self.repo, "app/a.txt", "two\n")
        for dirty in ("untracked.txt", "app/a.txt"):
            with self.subTest(dirty=dirty):
                self.write(self.repo, dirty, "uncommitted\n")
                with self.assertRaises(verify.VerifyError):
                    self.verify()
                git(self.repo, "checkout", "-q", "--", ".")
                git(self.repo, "clean", "-qfd")
        self.assertEqual(self.runs("policy"), 0)

    def test_check_that_changes_the_worktree_discards_the_receipt(self):
        head = self.commit(self.repo, "app/a.txt", "two\n")
        config = json.loads(json.dumps(self.config))
        config["verify"]["checks"][0]["command"] = "echo changed > app/a.txt"
        with self.assertRaises(verify.VerifyError):
            verify.verify(self.repo, config)
        self.assertFalse((self.receipts() / f"{head}.json").exists())


class MediaEvidenceTests(PostFixture):
    """Media boundary failures recorded in README.md's verify evidence contract."""

    def media(self):
        import base64
        # A real one-pixel PNG, not a renamed arbitrary file.
        return base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')

    def manifest(self):
        self.commit(self.repo, 'app/a.txt', 'media change\n')
        directory = self.tmp / 'capture'
        directory.mkdir()
        (directory / 'private-screen-name.png').write_bytes(self.media())
        manifest = directory / 'manifest.json'
        manifest.write_text(json.dumps({'head': git(self.repo, 'rev-parse', 'HEAD'),
                                        'artifacts': [{'path': 'private-screen-name.png'}]}))
        return manifest

    def test_cli_snapshot_reverify_and_private_upload(self):
        manifest = self.manifest()
        self.config['verify']['checks'][3]['paths'] = ['.github/**']
        self.commit(self.repo, '.github/work.json', json.dumps(self.config))
        value = json.loads(manifest.read_text())
        value['head'] = git(self.repo, 'rev-parse', 'HEAD')
        manifest.write_text(json.dumps(value))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('cli.py')),
                                 'verify', '--evidence-manifest', str(manifest)],
                                cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first = json.loads((self.receipts() / f"{value['head']}.json").read_text())
        (manifest.parent / 'private-screen-name.png').unlink()
        second = self.verify()
        self.assertEqual(first['artifacts'], second['artifacts'])
        self.push()
        self.post(second)
        import base64
        uploads = {path: base64.b64decode(body['content']) for method, path, body in self.api_calls()
                   if method == 'PUT'}
        media = {path: content for path, content in uploads.items() if '/media/' in path}
        self.assertEqual(list(media.values()), [self.media()])
        self.assertTrue(all(path.startswith('repos/acme/widget-evidence/') for path in media))
        public = self.comment_bodies()[0]
        self.assertIn('/media/', public)
        self.assertNotIn('private-screen-name', public)
        self.assertNotIn(str(manifest.parent), public)

    def test_movie_container_bytes_reach_private_upload_unchanged(self):
        manifest = self.manifest()
        value = json.loads(manifest.read_text())
        # Minimal ISO BMFF container. This proves transfer, not recording/playback.
        movie = bytes.fromhex('0000001466747970717420200000000071742020')
        (manifest.parent / 'capture.mov').write_bytes(movie)
        value['artifacts'].append({'path': 'capture.mov'})
        manifest.write_text(json.dumps(value))
        receipt = verify.verify(self.repo, self.config, manifest)
        self.push()
        self.post(receipt)
        import base64
        uploaded = [base64.b64decode(body['content']) for method, path, body in self.api_calls()
                    if method == 'PUT' and path.endswith('.mov')]
        self.assertEqual(uploaded, [movie])
        self.assertEqual(len(receipt['artifacts']), 2)

    def test_manifest_rejects_unsafe_or_unbounded_inputs_before_checks(self):
        manifest = self.manifest()
        good = json.loads(manifest.read_text())
        (manifest.parent / 'credentials.png').write_text('secret credential')
        (manifest.parent / 'link.png').symlink_to('private-screen-name.png')
        (manifest.parent / 'linked').symlink_to(manifest.parent, target_is_directory=True)
        os.mkfifo(manifest.parent / 'pipe.png')
        oversized = manifest.parent / 'large.png'
        with oversized.open('wb') as output:
            output.write(self.media())
            output.truncate(10 * 1024 * 1024 + 1)
        cases = [dict(good, head='0' * 40), dict(good, artifacts=[]),
                 dict(good, artifacts=[{'path': 'private-screen-name.png'}] * 11),
                 dict(good, artifacts=[{'path': 'private-screen-name.png'}] * 2)]
        cases += [dict(good, artifacts=[{'path': p}]) for p in (
            '../capture/private-screen-name.png', str(manifest.parent / 'private-screen-name.png'),
            'link.png', 'linked/private-screen-name.png', 'missing.png', 'credentials.png', 'pipe.png', 'large.png',
            'bad\x00.png')]
        for value in cases:
            with self.subTest(value=value):
                manifest.write_text(json.dumps(value))
                with self.assertRaises(verify.VerifyError):
                    verify.verify(self.repo, self.config, manifest)
                self.assertEqual(self.runs('policy'), 0)
                self.assertEqual(self.calls(), [])
        manifest.write_text('{')
        with self.assertRaises(verify.VerifyError):
            verify.verify(self.repo, self.config, manifest)

    def test_total_limit_and_manifest_symlink_refuse_before_checks(self):
        manifest = self.manifest()
        value = json.loads(manifest.read_text())
        linked = manifest.parent / 'alias.json'
        linked.symlink_to(manifest)
        with self.assertRaises(verify.VerifyError):
            verify.verify(self.repo, self.config, linked)
        value['artifacts'] = []
        for index in range(3):
            path = manifest.parent / f'large-{index}.png'
            with path.open('wb') as output:
                output.write(self.media() + bytes([index]))
                output.truncate(9 * 1024 * 1024)
            value['artifacts'].append({'path': path.name})
        manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(verify.VerifyError, 'total'):
            verify.verify(self.repo, self.config, manifest)
        self.assertEqual(self.runs('policy'), 0)

    def test_snapshot_directory_symlink_cannot_write_outside_git_storage(self):
        manifest = self.manifest()
        work = self.receipts().parent
        work.mkdir()
        outside = self.tmp / 'outside'
        outside.mkdir()
        (work / 'media').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(verify.VerifyError):
            verify.verify(self.repo, self.config, manifest)
        self.assertEqual(list(outside.iterdir()), [])

    def test_media_never_carries_to_a_new_head(self):
        manifest = self.manifest()
        first = verify.verify(self.repo, self.config, manifest)
        self.commit(self.repo, 'app/a.txt', 'later\n')
        for source in (None, manifest):
            with self.subTest(source=source), self.assertRaisesRegex(verify.VerifyError, 'head|recapture'):
                verify.verify(self.repo, self.config, source)
        self.assertFalse((self.receipts() / f"{git(self.repo, 'rev-parse', 'HEAD')}.json").exists())
        self.assertTrue(first['artifacts'])

    def test_missing_changed_or_symlink_snapshot_prevents_all_uploads(self):
        manifest = self.manifest()
        receipt = verify.verify(self.repo, self.config, manifest)
        self.push()
        artifact = receipt['artifacts'][0]
        snapshot = self.receipts().parent / 'media' / receipt['head'] / artifact['name']
        for mutation in ('changed', 'missing', 'symlink'):
            with self.subTest(mutation=mutation):
                self.gh_log.unlink(missing_ok=True)
                snapshot.unlink(missing_ok=True)
                if mutation == 'changed':
                    snapshot.write_bytes(b'changed')
                elif mutation == 'symlink':
                    snapshot.symlink_to(manifest.parent / 'private-screen-name.png')
                with self.assertRaises(verify.VerifyError):
                    self.post(receipt)
                self.assertFalse(any(method == 'PUT' for method, _, _ in self.api_calls()))
                self.assertEqual(self.comment_bodies(), [])
                self.assertNotIn('success', self.statuses())

    def test_public_repository_and_media_upload_failure_do_not_publish(self):
        manifest = self.manifest()
        receipt = verify.verify(self.repo, self.config, manifest)
        self.push()
        for variable, value in [('FAKE_GH_EVIDENCE_PUBLIC', '1'), ('FAKE_GH_FAIL', '/media/')]:
            with self.subTest(variable=variable):
                self.gh_log.unlink(missing_ok=True)
                os.environ[variable] = value
                try:
                    with self.assertRaises(Exception):
                        self.post(receipt)
                finally:
                    os.environ.pop(variable)
                self.assertEqual(self.statuses(), ['pending', 'failure'])
                self.assertEqual(self.comment_bodies(), [])
                if variable == 'FAKE_GH_EVIDENCE_PUBLIC':
                    self.assertFalse(any(method == 'PUT' for method, _, _ in self.api_calls()))


if __name__ == "__main__":
    unittest.main()
