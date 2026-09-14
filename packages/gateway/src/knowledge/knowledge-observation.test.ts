import { afterEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { DEFAULT_KNOWLEDGE_CONFIG } from "./knowledge-contract.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeObservationService, type ObservationModel } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

async function fixture(model: ObservationModel): Promise<{ store: KnowledgeStore; observer: KnowledgeObservationService }> {
  const root = await mkdtemp(join(tmpdir(), "tron-observer-")); roots.push(root);
  const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
  const store = new KnowledgeStore(workspace);
  await store.configure("observer-config", {
    ...DEFAULT_KNOWLEDGE_CONFIG,
    eligibility: { ...DEFAULT_KNOWLEDGE_CONFIG.eligibility, sessionIds: ["session-1"] },
    observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true },
  });
  return { store, observer: new KnowledgeObservationService(store, model) };
}

const entries = [
  { type: "session", id: "session-header", timestamp: "2026-01-01T00:00:00Z" },
  { type: "message", id: "entry-1", timestamp: "2026-01-01T00:00:01Z", message: { role: "user", content: "Remember that the release is Friday." } },
  { type: "message", id: "entry-2", timestamp: "2026-01-01T00:00:02Z", message: { role: "assistant", content: [{ type: "text", text: "I will keep that date." }, { type: "thinking", thinking: "private reasoning omitted" }] } },
] as const;

const output = JSON.stringify({ observations: [{ text: "The release is planned for Friday.", attribution: "user", certainty: "qualified", observedAt: "2026-01-01T00:00:01Z" }] });

async function waitFor(predicate: () => boolean | Promise<boolean>): Promise<void> {
  await vi.waitFor(async () => expect(await predicate()).toBe(true), { timeout: 3_000, interval: 10 });
}

describe("KnowledgeObservationService", () => {
  it("coalesces and durably deduplicates canonical no-tool turns without forwarding thinking", async () => {
    const infer = vi.fn(async (input) => {
      expect(input.sourceText).not.toContain("private reasoning omitted");
      return output;
    });
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(1);
    const tool = await new KnowledgeService(store, observer).tool({ action: "search", query: "release", limit: 8 });
    expect(tool.text).toContain("release");
    expect(JSON.stringify(tool.details).length).toBeLessThan(8_000);
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await new Promise(resolve => setTimeout(resolve, 50));
    expect(infer).toHaveBeenCalledTimes(1);
    const nextEntries = [...entries, { type: "message", id: "entry-3", timestamp: "2026-01-01T00:00:03Z", message: { role: "user", content: "The date is still Friday." } }];
    observer.admit({ sessionId: "session-1", entries: nextEntries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 2);
    await waitFor(async () => (await store.list({ kind: "observation" })).records.length === 2);
    expect(infer.mock.calls[1]?.[0].sourceText).toContain("The date is still Friday");
    expect(infer.mock.calls[1]?.[0].sourceText).not.toContain("release is Friday");
    observer.dispose();
    await new Promise(resolve => setTimeout(resolve, 25));
  });

  it("treats empty allowlists as an excluded, incomplete scope", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-observer-scope-")); roots.push(root);
    const workspace = new TronWorkspace(join(root, "home")); workspaces.push(workspace);
    const store = new KnowledgeStore(workspace);
    await store.configure("observer-scope-config", { ...DEFAULT_KNOWLEDGE_CONFIG, observation: { ...DEFAULT_KNOWLEDGE_CONFIG.observation, enabled: true } });
    const infer = vi.fn(async () => output);
    const observer = new KnowledgeObservationService(store, { infer });
    observer.admit({ sessionId: "unselected-session", entries, outcome: "completed" });
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect(infer).not.toHaveBeenCalled();
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await new Promise(resolve => setTimeout(resolve, 25));
  });

  it("records failed model inference as a non-success coverage disposition", async () => {
    const { store, observer } = await fixture({ infer: async () => { throw new Error("synthetic provider failure"); } });
    observer.admit({ sessionId: "session-1", entries, outcome: "failed" });
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await new Promise(resolve => setTimeout(resolve, 25));
  });

  it("does not publish a late result after configuration revision changes", async () => {
    let release!: () => void;
    const blocked = new Promise<string>(resolve => { release = () => resolve(output); });
    const infer = vi.fn(async () => blocked);
    const { store, observer } = await fixture({ infer });
    observer.admit({ sessionId: "session-1", entries, outcome: "completed" });
    await waitFor(() => infer.mock.calls.length === 1);
    const config = await store.config();
    await store.configure("observer-reconfigure", { ...config, observation: { ...config.observation, maxOutputChars: config.observation.maxOutputChars - 1 } });
    release();
    await waitFor(async () => (await store.status()).coverageCount === 1);
    expect((await store.list({ kind: "observation" })).records).toHaveLength(0);
    observer.dispose();
    await new Promise(resolve => setTimeout(resolve, 25));
  });
});
