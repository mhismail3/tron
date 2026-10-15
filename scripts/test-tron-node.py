#!/usr/bin/env python3
"""Real-boundary regression for scripts/tron-node, the one repository resolver for
the pinned development Node (#242).

Every case runs the real resolver (and the real scripts/tron entry point) as a
process in a temporary checkout with stand-in toolchains and a scrubbed
environment.

Failure modes:
  1. A Gateway payload runtime first on PATH (as in every Tron agent shell)
     answers the pinned version and owns an npm alias, and is chosen over the
     pinned nvm Node.
  2. With only that runtime (or an app-bundle runtime) available, the resolver
     picks it, or fails without saying why and how to install the pinned Node.
  3. TRON_NODE_BIN is ignored, or a refused TRON_NODE_BIN silently falls back.
  4. A Node of the wrong version or without a sibling npm is accepted, or a
     proven Node later on PATH is never reached.
  5. `scripts/tron` Gateway commands run whatever `node` is first on PATH; the
     mutant control (the pre-#242 `exec node`) must reproduce it.
  6. `tron-node exec` does not put the resolved Node first or drops
     PYTHONDONTWRITEBYTECODE (#638).
  7. A real hardened-runtime Node without disable-library-validation (the signed
     payload binary, copied anywhere) is accepted. Runs only where such a binary
     is installed on this Mac.
"""
from __future__ import annotations

import glob
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / ".node-version").read_text().strip()
SYSTEM_PATH = "/usr/bin:/bin"


