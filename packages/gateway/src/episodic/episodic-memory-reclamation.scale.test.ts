import { mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runInNewContext } from "node:vm";
import { setFlagsFromString } from "node:v8";
import { afterEach, describe, expect, it } from "vitest";
import { fauxAssistantMessage, type Message } from "@earendil-works/pi-ai";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import type { EpisodicSummarizer } from "./episodic-contract.js";
import { EpisodicMemory } from "./episodic-memory.js";

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
const summarizer: EpisodicSummarizer = async request => fauxAssistantMessage(request.turns.at(-1)!.text.slice(-120));

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

describe("episodic memory reclamation scale", () => {
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
      const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!, summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
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
      let memory: EpisodicMemory | null = await EpisodicMemory.open({ workspace, sessionId, sessionFile, summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
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
        reopened = await EpisodicMemory.open({ workspace, sessionId, sessionFile, summarizer, limits: { retryMs: 1, jobs: 4 }, sleep: async () => {} });
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
});
