"""Isolated checks for land --acceptance (failure modes 71 and 72 in README.md).

Each journey is the fake registered command in test_land.py, which writes the report its
spec names. The fixture is LandFixture in test_land.py.
Run: python3 -m unittest discover -s tools/work
"""
from __future__ import annotations

import acceptance
import hashlib
import json
import land
import signal
import subprocess
import threading
import unittest

import test_land
from test_land import PAIR, REPORT_PATH, WRONG_CODE, LandFixture, git


def setUpModule():
    # Each test_land_*.py module runs in its own process, so it builds the template itself.
    test_land.setUpModule()


class AcceptanceLandingTests(LandFixture):
    # Failure modes 71 and 72.
    def test_a_passing_journey_reaches_the_pull_request_as_its_report_digest(self):
        self.assertEqual(self.land(acceptance=PAIR), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        digest = hashlib.sha256(self.kept_report(PAIR, head)).hexdigest()
        body = self.state()["pulls"][0]["body"]
        self.assertIn("### Acceptance journeys", body)
        self.assertIn(f"report sha256 `{digest}`", body)
        self.assertIn(PAIR, body)
        self.assertIn(f"source `{head}`", body)
        self.assertNotIn(str(self.tmp), body)
        # The registered journey is what the command received and what the report names.
        self.assertEqual(self.journey_runs(), [f"{PAIR} started", f"{PAIR} report {head}"])
        self.assertEqual(len(self.merges()), 1)
        self.assertEqual((self.issue()["state"], self.issue()["status"]), ("CLOSED", "Done"))

    def test_each_journey_is_checked_against_the_report_its_own_run_left(self):
        # Both runs share the head's evidence directory, so the second one
        # replaces the report path the first one left behind.
        self.spec({PAIR: {}, WRONG_CODE: {"revision": self.claim_sha}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},{WRONG_CODE}")
        self.assertIn(WRONG_CODE, str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_from_another_head_is_refused(self):
        self.spec({PAIR: {"revision": self.claim_sha}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn(self.claim_sha[:12], str(raised.exception))
        self.assertIn(git(self.repo, "rev-parse", "HEAD")[:12], str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_that_is_not_from_a_completed_clean_run_is_refused(self):
        cases = {"a dirty run": ({"dirty": True}, "ran from a dirty worktree"),
                 "incomplete evidence": ({"evidence_complete": False}, "did not leave complete evidence"),
                 "a failed journey": ({"status": 1}, "reported status 1"),
                 "an unreadable report": ({"raw": "not json"}, "unreadable report"),
                 "no source fingerprint": ({"fingerprint": ""}, "names no source fingerprint"),
                 "a report for another journey": ({"journey": "TronMobileUITests/Other/x"},
                                                  "not the registered journey")}
        for name, (spec, message) in cases.items():
            with self.subTest(case=name):
                self.spec({PAIR: spec})
                with self.assertRaises(acceptance.AcceptanceError) as raised:
                    self.land(acceptance=PAIR)
                self.assertIn(message, str(raised.exception))
        self.assert_nothing_published()

    def test_a_journey_that_writes_no_report_is_refused(self):
        # A fresh evidence directory: no earlier run's report is there to be
        # taken for this run's.
        self.spec({PAIR: {"report": False}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("left no report", str(raised.exception))
        self.assert_nothing_published()

    def test_a_report_an_earlier_run_left_is_refused(self):
        # The declared path resolves to a file this run did not write. The
        # planted report is one land would otherwise accept, so only the run's
        # own write can qualify it.
        head = git(self.repo, "rev-parse", "HEAD")
        stale = self.acceptance_evidence(head) / REPORT_PATH
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps(self.passing_report(PAIR, head)))
        self.spec({PAIR: {"report": False}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("left no new report", str(raised.exception))
        self.assert_nothing_published()

    def test_a_journey_command_that_fails_is_refused(self):
        self.spec({PAIR: {"exit": 3}})
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("failed (exit 3)", str(raised.exception))
        self.assert_nothing_published()

    def _journey_wait_seam(self, ready, *, force_not_ready=False, handler_installed=None):
        popen = acceptance.subprocess.Popen
        self.controlled_journeys = []

        def spawn(*args, **kwargs):
            process = popen(*args, **kwargs)
            wait = process.wait

            def wait_for_bound(timeout=None):
                if timeout != 1:
                    return wait(timeout=timeout)
                self.controlled_journeys.append(process)
                if force_not_ready:
                    if handler_installed is not None:
                        handler_installed.wait(timeout=5)
                    readiness_failed = True
                else:
                    readiness_failed = not ready.wait(timeout=5)
                if readiness_failed:
                    try:
                        process.send_signal(signal.SIGINT)
                    except ProcessLookupError:
                        pass
                    try:
                        wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        wait()
                    raise AssertionError("journey did not become ready before the test bound")
                raise subprocess.TimeoutExpired(process.args, timeout)

            process.wait = wait_for_bound
            return process

        return popen, spawn

    def test_a_journey_that_passes_its_bound_is_interrupted_and_winds_down_itself(self):
        self.journey_timeout(PAIR, 1)
        self.spec({PAIR: {"sleep": 60, "trap_sigint": True, "ready_signal": True, "report": False}})
        ready = threading.Event()
        previous_handler = signal.getsignal(signal.SIGUSR1)
        signal.signal(signal.SIGUSR1, lambda *_: ready.set())
        popen, wait_seam = self._journey_wait_seam(ready)
        try:
            acceptance.subprocess.Popen = wait_seam
            with self.assertRaises(acceptance.AcceptanceError) as raised:
                self.land(acceptance=PAIR)
        finally:
            acceptance.subprocess.Popen = popen
            signal.signal(signal.SIGUSR1, previous_handler)
        message = str(raised.exception)
        self.assertIn("passed its 1s bound", message)
        self.assertIn("interrupted (exit 130)", message)
        # SIGINT reached the journey and its own wind-down ran; land never killed it.
        self.assertIn(f"{PAIR} cleanup", self.journey_runs())
        self.assertNotIn(f"{PAIR} wound down", self.journey_runs())
        [journey_process] = self.controlled_journeys
        self.assertEqual(journey_process.returncode, 130)
        self.assert_nothing_published()

    def test_a_journey_readiness_failure_stops_and_joins_the_exact_child(self):
        self.journey_timeout(PAIR, 1)
        self.spec({PAIR: {"sleep": 60, "trap_sigint": True, "handler_signal": True,
                          "delay_ready": True, "ready_signal": True, "report": False}})
        ready = threading.Event()
        handler_installed = threading.Event()
        previous_ready_handler = signal.getsignal(signal.SIGUSR1)
        previous_installed_handler = signal.getsignal(signal.SIGUSR2)
        signal.signal(signal.SIGUSR1, lambda *_: ready.set())
        signal.signal(signal.SIGUSR2, lambda *_: handler_installed.set())
        popen, wait_seam = self._journey_wait_seam(ready, force_not_ready=True,
                                                   handler_installed=handler_installed)
        try:
            acceptance.subprocess.Popen = wait_seam
            with self.assertRaisesRegex(AssertionError, "did not become ready"):
                self.land(acceptance=PAIR)
        finally:
            acceptance.subprocess.Popen = popen
            signal.signal(signal.SIGUSR1, previous_ready_handler)
            signal.signal(signal.SIGUSR2, previous_installed_handler)
        [journey_process] = self.controlled_journeys
        self.assertIsNotNone(journey_process.returncode)
        self.assertFalse(ready.is_set(), "a late readiness signal survived child cleanup")
        if handler_installed.is_set():
            self.assertEqual(journey_process.returncode, 130)
            self.assertIn(f"{PAIR} cleanup", self.journey_runs())
        else:
            self.assertEqual(journey_process.returncode, -signal.SIGINT)
        self.assert_nothing_published()

    def test_an_interrupted_land_waits_for_the_journey_to_wind_down(self):
        # The journey signals land's process the way a terminal interrupt does and
        # then winds down on its own. land must wait for that wind-down and
        # re-raise; the interrupt path of subprocess.run would kill it instead.
        # A backgrounded verify inherits SIGINT ignored (POSIX gives an
        # asynchronous job in a non-interactive shell SIG_IGN), so this test
        # listens for the interrupt it delivers either way: its subject is
        # land's own handler path, not the shell's disposition.
        inherited = signal.getsignal(signal.SIGINT)
        if inherited is signal.SIG_IGN:
            signal.signal(signal.SIGINT, signal.default_int_handler)
        self.addCleanup(signal.signal, signal.SIGINT, inherited)
        self.spec({PAIR: {"signal_parent": True, "report": False}})
        with self.assertRaises(KeyboardInterrupt):
            self.land(acceptance=PAIR)
        self.assertIn(f"{PAIR} wound down", self.journey_runs())
        self.assert_nothing_published()

    def test_the_journeys_run_against_the_head_that_is_pushed_after_a_base_move(self):
        before = git(self.repo, "rev-parse", "HEAD")
        # lib/** shares no check with the branch: only the requested journeys force the round.
        moved = self.base_commit("lib/new.txt", "from base\n")
        self.set_state(pendingViews=1, baseMoves={"1": moved})
        self.assertEqual(self.land(acceptance=PAIR), 0)
        head = git(self.repo, "rev-parse", "HEAD")
        self.assertNotEqual(head, before)
        # Round 1 proved the head it ran against; round 2 proved the head that
        # was verified, pushed and cited, which is where its evidence lives.
        self.assertIn(f"{PAIR} report {before}", self.journey_runs())
        self.assertIn(f"{PAIR} report {head}", self.journey_runs())
        body = self.state()["pulls"][0]["body"]
        digest = hashlib.sha256(self.kept_report(PAIR, head)).hexdigest()
        self.assertIn(f"source `{head}`", body)
        self.assertIn(f"report sha256 `{digest}`", body)
        [merge] = self.merges()
        self.assertEqual(merge[merge.index("--match-head-commit") + 1], head)

    def test_a_report_the_scrub_refuses_stops_before_any_github_write(self):
        self.spec({PAIR: {"fingerprint": "FORBIDDEN fingerprint"}})
        with self.assertRaises(land.LandError) as raised:
            self.land(acceptance=PAIR)
        self.assertIn("acceptance evidence", str(raised.exception))
        self.assert_nothing_published()

    def test_an_unknown_journey_id_is_refused_with_the_registered_ids(self):
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},typo")
        message = str(raised.exception)
        self.assertIn("typo", message)
        self.assertIn(WRONG_CODE, message)
        self.assert_nothing_published()
        self.assertFalse(self.acceptance_evidence(git(self.repo, "rev-parse", "HEAD")).exists())

    def test_an_empty_journey_id_is_refused(self):
        with self.assertRaises(acceptance.AcceptanceError) as raised:
            self.land(acceptance=f"{PAIR},")
        self.assertIn("comma-separated", str(raised.exception))
        self.assert_nothing_published()

    def test_a_repository_without_a_usable_registry_refuses(self):
        journeys = self.config["acceptance"]["journeys"]
        cases = {"no acceptance section": (None, "registers no acceptance journeys"),
                 "no journeys": ({"evidenceEnv": "FAKE_ACCEPTANCE_EVIDENCE", "journeys": {}},
                                 "registers no acceptance journeys"),
                 "no evidence variable": ({"journeys": journeys}, "evidenceEnv")}
        for name, (section, named) in cases.items():
            with self.subTest(case=name):
                if section is None:
                    self.config.pop("acceptance", None)
                else:
                    self.config["acceptance"] = section
                with self.assertRaises(acceptance.AcceptanceError) as raised:
                    self.land(acceptance=PAIR)
                self.assertIn(named, str(raised.exception))
        self.assert_nothing_published()


if __name__ == "__main__":
    unittest.main()
