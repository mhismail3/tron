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
  8. The checksum-verified cache `tron-node install` fills is never found, so an
     agent without nvm cannot run anything; or a linked worktree misses the
     primary checkout's cache and must download the pinned Node again (#244).
  9. `pin` writes a version whose archives disagree with SHASUMS256.txt, edits
     only part of the pins, or writes digests that `install` then rejects; the
     pin -> install -> resolve journey is the update (and rollback) path.
 10. `pin` leaves a compiled-in copy of a pin (payload deployer, signed app,
     native client headers) behind, or a drifted copy goes unnamed (#245).
 11. `status` touches the network without --online, or --online does not report
     a newer patch, its security releases and the major's support window.

Release files are served from a temporary directory through file:// URLs in
the fixture checkout's own config/ci-toolchain.env.
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / ".node-version").read_text().strip()
SYSTEM_PATH = "/usr/bin:/bin"
ARCH = "arm64" if platform.machine() in ("arm64", "aarch64") else "x64"
MIRRORS = ("scripts/gateway-payload-deploy.mjs", "packages/mac-app/Sources/Server/Paths/GatewayPayloadStore.swift",
           "packages/mac-app/native-gateway-client/node-headers.json")
HEADERS = ("node_api.h", "node_api_types.h", "js_native_api.h", "js_native_api_types.h")
PIN_KEYS = ("TRON_NODE_ARM64_ARCHIVE_SHA256", "TRON_NODE_X64_ARCHIVE_SHA256", "TRON_NODE_ARM64_RUNTIME_SHA256",
            "TRON_NODE_X64_RUNTIME_SHA256", "TRON_NODE_NPM_VERSION", "TRON_NODE_NPM_TREE_SHA256")


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

    # --- the verified cache, release status and the pin update (#244) ---

    def release_checkout(self) -> Path:
        """The fixture checkout with the release commands' real collaborators and a
        config pointing every release URL at a local directory."""
        for name in ("install-ci-tools.sh", "hash-npm-runtime.py", "node-pin-mirrors.py"):
            shutil.copy2(ROOT / "scripts" / name, self.checkout / "scripts" / name)
        # The real compiled-in copies `pin` owns (scripts/node-pin-mirrors.py).
        for path in MIRRORS:
            (self.checkout / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, self.checkout / path)
        (self.checkout / "config").mkdir(exist_ok=True)
        self.dist = self.tmp / "dist"
        self.dist.mkdir(exist_ok=True)
        config = (ROOT / "config/ci-toolchain.env").read_text()
        config = "\n".join(
            f"TRON_NODE_ARCHIVE_BASE_URL=file://{self.dist}" if line.startswith("TRON_NODE_ARCHIVE_BASE_URL=")
            else f"TRON_NODE_RELEASE_SCHEDULE_URL=file://{self.dist}/schedule.json"
            if line.startswith("TRON_NODE_RELEASE_SCHEDULE_URL=") else line
            for line in config.splitlines()) + "\n"
        (self.checkout / "config/ci-toolchain.env").write_text(config)
        return self.checkout

    def pins(self) -> dict[str, str]:
        return dict(line.split("=", 1) for line in (self.checkout / "config/ci-toolchain.env").read_text().splitlines()
                    if line.split("=", 1)[0] in PIN_KEYS)

    def publish(self, version: str, npm_version: str = "11.0.0") -> None:
        """Official-layout macOS archives and SHASUMS256.txt for `version`."""
        release = self.dist / f"v{version}"
        release.mkdir(parents=True)
        sums = []
        for arch in ("arm64", "x64"):
            stage = self.tmp / f"stage-{version}-{arch}"
            top = stage / f"node-v{version}-darwin-{arch}"
            self.toolchain(top / "bin", version, f"cached-{arch}")
            npm = top / "lib/node_modules/npm"
            (npm / "bin").mkdir(parents=True)
            (npm / "package.json").write_text(json.dumps({"name": "npm", "version": npm_version}))
            (npm / "bin/npm-cli.js").write_text("// npm\n")
            (top / "include/node").mkdir(parents=True)
            for header in HEADERS:
                (top / "include/node" / header).write_text(f"/* {header} of v{version} */\n")
            archive = release / f"node-v{version}-darwin-{arch}.tar.gz"
            subprocess.run(["tar", "-czf", str(archive), "-C", str(stage), top.name], check=True)
            sums.append(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}")
        (release / "SHASUMS256.txt").write_text("\n".join(sums) + "\n")

    def tron_node(self, *argv: str, **environment: str) -> subprocess.CompletedProcess:
        return self.run_script([str(self.checkout / "scripts/tron-node"), *argv], **environment)

    def test_a_linked_worktree_resolves_the_primary_checkouts_verified_cache(self) -> None:
        primary = self.checkout
        subprocess.run(["git", "init", "-q", "-b", "main", str(primary)], check=True)
        subprocess.run(["git", "-C", str(primary), "add", "."], check=True)
        subprocess.run(["git", "-C", str(primary), "-c", "user.email=t@example.invalid", "-c", "user.name=t",
                        "commit", "-qm", "fixture"], check=True)
        worktree = self.tmp / "worktree"
        subprocess.run(["git", "-C", str(primary), "worktree", "add", "-q", str(worktree)], check=True)
        cached = self.toolchain(primary / f".ci-tools/node-v{VERSION}-{ARCH}/bin", VERSION, "cached")
        # The Gateway runtime is first on PATH and there is no nvm: only the cache can serve.
        result = self.run_script([str(worktree / "scripts/tron-node")], PATH=self.gateway_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(cached))
        # nvm's exact directory still wins over the cache.
        result = self.run_script([str(worktree / "scripts/tron-node")], PATH=self.gateway_path, NVM_DIR=str(self.nvm))
        self.assertEqual(result.stdout.strip(), str(self.nvm_node))
        # Without the cache the refusal names the verified install command.
        shutil.rmtree(primary / ".ci-tools")
        result = self.run_script([str(worktree / "scripts/tron-node")], PATH=self.gateway_path)
        self.assertEqual(result.returncode, 127)
        self.assertIn("scripts/tron-node install", result.stderr)

    def test_pin_then_install_then_resolve_moves_and_rolls_back_the_pin(self) -> None:
        self.release_checkout()
        self.publish("99.1.0", npm_version="11.5.0")
        before = self.pins()
        result = self.tron_node("pin", "99.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("major move", result.stdout)
        self.assertEqual((self.checkout / ".node-version").read_text(), "99.1.0\n")
        pinned = self.pins()
        self.assertEqual(pinned["TRON_NODE_NPM_VERSION"], "11.5.0")
        self.assertTrue(all(pinned[key] != before[key] for key in PIN_KEYS), pinned)
        # Every compiled-in copy follows: the payload deployer, the signed app's
        # payload validator and the native client's C header pins.
        deploy = (self.checkout / MIRRORS[0]).read_text()
        self.assertIn(f'PINNED_NPM_VERSION = "11.5.0";', deploy)
        self.assertIn(f'PINNED_NPM_TREE_SHA256 = "{pinned["TRON_NODE_NPM_TREE_SHA256"]}";', deploy)
        self.assertIn(f'== "{pinned["TRON_NODE_NPM_TREE_SHA256"]}" else', (self.checkout / MIRRORS[1]).read_text())
        headers = json.loads((self.checkout / MIRRORS[2]).read_text())
        self.assertEqual(headers["version"], "99.1.0")
        self.assertEqual(headers["sha256"]["node_api.h"],
                         hashlib.sha256(b"/* node_api.h of v99.1.0 */\n").hexdigest())
        mirrors = [sys.executable, str(self.checkout / "scripts/node-pin-mirrors.py"), "check"]
        self.assertEqual(subprocess.run(mirrors, capture_output=True, text=True).returncode, 0)
        # Drift in one compiled-in copy is named, so it cannot ship unnoticed.
        swift = self.checkout / MIRRORS[1]
        swift.write_text(swift.read_text().replace('== "11.5.0",', '== "10.0.0",'))
        drift = subprocess.run(mirrors, capture_output=True, text=True)
        self.assertEqual(drift.returncode, 1)
        self.assertIn("GatewayPayloadStore.swift: TRON_NODE_NPM_VERSION literal 10.0.0 differs from 11.5.0", drift.stderr)
        swift.write_text(swift.read_text().replace('== "10.0.0",', '== "11.5.0",'))
        # The real installer accepts exactly what pin recorded, and the resolver serves it.
        cache = self.tmp / "cache"
        result = self.tron_node("install", PATH=self.gateway_path, TRON_CI_TOOLS_DIR=str(cache))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], str(cache / f"node-v99.1.0-{ARCH}/bin/node"))
        # Rollback is the same command with the earlier version: every pin returns.
        self.publish("99.0.0", npm_version="11.4.0")
        self.assertEqual(self.tron_node("pin", "99.1.0").returncode, 0)
        moved = self.pins()
        self.assertEqual(self.tron_node("pin", "99.0.0").returncode, 0)
        self.assertEqual(self.tron_node("pin", "99.1.0").returncode, 0)
        self.assertEqual(self.pins(), moved)
        self.assertEqual(self.tron_node("pin", "99.0.0").returncode, 0)
        self.assertEqual(self.pins()["TRON_NODE_NPM_VERSION"], "11.4.0")
        self.assertEqual((self.checkout / ".node-version").read_text(), "99.0.0\n")

    def test_pin_refuses_an_archive_that_disagrees_with_shasums_and_writes_nothing(self) -> None:
        self.release_checkout()
        self.publish("99.1.0")
        archive = self.dist / "v99.1.0/node-v99.1.0-darwin-x64.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"tampered")
        before, version = self.pins(), (self.checkout / ".node-version").read_text()
        result = self.tron_node("pin", "99.1.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("node-v99.1.0-darwin-x64.tar.gz does not match SHASUMS256.txt", result.stderr)
        self.assertEqual(self.pins(), before)
        self.assertEqual((self.checkout / ".node-version").read_text(), version)
        self.assertNotEqual(self.tron_node("pin", "99.2").returncode, 0)

    def test_status_reports_offline_and_online_release_freshness(self) -> None:
        self.release_checkout()
        major = VERSION.split(".")[0]
        # Offline status reads nothing remote: the (absent) release files cannot fail it.
        result = self.tron_node("status", PATH=self.gateway_path, NVM_DIR=str(self.nvm))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"pin: v{VERSION}", result.stdout)
        self.assertIn(f"toolchain: {self.nvm_node}", result.stdout)
        self.assertIn("release check: skipped", result.stdout)
        self.assertNotEqual(self.tron_node("status", "--online").returncode, 0)
        newer = f"{major}.999.1"
        (self.dist / "index.json").write_text(json.dumps([
            {"version": "v1000.0.0", "date": "2099-01-01", "security": False},
            {"version": f"v{newer}", "date": "2099-01-02", "security": False},
            {"version": f"v{major}.999.0", "date": "2099-01-01", "security": True},
            {"version": f"v{VERSION}", "date": "2000-01-01", "security": False},
        ]))
        (self.dist / "schedule.json").write_text(json.dumps({
            f"v{major}": {"start": "2000-01-01", "lts": "2000-06-01", "maintenance": "2001-01-01", "end": "2098-01-01"},
            "v1000": {"start": "2001-01-01", "lts": "2001-06-01", "maintenance": "2098-01-01", "end": "2099-01-01"},
        }))
        result = self.tron_node("status", "--online", NVM_DIR=str(self.nvm))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"patch: behind; latest v{major}.x is v{newer}", result.stdout)
        self.assertIn(f"security releases v{major}.999.0", result.stdout)
        self.assertIn(f"scripts/tron-node pin {newer}", result.stdout)
        self.assertIn(f"major: v{major} is maintenance LTS since 2001-01-01, end of life 2098-01-01", result.stdout)
        self.assertIn("lts: v1000 is the active LTS major", result.stdout)
        # The report never edits the pin.
        self.assertEqual((self.checkout / ".node-version").read_text().strip(), VERSION)


if __name__ == "__main__":
    unittest.main(verbosity=2)
