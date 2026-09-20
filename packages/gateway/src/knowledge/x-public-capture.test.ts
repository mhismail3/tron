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
  it("does not contact FxTwitter without explicit lookup permission", async () => {
    const store = await fixture(); const seen: string[] = [];
    await capture.captureSource(store, { ...request, publicPostLookup: false }, { resolveHost: options.resolveHost, fetcher: async url => { seen.push(String(url)); return new Response(null, { status: 403 }); } });
    expect(seen).toEqual([request.url]);
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