class TronNodeResolver(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tron-node-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.checkout = self.tmp / "checkout"
        (self.checkout / "scripts").mkdir(parents=True)
        (self.checkout / "packages/gateway/dist/admin").mkdir(parents=True)
        for name in ("tron-node", "tron"):
            shutil.copy2(ROOT / "scripts" / name, self.checkout / "scripts" / name)
        shutil.copy2(ROOT / ".node-version", self.checkout / ".node-version")
        (self.checkout / "packages/gateway/dist/admin/diagnose.js").write_text("// fixture\n")
        self.invocations = self.tmp / "invocations"
        self.invocations.write_text("")
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.nvm = self.tmp / "nvm"
        self.nvm_node = self.toolchain(self.nvm / f"versions/node/v{VERSION}/bin", VERSION, "nvm")
        # A payload in the layout bundle-gateway.sh stages and the Gateway installs:
        # <payload>/manifest.json, runtime/node-<arch>, runtime/bin-<arch>/{node,npm}.
        runtime = self.tmp / "payloads/stable/versions/1/runtime"
        real = self.toolchain(runtime / "real", VERSION, "payload")
        real.rename(runtime / "node-arm64")
        (runtime / "bin-arm64").mkdir()
        (runtime / "bin-arm64/node").symlink_to("../node-arm64")
        (runtime / "bin-arm64/npm").symlink_to("../real/npm")
        (runtime.parent / "manifest.json").write_text("{}\n")
        self.payload_node = runtime / "bin-arm64/node"
        self.gateway_path = f"{runtime / 'bin-arm64'}:{SYSTEM_PATH}"

    def toolchain(self, directory: Path, version: str, name: str, npm: bool = True) -> Path:
        """A stand-in Node answering `--version` and recording any other run."""
        directory.mkdir(parents=True, exist_ok=True)
        node = directory / "node"
        node.write_text(f'#!/bin/sh\nif [ "${{1:-}}" = --version ]; then echo "v{version}"; exit 0; fi\n'
                        f'echo "{name} $*" >> "{self.invocations}"\n')
        node.chmod(0o755)
        if npm:
            (directory / "npm").write_text("#!/bin/sh\nexit 0\n")
            (directory / "npm").chmod(0o755)
        return node

    def run_script(self, argv: list[str], **environment: str) -> subprocess.CompletedProcess:
        env = {"HOME": str(self.home), "PATH": SYSTEM_PATH, "NVM_DIR": str(self.tmp / "no-nvm"), **environment}
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60)

    def resolve(self, **environment: str) -> subprocess.CompletedProcess:
        return self.run_script([str(self.checkout / "scripts/tron-node")], **environment)

    def assertResolves(self, expected: Path, **environment: str) -> None:
        result = self.resolve(**environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(expected))

    def assertRefused(self, *messages: str, **environment: str) -> None:
        result = self.resolve(**environment)
        self.assertEqual(result.returncode, 127, f"accepted {result.stdout.strip()!r}")
        self.assertEqual(result.stdout, "")
        for message in messages:
            self.assertIn(message, result.stderr)

    def test_pinned_nvm_node_wins_over_a_payload_runtime_first_on_path(self) -> None:
        self.assertResolves(self.nvm_node, PATH=self.gateway_path, NVM_DIR=str(self.nvm))

    def test_a_lone_payload_runtime_is_refused_with_reason_and_install_hint(self) -> None:
        self.assertRefused(f"{self.payload_node}: it is a Gateway payload runtime", f"nvm install {VERSION}",
                           PATH=self.gateway_path)

    def test_an_app_bundle_runtime_is_refused(self) -> None:
        app = self.tmp / "Tron.app/Contents/Resources/bin"
        self.toolchain(app, VERSION, "app")
        self.assertRefused(f"{app / 'node'}: it is inside an app bundle", PATH=f"{app}:{SYSTEM_PATH}")

    def test_tron_node_bin_is_honoured_and_a_refused_one_never_falls_back(self) -> None:
        explicit = self.toolchain(self.tmp / "explicit", VERSION, "explicit")
        self.assertResolves(explicit, PATH=self.gateway_path, NVM_DIR=str(self.nvm), TRON_NODE_BIN=str(explicit))
        self.assertRefused(f"TRON_NODE_BIN={self.payload_node} is refused: it is a Gateway payload runtime",
                           PATH=self.gateway_path, NVM_DIR=str(self.nvm), TRON_NODE_BIN=str(self.payload_node))
        self.assertRefused("not an absolute path", NVM_DIR=str(self.nvm), TRON_NODE_BIN="explicit/node")

    def test_wrong_version_and_missing_npm_are_skipped_for_a_later_proven_node(self) -> None:
        old = self.toolchain(self.tmp / "old", "1.0.0", "old")
        no_npm = self.toolchain(self.tmp / "nonpm", VERSION, "nonpm", npm=False)
        ambient = self.toolchain(self.tmp / "ambient", VERSION, "ambient")
        # The proven Node is last on PATH: chosen only if both earlier ones are
        # skipped, and always before any host Homebrew Node.
        self.assertResolves(ambient, PATH=f"{old.parent}:{no_npm.parent}:{ambient.parent}:{SYSTEM_PATH}")
        self.assertRefused(f"reports v1.0.0, not v{VERSION}", TRON_NODE_BIN=str(old))
        self.assertRefused("has no sibling npm", TRON_NODE_BIN=str(no_npm))

    def test_scripts_tron_gateway_commands_run_the_resolved_node(self) -> None:
        tron = self.checkout / "scripts/tron"
        result = self.run_script([str(tron), "diagnose"], PATH=self.gateway_path, NVM_DIR=str(self.nvm))
        self.assertEqual(result.returncode, 0, result.stderr)
        runs = self.invocations.read_text()
        self.assertRegex(runs, r"(?m)^nvm .*diagnose\.js")
        self.assertNotIn("payload", runs)
        # Mutant control: without the resolver, the entry point reaches PATH's node.
        tron.write_text("".join(line for line in tron.read_text().splitlines(keepends=True)
                                if line.strip() != "use_pinned_node"))
        self.invocations.write_text("")
        self.run_script([str(tron), "diagnose"], PATH=self.gateway_path, NVM_DIR=str(self.nvm))
        self.assertIn("payload", self.invocations.read_text(), "the mutant control did not reach the payload runtime")

    def test_exec_puts_the_resolved_node_first_and_disables_bytecode(self) -> None:
        result = self.run_script([str(self.checkout / "scripts/tron-node"), "exec", "/bin/sh", "-c",
                                  'command -v node; echo "$PYTHONDONTWRITEBYTECODE"'],
                                 PATH=self.gateway_path, NVM_DIR=str(self.nvm))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.nvm_node), "1"])

    @unittest.skipUnless(Path("/usr/bin/codesign").exists(), "macOS code signatures")
    def test_a_copied_hardened_runtime_without_library_validation_opt_out_is_refused(self) -> None:
        signed = sorted(glob.glob(str(Path.home() / ".tron/gateway/payloads/*/versions/*/runtime/node-arm64")))
        if not signed:
            self.skipTest("no installed signed Gateway runtime on this Mac")
        copy = self.tmp / "copied"
        copy.mkdir()
        shutil.copy2(signed[-1], copy / "node")
        version = subprocess.run([str(copy / "node"), "--version"], capture_output=True, text=True).stdout.strip()
        (copy / "npm").write_text("#!/bin/sh\nexit 0\n")
        (copy / "npm").chmod(0o755)
        (self.checkout / ".node-version").write_text(version.removeprefix("v") + "\n")
        self.assertRefused("its hardened-runtime signature refuses unsigned native add-ons", TRON_NODE_BIN=str(copy / "node"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
