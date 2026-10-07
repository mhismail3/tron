import { mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
});
