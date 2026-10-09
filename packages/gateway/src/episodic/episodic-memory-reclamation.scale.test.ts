import { appendFile, mkdir, mkdtemp, open as openFile, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { runInNewContext } from "node:vm";
import { getHeapSnapshot, setFlagsFromString } from "node:v8";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import type { EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { EpisodicStore } from "./episodic-store.js";
import { EPISODIC_DEFAULTS, EPISODIC_STORE_VERSION, type EpisodicMessageRecord } from "./episodic-contract.js";

import { singleChapterSource } from "../../test-support/episodic-chapter-source.js";
const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
// A provider's reply is a fresh string. A slice of the prompt would keep the whole
// prompt alive with each node's summary, which is not what a production summary does.
const summarizer: EpisodicSummarizer = async request => fauxAssistantMessage(Buffer.from(request.turns.at(-1)!.text.slice(-120), "utf8").toString("utf8"));

async function namespaceBytes(path: string): Promise<number> {
  let total = 0;
  const visit = async (directory: string): Promise<void> => {
    for (const name of await readdir(directory)) {
      const child = join(directory, name);
      const info = await stat(child);
      if (info.isDirectory()) await visit(child);
      else total += info.size;
    }
  };
  await visit(path);
  return total;
}

async function retainedEditPayloads(stream: AsyncIterable<Uint8Array> = getHeapSnapshot()): Promise<{ count: number; bytes: number }> {
  const decoder = new TextDecoder();
  const stringNodeBytes = new Map<number, number>();
  const candidateIndexes = new Set<number>();
  const retainedEditIds = new Set<string>();
  let typeField = -1;
  let nameField = -1;
  let selfSizeField = -1;
  let nodeFieldCount = 0;
  let stringType = -1;
  let nodeOffset = 0;
  let nodeCount = 0;
  let stringCount = 0;
  let currentType = -1;
  let currentName = -1;
  let totalBytes = 0;
  const stack: Array<{ kind: "object" | "array"; context: string; key?: string; index: number; expectingKey: boolean }> = [];
  let inString = false;
  let escaped = false;
  let keepString = false;
  let token = "";
  const complete = (frame: (typeof stack)[number]): void => {
    if (frame.kind === "array") frame.index += 1;
    else { frame.key = undefined; frame.expectingKey = true; }
  };
  const consumeScalar = (kind: "string" | "number", raw: string): void => {
    const frame = stack.at(-1);
    if (!frame) return;
    if (kind === "string" && frame.kind === "object" && frame.expectingKey) {
      if (frame.context !== "skip") frame.key = JSON.parse(raw) as string;
      frame.expectingKey = false;
      return;
    }
    if (frame.context === "node_fields" && kind === "string") {
      const field = JSON.parse(raw) as string;
      if (field === "type") typeField = frame.index;
      if (field === "name") nameField = frame.index;
      if (field === "self_size") selfSizeField = frame.index;
      nodeFieldCount = frame.index + 1;
    } else if (frame.context === "node_types_inner" && kind === "string" && JSON.parse(raw) === "string") {
      stringType = frame.index;
    } else if (frame.context === "nodes" && kind === "number") {
      const field = nodeOffset % nodeFieldCount;
      if (field === typeField) currentType = Number(raw);
      else if (field === nameField) currentName = Number(raw);
      else if (field === selfSizeField && currentType === stringType) {
        candidateIndexes.add(currentName);
        stringNodeBytes.set(currentName, (stringNodeBytes.get(currentName) ?? 0) + Number(raw));
      }
      nodeOffset += 1;
    } else if (frame.context === "strings" && kind === "string") {
      stringCount = frame.index + 1;
      if (!candidateIndexes.has(frame.index)) {
        complete(frame);
        return;
      }
      const value = JSON.parse(raw) as string;
      const markers = value.matchAll(/edit-(\d{2}) r{64,}/gu);
      let containsEditPayload = false;
      for (const marker of markers) {
        retainedEditIds.add(`edit-${marker[1]}`);
        containsEditPayload = true;
      }
      if (containsEditPayload) totalBytes += stringNodeBytes.get(frame.index) ?? 0;
    }
    complete(frame);
  };
  const childContext = (parent: (typeof stack)[number] | undefined): string => {
    if (!parent) return "root";
    if (parent.kind === "array") {
      if (parent.context === "node_types_outer") return parent.index === 0 ? "node_types_inner" : "skip";
      return "skip";
    }
    if (parent.context === "root") return parent.key === "snapshot" ? "snapshot" : parent.key === "nodes" ? "nodes" : parent.key === "strings" ? "strings" : "skip";
    if (parent.context === "snapshot" && parent.key === "meta") return "meta";
    if (parent.context === "meta" && parent.key === "node_fields") return "node_fields";
    if (parent.context === "meta" && parent.key === "node_types") return "node_types_outer";
    return "skip";
  };
  const punctuation = new Set(["{", "}", "[", "]", ":", ","]);
  const emitString = (): void => {
    if (keepString) consumeScalar("string", token);
    else {
      const frame = stack.at(-1);
      if (frame && frame.kind === "object" && frame.expectingKey) consumeScalar("string", '""');
      else if (frame) {
        if (frame.context === "strings") stringCount = frame.index + 1;
        complete(frame);
      }
    }
    token = "";
    inString = false;
  };
  try {
    for await (const chunk of stream) {
      const text = decoder.decode(chunk, { stream: true });
      for (let index = 0; index < text.length; index += 1) {
        const char = text[index]!;
        if (inString) {
          if (keepString) token += char;
          if (escaped) escaped = false;
          else if (char === "\\") escaped = true;
          else if (char === '"') emitString();
          continue;
        }
        if (char === '"') {
          inString = true;
          const frame = stack.at(-1);
          keepString = Boolean(frame && ((frame.kind === "object" && frame.expectingKey && frame.context !== "skip")
            || (frame.kind === "array" && (frame.context === "node_fields" || frame.context === "node_types_inner"
              || (frame.context === "strings" && candidateIndexes.has(frame.index))))));
          token = keepString ? '"' : "";
          continue;
        }
        const frame = stack.at(-1);
        const relevantNumber = frame?.kind === "array" && frame.context === "nodes";
        if (relevantNumber && (punctuation.has(char!) || /\s/u.test(char!)) && token.length > 0) {
          consumeScalar("number", token);
          nodeCount += 1;
          token = "";
        }
        if (punctuation.has(char!)) {
          if (char === "{" || char === "[") {
            const parent = stack.at(-1);
            stack.push({ kind: char === "{" ? "object" : "array", context: childContext(parent), index: 0, expectingKey: char === "{" });
          } else if (char === "}" || char === "]") {
            stack.pop();
            const parent = stack.at(-1);
            if (parent) complete(parent);
          }
          continue;
        }
        if (/\s/u.test(char!)) continue;
        if (relevantNumber) token += char;
      }
    }
  } finally {
    if ("destroy" in stream && typeof stream.destroy === "function") stream.destroy();
  }
  if (typeField < 0 || nameField < 0 || selfSizeField < 0 || nodeFieldCount === 0 || stringType < 0
    || nodeCount === 0 || nodeOffset % nodeFieldCount !== 0 || stringCount === 0
    || [...candidateIndexes].some(index => index >= stringCount)) {
    throw new Error("Heap snapshot edit-payload measurement was incomplete or misaligned");
  }
  return { count: retainedEditIds.size, bytes: totalBytes };
}

describe("episodic memory reclamation scale", () => {
  it("parses numeric node fields when a chunk ends immediately before a delimiter", async () => {
    const snapshot = JSON.stringify({
      snapshot: { meta: { node_fields: ["type", "name", "self_size"], node_types: [["string"]] } },
      nodes: [0, 2, 131_104],
      strings: ["node", "unused", "edit-00 " + "r".repeat(64)],
    });
    const bytes = Buffer.from(snapshot);
    const nodesStart = bytes.indexOf(Buffer.from('"nodes"'));
    const delimiter = bytes.indexOf(Buffer.from(","), nodesStart);
    const result = await retainedEditPayloads(Readable.from([bytes.subarray(0, delimiter), bytes.subarray(delimiter)]));
    expect(result).toEqual({ count: 1, bytes: 131_104 });
  });

  it("keeps store bytes bounded by live state over repeated early edits", async () => {
    const measurements: number[] = [];
    const liveNodeCounts: number[] = [];
    for (const edits of [1, 3, 10]) {
      const root = await mkdtemp(join(tmpdir(), "tron-episodic-reclaim-scale-"));
      roots.push(root);
      const cwd = join(root, "project");
      const sessions = join(root, "sessions");
      await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessions, { recursive: true })]);
      const manager = SessionManager.create(cwd, sessions);
      manager.appendMessage({ role: "user", content: "first stable message", timestamp: Date.now() });
      for (let index = 1; index < 50; index += 1) {
        manager.appendMessage({ role: "user", content: `stable prompt ${index}`, timestamp: Date.now() } satisfies Message);
        manager.appendMessage(fauxAssistantMessage(`stable reply ${index}`));
      }
      manager.appendMessage({ role: "user", content: "stable final message", timestamp: Date.now() });
      const workspace = new TronWorkspace(join(root, "home"));
      owners.push(workspace);
      const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionSource: singleChapterSource(manager.getSessionId(), manager.getSessionFile()!), summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
      await memory.entriesCommitted(manager.getSessionId());
      const target = manager.getBranch().find(entry => entry.type === "message")!;
      for (let edit = 0; edit < edits; edit += 1) {
        manager.appendContextEdit(target.id, { content: `replacement ${edit} ${"x".repeat(4_096)}` });
        await memory.entriesCommitted(manager.getSessionId());
      }
      expect(memory.status().messages).toBe(100);
      expect(memory.status().blocked).toBeNull();
      liveNodeCounts.push(memory.status().nodes.total);
      expect(memory.searchMessages(`replacement ${edits - 1}`, 0, 1).matches).toBe(1);
      const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
      const names = await readdir(namespace);
      expect(names.filter(name => /^checkpoint-[A-Za-z0-9.-]+$/u.test(name)).length).toBe(1);
      measurements.push(await namespaceBytes(namespace));
      await memory.dispose();
    }
    expect(new Set(liveNodeCounts).size).toBe(1);
    expect(Math.max(...measurements) - Math.min(...measurements)).toBeLessThan(32_768);
    console.log(`episodic reclamation scale bytes N=100 K=1,3,10: ${measurements.join(",")}`);
  }, 120_000);

  it("keeps sampled open peak and post-GC heap bounded across edit history", async () => {
    // Vitest workers are not launched with --expose-gc; enable a test-scoped
    // explicit collector so the post-GC measurement is repeatable.
    setFlagsFromString("--expose_gc");
    const collect = runInNewContext("gc") as () => void;
    const measurements: Array<{ edits: number; peakDelta: number; retainedDelta: number }> = [];
    const liveNodeCounts: number[] = [];
    for (const edits of [1, 10, 50]) {
      const root = await mkdtemp(join(tmpdir(), "tron-episodic-reclaim-heap-"));
      roots.push(root);
      const cwd = join(root, "project");
      const sessions = join(root, "sessions");
      await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessions, { recursive: true })]);
      let manager: SessionManager | null = SessionManager.create(cwd, sessions);
      manager.appendMessage({ role: "user", content: "heap baseline target", timestamp: Date.now() });
      for (let index = 1; index < 50; index += 1) {
        manager.appendMessage({ role: "user", content: `heap prompt ${index}`, timestamp: Date.now() } satisfies Message);
        manager.appendMessage(fauxAssistantMessage(`heap reply ${index}`));
      }
      manager.appendMessage({ role: "user", content: "heap final message", timestamp: Date.now() });
      const workspace = new TronWorkspace(join(root, "home"));
      owners.push(workspace);
      const sessionId = manager.getSessionId();
      const sessionFile = manager.getSessionFile()!;
      let memory: EpisodicMemory | null = await EpisodicMemory.open({ workspace, sessionId, sessionSource: singleChapterSource(sessionId, sessionFile), summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
      await memory.entriesCommitted(sessionId);
      const target = manager.getBranch().find(entry => entry.type === "message")!;
      for (let edit = 0; edit < edits; edit += 1) manager.appendContextEdit(target.id, { content: `fixed live replacement ${"x".repeat(128 * 1024)}` });
      await memory.entriesCommitted(sessionId);
      expect(memory.status().messages).toBe(100);
      expect(memory.status().blocked).toBeNull();
      await memory.dispose();
      // Drop the canonical manager's in-memory branch before measuring the
      // owner's reopen; only the files and bounded projection remain live.
      memory = null;
      manager = null;
      await Promise.resolve();
      for (let pass = 0; pass < 3; pass += 1) { collect!(); await new Promise<void>(resolve => setImmediate(resolve)); }
      const baseline = process.memoryUsage().heapUsed;
      let peak = baseline;
      const sampler = setInterval(() => { peak = Math.max(peak, process.memoryUsage().heapUsed); }, 1);
      let reopened: EpisodicMemory | undefined;
      try {
        reopened = await EpisodicMemory.open({ workspace, sessionId, sessionSource: singleChapterSource(sessionId, sessionFile), summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
        peak = Math.max(peak, process.memoryUsage().heapUsed);
        expect(reopened.status().messages).toBe(100);
        liveNodeCounts.push(reopened.status().nodes.total);
        for (let pass = 0; pass < 3; pass += 1) { collect!(); await new Promise<void>(resolve => setImmediate(resolve)); }
        const retained = process.memoryUsage().heapUsed - baseline;
        measurements.push({ edits, peakDelta: peak - baseline, retainedDelta: retained });
      } finally {
        clearInterval(sampler);
        await reopened?.dispose();
      }
    }
    const peaks = measurements.map(item => item.peakDelta);
    const retained = measurements.map(item => item.retainedDelta);
    expect(new Set(liveNodeCounts).size).toBe(1);
    expect(Math.max(...peaks) - Math.min(...peaks)).toBeLessThan(2 * 1024 * 1024);
    expect(Math.max(...retained) - Math.min(...retained)).toBeLessThan(2 * 1024 * 1024);
    console.log(`episodic open heap N=100 K=1,10,50: ${JSON.stringify(measurements)}`);
  }, 180_000);

  it("bounds legacy replay peak and retained source payloads as history grows", async () => {
    setFlagsFromString("--expose_gc");
    const collect = runInNewContext("gc") as () => void;
    const replayMeasurements: Array<{ revisions: number; logBytes: number; peakDelta: number; retainedDelta: number }> = [];
    for (const revisions of [100, 5_000, 75_000]) {
      const root = await mkdtemp(join(tmpdir(), "tron-episodic-legacy-heap-"));
      roots.push(root);
      const workspace = new TronWorkspace(join(root, "home"));
      owners.push(workspace);
      const sessionId = `legacy-heap-${revisions}`;
      const store = new EpisodicStore(workspace, sessionId, EPISODIC_DEFAULTS.maxStoreLineBytes);
      const base: EpisodicMessageRecord = {
        revision: 1, index: 0, entryId: "one-live-message", kind: "user", text: "x".repeat(900), omitted: false, omissions: [],
        sourceDigest: "source", projectedDigest: "projection", timestamp: "2026-01-01T00:00:00.000Z", sessionId,
      };
      await store.appendCatalog(base);
      await store.saveState({ version: EPISODIC_STORE_VERSION, generation: 0, cursor: null, blocked: null, spend: 0 });
      const catalogPath = join(root, "home", "workspace", "state", "episodic", sessionId, "catalog.jsonl");
      const writer = await openFile(catalogPath, "w", 0o600);
      let position = 0;
      let lines: string[] = [];
      const flush = async (): Promise<void> => {
        if (lines.length === 0) return;
        const chunk = Buffer.from(lines.join(""));
        let written = 0;
        while (written < chunk.length) {
          const result = await writer.write(chunk, written, chunk.length - written, position + written);
          written += result.bytesWritten;
        }
        position += chunk.length;
        lines = [];
      };
      for (let revision = 1; revision <= revisions; revision += 1) {
        lines.push(`${JSON.stringify({ ...base, revision: revision + 1 })}\n`);
        if (lines.length === 100) await flush();
      }
      await flush();
      await writer.sync();
      await writer.close();
      for (let pass = 0; pass < 3; pass += 1) { collect(); await new Promise<void>(resolve => setImmediate(resolve)); }
      const baseline = process.memoryUsage().heapUsed;
      let peak = baseline;
      const sampler = setInterval(() => { peak = Math.max(peak, process.memoryUsage().heapUsed); }, 1);
      try {
        const snapshot = await store.read();
        peak = Math.max(peak, process.memoryUsage().heapUsed);
        expect(snapshot.messages.size).toBe(1);
        expect(snapshot.messages.get(0)?.revision).toBe(revisions + 1);
      } finally { clearInterval(sampler); }
      for (let pass = 0; pass < 3; pass += 1) { collect(); await new Promise<void>(resolve => setImmediate(resolve)); }
      const logBytes = (await stat(catalogPath)).size;
      replayMeasurements.push({ revisions, logBytes, peakDelta: peak - baseline, retainedDelta: process.memoryUsage().heapUsed - baseline });
    }
    expect(replayMeasurements.at(-1)!.logBytes).toBeGreaterThan(64 * 1024 * 1024);
    expect(Math.max(...replayMeasurements.map(item => item.peakDelta)) - Math.min(...replayMeasurements.map(item => item.peakDelta))).toBeLessThan(32 * 1024 * 1024);
    expect(Math.max(...replayMeasurements.map(item => item.retainedDelta)) - Math.min(...replayMeasurements.map(item => item.retainedDelta))).toBeLessThan(8 * 1024 * 1024);
    console.log(`episodic legacy replay heap N=1 K=100,5000,75000: ${JSON.stringify(replayMeasurements)}`);

    const sourceMeasurements: Array<{ edits: number; baseline: number; peakDelta: number; retainedPayloads: number; retainedPayloadBytes: number }> = [];
    const liveNodeCounts: number[] = [];
    for (const edits of [1, 10, 30]) {
      const root = await mkdtemp(join(tmpdir(), "tron-episodic-source-heap-"));
      roots.push(root);
      const cwd = join(root, "project");
      const sessions = join(root, "sessions");
      await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessions, { recursive: true })]);
      let manager: SessionManager | null = SessionManager.create(cwd, sessions);
      manager.appendMessage({ role: "user", content: "resident baseline target", timestamp: Date.now() });
      for (let index = 1; index < 10; index += 1) {
        manager.appendMessage({ role: "user", content: `resident prompt ${index}`, timestamp: Date.now() } satisfies Message);
        manager.appendMessage(fauxAssistantMessage(`resident reply ${index}`));
      }
      manager.appendMessage({ role: "user", content: "resident final message", timestamp: Date.now() });
      const workspace = new TronWorkspace(join(root, "home"));
      owners.push(workspace);
      const sessionId = manager.getSessionId();
      const sessionFile = manager.getSessionFile()!;
      const memory = await EpisodicMemory.open({ workspace, sessionId, sessionSource: singleChapterSource(sessionId, sessionFile), summarizer, limits: { nodeBytes: 512, jobs: 4, retryMs: 1 }, sleep: async () => {} });
      await memory.entriesCommitted(sessionId);
      await memory.whenReady(memory.status().messages);
      const targetId = manager.getBranch().find(entry => entry.type === "message")!.id;
      let original: Buffer | null = await readFile(sessionFile);
      for (let edit = 0; edit < edits; edit += 1) {
        const text = `edit-${String(edit).padStart(2, "0")} ${"r".repeat(64 * 1024 - 9)}`;
        manager.appendContextEdit(targetId, { content: text });
      }
      let full: Buffer | null = await readFile(sessionFile);
      let suffix: Buffer | null = full.subarray(original!.length);
      const editFile = join(root, "context-edit-history.jsonl");
      await writeFile(editFile, suffix);
      const restored = join(root, "session-before-edits.jsonl");
      await writeFile(restored, original!);
      await rename(restored, sessionFile);
      original = null;
      full = null;
      suffix = null;
      manager = null;
      for (let pass = 0; pass < 3; pass += 1) { collect(); await new Promise<void>(resolve => setImmediate(resolve)); }
      const baseline = process.memoryUsage().heapUsed;
      let peak = baseline;
      const sampler = setInterval(() => { peak = Math.max(peak, process.memoryUsage().heapUsed); }, 1);
      const lineStream = createInterface({ input: createReadStream(editFile), crlfDelay: Infinity });
      let consumed = 0;
      try {
        consumed = await (async (): Promise<number> => {
          let count = 0;
          for await (const line of lineStream) {
            if (line.trim() === "") continue;
            await appendFile(sessionFile, `${line}\n`);
            await memory.entriesCommitted(sessionId);
            count += 1;
            expect(memory.status().messages).toBe(20);
            expect(memory.searchMessages(`edit-${String(count - 1).padStart(2, "0")}`, 0, 1).matches).toBe(1);
          }
          return count;
        })();
        lineStream.close();
      } finally { clearInterval(sampler); }
      expect(consumed).toBe(edits);
      liveNodeCounts.push(memory.status().nodes.total);
      peak = Math.max(peak, process.memoryUsage().heapUsed);
      if (edits === 1 || edits === 30) {
        const retained = await retainedEditPayloads();
        sourceMeasurements.push({ edits, baseline, peakDelta: peak - baseline, retainedPayloads: retained.count, retainedPayloadBytes: retained.bytes });
      }
      await memory.dispose();
    }
    expect(new Set(liveNodeCounts).size).toBe(1);
    console.log(`episodic owner source payloads N=20 K=1,30: ${JSON.stringify(sourceMeasurements)}`);
    const baseline = sourceMeasurements[0]!;
    // The owner can overlap one in-flight source cut with its current message payload;
    // allow that single bounded identity beyond K=1, never one per historical edit.
    expect(baseline.retainedPayloads).toBeGreaterThan(0);
    expect(baseline.retainedPayloadBytes).toBeGreaterThan(0);
    const boundedAllowance = baseline.retainedPayloads + 1;
    const extraPayloadBytes = Math.ceil(baseline.retainedPayloadBytes / (64 * 1024)) * 64 * 1024;
    expect(sourceMeasurements.at(-1)!.retainedPayloads).toBeLessThanOrEqual(boundedAllowance);
    expect(sourceMeasurements.at(-1)!.retainedPayloadBytes).toBeLessThanOrEqual(baseline.retainedPayloadBytes + extraPayloadBytes);
  }, 300_000);
});
