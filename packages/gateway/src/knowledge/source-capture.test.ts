import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { captureSource, isPrivateAddress, refreshSourcePreview } from "./source-capture.js";

const homes: string[] = [];
const command = (value: string) => `source-test-${value}`;
async function fixture(): Promise<{ store: KnowledgeStore; home: string }> {
  const home = await mkdtemp(join(tmpdir(), "tron-source-")); homes.push(home);
  return { home, store: new KnowledgeStore(new TronWorkspace(home)) };
}
afterEach(async () => { vi.useRealTimers(); await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true }))); });

const publicResolver = async () => ["93.184.216.34"];

describe("safe source capture", () => {
  it("refreshes a complete source preview in place while preserving its envelope", async () => {
    const { store } = await fixture();
    const original = await store.captureSource({ commandId: command("preview-source"), record: {
      kind: "source", scope: "research", provenance: { actor: "user", source: "fixture", evidence: [] }, relations: [],
      content: { title: "Preview article", uri: "https://example.com/article", text: "Saved body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual", admission: { status: "retained", reason: "fixture", decidedAt: "2026-01-01T00:00:00Z" }, retention: { sensitivity: "public", evidenceAvailable: true } },
    }});
    const before = original.record;
    const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const fetcher = vi.fn(async (url: URL) => url.toString() === "https://example.com/article"
      ? new Response('<html><head><meta property="og:image" content="https://cdn.example.com/cover.jpg"></head></html>', { headers: { "content-type": "text/html" } })
      : new Response(jpg, { headers: { "content-type": "image/jpeg" } }));
    const result = await refreshSourcePreview(store, { commandId: command("preview-refresh"), sourceId: before.id, expectedRevision: before.revisionId }, { fetcher, resolveHost: publicResolver });
    expect(result.status).toBe("updated");
    expect(result.record?.id).toBe(before.id);
    const after = await store.read(before.id, undefined, false, true, true);
    expect(after?.content.preview).toMatchObject({ mediaType: "image/jpeg", bytes: jpg.byteLength });
    expect(after?.content.title).toBe(before.content.title);
    expect(after?.content.text).toBe(before.content.text);
    expect(after?.content.object).toEqual(before.content.object);
    expect(after?.content.admission).toEqual(before.content.admission);
    expect(after?.content.retention).toEqual(before.content.retention);
    expect(after?.relations).toEqual(before.relations);
    const previewBytes = await store.readObject(after!.content.preview!, { recordId: after!.id, revisionId: after!.revisionId });
    expect(Buffer.from(previewBytes ?? [])).toEqual(Buffer.from(jpg));
    expect((await store.list({ kind: "source", includeArchived: true, includePending: true })).records).toHaveLength(1);
    const second = await refreshSourcePreview(store, { commandId: command("preview-refresh-again"), sourceId: before.id, expectedRevision: after!.revisionId }, { fetcher, resolveHost: publicResolver });
    expect(second.status).toBe("unchanged");
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("resolves retained HTML previews against the canonical source URI, not referral origins", async () => {
    const { store } = await fixture();
    const html = Buffer.from('<html><head><meta property="og:image" content="../cover.png"></head></html>');
    const object = await store.putObject(html, "text/html");
    const source = await store.captureSource({ commandId: command("relative-preview-source"), record: {
      kind: "source", scope: "research", provenance: { actor: "connector", source: "fixture", evidence: [] }, relations: [],
      content: { title: "Canonical page", uri: "https://site.test/path/page.html", text: "body", object, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "connector", origins: [{ kind: "connector", capturedAt: "2026-01-01T00:00:00Z", uri: "https://x.com/example/status/1234567890123456789" }], admission: { status: "retained", decidedAt: "2026-01-01T00:00:00Z" } },
    }});
    const image = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
    const requested: string[] = [];
    const result = await refreshSourcePreview(store, { commandId: command("relative-preview-refresh"), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher: async (url: URL) => { requested.push(url.toString()); return new Response(image, { headers: { "content-type": "image/png" } }); }, resolveHost: publicResolver });
    expect(result.status).toBe("updated");
    expect(requested).toEqual(["https://site.test/cover.png"]);
  });

  it("uses the bounded public X Article cover without linked-target capture", async () => {
    const { store } = await fixture();
    const source = await store.captureSource({ commandId: command("x-preview-source"), record: {
      kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "X source", uri: "https://x.com/example/status/1234567890123456789", text: "Saved X text", captureDisposition: "partial", capturedAt: "2026-01-01T00:00:00Z", origin: "manual", admission: { status: "retained", decidedAt: "2026-01-01T00:00:00Z" } },
    }});
    const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const fetcher = vi.fn(async (url: URL) => url.toString().startsWith("https://api.fxtwitter.com/")
      ? new Response(JSON.stringify({ code: 200, status: { id: "1234567890123456789", text: "", author: { id: "42" }, article: { id: "1234567890123456790", title: "Article", content: { blocks: [{ text: "Body" }] }, cover_media: { media_info: { original_img_url: "https://cdn.example.com/x-cover.jpg" } } } }, thread: [], replies: [] }), { headers: { "content-type": "application/json" } })
      : new Response(jpg, { headers: { "content-type": "image/jpeg" } }));
    const result = await refreshSourcePreview(store, { commandId: command("x-preview-refresh"), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher, resolveHost: publicResolver });
    expect(result.status).toBe("updated");
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect((await store.read(source.record.id, undefined, false, true, true))?.content.preview?.mediaType).toBe("image/jpeg");
    expect((await store.list({ kind: "source", includeArchived: true, includePending: true })).records).toHaveLength(1);
  });

  it("fences exclusion that arrives between final read and atomic publication", async () => {
    const { store } = await fixture();
    const source = await store.captureSource({ commandId: command("race-source"), record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Race", uri: "https://example.com/race", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" } } });
    const image = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const publish = store.publishSourcePreview.bind(store);
    vi.spyOn(store, "publishSourcePreview").mockImplementation(async request => { await store.setExclusion(command("race-exclude"), source.record.id, true, source.record.revisionId, "race"); return publish(request); });
    await expect(refreshSourcePreview(store, { commandId: command("race-refresh"), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher: async (url: URL) => url.toString() === "https://example.com/race" ? new Response('<meta property="og:image" content="https://cdn.example.com/race.jpg">', { headers: { "content-type": "text/html" } }) : new Response(image, { headers: { "content-type": "image/jpeg" } }), resolveHost: publicResolver })).rejects.toThrow(/unavailable|excluded/i);
    const after = await store.read(source.record.id, undefined, true, true, true);
    expect(after?.revisionId).toBe(source.record.revisionId);
    expect(after?.content.preview).toBeUndefined();
  });

  it.each(["pending", "archived"] as const)("checks %s policy before stale-preview reuse", async status => {
    const { store } = await fixture();
    const preview = await store.putObject(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]), "image/jpeg");
    const source = await store.captureSource({ commandId: command(`policy-${status}`), record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Policy", uri: "https://example.com/policy", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual", preview, admission: { status, decidedAt: "2026-01-01T00:00:00Z" } } } });
    const newer = await store.captureSource({ commandId: command(`policy-newer-${status}`), expectedRevision: source.record.revisionId, record: { ...source.record, content: { ...source.record.content, title: "Newer" } } as never });
    const result = await refreshSourcePreview(store, { commandId: command(`policy-refresh-${status}`), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher: async () => { throw new Error("must not fetch"); }, resolveHost: publicResolver });
    expect(result.status).toBe("unavailable");
    expect(result.reason).toContain(status === "pending" ? "Pending" : "Archived");
    expect(newer.record.content.preview).toEqual(preview);
  });

  it("redacts unsafe preview failures instead of echoing credential-bearing URLs", async () => {
    const { store } = await fixture();
    const source = await store.captureSource({ commandId: command("redact-source"), record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Redact", uri: "https://example.com/redact", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" } } });
    const result = await refreshSourcePreview(store, { commandId: command("redact-refresh"), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher: async (url: URL) => url.toString() === "https://example.com/redact" ? new Response('<meta property="og:image" content="https://cdn.example.com/redact.jpg">', { headers: { "content-type": "text/html" } }) : new Response(null, { status: 302, headers: { location: "https://cdn.example.com/image.jpg?token=secret" } }), resolveHost: publicResolver });
    expect(result.status).toBe("no-image");
    expect(result.reason).not.toContain("secret");
    expect(result.reason).not.toContain("cdn.example.com");
  });

  it("does not publish when cancellation arrives at the publication boundary", async () => {
    const { store } = await fixture();
    const source = await store.captureSource({ commandId: command("cancel-source"), record: { kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [], content: { title: "Cancel", uri: "https://example.com/cancel", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual" } } });
    const image = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const publish = store.publishSourcePreview.bind(store);
    vi.spyOn(store, "publishSourcePreview").mockImplementation(async request => { request.signal?.throwIfAborted(); const controller = new AbortController(); controller.abort(new Error("cancel publication")); return publish({ ...request, signal: controller.signal }); });
    await expect(refreshSourcePreview(store, { commandId: command("cancel-refresh"), sourceId: source.record.id, expectedRevision: source.record.revisionId }, { fetcher: async (url: URL) => url.toString() === "https://example.com/cancel" ? new Response('<meta property="og:image" content="https://cdn.example.com/cancel.jpg">', { headers: { "content-type": "text/html" } }) : new Response(image, { headers: { "content-type": "image/jpeg" } }), resolveHost: publicResolver })).rejects.toThrow(/cancel/i);
    const after = await store.read(source.record.id, undefined, true, true, true);
    expect(after?.revisionId).toBe(source.record.revisionId);
    expect(after?.content.preview).toBeUndefined();
  });

  it("keeps an existing preview when the new image is invalid or unavailable", async () => {
    const { store } = await fixture();
    const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const preview = await store.putObject(jpg, "image/jpeg");
    const original = await store.captureSource({ commandId: command("existing-preview"), record: {
      kind: "source", scope: "research", provenance: { actor: "user", evidence: [] }, relations: [],
      content: { title: "Existing", uri: "https://example.com/existing", text: "body", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00Z", origin: "manual", preview, admission: { status: "retained", decidedAt: "2026-01-01T00:00:00Z" } },
    }});
    const result = await refreshSourcePreview(store, { commandId: command("invalid-preview"), sourceId: original.record.id, expectedRevision: original.record.revisionId }, { fetcher: async (url: URL) => url.toString() === "https://example.com/existing" ? new Response('<meta property="og:image" content="https://cdn.example.com/bad"></meta>', { headers: { "content-type": "text/html" } }) : new Response("not image", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    expect(["unchanged", "no-image"]).toContain(result.status);
    expect((await store.read(original.record.id, undefined, false, true, true))?.content.preview).toEqual(preview);
  });

  it("rejects hexadecimal IPv4-mapped private IPv6 destinations", () => {
    expect(isPrivateAddress("::ffff:7f00:1")).toBe(true);
    expect(isPrivateAddress("::ffff:c0a8:101")).toBe(true);
    expect(isPrivateAddress("2001:db8::1")).toBe(false);
  });
  it.each([-1, 0, 1.5, Infinity, 2_000_001])("rejects invalid readable input limit %s before fetching", async (maxReadableChars) => {
    const { store } = await fixture();
    const fetcher = vi.fn(async () => new Response("not reached"));
    await expect(captureSource(store, { commandId: command("invalid-readable-bound"), url: "https://example.com/bound", scope: "research" }, {
      fetcher, resolveHost: publicResolver, limits: { maxReadableChars },
    })).rejects.toThrow(/Invalid source capture limits/);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("fences the primary source write when cancellation wins before store admission", async () => {
    const { store } = await fixture();
    const controller = new AbortController();
    const capture = store.captureSource.bind(store);
    const write = vi.spyOn(store, "captureSource").mockImplementationOnce(request => {
      controller.abort(new Error("cancel before source publication"));
      return capture(request);
    });
    try {
      await expect(captureSource(store, { commandId: command("cancel-primary"), url: "https://example.com/primary", scope: "research" }, {
        signal: controller.signal,
        fetcher: async () => new Response("complete source", { headers: { "content-type": "text/plain" } }),
        resolveHost: publicResolver,
      })).rejects.toThrow(/cancel/i);
      expect((await store.list({ kind: "source" })).records).toEqual([]);
    } finally { write.mockRestore(); }
  });

  it("rejects credential-bearing query parameters before persistence or fetch", async () => {
    const { store } = await fixture();
    let fetched = false;
    await expect(captureSource(store, { commandId: command("query-secret"), url: "https://example.com/article?access_token=secret", scope: "research" }, { resolveHost: publicResolver, fetcher: async () => { fetched = true; return new Response("not reached"); } })).rejects.toThrow(/credential-bearing/);
    expect(fetched).toBe(false);
    expect((await store.status()).state).toBe("uninitialized");
  });

  it("retains raw bytes separately from readable extraction and deduplicates normalized URLs", async () => {
    const { store } = await fixture();
    const fetcher = async () => new Response("<html><title>Useful</title><script>evil()</script><body>Hello <b>world</b></body></html>", { headers: { "content-type": "text/html; charset=utf-8" } });
    const first = await captureSource(store, { commandId: command("capture-one"), url: "https://Example.com:443/article#part", scope: "research", identity: { provider: "fixture", accountId: "account-1", itemId: "item-1" } }, { fetcher, resolveHost: publicResolver });
    expect(first.record.content.captureDisposition).toBe("complete");
    expect(first.record.content.text).toContain("Hello world");
    expect(first.record.content.text).not.toContain("evil");
    expect(first.record.content.object?.bytes).toBeGreaterThan(0);
    expect(first.record.content.identity?.itemId).toBe("item-1");
    const duplicate = await captureSource(store, { commandId: command("capture-two"), url: "https://example.com/article", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(duplicate.duplicate).toBe(true);
    expect((await store.list({ kind: "source" })).records).toHaveLength(1);
  });

  it("reconciles redirect aliases to an existing canonical source without inspecting referral origins", async () => {
    const { store } = await fixture();
    const requested: string[] = [];
    const fetcher = async (url: URL) => {
      requested.push(url.toString());
      if (["http://example.com/old-guide", "http://example.com/legacy-guide"].includes(url.toString())) return new Response(null, { status: 301, headers: { location: "https://example.com/new-guide" } });
      return new Response("canonical guide", { headers: { "content-type": "text/plain" } });
    };
    const canonical = await captureSource(store, { commandId: command("canonical"), url: "https://example.com/new-guide", scope: "research", identity: { provider: "fixture", accountId: "account-1", itemId: "canonical" } }, { fetcher, resolveHost: publicResolver });
    const admitted = await store.setSourceAdmission({ commandId: command("canonical-admit"), recordId: canonical.record.id, expectedRevision: canonical.record.revisionId, status: "retained", reason: "fixture retention" });
    const alias = await captureSource(store, { commandId: command("old-guide"), url: "http://example.com/old-guide", scope: "research", annotations: [{ text: "declared alias", locator: "fixture" }] }, { fetcher, resolveHost: publicResolver });
    expect(alias.record.id).toBe(canonical.record.id);
    expect(alias.duplicate).toBe(true);
    expect(alias.record.content.admission).toEqual(admitted.record.content.admission);
    expect(alias.record.content.object?.hash).toBe(canonical.record.content.object?.hash);
    expect(alias.record.content.origins?.some(origin => origin.uri === "http://example.com/old-guide")).toBe(true);
    expect(alias.record.content.annotations).toContainEqual({ text: "declared alias", locator: "fixture" });
    expect(requested).toEqual(["https://example.com/new-guide", "http://example.com/old-guide", "https://example.com/new-guide"]);
    const repeated = await captureSource(store, { commandId: command("old-guide-repeat"), url: "http://example.com/legacy-guide", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(repeated.record.id).toBe(canonical.record.id);
    expect(repeated.duplicate).toBe(true);
    const repeatedAgain = await captureSource(store, { commandId: command("old-guide-repeat-again"), url: "http://example.com/legacy-guide", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(repeatedAgain.record.content.origins?.length).toBe(repeated.record.content.origins?.length);
    expect((await store.list({ kind: "source", scope: "research", includeArchived: true, includePending: true })).records).toHaveLength(1);
  });

  it("serializes concurrent redirect aliases at the source publication owner", async () => {
    const { store } = await fixture();
    // The fetcher pauses on the fake clock, so both alias reads are provably in
    // flight together. `waitFor` advances that clock while it polls, so the race
    // is real but costs no wall time.
    vi.useFakeTimers();
    const fetcher = async (url: URL) => {
      await new Promise(resolve => setTimeout(resolve, 10));
      if (["https://example.com/alias-a", "https://example.com/alias-b"].includes(url.toString())) return new Response(null, { status: 302, headers: { location: "https://example.com/canonical" } });
      return new Response("concurrent canonical", { headers: { "content-type": "text/plain" } });
    };
    const captures = Promise.all([
      captureSource(store, { commandId: command("concurrent-a"), url: "https://example.com/alias-a", scope: "research" }, { fetcher, resolveHost: publicResolver }),
      captureSource(store, { commandId: command("concurrent-b"), url: "https://example.com/alias-b", scope: "research" }, { fetcher, resolveHost: publicResolver }),
    ]);
    const [first, second] = await vi.waitFor(() => captures, { interval: 10, timeout: 3_000 });
    expect(first.record.id).toBe(second.record.id);
    expect((await store.list({ kind: "source", includeArchived: true, includePending: true })).records).toHaveLength(1);
  });

  it("does not poison later callers when an earlier fetch blocks and a queued caller cancels", async () => {
    const { store } = await fixture();
    const blocked = captureSource(store, { commandId: command("blocked-first"), url: "https://example.com/blocked", scope: "research" }, { fetcher: async () => new Response(new ReadableStream<Uint8Array>({ start() {} }), { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { timeoutMs: 100 } }).then(() => undefined, error => error as Error);
    const cancelledController = new AbortController(); cancelledController.abort(new Error("cancelled second"));
    const cancelled = captureSource(store, { commandId: command("cancelled-second"), url: "https://example.com/cancelled", scope: "research" }, { signal: cancelledController.signal, fetcher: async () => new Response("must not fetch"), resolveHost: publicResolver }).then(() => undefined, error => error as Error);
    const healthy = captureSource(store, { commandId: command("healthy-third"), url: "https://example.com/healthy", scope: "research" }, { fetcher: async () => new Response("healthy", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    expect((await blocked)?.message).toMatch(/timed out|cancelled/);
    expect((await cancelled)?.message).toMatch(/cancel/i);
    await expect(healthy).resolves.toMatchObject({ record: { content: { text: "healthy" } } });
  });

  it("upgrades an existing partial redirect target in place and preserves its envelope", async () => {
    const { store } = await fixture();
    const partial = await captureSource(store, { commandId: command("partial-target"), url: "https://example.com/new-guide", scope: "research", identity: { provider: "fixture", accountId: "account-1", itemId: "partial" } }, { fetcher: async () => new Response("short", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { maxBytes: 3 } });
    const admitted = await store.setSourceAdmission({ commandId: command("partial-admit"), recordId: partial.record.id, expectedRevision: partial.record.revisionId, status: "retained", reason: "fixture retention" });
    const alias = await captureSource(store, { commandId: command("partial-alias"), url: "https://example.com/old-guide", scope: "research" }, { fetcher: async (url: URL) => url.toString() === "https://example.com/old-guide" ? new Response(null, { status: 302, headers: { location: "https://example.com/new-guide" } }) : new Response("recovered canonical guide", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    expect(alias.record.id).toBe(partial.record.id);
    expect(alias.record.content.captureDisposition).toBe("complete");
    expect(alias.record.content.admission).toEqual(admitted.record.content.admission);
    expect(alias.record.content.text).toBe("recovered canonical guide");
    expect(alias.record.content.origins?.some(origin => origin.uri === "https://example.com/old-guide")).toBe(true);
    expect((await store.list({ kind: "source", includeArchived: true, includePending: true })).records).toHaveLength(1);
  });

  it("preserves archived, pending, and suppressed final ownership without recreating visible sources", async () => {
    const { store } = await fixture();
    const fetcher = async (url: URL) => ["https://example.com/archived-alias", "https://example.com/pending-alias", "https://example.com/suppressed-alias"].includes(url.toString())
      ? new Response(null, { status: 302, headers: { location: "https://example.com/canonical" } })
      : new Response("canonical", { headers: { "content-type": "text/plain" } });
    const canonical = await captureSource(store, { commandId: command("ownership-seed"), url: "https://example.com/canonical", scope: "research" }, { fetcher, resolveHost: publicResolver });
    const archived = await store.setSourceAdmission({ commandId: command("ownership-archive"), recordId: canonical.record.id, expectedRevision: canonical.record.revisionId, status: "archived", reason: "fixture archive" });
    const archivedAlias = await captureSource(store, { commandId: command("ownership-archived-alias"), url: "https://example.com/archived-alias", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(archivedAlias.record.id).toBe(canonical.record.id); expect(archivedAlias.record.content.admission).toEqual(archived.record.content.admission);
    const pending = await store.setSourceAdmission({ commandId: command("ownership-pending"), recordId: archivedAlias.record.id, expectedRevision: archivedAlias.record.revisionId, status: "pending", reason: "fixture pending" });
    const pendingAlias = await captureSource(store, { commandId: command("ownership-pending-alias"), url: "https://example.com/pending-alias", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(pendingAlias.record.id).toBe(canonical.record.id); expect(pendingAlias.record.content.admission).toEqual(pending.record.content.admission);
    const excluded = await store.setExclusion(command("ownership-suppress"), canonical.record.id, true, pendingAlias.record.revisionId, "fixture suppression");
    const suppressedAlias = await captureSource(store, { commandId: command("ownership-suppressed-alias"), url: "https://example.com/suppressed-alias", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(suppressedAlias.record.id).toBe(canonical.record.id);
    expect((await store.list({ kind: "source", scope: "research" })).records).toHaveLength(0);
    expect((await store.list({ kind: "source", scope: "research", includeSuppressed: true, includeArchived: true, includePending: true })).records).toHaveLength(1);
    expect(excluded.excluded).toBe(true);
  });

  it("fails before mutation when canonical provenance or annotations are already saturated", async () => {
    const { store } = await fixture();
    const fetcher = async (url: URL) => url.toString() === "https://example.com/alias" ? new Response(null, { status: 302, headers: { location: "https://example.com/canonical" } }) : new Response("canonical", { headers: { "content-type": "text/plain" } });
    const seed = await captureSource(store, { commandId: command("saturated-seed"), url: "https://example.com/canonical", scope: "research" }, { fetcher, resolveHost: publicResolver });
    const saturated = await store.captureSource({ commandId: command("saturated-origins"), expectedRevision: seed.record.revisionId, record: { ...seed.record, content: { ...seed.record.content, origins: Array.from({ length: 20 }, (_, index) => ({ kind: "manual", capturedAt: seed.record.content.capturedAt, uri: `https://fixture.example/origin-${index}` })) } } });
    await expect(captureSource(store, { commandId: command("saturated-origin-alias"), url: "https://example.com/alias", scope: "research" }, { fetcher, resolveHost: publicResolver })).rejects.toThrow(/provenance bound/);
    expect((await store.read(seed.record.id, saturated.record.revisionId, true, true, true))?.revisionId).toBe(saturated.record.revisionId);

    const second = await fixture();
    const annotatedSeed = await captureSource(second.store, { commandId: command("saturated-annotation-seed"), url: "https://example.com/canonical", scope: "research" }, { fetcher, resolveHost: publicResolver });
    const annotated = await second.store.captureSource({ commandId: command("saturated-annotations"), expectedRevision: annotatedSeed.record.revisionId, record: { ...annotatedSeed.record, content: { ...annotatedSeed.record.content, annotations: Array.from({ length: 200 }, (_, index) => ({ text: `annotation-${index}`, locator: "fixture" })) } } });
    await expect(captureSource(second.store, { commandId: command("saturated-annotation-alias"), url: "https://example.com/alias", scope: "research", annotations: [{ text: "new annotation", locator: "fixture" }] }, { fetcher, resolveHost: publicResolver })).rejects.toThrow(/annotation bound/);
    expect((await second.store.read(annotatedSeed.record.id, annotated.record.revisionId, true, true, true))?.revisionId).toBe(annotated.record.revisionId);
  });

  it("keeps redirect matching within scope and rejects ambiguous canonical duplicates", async () => {
    const { store } = await fixture();
    const fetcher = async (url: URL) => url.toString() === "https://example.com/old" ? new Response(null, { status: 301, headers: { location: "https://example.com/new" } }) : new Response("new", { headers: { "content-type": "text/plain" } });
    const personal = await captureSource(store, { commandId: command("personal-target"), url: "https://example.com/new", scope: "personal" }, { fetcher, resolveHost: publicResolver });
    const research = await captureSource(store, { commandId: command("research-alias"), url: "https://example.com/old", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(research.record.id).not.toBe(personal.record.id);
    const conflicting = await store.captureSource({ commandId: command("conflicting-target"), record: { ...personal.record, id: randomUUID(), createdAt: new Date().toISOString() } });
    expect(conflicting.record.id).not.toBe(personal.record.id);
    await expect(captureSource(store, { commandId: command("ambiguous-direct"), url: "https://example.com/new", scope: "personal" }, { fetcher, resolveHost: publicResolver })).rejects.toThrow(/Multiple sources/);
    await expect(captureSource(store, { commandId: command("ambiguous-alias"), url: "https://example.com/old-2", scope: "personal" }, { fetcher: async (url: URL) => url.toString() === "https://example.com/old-2" ? new Response(null, { status: 302, headers: { location: "https://example.com/new" } }) : new Response("new", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver })).rejects.toThrow(/Multiple sources match/);
  });

  it("records destination safety failures without fetching the forbidden hop, while preserving SSRF defenses", async () => {
    const { store } = await fixture();
    const fetchedUrls: string[] = [];
    const redirect = async (url: URL) => { fetchedUrls.push(url.toString()); return new Response(null, { status: 302, headers: { location: "http://127.0.0.1/admin" } }); };
    const blocked = await captureSource(store, { commandId: command("private-redirect"), url: "https://example.com/start", scope: "research" }, { fetcher: redirect, resolveHost: publicResolver });
    expect(fetchedUrls).toEqual(["https://example.com/start"]);
    expect(blocked.record.content.captureDisposition).toBe("reference-only");
    expect(blocked.record.content.captureReason).toContain("Redirect target failed");
    expect(blocked.fetched).toBe(true);
    expect(blocked.record.content.admission?.status).toBeUndefined();
    const inaccessible = await captureSource(store, { commandId: command("login-wall"), url: "https://example.com/login", scope: "research" }, { fetcher: async () => new Response("login", { status: 401, headers: { "content-type": "text/html" } }), resolveHost: publicResolver });
    expect(inaccessible.record.content.captureDisposition).toBe("inaccessible");
    expect(inaccessible.record.content.text).toBeUndefined();
    let fetched = false;
    const directBlocked = await captureSource(store, { commandId: command("direct-private"), url: "http://127.0.0.1/admin", scope: "research" }, { fetcher: async () => { fetched = true; return new Response("must not fetch"); }, resolveHost: publicResolver });
    expect(fetched).toBe(false); expect(directBlocked.fetched).toBe(false); expect(directBlocked.record.content.captureDisposition).toBe("reference-only");
  });

  it("cleans the operation timer when publishing a blocked-source result fails", async () => {
    const { store } = await fixture();
    const publish = vi.spyOn(store, "captureSource").mockRejectedValueOnce(new Error("synthetic store failure"));
    const started = Date.now();
    await expect(captureSource(store, { commandId: command("blocked-store-failure"), url: "http://127.0.0.1/admin", scope: "research" }, { resolveHost: publicResolver })).rejects.toThrow("synthetic store failure");
    expect(Date.now() - started).toBeLessThan(500);
    publish.mockRestore();
  });

  it("terminates a stalled response body at the operation deadline", async () => {
    const { store } = await fixture();
    const stalled = new ReadableStream<Uint8Array>({ start() {} });
    const started = Date.now();
    await expect(captureSource(store, { commandId: command("stalled-body"), url: "https://example.com/stalled", scope: "research" }, { fetcher: async () => new Response(stalled, { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { timeoutMs: 100 } })).rejects.toThrow(/timed out|cancelled/);
    expect(Date.now() - started).toBeLessThan(2_000);
  });

  it("returns the retained source with an explicit assessment error when the assessor ignores cancellation", async () => {
    const { store } = await fixture();
    // The adapter never settles and ignores its AbortSignal. The bounded await
    // must release the accepted capture instead of holding it open forever.
    let assessmentStarted: (() => void) | undefined;
    const started = new Promise<void>((resolve) => { assessmentStarted = resolve; });
    const controller = new AbortController();
    const capture = captureSource(store, { commandId: command("stalled-assessment"), url: "https://example.com/assess", scope: "research" }, {
      signal: controller.signal,
      fetcher: async () => new Response("<html><title>Assessed</title><body>Evidence</body></html>", { headers: { "content-type": "text/html" } }),
      resolveHost: publicResolver,
      model: { assess: () => { assessmentStarted?.(); return new Promise<never>(() => {}); } },
    });
    await started;
    controller.abort(new Error("caller cancelled"));
    const captured = await capture;
    expect(captured.assessmentError).toMatch(/deadline|cancel/i);
    expect(captured.record.content.captureDisposition).toBe("complete");
    expect(captured.record.content.assessment).toBeUndefined();
  });

  it("upgrades an incomplete URL capture in place on retry", async () => {
    const { store } = await fixture();
    const partial = await captureSource(store, { commandId: command("partial-first"), url: "https://example.com/retry", scope: "research" }, { fetcher: async () => new Response("x".repeat(20), { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { maxBytes: 5 } });
    expect(partial.record.content.captureDisposition).toBe("partial");
    const complete = await captureSource(store, { commandId: command("partial-retry"), url: "https://example.com/retry", scope: "research" }, { fetcher: async () => new Response("recovered", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    expect(complete.record.id).toBe(partial.record.id);
    expect(complete.record.content.captureDisposition).toBe("complete");
    expect((await store.list({ kind: "source" })).records).toHaveLength(1);
  });

  it("records a retry network error on the existing incomplete source", async () => {
    const { store } = await fixture();
    const first = await captureSource(store, { commandId: command("network-first"), url: "https://example.com/network", scope: "research" }, { fetcher: async () => new Response("partial evidence", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { maxBytes: 5 } });
    const retried = await captureSource(store, { commandId: command("network-retry"), url: "https://example.com/network", scope: "research" }, { fetcher: async () => { throw new Error("synthetic network failure"); }, resolveHost: publicResolver });
    expect(retried.record.id).toBe(first.record.id);
    expect(retried.record.content.captureDisposition).toBe("partial");
    expect(retried.record.content.text).toBe("parti");
  });
  it("uses the configured readable-character bound rather than the global maximum", async () => {
    const { store } = await fixture();
    const result = await captureSource(store, { commandId: command("readable-bound"), url: "https://example.com/readable-bound", scope: "research" }, {
      fetcher: async () => new Response("a".repeat(100), { headers: { "content-type": "text/plain" } }),
      resolveHost: publicResolver,
      limits: { maxReadableChars: 10 },
    });
    expect(result.record.content.text).toHaveLength(10);
    expect(result.record.content.captureDisposition).toBe("partial");
  });

  it("bounds response extraction and keeps capture successful when assessment fails", async () => {
    const { store } = await fixture();
    const result = await captureSource(store, { commandId: command("bounded"), url: "https://example.com/large", scope: "research", interests: ["testing"] }, {
      fetcher: async () => new Response("a".repeat(100), { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver, limits: { maxBytes: 10 }, model: { assess: async () => { throw new Error("model unavailable"); } },
    });
    expect(result.record.content.captureDisposition).toBe("partial");
    expect(result.record.content.text).toHaveLength(10);
    expect(result.assessmentError).toContain("model unavailable");
    expect(result.record.content.object).toBeDefined();
  });
});

describe("preview capture", () => {
  it("retains a safe bounded OpenGraph image without failing the source when absent", async () => {
    const { store } = await fixture();
    const html = '<html><head><meta property="og:image" content="https://example.com/preview.png"></head><body>Readable</body></html>';
    const fetcher = vi.fn(async (url: URL) => url.toString() === "https://example.com/preview.png"
      ? new Response(new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]), { headers: { "content-type": "image/png" } })
      : new Response(html, { headers: { "content-type": "text/html" } }));
    const result = await captureSource(store, { commandId: command("preview"), url: "https://example.com/article", scope: "research" }, { fetcher, resolveHost: publicResolver });
    expect(result.record.content.preview?.mediaType).toBe("image/png");
    expect(result.record.content.object).toBeDefined();
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("rejects unsafe or unsupported preview responses without failing capture", async () => {
    const { store } = await fixture();
    const html = '<meta property="og:image" content="file:///private/image.png">';
    const result = await captureSource(store, { commandId: command("preview-unsafe"), url: "https://example.com/article", scope: "research" }, { fetcher: async () => new Response(html, { headers: { "content-type": "text/html" } }), resolveHost: publicResolver });
    expect(result.record.content.preview).toBeUndefined();
    expect(result.record.content.captureDisposition).not.toBe("failed");
  });
});

describe("semantic notes", () => {
  it("preserves field evidence, corrections, contrary evidence, and supersession", async () => {
    const { store } = await fixture();
    const source = await captureSource(store, { commandId: command("note-source"), url: "https://example.com/note", scope: "research" }, { fetcher: async () => new Response("evidence", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    const citation = { recordId: source.record.id, revisionId: source.record.revisionId, objectHash: source.record.content.object!.hash };
    const note = await store.createNote({ commandId: command("note-create"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", evidence: [citation] }, relations: [], content: { title: "Preference", role: "preference", confirmed: true, fields: [{ field: "theme", value: "dark", evidence: [citation], certainty: "confirmed" }] } } });
    const updated = await store.updateNote({ commandId: command("note-update"), recordId: note.record.id, expectedRevision: note.record.revisionId, record: { kind: "note", scope: "personal", provenance: { actor: "agent", evidence: [citation] }, relations: [], content: { title: "Preference", role: "preference", confirmed: true, freshness: "current", contraryEvidence: [citation], fields: [{ field: "theme", value: "light", evidence: [citation], certainty: "confirmed" }] } } });
    const corrected = await store.correct(command("note-correct"), updated.record.id, updated.record.revisionId, { kind: "note", scope: "personal", provenance: { actor: "agent", evidence: [citation] }, relations: [], content: { title: "Corrected", role: "preference", confirmed: true, fields: [{ field: "theme", value: "system", evidence: [citation], certainty: "confirmed" }] } }, { type: "corrects", recordId: updated.record.id, revisionId: updated.record.revisionId });
    const replacement = await store.createNote({ commandId: command("note-supersede"), record: { kind: "note", scope: "personal", provenance: { actor: "agent", evidence: [] }, relations: [{ type: "supersedes", recordId: corrected.record.id, revisionId: corrected.record.revisionId }], content: { title: "Current preference", role: "preference", confirmed: false } } });
    expect(updated.record.content).toMatchObject({ contraryEvidence: [citation], fields: [{ value: "light" }] });
    expect(corrected.record.relations).toContainEqual({ type: "corrects", recordId: updated.record.id, revisionId: updated.record.revisionId });
    expect(replacement.record.relations).toContainEqual({ type: "supersedes", recordId: corrected.record.id, revisionId: corrected.record.revisionId });
    const sourceRecord = await store.read(citation.recordId, citation.revisionId);
    expect(sourceRecord?.kind).toBe("source");
    expect((await store.readObject(sourceRecord!.content.object!, { recordId: citation.recordId, revisionId: citation.revisionId }))?.byteLength).toBeGreaterThan(0);
  });
});
