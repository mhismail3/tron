#!/usr/bin/env python3
"""Gate test for the real proof blocks of packages/core (tools/proof/README.md "Verify").

For every block with a mutate.json, with the pinned toolchain and the repository's own CLI:

1. `scripts/tron proof check` passes on a fresh cache (every block verified now, not remembered).
2. `scripts/tron proof packet <block>` regenerates exactly the committed LAWS.md, has no packet problems,
   and its gates hold for the current sources: proof PASS, mutation report PASS and not STALE, shadow
   match and not STALE, REVIEW.json for the current block hash with every law ACCEPT.
3. `scripts/tron proof facade <block> --check`: the checked-in compiled core and façade in
   packages/core/dist/<block> are exactly what the current sources generate.

So an edit to a block that does not re-run its mutation check, shadow and review, or regenerate its
packet, fails here. The reviewer transcript check reads Pi's session store; it is not re-derived here.
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
                self.assertEqual((directory / "LAWS.md").read_text(), packet.stdout,
                                 f"LAWS.md is not the current packet: run scripts/tron proof packet {block} --write")
                rows = {line.split(" | ")[0][2:]: line for line in packet.stdout.splitlines() if line.startswith("| ")}
                self.assertRegex(rows["Proof (pinned Dafny, --verify-included-files)"], r"\| PASS: ")
                self.assertRegex(rows["Mutation check"], r"^\| Mutation check \| PASS: ")
                self.assertRegex(rows["Shadow"], r"^\| Shadow \| match: ")
                self.assertNotIn("STALE", rows["Shadow"])
                current = re.search(r"Block hash: `([0-9a-f]{16})`", packet.stdout).group(1)
                review = json.loads((directory / "REVIEW.json").read_text())
                self.assertEqual(review["packetHash"], current, "REVIEW.json is for another version of the block")
                laws = json.loads((directory / "mutate.json").read_text())["laws"]
                self.assertEqual({law: review["laws"].get(law, {}).get("verdict") for law in laws}, {law: "ACCEPT" for law in laws})
                facade = tron("facade", block, "--check")
                self.assertEqual(facade.returncode, 0, facade.stdout + facade.stderr)


if __name__ == "__main__":
    unittest.main()
