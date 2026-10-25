import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemoryCredentialStore, fauxAssistantMessage, fauxProvider } from "@earendil-works/pi-ai";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { expect, it } from "vitest";
import { GatewayWorkRegistry } from "../kernel/run/gateway-work-registry.js";
import { ModelQueueOwner } from "../providers/model-queue.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { waitFor } from "../../test-support/wait-for.js";
import { knowledgeModelLimits } from "./knowledge-contract.js";
import { KnowledgeService, QueueKnowledgeModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";

it("keeps shutdown cancellation distinct from provider failure until summary work physically retires", async () => {
  const root = await mkdtemp(join(tmpdir(), "tron-summary-retirement-"));
  let release!: () => void;
  const held = new Promise<void>(resolve => { release = resolve; });
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  let signal: AbortSignal | undefined;
  const work = new GatewayWorkRegistry();
  const workspaces = [new TronWorkspace(join(root, "tron"))];
  let service: KnowledgeService | undefined;
  try {
    const faux = fauxProvider({ provider: "tron-summary-retirement", tokensPerSecond: 100_000 });
    const runtime = await ModelRuntime.create({ modelsPath: null, credentials: new InMemoryCredentialStore(), refreshOnCreate: false });
    runtime.registerNativeProvider(faux.provider);
    faux.setResponses([async (_context, options) => {
      signal = options?.signal;
      entered();
      // A provider may ignore cancellation while physical work is still running.
      await held;
      return fauxAssistantMessage(JSON.stringify({ text: "A late summary must not publish." }));
    }]);
    const store = new KnowledgeStore(workspaces[0]!);
    const capture = { commandId: "saved-source", record: { kind: "source" as const, scope: "research" as const,
      provenance: { actor: "user" as const, evidence: [] }, relations: [],
      content: { title: "Tides", text: "A saved tide table excerpt.", captureDisposition: "partial" as const, capturedAt: "2026-01-01T00:00:00Z" } } };
    const saved = await store.captureSource(capture);
    const model = faux.getModel();
    const queue = new ModelQueueOwner({ runtime, usage: { read: async () => ({ providers: [] }) }, queue: async () => [`${model.provider}/${model.id}`] });
    service = new KnowledgeService(store, {}, config => new QueueKnowledgeModel(queue, knowledgeModelLimits(config)), work);
    const request = { commandId: "shutdown-summary", sourceId: saved.record.id, expectedRevision: saved.record.revisionId };
    await service.invoke({ operation: "knowledge.source.summarize", request });
    await started;
    expect(work.facts()).toMatchObject([{ kind: "knowledge-curation" }]);

    service.dispose();
    expect(signal?.aborted).toBe(true);
    expect(work.size).toBe(1);
    expect(service.summaryJobs({ commandId: request.commandId }).running).toBe(1);
    release();
    await work.waitUntilSettled();
    const job = await waitFor(() => {
      const current = service!.summaryJobs({ commandId: request.commandId }).jobs[0];
      return current?.status === "failed" ? current : undefined;
    }, "the cancelled summary to retire");
    expect(job).toMatchObject({ status: "failed", code: "cancelled" });
    expect((await store.read(saved.record.id))?.content).not.toHaveProperty("summary");

    await workspaces[0]!.dispose();
    workspaces.push(new TronWorkspace(join(root, "tron")));
    const reopened = new KnowledgeStore(workspaces[1]!);
    expect((await reopened.read(saved.record.id))?.revisionId).toBe(saved.record.revisionId);
    expect((await reopened.captureSource(capture)).record.revisionId).toBe(saved.record.revisionId);
    const evidence = join(process.cwd(), "test-results", "knowledge-summary-retirement");
    await mkdir(evidence, { recursive: true });
    await writeFile(join(evidence, "report.json"), JSON.stringify({ job, remainingWork: work.size, committedSourceReopened: true }, null, 2));
  } finally {
    service?.dispose();
    release();
    await work.waitUntilSettled();
    for (const workspace of workspaces) await workspace.dispose();
    await rm(root, { recursive: true, force: true });
  }
});
