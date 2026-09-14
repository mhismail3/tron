import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService, type KnowledgeGenerationModel } from "./knowledge-service.js";
import { KnowledgeStore } from "./knowledge-store.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function model(): KnowledgeGenerationModel {
  return {
    async reflect() { return "generated handoff"; },
    async assess() { return { summary: "Useful source", evidenceQuality: "high", freshness: "current" }; },
  };
}

describe("KnowledgeService integration", () => {
  it("routes source triage through the persisted source and model seam", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const source = await store.captureSource({ commandId: "service-source", record: {
      kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Retained source", text: "bounded source evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" },
    }});
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, () => model());
    const result = await service.invoke({ operation: "knowledge.source.triage", request: { commandId: "service-triage", sourceId: source.record.id, expectedRevision: source.record.revisionId } });
    expect(result).toMatchObject({ assessment: { summary: "Useful source", evidenceQuality: "high" } });
    expect((await store.read(source.record.id))?.content).toMatchObject({ assessment: { summary: "Useful source" } });
  });

  it("exposes typed connector sweeps to existing Automation tool callers", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {
      connector: async action => ({ operation: action.operation, accepted: true }),
    });
    const result = await service.tool({ action: "connectorSweep", commandId: "service-sweep", connector: "raindrop", dryRun: true, limit: 1 });
    expect(result.text).toContain("connector sweep completed");
    expect(result.details).toEqual({ operation: "knowledge.connector.run", accepted: true });
  });

  it("rejects connector and importer calls without an installed extension", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-knowledge-service-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    await expect(service.invoke({ operation: "knowledge.connector.status", request: { connector: "raindrop" } })).rejects.toMatchObject({ code: "unsupported" });
    await expect(service.invoke({ operation: "knowledge.import.dry-run", request: { commandId: "service-import", source: "synthetic", limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
  });
});
