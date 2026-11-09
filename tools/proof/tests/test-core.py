#!/usr/bin/env python3
"""Gate test for the real proof blocks of packages/core (tools/proof/README.md "Verify").

For every block with a mutate.json, with the pinned toolchain and the repository's own CLI:

1. `scripts/tron proof check` passes on a fresh cache (every block verified now, not remembered).
2. `scripts/tron proof packet <block>` regenerates exactly the committed LAWS.md, has no packet problems,
   and its gates hold for the current sources: proof PASS, mutation report PASS and not STALE, shadow
   match and not STALE, REVIEW.json for the current block hash with every law ACCEPT.
3. `scripts/tron proof facade <block> --check`: the checked-in compiled core and façade in
   packages/core/dist/<block> are exactly what the current sources generate.
4. `scripts/tron proof shadow <block>` still matches today's shipped TypeScript.

And for the protocol source packages/core/wire/Protocol.dfy: the Gateway's protocol types are what it
generates, and its TypeScript and Swift codecs agree (the protocol test of wire.test.mjs).

So an edit to a block that does not re-run its mutation check, shadow and review, or regenerate its
packet, fails here. The review row is verified against the reviewer's transcript in this machine's Pi
session store (read only), so the test needs that transcript.
"""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
import unittest
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
                self.assertRegex(rows["Shadow"], r"^\| Shadow \| match: ")
                self.assertNotIn("STALE", rows["Shadow"])
                self.assertNotIn("not checked", rows["Shadow"])
                current = re.search(r"Block hash: `([0-9a-f]{16})`", packet.stdout).group(1)
                review = json.loads((directory / "REVIEW.json").read_text())
                self.assertEqual(review["packetHash"], current, "REVIEW.json is for another version of the block")
                laws = json.loads((directory / "mutate.json").read_text())["laws"]
                self.assertEqual({law: review["laws"].get(law, {}).get("verdict") for law in laws}, {law: "ACCEPT" for law in laws})
                facade = tron("facade", block, "--check")
                self.assertEqual(facade.returncode, 0, facade.stdout + facade.stderr)
                # The shadow comparison still runs against today's shipped TypeScript (a change there, such as a
                # new import, must not break the block's oracle).
                with tempfile.TemporaryDirectory(prefix="tron-proof-shadow.") as tmp:
                    out = Path(tmp) / "SHADOW.json"
                    shadow = tron("shadow", block, "--out", str(out))
                    self.assertEqual(shadow.returncode, 0, shadow.stderr)
                    self.assertEqual(json.loads(out.read_text())["status"], "match")


if __name__ == "__main__":
    unittest.main()
