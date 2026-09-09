#!/usr/bin/env node
// Test-owned synthetic history only. This never connects to a Gateway or opens
// a user's session. Compile first; optional baseline is another compiled dist.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { arch, cpus, platform } from "node:os";
import { performance } from "node:perf_hooks";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { BlobStore } from "../dist/sessions/blob-store.js";
import { jsonNodeCount } from "../dist/protocol/json-budget.js";

const args = process.argv.slice(2);
const extended = args[0] === "--extended";
if (extended) args.shift();
if (args.length !== 0 && (args.length !== 2 || args[0] !== "--baseline")) {
  throw new Error("Usage: node --expose-gc scripts/measure-projection.mjs [--extended] [--baseline /path/to/compiled/dist]");
}
const candidatePath = new URL("../dist/sessions/projection.js", import.meta.url);
const baselinePath = args.length ? pathToFileURL(resolve(args[1], "sessions/projection.js")) : undefined;
const modules = [{ name: "candidate", path: candidatePath, projection: await import(candidatePath.href) }];
if (baselinePath) modules.unshift({ name: "baseline", path: baselinePath, projection: await import(baselinePath.href) });
const warmup = 10;
const repetitions = 30;
const deadline = performance.now() + 120_000;
const hash = value => createHash("sha256").update(value).digest("hex");
const percentile = (values, fraction) => [...values].sort((a, b) => a - b)[Math.ceil(values.length * fraction) - 1];
const samples = [];
for (const entries of extended ? [100, 1_000, 10_000, 25_000, 100_000] : [100, 1_000, 10_000]) {
  const manager = SessionManager.inMemory("/tmp/tron-synthetic-projection");
  for (let index = 0; index < entries; index++) {
    if (index % 4 === 1) manager.appendMessage(fauxAssistantMessage(`Assistant ${index}`, { timestamp: index }));
    else if (index % 4 === 2) manager.appendMessage({
      role: "toolResult", toolCallId: `call-${index}`, toolName: "read", isError: false,
      content: [{ type: "text", text: `Result ${index}` }], timestamp: index,
    });
    else manager.appendMessage({ role: "user", content: [{ type: "text", text: `Input ${index}` }], timestamp: index });
  }
  const canonical = manager.getBranch();
  const canonicalHash = hash(JSON.stringify(canonical));
  const blobs = new BlobStore();
  try {
  const records = modules.map(module => ({ module, durations: [], branchWalks: [], last: undefined }));
  for (let iteration = -warmup; iteration < repetitions; iteration++) {
    // Balance order in the same process; report samples rather than asserting
    // a machine-specific latency threshold in the ordinary unit suite.
    const order = iteration % 2 === 0 ? records : [...records].reverse();
    for (const record of order) {
      assert.ok(performance.now() < deadline, "synthetic workload exceeded its two-minute ceiling");
      assert.ok(process.memoryUsage().heapUsed < 512 * 1_048_576, "synthetic workload exceeded its heap ceiling");
      let branchWalks = 0;
      const reader = { getBranch: () => { branchWalks++; return manager.getBranch(); }, getSessionId: () => manager.getSessionId() };
      const started = performance.now();
      const page = record.module.projection.projectTranscriptPage(reader, blobs);
      const duration = performance.now() - started;
      assert.equal(page.total, entries);
      assert.equal(page.end, entries);
      assert.deepEqual(page.items.map(item => item.id), canonical.slice(page.start, page.end).map(entry => entry.id));
      assert.equal(page.end - page.start, page.items.length);
      // Independent canonical oracle: no assertion just compares a fitter to
      // itself. Role/text/identity and full baseline equality are both checked.
      assert.deepEqual(page.items.map(item => [item.role, item.content?.[0]?.text]),
        canonical.slice(page.start, page.end).map(entry => [entry.message.role, entry.message.content[0].text]));
      record.last = page;
      if (iteration >= 0) { record.durations.push(duration); record.branchWalks.push(branchWalks); }
    }
    if (records.length === 2) assert.deepEqual(records[0].last, records[1].last);
  }
  assert.equal(hash(JSON.stringify(manager.getBranch())), canonicalHash, "projection changed canonical input");
  for (const record of records) {
    const wire = record.module.projection.safeJson({ type: "response", id: "fixture", ok: true, result: record.last });
    const wireBytes = Buffer.byteLength(JSON.stringify(wire));
    const wireNodes = jsonNodeCount(wire, Infinity);
    assert.ok(wireBytes <= 1_048_576 && wireNodes <= 32_768);
    samples.push({ implementation: record.module.name, inputEntries: entries,
      inputBytes: Buffer.byteLength(JSON.stringify(canonical)), repetitions,
      branchWalks: [...new Set(record.branchWalks)], medianMs: percentile(record.durations, 0.5),
      p95Ms: percentile(record.durations, 0.95), minMs: Math.min(...record.durations), maxMs: Math.max(...record.durations),
      outputRows: record.last.items.length, outputBytes: wireBytes, outputNodes: wireNodes,
      samplesMs: record.durations });
  }
  } finally {
    await blobs.dispose();
  }
  global.gc?.();
}
console.log(JSON.stringify({ schema: 1, workload: "synthetic-warm-transcript-page", node: process.version,
  platform: platform(), arch: arch(), cpu: cpus()[0]?.model, warmup,
  implementations: await Promise.all(modules.map(async module => ({ name: module.name, compiledSHA256: hash(await readFile(module.path)) }))),
  memory: process.memoryUsage(), samples,
  limits: "Warm CPU-only projection, not cold runtime/catalog or peer fanout capacity; shared-host wall timings are not physical iOS or production qualification."
}, null, 2));
