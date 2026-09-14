import { createHash } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { LegacyKnowledgeImporter } from "./legacy-import.js";

const execFile = promisify(execFileCallback);
const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(path => rm(path, { recursive: true, force: true }))); });

async function legacyFixture(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "tron-legacy-import-")); roots.push(root);
  await mkdir(join(root, "sources", "records"), { recursive: true }); await mkdir(join(root, "graph"), { recursive: true });
  await execFile("git", ["init", "-q", root]); await execFile("git", ["-C", root, "config", "user.email", "test@example.invalid"]); await execFile("git", ["-C", root, "config", "user.name", "Test"]);
  const evidence = Buffer.from("Historical extracted wiki evidence\n", "utf8"); const evidencePath = join(root, "held.md"); await writeFile(evidencePath, evidence);
  const { stdout } = await execFile("git", ["-C", root, "hash-object", "-w", "held.md"]); const blob = stdout.trim();
  const source = { schema_version: 1, source_id: "src-git-only", representation: "llm-wiki", status: "accepted", captured_at: "2026-01-02T03:04:05Z", content_sha256: createHash("sha256").update(evidence).digest("hex"), evidence_path: "missing/held.md", media_type: "text/markdown; profile=historical-extractor-output", sensitivity: "public", metadata: { canonical_url: "https://example.test/history", reference_title: "Historical evidence", usage_constraint: "Historical extract only", review_batch: "R001", legacy_provenance: { git_blob: blob } }, origin: { kind: "raindrop-held", locator: "raindrop:42" } };
  await writeFile(join(root, "sources", "records", "src-git-only.json"), JSON.stringify(source));
  await writeFile(join(root, "sources", "records", "src-missing.json"), JSON.stringify({ schema_version: 1, source_id: "src-missing", representation: "personal-os", status: "accepted", captured_at: "2025-05-01", sensitivity: "restricted", metadata: { reference_title: "Missing original", usage_constraint: "Do not reconstruct" }, evidence_path: null }));
  await writeFile(join(root, "graph", "entities.jsonl"), `${JSON.stringify({ entity_id: "ent-person", kind: "person", label: "A person", aliases: ["A"] })}\n`);
  await writeFile(join(root, "graph", "assertions.jsonl"), `${JSON.stringify({ assertion_id: "ast-old", assertion_type: "attribute", subject_id: "ent-person", predicate: "has_preference", value: { negated: true, channel: "email", qualification: "Historical only" }, basis: "direct", status: "superseded", supersedes: "ast-new", valid_from: "2024-01-01", valid_to: "2024-12-31", evidence: [{ source_id: "src-git-only", locator: "p. 1" }] })}\n${JSON.stringify({ assertion_id: "ast-new", assertion_type: "attribute", subject_id: "ent-person", predicate: "has_preference", value: { negated: false, channel: "chat" }, basis: "user-confirmed", status: "active", evidence: [{ source_id: "src-missing", locator: "reviewed metadata" }] })}\n`);
  await mkdir(join(root, "audits", "records"), { recursive: true }); await writeFile(join(root, "audits", "records", "audit-R001.json"), JSON.stringify({ audit_id: "audit-R001", assertions: [{ assertion_id: "ast-old" }] })); await mkdir(join(root, "reviews", "receipts"), { recursive: true }); await writeFile(join(root, "reviews", "receipts", "review-R001.json"), JSON.stringify({ batch_id: "R001", receipt_id: "receipt-R001", result_revision: "result-revision-1" }));
  await execFile("git", ["-C", root, "add", "."]); await execFile("git", ["-C", root, "commit", "-qm", "fixture"]);
  return root;
}

describe("LegacyKnowledgeImporter", () => {
  it("dry-runs deterministically, reads a verified Git-only blob, and preserves lineage", async () => {
    const root = await legacyFixture(); const destination = await mkdtemp(join(tmpdir(), "tron-import-dest-")); roots.push(destination); const store = new KnowledgeStore(new TronWorkspace(destination));
    const importer = new LegacyKnowledgeImporter(store, { roots: { "llm-wiki": root } });
    const first = await importer.execute({ commandId: "import-dry-run", source: "llm-wiki", scope: { kinds: ["sources", "entities", "assertions"] } });
    const second = await importer.execute({ commandId: "import-dry-run-2", source: "llm-wiki", scope: { kinds: ["sources", "entities", "assertions"] } });
    expect(first.planHash).toBe(second.planHash); expect(first.selected).toBe(5); expect(first.warnings.some(item => item.includes("src-missing"))).toBe(true);
    const result = await importer.execute({ commandId: "import-run", source: "llm-wiki", expectedPlanHash: first.planHash, scope: { kinds: ["sources", "entities", "assertions"] } });
    expect(result.completed).toBe(true); expect(result.imported).toBe(5);
    const gitSource = (await store.read("import:llm-wiki:source:src-git-only"))!; expect(gitSource.content).toMatchObject({ captureDisposition: "complete", retention: { evidenceAvailable: true, usageConstraint: "Historical extract only" } }); expect(gitSource.importOrigin?.review).toMatchObject({ batch: "R001", receiptId: "receipt-R001", resultRevision: "result-revision-1" });
    const missing = await store.read("import:llm-wiki:source:src-missing"); expect(missing?.content).toMatchObject({ captureDisposition: "metadata-only", retention: { evidenceAvailable: false } });
    const old = await store.read("import:llm-wiki:assertion:ast-old"); expect(old).toMatchObject({ importOrigin: { recordId: "ast-old", review: { auditId: "audit-R001" } }, relations: [{ type: "related" }, { type: "supersedes", recordId: "import:llm-wiki:assertion:ast-new" }] }); expect(old?.kind === "note" && old.content.fields?.find(field => field.field === "value")).toMatchObject({ value: { negated: true, channel: "email", qualification: "Historical only" }, certainty: "external" });
  });

  it("records exact batch progress and resumes an interrupted batch idempotently", async () => {
    const root = await legacyFixture(); const destination = await mkdtemp(join(tmpdir(), "tron-import-dest-")); roots.push(destination);
    const importer = new LegacyKnowledgeImporter(new KnowledgeStore(new TronWorkspace(destination)), { roots: { "llm-wiki": root } });
    const dry = await importer.execute({ commandId: "import-dry-limit", source: "llm-wiki", limit: 1 });
    const first = await importer.execute({ commandId: "import-run-limit", source: "llm-wiki", expectedPlanHash: dry.planHash, limit: 1 }); expect(first.completed).toBe(true); expect(first.imported).toBe(1);
    const retry = await importer.execute({ commandId: "import-run-limit-retry", source: "llm-wiki", expectedPlanHash: dry.planHash, limit: 1 }); expect(retry.completed).toBe(true); expect(retry.resumed).toBe(1); expect(retry.imported).toBe(0);
    await expect(importer.execute({ commandId: "import-absolute", source: root, limit: 1 })).rejects.toThrow("explicitly named");
  });
});
