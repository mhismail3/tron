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
async function fixture() {
  const home = await mkdtemp(join(tmpdir(), "tron-x-capture-")); homes.push(home);
  return new KnowledgeStore(new TronWorkspace(home));
}
afterEach(async () => { vi.restoreAllMocks(); await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true }))); });
const raw = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Actual synthetic post, not author metadata", is_note_tweet: false, author: { screen_name: "synthetic" } } });
const options = { resolveHost: async () => ["93.184.216.34"], fetcher: vi.fn(async () => new Response(raw, { headers: { "content-type": "application/json" } })) };
const request = { commandId: "x-capture-synthetic", url: "https://x.com/synthetic/status/123456789?s=20", scope: "research" as const, publicPostLookup: true };

describe("X public lookup ownership", () => {
  it("captures root text plus exact raw evidence under canonical X identity and deduplicates URL aliases", async () => {
    const store = await fixture();
    const result = await capture.captureSource(store, request, options);
    expect(result.record.content).toMatchObject({ uri: "https://x.com/i/web/status/123456789", text: "Actual synthetic post, not author metadata", captureDisposition: "complete" });
    expect(result.record.content.captureReason).toContain("https://api.fxtwitter.com/status/123456789");
    const object = await store.readObject(result.record.content.object!, { recordId: result.record.id, revisionId: result.record.revisionId });
    expect(new TextDecoder().decode(object!)).toBe(raw);
    const duplicate = await capture.captureSource(store, { ...request, commandId: "x-capture-duplicate", url: "https://twitter.com/other/status/123456789" }, options);
    expect(duplicate.duplicate).toBe(true);
    expect(duplicate.record.id).toBe(result.record.id);
  });
  it("captures bounded external targets as separate sources with referring-post evidence", async () => {
    const store = await fixture();
    const root = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Read the underlying guide", is_note_tweet: false, author: { screen_name: "synthetic" }, entities: { urls: [{ expanded_url: "https://docs.example.test/guide" }] } } });
    const fetcher = vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com")
      ? new Response(root, { headers: { "content-type": "application/json" } })
      : new Response("Underlying guide evidence", { headers: { "content-type": "text/plain" } }));
    const result = await capture.captureSource(store, request, { ...options, fetcher });
    const records = (await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records.filter(record => record.kind === "source");
    expect(records).toHaveLength(2);
    expect(result.record.content.linkedUrls).toEqual(["https://docs.example.test/guide"]);
    const target = records.find(record => record.id !== result.record.id);
    expect(target?.content.text).toBe("Underlying guide evidence");
    expect(target?.provenance.evidence).toContainEqual(expect.objectContaining({ recordId: result.record.id }));
    expect(result.record.relations).toContainEqual(expect.objectContaining({ type: "related", recordId: target?.id }));
  });
  it("keeps bounded child command IDs distinct for long roots and linked reruns idempotent", async () => {
    const store = await fixture();
    const longCommand = "x".repeat(160);
    const root = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Two underlying sources", is_note_tweet: false, author: { screen_name: "synthetic" }, entities: { urls: [{ expanded_url: "https://docs.example.test/one" }, { expanded_url: "https://docs.example.test/two" }] } } });
    const fetcher = vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com") ? new Response(root, { headers: { "content-type": "application/json" } }) : new Response(`Evidence for ${url}`, { headers: { "content-type": "text/plain" } }));
    const first = await capture.captureSource(store, { ...request, commandId: longCommand }, { ...options, fetcher });
    expect(first.record.relations).toHaveLength(2);
    expect((await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records).toHaveLength(3);
    const callsAfterFirst = fetcher.mock.calls.length;
    const rerun = await capture.captureSource(store, { ...request, commandId: longCommand }, { ...options, fetcher });
    expect(rerun.duplicate).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(callsAfterFirst);
    expect((await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records).toHaveLength(3);
    expect(rerun.record.relations).toHaveLength(2);
  });
  it("does not contact FxTwitter without explicit lookup permission", async () => {
    const store = await fixture(); const seen: string[] = [];
    await capture.captureSource(store, { ...request, publicPostLookup: false }, { resolveHost: options.resolveHost, fetcher: async url => { seen.push(String(url)); return new Response(null, { status: 403 }); } });
    expect(seen).toEqual([request.url]);
  });
  it("retains bounded provider HTTP diagnostics on an inaccessible capture", async () => {
    const store = await fixture();
    const result = await capture.captureSource(store, request, { ...options, fetcher: async (url: string | URL) => new Response(null, { status: String(url).includes("fxtwitter") ? 401 : 400 }) });
    expect(result.record.content.captureDisposition).toBe("inaccessible");
    expect(result.record.content.captureReason).toContain("fxtwitter:unavailable status=401");
    expect(result.record.content.captureReason).toContain("x-syndication:unavailable status=400");
  });
  it("preserves the existing identity, admission, provenance, relations, and representations across failed and successful hydration", async () => {
    const store = await fixture();
    const retainedBytes = await store.putObject(new TextEncoder().encode("better retained evidence"), "text/plain");
    const providerBytes = await store.putObject(new TextEncoder().encode("provider metadata"), "application/json");
    const seeded = await store.captureSource({ commandId: "seed-x-reference", record: {
      kind: "source", scope: "research", provenance: { actor: "connector", source: "raindrop:synthetic-account:synthetic-item", evidence: [{ recordId: "evidence-record", revisionId: "1234567890abcdef" }] },
      relations: [{ type: "related", recordId: "related-record" }], content: {
        title: "Saved X reference", uri: "https://x.com/synthetic/status/123456789", text: "better retained evidence", object: retainedBytes,
        representations: [{ kind: "provider-api", object: providerBytes, mediaType: "application/json" }], captureDisposition: "reference-only", capturedAt: "2026-01-01T00:00:00.000Z",
        origin: "connector", origins: [{ kind: "connector", capturedAt: "2026-01-01T00:00:00.000Z", uri: "https://x.com/i/web/status/123456789", identity: { provider: "raindrop", accountId: "synthetic-account", itemId: "synthetic-item" } }], identity: { provider: "raindrop", accountId: "synthetic-account", itemId: "synthetic-item" }, admission: { status: "retained", reason: "user admission", decidedAt: "2026-01-01T00:00:00.000Z" }, retention: { sensitivity: "public", evidenceAvailable: true },
      },
    }, });
    const failed = await capture.captureSource(store, { ...request, commandId: "x-hydrate-failed" }, { resolveHost: options.resolveHost, fetcher: async (url: string | URL) => new Response(null, { status: String(url).includes("fxtwitter") ? 401 : 400 }) });
    expect(failed.record.id).toBe(seeded.record.id);
    expect(failed.record.content).toMatchObject({ captureDisposition: "reference-only", text: "better retained evidence", object: retainedBytes, identity: { provider: "raindrop" }, admission: { status: "retained" }, retention: { sensitivity: "public" } });
    expect(failed.record.provenance).toEqual(seeded.record.provenance);
    expect(failed.record.relations).toEqual(seeded.record.relations);
    expect(failed.record.content.representations).toEqual(seeded.record.content.representations);
    const rawSuccess = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Fresh verified root", is_note_tweet: false, author: { screen_name: "synthetic" } } });
    const success = await capture.captureSource(store, { ...request, commandId: "x-hydrate-success" }, { resolveHost: options.resolveHost, fetcher: async () => new Response(rawSuccess, { headers: { "content-type": "application/json" } }) });
    expect(success.record.id).toBe(seeded.record.id);
    expect(success.record.content.text).toBe("Fresh verified root");
    expect(success.record.content.admission?.status).toBe("retained");
    expect(success.record.content.representations).toEqual(seeded.record.content.representations);
    expect(success.record.provenance).toEqual(seeded.record.provenance);
    expect((await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records).toHaveLength(1);
  });
  it("uses URL-only hydration to carry the existing Raindrop origin onto the linked target without assigning target identity", async () => {
    const store = await fixture();
    const seeded = await store.captureSource({ commandId: "seed-url-only", record: { kind: "source", scope: "research", provenance: { actor: "connector", source: "raindrop:account:item", evidence: [] }, relations: [], content: { title: "Pending X", uri: "https://x.com/synthetic/status/123456789", captureDisposition: "reference-only", capturedAt: "2026-01-01T00:00:00.000Z", origin: "connector", origins: [{ kind: "connector", capturedAt: "2026-01-01T00:00:00.000Z", uri: "https://x.com/synthetic/status/123456789", identity: { provider: "raindrop", accountId: "account", itemId: "item" } }], identity: { provider: "raindrop", accountId: "account", itemId: "item" }, admission: { status: "pending", reason: "awaiting hydration", decidedAt: "2026-01-01T00:00:00.000Z" } } } });
    const root = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "See the guide", is_note_tweet: false, author: { screen_name: "synthetic" }, entities: { urls: [{ expanded_url: "https://docs.example.test/guide" }] } } });
    const result = await capture.captureSource(store, request, { ...options, fetcher: vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com") ? new Response(root, { headers: { "content-type": "application/json" } }) : new Response("guide", { headers: { "content-type": "text/plain" } })) });
    expect(result.record.id).toBe(seeded.record.id);
    const records = (await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records.filter(record => record.kind === "source");
    const target = records.find(record => record.id !== result.record.id)!;
    expect(target.content.identity).toBeUndefined();
    expect(target.content.origins).toContainEqual(expect.objectContaining({ kind: "connector", identity: { provider: "raindrop", accountId: "account", itemId: "item" } }));
    expect(target.relations).toContainEqual(expect.objectContaining({ type: "related", recordId: result.record.id }));
  });
  it("downgrades linked GitHub UI pages to partial repository/file coverage", async () => {
    const store = await fixture();
    const root = JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Read this repo", is_note_tweet: false, author: { screen_name: "synthetic" }, entities: { urls: [{ expanded_url: "https://github.com/example/project" }] } } });
    const result = await capture.captureSource(store, request, { ...options, fetcher: vi.fn(async (url: string | URL) => String(url).includes("api.fxtwitter.com") ? new Response(root, { headers: { "content-type": "application/json" } }) : new Response("<html><title>Repo</title><body>file listing</body></html>", { headers: { "content-type": "text/html" } })) });
    const records = (await store.list({ kind: "source", includePending: true, includeArchived: true, limit: 10 })).records.filter(record => record.kind === "source");
    const target = records.find(record => record.id !== result.record.id)!;
    expect(target.content.captureDisposition).toBe("partial");
    expect(target.content.captureReason).toContain("repository and file completeness");
  });
  it("retries failed capture in the same record and preserves incomplete content honestly", async () => {
    const store = await fixture();
    const failed = await capture.captureSource(store, request, { ...options, fetcher: async () => new Response("{}") });
    expect(failed.record.content.captureDisposition).toBe("inaccessible");
    const retried = await capture.captureSource(store, { ...request, commandId: "x-capture-retry" }, { ...options, fetcher: async () => new Response(JSON.stringify({ code: 200, tweet: { id: "123456789", text: "Article preview", article: { title: "Synthetic" } } })) });
    expect(retried.record.id).toBe(failed.record.id);
    expect(retried.record.content.captureDisposition).toBe("partial");
    expect(retried.record.content.captureReason).toContain("Article");
  });
  it("never calls truncated raw/text evidence complete", async () => {
    const store = await fixture();
    const result = await capture.captureSource(store, request, { ...options, limits: { maxBytes: 20, maxReadableChars: 5 } });
    expect(result.record.content.captureDisposition).toBe("partial");
    expect(result.record.content.text).toHaveLength(5);
  });
  it("wires read-only x to the live reader without writing a source", async () => {
    const store = await fixture();
    const reader = vi.spyOn(capture, "readPublicXPost").mockResolvedValue({ id: "123456789", url: request.url, text: "Synthetic read", disposition: "partial", limitations: ["not a thread"], attempts: [] });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined));
    try {
      const result = await service.tool({ action: "x", url: request.url });
      expect(result.text).toContain("Synthetic read");
      expect(reader).toHaveBeenCalledWith(request.url, { signal: expect.any(AbortSignal) });
      expect((await store.list({ kind: "source" })).records).toHaveLength(0);
    } finally { service.dispose(); }
  });
  it("forwards explicit public lookup capture permission through the agent tool", async () => {
    const store = await fixture();
    const capturer = vi.spyOn(capture, "captureSource").mockResolvedValue({ record: {} as never, duplicate: false, fetched: false });
    const modelFactory = vi.fn(() => { throw new Error("Free X capture must not request an assessment model"); });
    const service = new KnowledgeService(store, new KnowledgeObservationService(store, undefined), {}, modelFactory);
    try {
      // Return no record to avoid unrelated record rendering in this routing oracle.
      capturer.mockResolvedValue({ duplicate: false, fetched: false } as never);
      await service.tool({ action: "captureSource", ...request });
      expect(capturer.mock.calls[0]?.[1].publicPostLookup).toBe(true);
      expect(capturer.mock.calls[0]?.[2]?.model).toBeUndefined();
      expect(modelFactory).not.toHaveBeenCalled();
    } finally { service.dispose(); }
  });
});
