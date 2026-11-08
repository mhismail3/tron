// Purpose: exercise hash-bound packet staleness through the shipped packet renderer.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(fileURLToPath(new URL("../../..", import.meta.url)));
const fixture = join(root, "tools/proof/tests/fixtures/mutate-demo");
const packet = join(root, "tools/proof/packet/packet.mjs");
test("packet marks a review stale after a block source edit", () => {
  const dir = mkdtempSync(join(tmpdir(), "proof-packet-"));
  try {
    cpSync(fixture, dir, { recursive: true });
    writeFileSync(join(dir, "REVIEW.json"), JSON.stringify({ packetHash: "old-hash", tier: "high-stakes" }));
    writeFileSync(join(dir, "Core.dfy"), readFileSync(join(dir, "Core.dfy"), "utf8") + "\n// edit\n");
    const run = spawnSync(process.execPath, [packet, dir, "--no-verify"], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /STALE \(reviewed old-hash, current [a-f0-9]+\)/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
