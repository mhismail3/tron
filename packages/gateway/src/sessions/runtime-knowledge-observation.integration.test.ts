import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TrustService } from "../admin/trust-service.js";
import { KnowledgeStore } from "../knowledge/knowledge-store.js";
import { KnowledgeService } from "../knowledge/knowledge-service.js";
import { KnowledgeObservationService, type ObservationModelInput } from "../knowledge/knowledge-observation.js";
import { invocationReceipts } from "./invocation-receipts.js";
import { RuntimeRegistry } from "./runtime-registry.js";

describe.sequential("canonical conversation observation", () => {
  const cleanup: Array<() => Promise<void>> = [];
  const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
  afterEach(async () => {
    for (const release of cleanup.splice(0).reverse()) await release();
    if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
  });

  it.each([false, true])("captures a normal settled turn without backfill (global: %s)", async global => {
    const root = await mkdtemp(join(tmpdir(), "tron-conversation-observation-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    const agentDir = join(root, "agent");
    const cwd = join(root, "project");
    await Promise.all([mkdir(agentDir), mkdir(cwd)]);
    process.env.PI_CODING_AGENT_DIR = agentDir;
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false });
    const faux = fauxProvider({ provider: "tron-observation-test", tokensPerSecond: 100_000 });
    faux.setResponses([fauxAssistantMessage("Earlier answer."), fauxAssistantMessage("I will keep replies concise.")]);
    runtime.registerNativeProvider(faux.provider);
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000,
      modelRuntimeFactory: async () => runtime, trust: new TrustService(agentDir),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    cleanup.push(() => registry.dispose());
    const store = new KnowledgeStore(registry.knowledgeWorkspace());
    const infer = vi.fn(async (_input: ObservationModelInput) => JSON.stringify({ observations: [{
      text: "The user prefers concise replies.", attribution: "user", certainty: "certain",
      observedAt: "2026-01-01T00:00:00Z",
    }] }));
    registry.setKnowledgeService(new KnowledgeService(store, new KnowledgeObservationService(store, { infer })));
    await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel();
    await slot.setModel(model.provider, model.id);

    await slot.prompt("SYNTHETIC_EARLIER_PRIVATE_TURN");
    await vi.waitFor(() => expect(slot.isBusy).toBe(false));
    expect((await store.status()).state).toBe("uninitialized");
    expect(infer).not.toHaveBeenCalled();
    const config = await store.config();
    await store.configure("enable-conversation-observation", {
      ...config,
      eligibility: { ...config.eligibility, ...(global ? { allSessions: true as const } : {}), projectIds: global ? [] : [slot.cwd] },
      observation: { ...config.observation, enabled: true, model: `${model.provider}/${model.id}` },
    });
    const turn = await slot.prompt("I prefer concise replies.");
    await vi.waitFor(async () => expect((await store.list({ kind: "observation" })).records).toHaveLength(1), { timeout: 5_000 });
    expect(infer).toHaveBeenCalledTimes(1);
    const input = infer.mock.calls[0]![0];
    expect(input.sourceText).toContain("I prefer concise replies.");
    expect(input.sourceText).toContain("I will keep replies concise.");
    expect(input.sourceText).not.toContain("SYNTHETIC_EARLIER_PRIVATE_TURN");
    const canonical = slot.canonicalSessionEntries();
    const terminal = invocationReceipts(canonical, slot.id).find(receipt => receipt.receiptKind === "terminal" && receipt.operationId === turn.operationId);
    expect(terminal?.lifecycle).toBe("completed");
    expect(input.range.invocationIds).toEqual([terminal!.invocationId]);
    const records = (await store.recall({ query: "concise" })).records;
    expect(records).toHaveLength(1);
    expect(records[0]!.provenance.evidence?.map(evidence => evidence.sessionEntry?.entryId)).toEqual(input.range.entryIds);
    expect(input.range.entryIds.every(id => canonical.some(entry => entry.id === id))).toBe(true);
    expect((await store.status()).coverage).toMatchObject({ observedCount: 1, failedCount: 0 });
  });
});
