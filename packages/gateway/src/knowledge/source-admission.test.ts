import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { validateKnowledgeRecord } from "./knowledge-contract.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-source-admission-")); roots.push(root);
  return new KnowledgeStore(new TronWorkspace(root));
}

describe("source admission lifecycle", () => {
  it("validates optional assessment usage without inventing missing historical cost", async () => {
    const store = await fixture();
    const source = await store.captureSource({ commandId: "source-usage-validation", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Synthetic usage", text: "evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
    const assessment = { summary: "Synthetic", evidenceQuality: "unknown", freshness: "unknown", generatedAt: "2026-01-01T00:00:00.000Z" };
    const record = (usage?: unknown) => ({ ...source.record, content: { ...source.record.content, assessment: { ...assessment, ...(usage === undefined ? {} : { usage }) } } });
    expect(() => validateKnowledgeRecord(record())).not.toThrow();
    const usage = { inputTokens: 100, outputTokens: 4, estimatedCostCents: 0.00042, pricing: "synthetic-price" };
    expect(() => validateKnowledgeRecord(record(usage))).not.toThrow();
    for (const invalid of [{ ...usage, inputTokens: -1 }, { ...usage, outputTokens: 0.5 }, { ...usage, estimatedCostCents: Infinity }, { ...usage, pricing: "x".repeat(201) }, {}]) {
      expect(() => validateKnowledgeRecord(record(invalid))).toThrow();
    }
  });
  it("keeps archive separate from privacy suppression and supports explicit restore", async () => {
    const store = await fixture();
    const source = await store.captureSource({ commandId: "source-admission-create", record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Synthetic source", uri: "https://example.test/source", text: "evidence", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
    const archiveRequest = { commandId: "source-admission-archive", recordId: source.record.id, expectedRevision: source.record.revisionId, status: "archived" as const, reason: "synthetic archive" };
    const archived = await store.setSourceAdmission(archiveRequest);
    const replayed = await store.setSourceAdmission(archiveRequest);
    expect(replayed.record.revisionId).toBe(archived.record.revisionId);
    expect((await store.list({ kind: "source" })).records).toHaveLength(0);
    expect(await store.read(source.record.id, archived.record.revisionId)).toBeNull();
    expect(await store.read(source.record.id, source.record.revisionId, false, true)).not.toBeNull();
    expect((await store.list({ kind: "source", includeArchived: true })).records[0]?.content.admission?.status).toBe("archived");
    expect((await store.read(source.record.id, archived.record.revisionId, false, true))?.content.admission?.reason).toBe("synthetic archive");
    const restored = await store.setSourceAdmission({ commandId: "source-admission-restore", recordId: source.record.id, expectedRevision: archived.record.revisionId, status: "retained", reason: "synthetic restore" });
    expect(restored.record.content.admission?.status).toBe("retained");
    expect((await store.list({ kind: "source" })).records).toHaveLength(1);
  });
});
