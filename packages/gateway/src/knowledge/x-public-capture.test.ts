import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeObservationService } from "./knowledge-observation.js";
import { KnowledgeService } from "./knowledge-service.js";
import * as capture from "./source-capture.js";

const homes: string[] = [];
async function fixture() { const home = await mkdtemp(join(tmpdir(), "tron-x-capture-")); homes.push(home); return new KnowledgeStore(new TronWorkspace(home)); }
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true }))); });
const v2 = (extra: Record<string, unknown> = {}) => JSON.stringify({ code: 200, status: { id: "123456789", text: "Actual synthetic post", author: { id: "42" }, replying_to: null, raw_text: { facets: [] }, ...extra }, thread: [], replies: [], cursor: {} });
const request = { commandId: "x-capture-synthetic", url: "https://x.com/synthetic/status/123456789?s=20", scope: "research" as const, publicPostLookup: true };
const options = { resolveHost: async () => ["93.184.216.34"], fetcher: vi.fn(async () => new Response(v2(), { headers: { "content-type": "application/json" } })) };

describe("X public v2 capture ownership", () => {
  it("captures v2 root text/raw evidence under canonical identity and reuses unchanged complete evidence", async () => {
    const store = await fixture(); const result = await capture.captureSource(store, request, options);
    expect(result.record.content).toMatchObject({ uri: "https://x.com/i/web/status/123456789", text: "Actual synthetic post", captureDisposition: "complete" });
    expect(result.record.content.captureReason).toContain("/2/conversation/123456789");
    const object = await store.readObject(result.record.content.object!, { recordId: result.record.id, revisionId: result.record.revisionId }); expect(new TextDecoder().decode(object!)).toBe(v2());
    const duplicate = await capture.captureSource(store, { ...request, commandId: "x-capture-duplicate", url: "https://twitter.com/other/status/123456789" }, options); expect(duplicate.duplicate).toBe(true); expect(options.fetcher).toHaveBeenCalledTimes(1);
  });
  it("refreshes explicitly requested conversation coverage in the same source envelope", async () => {
    const store = await fixture(); const fetcher = vi.fn().mockResolvedValue(new Response(v2({ text: "root" }), { headers: { "content-type": "application/json" } }));
    const first = await capture.captureSource(store, request, { ...options, fetcher });
    const enriched = await store.captureSource({ commandId: "enrich-x-envelope", expectedRevision: first.record.revisionId, record: { kind: "source", id: first.record.id, createdAt: first.record.createdAt, scope: first.record.scope, provenance: { ...first.record.provenance, actor: "connector", source: "raindrop:account:item" }, relations: [{ type: "related", recordId: "existing-related" }], content: { ...first.record.content, admission: { status: "retained", reason: "user admission", decidedAt: first.record.content.capturedAt }, retention: { sensitivity: "public", evidenceAvailable: true } } } });
    const refreshed = await capture.captureSource(store, { ...request, commandId: "x-coverage-refresh", publicPostCoverage: "conversation" }, { ...options, fetcher });
    expect(refreshed.record.id).toBe(enriched.record.id); expect(refreshed.record.provenance).toEqual(enriched.record.provenance); expect(refreshed.record.relations).toEqual(enriched.record.relations); expect(refreshed.record.content.admission).toEqual(enriched.record.content.admission); expect(fetcher.mock.calls.length).toBeGreaterThanOrEqual(2);
    const failed = await capture.captureSource(store, { ...request, commandId: "x-coverage-failed", publicPostCoverage: "thread" }, { ...options, fetcher: vi.fn().mockResolvedValueOnce(new Response(null, { status: 503 })).mockResolvedValueOnce(new Response(null, { status: 400 })) });
    expect(failed.record.id).toBe(enriched.record.id); expect(failed.record.content.admission).toEqual(enriched.record.content.admission); expect(failed.record.relations).toEqual(enriched.record.relations);
  });
  it("downgrades tiny linked HTML app shells instead of retaining them as articles", async () => {
    const store = await fixture();
    const root = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root", author: { id: "42" }, replying_to: null, raw_text: { facets: [{ type: "url", replacement: "https://app.example.test/article" }] } }, thread: [], replies: [], cursor: {} });
    const fetcher = vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com") ? new Response(root, { headers: { "content-type": "application/json" } }) : new Response("<html><head><title>App</title></head><body><div id=app></div><script>Loading...</script></body></html>", { headers: { "content-type": "text/html" } }));
    const result = await capture.captureSource(store, { ...request, publicPostCoverage: "root" }, { ...options, fetcher });
    const records = (await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records.filter(record => record.kind === "source");
    const target = records.find(record => record.id !== result.record.id)!;
    expect(target.content.captureDisposition).toBe("partial"); expect(target.content.captureReason).toContain("app shell");
  });
  it("captures http linked targets with exact continuation evidence", async () => {
    const store = await fixture();
    const root = JSON.stringify({ code: 200, status: { id: "123456789", text: "Root", author: { id: "42" }, replying_to: null, raw_text: { facets: [] } }, thread: [], replies: [{ id: "2", text: "Continuation http://example.test/guide", author: { id: "42" }, replying_to: { status: "123456789" }, raw_text: { facets: [{ type: "url", replacement: "http://example.test/guide" }] } }], cursor: {} });
    const fetcher = vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com") ? new Response(root, { headers: { "content-type": "application/json" } }) : new Response("Underlying guide evidence", { headers: { "content-type": "text/plain" } }));
    const result = await capture.captureSource(store, { ...request, publicPostCoverage: "conversation" }, { ...options, fetcher });
    const records = (await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records.filter(record => record.kind === "source");
    expect(records).toHaveLength(2); expect(result.record.content.linkedUrls).toEqual(["http://example.test/guide"]);
    const target = records.find(record => record.id !== result.record.id)!; expect(target.content.text).toBe("Underlying guide evidence"); expect(target.provenance.evidence).toContainEqual(expect.objectContaining({ locator: "https://x.com/i/web/status/2" }));
  });
  it("does not contact public providers without explicit lookup permission", async () => {
    const store = await fixture(); const seen: string[] = [];
    await capture.captureSource(store, { ...request, publicPostLookup: false }, { resolveHost: options.resolveHost, fetcher: async url => { seen.push(String(url)); return new Response(null, { status: 403 }); } });
    expect(seen).toEqual([request.url]);
  });
  it("wires read-only x to the live v2 reader without writing a source", async () => {
    const store = await fixture(); const reader = vi.spyOn(capture, "readPublicXPost").mockResolvedValue({ id: "123456789", url: request.url, text: "Synthetic read", disposition: "partial", limitations: ["not universal"], attempts: [] });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    try { const result = await service.tool({ action: "x", url: request.url }); expect(result.text).toContain("Synthetic read"); expect(reader).toHaveBeenCalledWith(request.url, { signal: expect.any(AbortSignal) }); expect((await store.list({ kind: "source" })).records).toHaveLength(0); } finally { service.dispose(); }
  });
});
