import { mkdtemp, mkdir, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { EpisodicMemory } from "./episodic-memory.js";
import type { EpisodicSummarizer } from "./episodic-contract.js";

const roots: string[] = [];
const owners: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(owners.splice(0).map(owner => owner.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

const summarizer: EpisodicSummarizer = async request => {
  const last = request.turns.at(-1)!;
  return { role: "assistant", content: [{ type: "text", text: last.text.slice(-120) }], api: "openai-completions", provider: "test", model: "test", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "stop", timestamp: Date.now() } as never;
};

describe("episodic store checkpoint", () => {
  it("folds a legacy store forward before returning an opener", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-episodic-checkpoint-"));
    roots.push(root);
    const cwd = join(root, "project");
    const sessionDir = join(root, "sessions");
    await Promise.all([mkdir(cwd, { recursive: true }), mkdir(sessionDir, { recursive: true })]);
    const manager = SessionManager.create(cwd, sessionDir);
    manager.appendMessage({ role: "user", content: "checkpoint message", timestamp: Date.now() });
    const workspace = new TronWorkspace(join(root, "home"));
    owners.push(workspace);
    const memory = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!, summarizer, limits: { retryMs: 1 }, sleep: async () => {} });
    await memory.entriesCommitted(manager.getSessionId());
    const namespace = join(root, "home", "workspace", "state", "episodic", manager.getSessionId());
    const names = await readdir(namespace);
    expect(names.some(name => name.startsWith("checkpoint-"))).toBe(true);
    expect(names).toContain("checkpoint.current.json");
    expect(memory.status().messages).toBe(1);
    await memory.dispose();
    const reopened = await EpisodicMemory.open({ workspace, sessionId: manager.getSessionId(), sessionFile: manager.getSessionFile()!, summarizer, limits: { retryMs: 1 }, sleep: async () => {} });
    expect(reopened.status().messages).toBe(1);
    await reopened.dispose();
  });
});
