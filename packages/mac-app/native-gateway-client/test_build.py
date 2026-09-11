"""Offline build-input regressions: no compiler, Node load, XPC or live host."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build


class NativeCaptureBuildInputsTests(unittest.TestCase):
    def test_exact_production_inputs_and_changed_shared_header_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            metadata = Path(temporary) / "inputs.json"
            value = {"schema": 1, "testOnly": False,
                     "inputs": {name: build.digest((build.ROOT / name).read_bytes()) for name in build.INPUTS}}
            metadata.write_text(json.dumps(value))
            build.verify_inputs(metadata)
            value["inputs"]["packages/mac-app/Sources/Support/Onboarding/NativeCaptureService.h"] = "0" * 64
            metadata.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                build.verify_inputs(metadata)

    def test_test_artifact_cannot_supply_production_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            metadata = Path(temporary) / "inputs.json"
            value = {"schema": 1, "testOnly": True,
                     "inputs": {name: build.digest((build.ROOT / name).read_bytes()) for name in build.INPUTS}}
            metadata.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "inputs changed"):
                build.verify_inputs(metadata)
            with self.assertRaisesRegex(ValueError, "fresh tron-native-capture-test.node"):
                build.build(Path(temporary) / "tron-native-capture.node", test=True)

    def test_wrong_local_header_fails_before_compile_or_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            headers = root / "headers"
            headers.mkdir()
            for name in build.HEADERS:
                (headers / name).write_text("unauthenticated wrong header\n")
            with patch.object(build.subprocess, "run", side_effect=AssertionError("compiler must not run")):
                with self.assertRaisesRegex(ValueError, "header integrity mismatch"):
                    build.build(root / "tron-native-capture.node", headers)
            self.assertFalse((root / "tron-native-capture.node").exists())
            self.assertFalse((root / "tron-native-capture.inputs.json").exists())

    def test_canonical_stores_are_not_build_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            with patch.object(build.Path, "home", return_value=home):
                for relative in [".pi/agent", ".tron/gateway", ".tron/workspace/state", ".tron/settings"]:
                    with self.assertRaisesRegex(ValueError, "canonical runtime"):
                        build.validate_output(home / relative / "tron-native-capture.node")
                build.validate_output(home / ".tron/workspace/files/builds/tron-native-capture.node")

    def test_broken_metadata_symlink_is_not_fresh(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / "tron-native-capture.node"
            output.with_suffix(".inputs.json").symlink_to(output.parent / "missing")
            with self.assertRaisesRegex(ValueError, "fresh"):
                build.validate_output(output)

    def test_raced_output_or_metadata_never_overwrites_and_preserves_partial_evidence(self):
        for raced_name in ["tron-native-capture.node", "tron-native-capture.inputs.json"]:
            with self.subTest(raced_name=raced_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                artifact = root / "compiled"
                artifact.write_bytes(b"compiled fixture")
                output = root / "tron-native-capture.node"
                actual_open = os.open
                injected = False

                def racing_open(path, flags, *args, **kwargs):
                    nonlocal injected
                    if path == output.name and not injected:
                        injected = True
                        (root / raced_name).write_bytes(b"other writer")
                    return actual_open(path, flags, *args, **kwargs)

                with patch.object(build.os, "open", side_effect=racing_open):
                    with self.assertRaises(FileExistsError):
                        build.publish(artifact, output, {"schema": 1})
                self.assertEqual((root / raced_name).read_bytes(), b"other writer")
                if raced_name.endswith(".json"):
                    self.assertEqual(output.read_bytes(), b"compiled fixture")

    def test_metadata_read_is_bounded_and_refuses_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = root / "inputs.json"
            metadata.write_bytes(b" " * 65537)
            with self.assertRaisesRegex(ValueError, "exceeds bounds"):
                build.verify_inputs(metadata)
            link = root / "linked.json"
            link.symlink_to(metadata)
            with self.assertRaises(OSError):
                build.verify_inputs(link)

    def test_canonical_header_set_has_no_node_cpp_or_ambient_engine_inputs(self):
        pin = json.loads((build.ROOT / build.OWNER / "node-headers.json").read_text())
        self.assertEqual(pin["version"], (build.ROOT / ".node-version").read_text().strip())
        self.assertEqual(set(pin["sha256"]), {"node_api.h", "node_api_types.h", "js_native_api.h", "js_native_api_types.h"})
        for digest in pin["sha256"].values():
            self.assertRegex(digest, r"^[a-f0-9]{64}$")


if __name__ == "__main__":
    unittest.main()
