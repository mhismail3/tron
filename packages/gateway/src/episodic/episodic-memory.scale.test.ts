import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { afterAll, afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, fauxProvider, fauxText, type Message, type TranscriptContext } from "@earendil-works/pi-ai";
import { ModelRuntime, SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import type { EpisodicSummarizer } from "./episodic-contract.js";
import { createModelRuntimeSummarizer } from "./episodic-compactor.js";
import { EpisodicMemory } from "./episodic-memory.js";
import { decodeContextRuns, encodeContextRuns, foldView, foldViewSliced, nodeAddress } from "./episodic-tree.js";

/*
 * Scale measurements, run by `npm run test:scale` and never by the focused
 * suite. They measure the refold, the invalidation cost of an early edit, and
 * the size of a node's recorded context; they assert the round trips that make
 * those numbers meaningful, not the numbers themselves.
 *
 * The artifact is packages/gateway/test-results/episodic-memory/scale.json.
 */

import { fileURLToPath } from "node:url";
const GATEWAY_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const REPORT_PATH = join(GATEWAY_ROOT, "test-results/episodic-memory/scale.json");
const PLACEHOLDER_BYTES = Buffer.byteLength("(not summarized yet: zoom it)", "utf8");

interface ScaleReport {
  generatedAt: string;
  refold: Array<{ messages: number; ms: number; parts: number; worstSliceMs: number; sliceMessages: number }>;
  contextEncoding: { parts: number; addresses: number; addressListBytes: number; runBytes: number; runs: number };
  earlyEdit: { messages: number; nodesBefore: number; invalidated: number; chunks: number } | null;
}

const report: ScaleReport = { generatedAt: new Date().toISOString(), refold: [], contextEncoding: { parts: 0, addresses: 0, addressListBytes: 0, runBytes: 0, runs: 0 }, earlyEdit: null };

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
afterAll(async () => {
  await mkdir(join(GATEWAY_ROOT, "test-results/episodic-memory"), { recursive: true });
  const { writeFile } = await import("node:fs/promises");
  await writeFile(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`episodic scale: refold ${report.refold.map(entry => `${entry.messages}=${entry.ms.toFixed(0)}ms(slice<=${entry.worstSliceMs.toFixed(1)}ms)`).join(" ")}, context ${report.contextEncoding.parts} parts ${report.contextEncoding.addressListBytes}B -> ${report.contextEncoding.runBytes}B, early edit ${report.earlyEdit ? `${report.earlyEdit.invalidated}/${report.earlyEdit.nodesBefore}` : "not measured"}`);
});

describe("episodic memory scale", () => {
  it("refolds a 100k-message view in bounded synchronous slices", async () => {
    for (const messages of [10_000, 100_000]) {
      const built = new Set<string>();
      for (let level = 0; 2 ** level <= messages; level += 1) {
        const span = 2 ** level;
        for (let index = 0; (index + 1) * span <= messages; index += 1) built.add(nodeAddress(level, index));
      }
      // The fold's own reads are the synchronous work; the gap between two of
      // them is the slice the event loop is blocked for.
      let last = performance.now();
      let worstSlice = 0;
      const bytesOf = (part: { level: number; index: number }): { built: boolean; bytes: number } => {
        const now = performance.now();
        worstSlice = Math.max(worstSlice, now - last);
        last = now;
        return built.has(nodeAddress(part.level, part.index)) ? { built: true, bytes: 250 } : { built: false, bytes: PLACEHOLDER_BYTES };
      };
      const started = performance.now();
      let eventLoopTurns = 0;
      let done = false;
      const countTurn = (): void => {
        eventLoopTurns += 1;
        if (!done) setImmediate(countTurn);
      };
      setImmediate(countTurn);
      const folding = foldViewSliced(messages, 128_000, bytesOf, key => built.has(key)).finally(() => { done = true; });
      const parts = await folding;
      const refoldMs = performance.now() - started;
      const refoldWorstSliceMs = worstSlice;
      const reference = foldView(messages, 128_000, bytesOf, key => built.has(key));
      report.refold.push({ messages, ms: refoldMs, parts: parts.length, worstSliceMs: refoldWorstSliceMs, sliceMessages: 2_000 });
      expect(parts).toEqual(reference);
      expect(eventLoopTurns).toBeGreaterThan(1);
    }
    expect(report.refold).toHaveLength(2);
    // The sliced fold hands the loop back, so no single synchronous stretch is
    // the whole fold.
    expect(report.refold[1]!.worstSliceMs).toBeLessThan(report.refold[1]!.ms);
  }, 300_000);

  it("encodes a node's context as level runs at production VIEW size", () => {
    const messages = 5_000;
    const bytesOf = (): { built: boolean; bytes: number } => ({ built: true, bytes: 400 });
    const view = foldView(messages, 128_000, bytesOf, () => true);
    const runs = encodeContextRuns(view);
    const addresses = decodeContextRuns(runs);
    const expected = view.map(part => nodeAddress(part.level, part.index));
    // The run encoding reconstructs every address exactly, in order.
    expect(addresses).toEqual(expected);
    report.contextEncoding = {
      parts: view.length,
      addresses: addresses.length,
      // The full address list a record would have carried before this encoding.
      addressListBytes: JSON.stringify(expected).length,
      runBytes: JSON.stringify(runs).length,
      runs: runs.length,
    };
    expect(report.contextEncoding.runBytes).toBeLessThan(report.contextEncoding.addressListBytes);
    expect(view.length).toBeGreaterThan(100);
  }, 300_000);

  it("measures how many nodes an early edit invalidates in a 1,000-message history", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-scale-"));
    roots.push(root);
    const home = join(root, "home");
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "first prompt", timestamp: Date.now() });
    const workspace = new TronWorkspace(home);
    owners.push(workspace);
    const faux = fauxProvider({ provider: "tron-episodic-scale", models: [{ id: "compactor", reasoning: false }] });
    const modelRuntime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null, refreshOnCreate: false });
    modelRuntime.registerNativeProvider(faux.provider);
    const model = faux.getModel();
    const base = createModelRuntimeSummarizer(modelRuntime, model);
    const summarizer: EpisodicSummarizer = async (request) => {
      faux.appendResponses([(context: TranscriptContext) => {
        const last = [...context.messages].reverse().find(message => message.role === "user");
        // The compactor sends its context as cache pieces (#466), so the user
        // message is text blocks, not one string.
        const content = last && last.role === "user" ? last.content : "";
        const text = typeof content === "string" ? content
          : content.flatMap(part => part.type === "text" ? [part.text] : []).join("");
        return fauxAssistantMessage(text.replace(/\s+/gu, " ").trim().slice(-200));
      }]);
      return base(request);
    };
    const memory = await EpisodicMemory.open({
      workspace, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!, modelRuntime, model,
      summarizer,
      limits: { viewBytes: 8_192, jobs: 8, retryMs: 1 }, sleep: async () => {},
    });
    // The fixture's seed message plus 999 more make a 1,000-message history.
    for (let index = 0; index < 499; index += 1) {
      manager.appendMessage({ role: "user", content: `thousand case prompt ${index} ${"k".repeat(600)}`, timestamp: Date.now() } satisfies Message);
      manager.appendMessage(fauxAssistantMessage([fauxText(`reply ${index} ${"l".repeat(600)}`)]));
    }
    manager.appendMessage({ role: "user", content: `thousand case prompt 999 ${"k".repeat(600)}`, timestamp: Date.now() } satisfies Message);
    await memory.entriesCommitted(manager.getSessionId());
    const nodesBefore = memory.status().nodes.total;
    const nodeWrites: Array<Record<string, unknown>> = [];
    const storeOwner = memory as unknown as { store: { appendNode(record: unknown): Promise<void> } };
    const appendNode = storeOwner.store.appendNode.bind(storeOwner.store);
    storeOwner.store.appendNode = async record => {
      await appendNode(record);
      nodeWrites.push(record as Record<string, unknown>);
    };
    const target = manager.getBranch().filter(entry => entry.type === "message")[1]!;
    const invalidationStart = nodeWrites.length;
    manager.appendContextEdit(target.id, { content: "early replacement" });
    await memory.entriesCommitted(manager.getSessionId());
    const invalidations = nodeWrites.slice(invalidationStart).filter(record => typeof record.nodes === "string");
    const invalidated = invalidations.reduce((total, record) => total + (record.nodes as string).split(" ").filter(code => code !== "").length, 0);
    report.earlyEdit = { messages: memory.status().messages, nodesBefore, invalidated, chunks: invalidations.length };
    expect(memory.status().messages).toBe(1_000);
    expect(invalidated).toBeGreaterThan(0);
    expect(invalidated).toBeLessThanOrEqual(nodesBefore);
    expect(memory.status().blocked).toBeNull();
    await memory.dispose();
  }, 900_000);
});
