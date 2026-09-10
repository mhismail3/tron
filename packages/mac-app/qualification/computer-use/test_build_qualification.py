import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_qualification import sha, signing_policy, verify_checkout, verify_declared_patch


class SourcePinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tron-pin-fixture-")
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://example.invalid/native.git")
        (self.root / "source.swift").write_text("let fixture = 1\n")
        (self.root / ".gitignore").write_text("ignored.swift\n")
        self.git("add", ".")
        # Commits belong only to this disposable test repository, never Tron.
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        self.pin = self.git("rev-parse", "HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=",
                                        "-C", str(self.root), *args], text=True, env=env).strip()

    def verify(self):
        return verify_checkout(self.root, self.pin, "https://example.invalid/native.git")

    def test_clean_pin_records_exact_content(self):
        result = self.verify()
        self.assertEqual(result["revision"], self.pin)
        self.assertEqual(set(result["files"]), {".gitignore", "source.swift"})

    def test_dirty_source_is_rejected(self):
        (self.root / "source.swift").write_text("let fixture = 2\n")
        with self.assertRaises(ValueError):
            self.verify()

    def test_assume_unchanged_cannot_hide_changed_bytes(self):
        self.git("update-index", "--assume-unchanged", "source.swift")
        (self.root / "source.swift").write_text("let fixture = 2\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.verify()

    def test_ignored_source_cannot_enter_build(self):
        (self.root / "ignored.swift").write_text("let injected = 1\n")
        with self.assertRaisesRegex(ValueError, "not clean"):
            self.verify()

    def test_wrong_repository_is_rejected(self):
        self.git("remote", "set-url", "origin", "https://example.invalid/other.git")
        with self.assertRaisesRegex(ValueError, "repository"):
            self.verify()

    def test_untracked_source_is_rejected(self):
        (self.root / "extra.swift").write_text("let injected = 1\n")
        with self.assertRaisesRegex(ValueError, "not clean"):
            self.verify()


class QualificationHostPolicyTests(unittest.TestCase):
    host = (Path(__file__).parent / "Sources/TronComputerUseQualification/QualificationHost.swift")

    def test_background_mode_is_exact_and_action_only(self):
        source = self.host.read_text()
        for required in [
            "--background-qualification",
            "available-but-not-attempted",
            "requiresFreshAccessibilityTree: true",
            "allowApplicationScopedAccessibilityFallback: false",
            "defaultStrategy: .actionOnly",
            "performAction: .actionOnly",
            "withCaptureEngine(.modern)",
            "captureWindow(",
            "windowID: window.id",
            "windowMutationIdentity == identity",
            "nativeActionEvidence",
            "FixtureMarkerView",
            "beforeGreenMarkerSamples",
            "afterRedMarkerSamples",
            "BoundedPipeCollector",
            "candidate.bundleIdentifier == Bundle.main.bundleIdentifier",
            "candidate.executablePath == fixtureURL.path",
            "frontmostReceipt",
            "backgroundNonActivationVerified: true",
            "action.targetIdentity?.exactWindow",
            "target.identity == identity",
        ]:
            self.assertIn(required, source)
        for forbidden in [
            "AXUIElementPerformAction",
            "CGEvent",
            "captureScreen(",
            "captureArea(",
            "activate(ignoringOtherApps",
            "orderFrontRegardless",
            "child.terminate()",
            "NativeAwaitState",
        ]:
            self.assertNotIn(forbidden, source)

    def test_ax_only_mode_is_explicit_and_does_not_request_capture(self):
        source = self.host.read_text()
        for required in [
            "--background-ax-only",
            "case axOnly",
            "mode.captures",
            "capture: mode.captures ? \"exact-window-modern-screencapturekit\" : \"not-requested\"",
            "actionReceiptIdentity",
            "windowOrderAfterAX",
            "requireScreenCapture: mode.captures",
        ]:
            self.assertIn(required, source)
        self.assertIn("if mode.captures {", source)
        self.assertIn("captureService!", source)

    def test_gui_availability_and_owner_probe_are_separate(self):
        source = self.host.read_text()
        self.assertIn("guiSessionLocked", source)
        self.assertIn("try requireUnlockedGUI()", source)
        self.assertIn("--capture-owner-check", source)
        self.assertIn("ScreenCaptureKitOwnerLease().claim().receipt", source)
        self.assertNotIn("static func main() async", source)
        self.assertIn("withExtendedLifetime(delegate)", source)

    def test_background_mode_rejects_running_native_operation(self):
        source = self.host.read_text()
        self.assertIn("outcome.evidence == .deliveryAccepted", source)
        self.assertIn("outcome.evidence != .operationStillRunning", source)
        self.assertIn("retireOwnedFixture", source)
        self.assertIn("nativeQuiescence = \"uncertain\"", source)
        self.assertIn("native-qualification-failed", source)
        self.assertIn("uncertain-not-joined", source)
        self.assertIn("uncertain-controller-exiting", source)
        self.assertIn("window.orderBack(nil)", source)
        self.assertIn("InMemorySnapshotManager()", source)
        self.assertIn("snapshots.createSnapshot()", source)
        self.assertIn("in: Data(), snapshotId: snapshotID, windowContext: context", source)
        self.assertIn("shouldFocusWebContent: false", source)


class DownstreamPatchTests(unittest.TestCase):
    git = SourcePinTests.git
    tearDown = SourcePinTests.tearDown

    def setUp(self):
        SourcePinTests.setUp(self)
        base = self.pin
        (self.root / "source.swift").write_text("let fixture = 2\n")
        self.git("add", "source.swift")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "candidate")
        revision = self.git("rev-parse", "HEAD")
        data = subprocess.check_output(["git", "-C", str(self.root), "diff", "--binary", base, revision])
        self.patch = self.root / "candidate.patch"
        self.patch.write_bytes(data)
        self.candidate = {"upstreamRevision": base, "revision": revision,
                          "patchFile": "candidate.patch", "patchSHA256": sha(data)}
        self.pin = revision

    def test_exact_downstream_patch_is_required(self):
        verify_declared_patch(self.root, self.candidate, self.root)
        self.patch.write_bytes(self.patch.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "patch bytes changed"):
            verify_declared_patch(self.root, self.candidate, self.root)

    def test_matching_sidecar_hash_cannot_hide_different_code(self):
        self.patch.write_bytes(b"not the candidate diff\n")
        self.candidate["patchSHA256"] = sha(self.patch.read_bytes())
        with self.assertRaisesRegex(ValueError, "does not match"):
            verify_declared_patch(self.root, self.candidate, self.root)


class SigningPolicyTests(unittest.TestCase):
    identity = "A" * 40
    team = "EXAMPLE123"
    inventory = '  1) ' + identity + ' "Apple Development: Fixture"\n'

    def test_one_development_identity_is_selected(self):
        self.assertEqual(signing_policy(None, self.inventory, self.team), self.identity)

    def test_ad_hoc_or_unlisted_identity_is_rejected(self):
        for value in ["-", "B" * 40, "Apple Development: Fixture"]:
            with self.assertRaises(ValueError):
                signing_policy(value, self.inventory, self.team)

    def test_multiple_identities_require_explicit_selection(self):
        inventory = self.inventory + '  2) ' + "B" * 40 + ' "Apple Development: Other"\n'
        with self.assertRaises(ValueError):
            signing_policy(None, inventory, self.team)
        self.assertEqual(signing_policy(self.identity, inventory, self.team), self.identity)


if __name__ == "__main__":
    unittest.main()
