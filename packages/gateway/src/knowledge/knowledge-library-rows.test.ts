import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KNOWLEDGE_PREVIEW_BATCH_ITEMS, KNOWLEDGE_PREVIEW_MAX_BYTES } from "./knowledge-store.js";
import type { KnowledgeRecord } from "./knowledge-contract.js";
import { sourceEvidenceDigest } from "./knowledge-store.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "tron-library-rows-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  return { root, store };
}

/** Failure modes under test: a page carries the saved text and the rows are not
 * bounded; a provider's misfiled save time is presented as publication time; a
 * stale summary is presented as current evidence. */
async function capture(store: KnowledgeStore, index: number, textChars: number, overrides: Record<string, unknown> = {}) {
  const body = `${"X Article body sentence. ".repeat(Math.ceil(textChars / 24))}${index}`;
  const result = await store.captureSource({
    commandId: `row-library-capture-${index}`,
    record: {
      kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [],
      content: {
        title: `Saved source ${index}`, uri: `https://example.test/${index}`, text: body,
        mediaType: "text/html; charset=utf-8", captureDisposition: "partial",
        admission: { status: "retained", reason: "Fixture admission", decidedAt: "2026-01-01T00:00:00Z" },
        capturedAt: new Date(Date.UTC(2026, 0, 1) + index * 60_000).toISOString(),
        identity: { provider: "raindrop", accountId: "915401", itemId: `${index}` },
        ...overrides,
      },
    },
  });
  return result.record;
}
describe("Knowledge library rows", () => {
  it("serves a full bounded row page when source bodies exceed the full-record budget", async () => {
    const { store } = await fixture();
    const count = 50;
    for (let index = 0; index < count; index += 1) await capture(store, index, index >= 45 ? 200_000 : 100);
    const page = await store.listSourceRows({ kind: "source", sourceAdmission: "retained", projection: "sourceRow", limit: 50 });
    expect(page.rows).toHaveLength(count);
    // Newest first, matching the full-record page order.
    expect(page.rows[0]?.title).toBe("Saved source 49");
    expect(Buffer.byteLength(JSON.stringify(page))).toBeLessThan(30_000);
    // Large source bodies consume the full-record page budget, while the row
    // projection still returns every source in the requested page.
    const full = await store.list({ kind: "source", limit: 50 });
    expect(full.records.length).toBeLessThan(5);
    expect(Buffer.byteLength(JSON.stringify(full))).toBeGreaterThan(500_000);
    const row = page.rows.find(candidate => candidate.title === "Saved source 0")!;
    expect(row).toMatchObject({ title: "Saved source 0", uri: "https://example.test/0", captureDisposition: "partial", admission: "retained", scope: "research" });
    expect(JSON.stringify(row)).not.toContain("X Article body sentence");
  });

  it("publishes the original link, provider save time and no misfiled publication time", async () => {
    const { store } = await fixture();
    const published = new Date(Date.UTC(2026, 1, 2)).toISOString();
    const saved = new Date(Date.UTC(2026, 1, 3)).toISOString();
    const viaProvider = (await capture(store, 1, 100, { sourcePublishedAt: published, sourceSavedAt: saved })).id;
    const requested = "https://publisher.test/requested";
    const redirected = await store.captureSource({
      commandId: "row-library-redirect-capture",
      record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [],
        content: { title: "Redirected", uri: "https://publisher.test/final", text: "Body", captureDisposition: "partial", capturedAt: published,
          identity: { provider: "raindrop", accountId: "915401", itemId: "redirect" },
          origins: [{ kind: "connector", capturedAt: published, uri: requested, identity: { provider: "raindrop", accountId: "915401", itemId: "redirect" } }] } },
    });
    const rows = new Map((await store.listSourceRows({ kind: "source", projection: "sourceRow", ids: [viaProvider, redirected.record.id] })).rows.map(row => [row.id, row]));
    expect(rows.get(viaProvider)).toMatchObject({ sourceSavedAt: saved });
    // Raindrop's stored publication field is the misfiled bookmark time.
    expect(rows.get(viaProvider)?.sourcePublishedAt).toBeUndefined();
    expect(rows.get(redirected.record.id)?.originalUri).toBe(requested);
  });

  it("presents a summary only while its evidence digest still matches", async () => {
    const { store } = await fixture();
    const record = await capture(store, 1, 200);
    const text = record.content.text ?? "";
    const summary = (digest: string) => ({ text: "Generated summary", generatedAt: "2026-02-01T00:00:00Z", sourceRevisionId: record.revisionId, evidenceDigest: digest, coverage: "sampled" as const, producer: { actor: "agent" as const } });
    const stale = await store.captureSource({ commandId: "row-library-summary-stale", expectedRevision: record.revisionId, record: { kind: "source", id: record.id, createdAt: record.createdAt, scope: record.scope, provenance: record.provenance, relations: [], content: { ...(record.content as object), summary: summary("b".repeat(64)) } as never } });
    expect((await store.listSourceRows({ kind: "source", projection: "sourceRow", ids: [record.id] })).rows[0]?.summary).toBeUndefined();
    const current = await store.captureSource({ commandId: "row-library-summary-current", expectedRevision: stale.record.revisionId, record: { kind: "source", id: record.id, createdAt: record.createdAt, scope: record.scope, provenance: record.provenance, relations: [], content: { ...(stale.record.content as object), summary: summary(sourceEvidenceDigest(record.content.title, text)) } as never } });
    expect(current.record.revisionId).not.toBe(record.revisionId);
    expect((await store.listSourceRows({ kind: "source", projection: "sourceRow", ids: [record.id] })).rows[0]?.summary).toBe("Generated summary");
  });

  it("partitions rows by admission with one cursor per partition", async () => {
    const { store } = await fixture();
    const records: KnowledgeRecord[] = [];
    for (let index = 0; index < 4; index += 1) records.push(await capture(store, index, 100));
    await store.setSourceAdmission({ commandId: "row-library-admit-pending", recordId: records[0]!.id, expectedRevision: records[0]!.revisionId, status: "pending" });
    await store.setSourceAdmission({ commandId: "row-library-admit-archived", recordId: records[1]!.id, expectedRevision: records[1]!.revisionId, status: "archived" });
    // The saved view is exactly the retained partition: waiting and archived
    // work never leaks into it.
    const saved = await store.listSourceRows({ kind: "source", projection: "sourceRow" });
    expect(saved.rows.map(row => row.id)).toEqual([records[3]!.id, records[2]!.id]);
    const retained = await store.listSourceRows({ kind: "source", sourceAdmission: "retained", projection: "sourceRow", limit: 1 });
    expect(retained.rows.map(row => row.id)).toEqual([records[3]!.id]);
    expect((await store.listSourceRows({ kind: "source", sourceAdmission: "retained", projection: "sourceRow", limit: 1, cursor: retained.nextCursor! })).rows.map(row => row.id)).toEqual([records[2]!.id]);
    expect((await store.listSourceRows({ kind: "source", sourceAdmission: "archived", includeArchived: true, projection: "sourceRow" })).rows.map(row => row.id)).toEqual([records[1]!.id]);
    expect((await store.listSourceRows({ kind: "source", sourceAdmission: "pending", includePending: true, projection: "sourceRow" })).rows.map(row => row.id)).toEqual([records[0]!.id]);
    // A partition's cursor is not a cursor for another partition.
    await expect(store.listSourceRows({ kind: "source", sourceAdmission: "archived", includeArchived: true, projection: "sourceRow", cursor: retained.nextCursor! })).rejects.toThrow(/cursor is invalid/);
  });

  it("pages a long row list exactly once and refreshes identities in the requested order", async () => {
    const { store } = await fixture();
    const ids: string[] = [];
    for (let index = 0; index < 7; index += 1) ids.push((await capture(store, index, 100)).id);
    const seen: string[] = []; let cursor: string | undefined;
    do {
      const page = await store.listSourceRows({ kind: "source", projection: "sourceRow", limit: 2, ...(cursor ? { cursor } : {}) });
      seen.push(...page.rows.map(row => row.id)); cursor = page.nextCursor;
    } while (cursor);
    expect(seen).toEqual([...ids].reverse());
    expect(new Set(seen).size).toBe(ids.length);
    const requested = [ids[2]!, ids[0]!, ids[5]!];
    expect((await store.listSourceRows({ kind: "source", projection: "sourceRow", ids: requested })).rows.map(row => row.id)).toEqual(requested);
    expect((await store.listSourceRows({ kind: "source", projection: "sourceRow", ids: ["missing-record", ...requested] })).rows.map(row => row.id)).toEqual(requested);
    await expect(store.listSourceRows({ kind: "source", projection: "sourceRow", ids: requested, cursor: "x" })).rejects.toThrow(/no cursor/);
    await expect(store.listSourceRows({ kind: "note", projection: "sourceRow" })).rejects.toThrow(/sources only/);
  });

  it("batches exact preview references and keeps one bad item local to its row", async () => {
    const { store } = await fixture();
    const record = await capture(store, 1, 100);
    const image = new Uint8Array(Array.from({ length: 1_024 }, (_, index) => index % 251));
    const object = await store.putObject(image, "image/png");
    const withPreview = await store.captureSource({ commandId: "row-library-preview", expectedRevision: record.revisionId,
      record: { kind: "source", id: record.id, createdAt: record.createdAt, scope: record.scope, provenance: record.provenance, relations: [], content: { ...(record.content as object), preview: object } as never } });
    const other = await capture(store, 2, 100);
    const oversized = await store.putObject(new Uint8Array(KNOWLEDGE_PREVIEW_MAX_BYTES + 1), "image/png");
    const large = await store.captureSource({ commandId: "row-library-preview-large", expectedRevision: other.revisionId,
      record: { kind: "source", id: other.id, createdAt: other.createdAt, scope: other.scope, provenance: other.provenance, relations: [], content: { ...(other.content as object), preview: oversized } as never } });
    const base = { recordId: record.id, revisionId: withPreview.record.revisionId };
    const largeBase = { recordId: other.id, revisionId: large.record.revisionId };
    const result = await store.readPreviewsBatch({ items: [
      { ...base, ...object },
      { ...base, hash: "c".repeat(64), mediaType: "image/png", bytes: object.bytes },
      { recordId: "absent-record", revisionId: large.record.revisionId, ...object },
    ] });
    expect(result.items.map(item => item.base64 !== undefined)).toEqual([true, false, false]);
    expect(result.items[1]).toMatchObject({ unavailable: "forbidden" });
    expect(Buffer.from(result.items[0]!.base64!, "base64")).toEqual(Buffer.from(image));
    // The over-budget preview stays local to its own item.
    const bounded = await store.readPreviewsBatch({ items: [{ ...largeBase, ...oversized }, { ...base, ...object }] });
    expect(bounded.items.map(item => item.unavailable)).toEqual(["too-large", undefined]);
    expect(bounded.items[1]!.base64).toBeDefined();
    const many = Array.from({ length: KNOWLEDGE_PREVIEW_BATCH_ITEMS + 1 }, () => ({ ...base, ...object }));
    await expect(store.readPreviewsBatch({ items: many })).rejects.toThrow(/bounded/);
    await expect(store.readPreviewsBatch({ items: [{ ...base, ...object }, { ...base, ...object }] })).rejects.toThrow(/distinct/);
  });

  it("pages a scored search and refuses a cursor from another corpus revision", async () => {
    const { store } = await fixture();
    const first = await capture(store, 1, 100, { title: "Rare needle", text: "Body mentions a needle and the thread holding it" });
    const second = await capture(store, 2, 100, { title: "Rare needle" });
    const third = await capture(store, 3, 100, { title: "Unrelated" });
    const whole = await store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "needle" });
    expect(whole.rows.map(row => row.id)).toEqual([first.id, second.id]);
    expect(whole.nextCursor).toBeUndefined();
    const paged: string[] = []; let cursor: string | undefined;
    do {
      const page = await store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "needle", limit: 1, ...(cursor ? { cursor } : {}) });
      expect(page.rows).toHaveLength(1);
      paged.push(page.rows[0]!.id); cursor = page.nextCursor;
    } while (cursor);
    // Continuation must reproduce the scored order exactly, without repeats.
    expect(paged).toEqual([first.id, second.id]);
    const stale = (await store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "needle", limit: 1 })).nextCursor!;
    await capture(store, 4, 100, { title: "Another needle" });
    await expect(store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "needle", limit: 1, cursor: stale })).rejects.toThrow(/reload the first page/);
    await expect(store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "needle", cursor: "not-a-cursor" })).rejects.toThrow(/invalid/);
    expect((await store.searchSourceRows({ kind: "source", projection: "sourceRow", query: "unrelated" })).rows.map(row => row.id)).toEqual([third.id]);
  });
});
