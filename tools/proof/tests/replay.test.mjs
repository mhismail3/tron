// Integration test for `scripts/tron proof shadow <block> --days N` (tools/proof/README.md "Shadow and oracles"):
// the real block schedule/occurrence replays a corpus of tron-proof-traffic/1 records, as the Debug recorder writes
// them, of calls to the shipped packages/gateway/src/automations/schedule.ts. A faithful corpus over two days is a
// real-traffic match covering two days; one hand-corrupted recorded output is a mismatch naming that record; a
// malformed line, a foreign record and an empty corpus are errors, never a match.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

test("replayed Debug traffic is a real-traffic shadow that catches a corrupted record", async (t) => {
  const base = mkdtempSync(join(tmpdir(), "tron-proof-replay-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const ts = await import(join(ROOT, "packages/gateway/src/automations/schedule.ts"));
  let seed = 3;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const start = Date.parse("2026-11-01T00:00:00.000Z");
  const day = (d) => {
    const lines = [];
    for (let i = 0; i < 300; i++) {
      const anchor = start + Math.floor(rnd() * 2e9);
      const trigger = rnd() < 0.3 ? { kind: "once", at: new Date(anchor).toISOString() }
        : { kind: "interval", anchorAt: new Date(anchor).toISOString(), everySeconds: [60, 900, 3600, 86400][Math.floor(rnd() * 4)] };
      const now = anchor + Math.floor((rnd() - 0.2) * 1e8);
      const seam = ["next", "first", "classify"][i % 3];
      const input = seam === "next" ? { trigger, afterMs: now } : seam === "first" ? { trigger, nowMs: now }
        : { trigger, nextOccurrenceAt: ts.firstAutomationOccurrence(trigger, anchor - 1), nowMs: now, policy: rnd() < 0.5 ? "latest" : "skip" };
      const output = seam === "next" ? ts.nextAutomationOccurrence(trigger, now) : seam === "first" ? ts.firstAutomationOccurrence(trigger, now)
        : ts.classifyDueOccurrence(trigger, input.nextOccurrenceAt, now, input.policy);
      lines.push(JSON.stringify({ schema: "tron-proof-traffic/1", block: "schedule/occurrence", seam, seq: i + 1, at: `${d}T12:00:00.000Z`, input, output: output ?? null }));
    }
    return lines;
  };
  const corpus = join(base, "corpus");
  mkdirSync(corpus);
  const files = { "2026-11-06.jsonl": day("2026-11-06"), "2026-11-07.jsonl": day("2026-11-07") };
  const write = () => { for (const [name, lines] of Object.entries(files)) writeFileSync(join(corpus, name), `${lines.join("\n")}\n`); };
  write();
  const out = join(base, "SHADOW.json");
  const shadow = (days = 7) => {
    const run = spawnSync(join(ROOT, "scripts/tron"), ["proof", "shadow", "schedule/occurrence", "--days", String(days), "--corpus", corpus, "--out", out], { encoding: "utf8" });
    return { status: run.status, result: JSON.parse(readFileSync(out, "utf8")) };
  };

  const match = shadow();
  assert.equal(match.status, 0, JSON.stringify(match.result));
  assert.deepEqual([match.result.status, match.result.compared, match.result.mismatches, match.result.realTraffic, match.result.windowDays, match.result.corpus.first, match.result.corpus.last],
    ["match", 600, 0, true, 2, "2026-11-06", "2026-11-07"]);

  // A recorded output nudged by one millisecond: the core disagrees with that record only.
  const record = JSON.parse(files["2026-11-07.jsonl"][4]);
  assert.equal(record.seam, "first");
  record.output = new Date(Date.parse(record.output) + 1).toISOString();
  files["2026-11-07.jsonl"][4] = JSON.stringify(record);
  write();
  const mismatch = shadow();
  assert.equal(mismatch.status, 1);
  assert.deepEqual([mismatch.result.status, mismatch.result.mismatches], ["mismatch", 1]);
  assert.match(mismatch.result.firstMismatch.where, /2026-11-07\.jsonl:5$/);

  // The window counts day files: --days 1 replays only the newest day.
  files["2026-11-07.jsonl"] = day("2026-11-07");
  write();
  const window = shadow(1);
  assert.deepEqual([window.result.status, window.result.compared, window.result.windowDays], ["match", 300, 1]);

  for (const [name, line] of [["not JSON", "{"], ["foreign record", JSON.stringify({ schema: "tron-proof-traffic/1", block: "other/block", seam: "next", input: {}, output: null })]]) {
    writeFileSync(join(corpus, "2026-11-07.jsonl"), `${line}\n`);
    const broken = shadow();
    assert.deepEqual([broken.status, broken.result.status], [1, "error"], name);
  }
  rmSync(corpus, { recursive: true });
  const empty = shadow();
  assert.deepEqual([empty.status, empty.result.status], [1, "error"]);
  assert.match(empty.result.error, /no recorded traffic for schedule\/occurrence/);
});
