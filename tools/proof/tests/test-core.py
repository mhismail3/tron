#!/usr/bin/env python3
"""Gate test for the real proof blocks of packages/core (tools/proof/README.md "Verify").

For every block with a mutate.json, with the pinned toolchain and the repository's own CLI:

1. `scripts/tron proof check` passes on a fresh cache (every block verified now, not remembered).
2. `scripts/tron proof packet <block>` regenerates exactly the committed LAWS.md, has no packet problems,
   and its gates hold for the current sources: proof PASS, mutation report PASS and not STALE, REVIEW.json
   for the current block hash with every law ACCEPT.
3. `scripts/tron proof facade <block> --check`: the checked-in compiled core and façade in the block's shell
   (block.json "shell") are exactly what the current sources generate, and the packet shows the block cut over.

And for the protocol source packages/core/wire/Protocol.dfy: the Gateway's protocol types are what it
generates, and its TypeScript and Swift codecs agree (the protocol test of wire.test.mjs).

4. A block with a compiled method lists hand-made changes to it in `method-mutants.json` (`[{from, to}]`, each
   `from` text occurring once in the block's implementation): the mutation tool does not mutate a method, so
   each change must make `scripts/tron proof check` fail on a copy of the block with a verification error.

So an edit to a block that does not re-run its mutation check and review, or regenerate its packet and
façade, fails here. The review row is verified against the reviewer's transcript in this machine's Pi
session store (read only), so the test needs that transcript.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CORE = ROOT / "packages/core"
BLOCKS = sorted(path.parent for path in (CORE / "blocks").rglob("mutate.json"))


def tron(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(ROOT / "scripts/tron"), "proof", *args], capture_output=True, text=True, timeout=1800)


class CoreBlocksTest(unittest.TestCase):
    def test_protocol_is_generated_and_its_codecs_agree(self) -> None:
        run = subprocess.run([str(ROOT / "scripts/tron-node"), "exec", "node", "--test", "--test-name-pattern", "^protocol",
                              str(ROOT / "tools/proof/tests/wire.test.mjs")], capture_output=True, text=True, timeout=1800, cwd=ROOT)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("pass 1\n", run.stdout)


    def test_blocks_hold_their_gates(self) -> None:
        self.assertTrue(BLOCKS, "no proof blocks under packages/core/blocks")
        with tempfile.TemporaryDirectory(prefix="tron-proof-core.") as tmp:
            check = tron("check", "--cache", str(Path(tmp) / "cache.json"))
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn("proof check: PASS", check.stdout)
        for directory in BLOCKS:
            block = directory.relative_to(CORE / "blocks").as_posix()
            with self.subTest(block=block):
                packet = tron("packet", block)
                self.assertEqual(packet.returncode, 0, packet.stderr)
                rows = {line.split(" | ")[0][2:]: line for line in packet.stdout.splitlines() if line.startswith("| ")}
                # The review row is verified against the reviewer's transcript in this machine's Pi session store.
                self.assertRegex(rows["Independent review"], r"^\| Independent review \| ACCEPT by ", "review not verified here (transcript missing or stale)")
                self.assertEqual((directory / "LAWS.md").read_text(), packet.stdout,
                                 f"LAWS.md is not the current packet: run scripts/tron proof packet {block} --write")
                self.assertRegex(rows["Proof (pinned Dafny, --verify-included-files)"], r"\| PASS: ")
                self.assertRegex(rows["Mutation check"], r"^\| Mutation check \| PASS: ")
                current = re.search(r"Block hash: `([0-9a-f]{16})`", packet.stdout).group(1)
                review = json.loads((directory / "REVIEW.json").read_text())
                self.assertEqual(review["packetHash"], current, "REVIEW.json is for another version of the block")
                laws = json.loads((directory / "mutate.json").read_text())["laws"]
                self.assertEqual({law: review["laws"].get(law, {}).get("verdict") for law in laws}, {law: "ACCEPT" for law in laws})
                facade = tron("facade", block, "--check")
                self.assertEqual(facade.returncode, 0, facade.stdout + facade.stderr)
                # Every block is cut over: its shell runs the compiled core.
                self.assertRegex(rows["Cut over"], r"^\| Cut over \| the only implementation: ")

    def test_compiled_methods_reject_their_hand_mutants(self) -> None:
        for listed in sorted((CORE / "blocks").rglob("method-mutants.json")):
            block = listed.parent.relative_to(CORE / "blocks").as_posix()
            impl = Path(json.loads((listed.parent / "mutate.json").read_text())["impl"])
            source = (CORE / impl).read_text()
            mutants = json.loads(listed.read_text())
            self.assertTrue(mutants, f"{block}: no method mutants listed")

            def checked(text: str) -> subprocess.CompletedProcess:
                with tempfile.TemporaryDirectory(prefix="tron-proof-method-mutant.") as tmp:
                    for part in ("laws", "blocks"):
                        shutil.copytree(CORE / part, Path(tmp) / part)
                    (Path(tmp) / impl).write_text(text)
                    return tron("check", block, "--root", tmp, "--cache", str(Path(tmp) / "cache.json"))

            # The control: an unchanged copy verifies, so a rejection below is the change's doing.
            control = checked(source)
            self.assertEqual(control.returncode, 0, control.stdout + control.stderr)

            def rejected(mutant: dict[str, str]) -> str | None:
                if source.count(mutant["from"]) != 1:
                    return f"'{mutant['from']}' does not occur exactly once in {impl}"
                check = checked(source.replace(mutant["from"], mutant["to"]))
                # A verification error, not a change the compiler refuses.
                if check.returncode == 1 and re.search(r"finished with \d+ verified, [1-9]\d* errors?", check.stdout + check.stderr):
                    return None
                return f"'{mutant['from']}' -> '{mutant['to']}' was not rejected by the verifier:\n{(check.stdout + check.stderr)[-600:]}"

            with ThreadPoolExecutor(max_workers=3) as pool:
                failures = [failure for failure in pool.map(rejected, mutants) if failure]
            self.assertEqual(failures, [], f"{block}: {len(failures)} of {len(mutants)} method mutants not rejected")


if __name__ == "__main__":
    unittest.main()
