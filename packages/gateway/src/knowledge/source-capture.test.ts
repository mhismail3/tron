import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { captureSource, isPrivateAddress } from "./source-capture.js";
import { createSemanticNote, correctSemanticNote, readCitedSourceObject, supersedeSemanticNote, updateSemanticNote } from "./semantic-notes.js";

const homes: string[] = [];
const command = (value: string) => `source-test-${value}`;
async function fixture(): Promise<{ store: KnowledgeStore; home: string }> {
  const home = await mkdtemp(join(tmpdir(), "tron-source-")); homes.push(home);
  return { home, store: new KnowledgeStore(new TronWorkspace(home)) };
}
afterEach(async () => { await Promise.all(homes.splice(0).map(home => rm(home, { recursive: true, force: true }))); });

const publicResolver = async () => ["93.184.216.34"];

describe("safe source capture", () => {
  it("rejects hexadecimal IPv4-mapped private IPv6 destinations", () => {
    expect(isPrivateAddress("::ffff:7f00:1")).toBe(true);
    expect(isPrivateAddress("::ffff:c0a8:101")).toBe(true);
    expect(isPrivateAddress("2001:db8::1")).toBe(false);
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

  it("blocks private redirect destinations and records inaccessible responses without a fake success", async () => {
    const { store } = await fixture();
    const redirect = async () => new Response(null, { status: 302, headers: { location: "http://127.0.0.1/admin" } });
    await expect(captureSource(store, { commandId: command("private-redirect"), url: "https://example.com/start", scope: "research" }, { fetcher: redirect, resolveHost: publicResolver })).rejects.toThrow(/publicly routable/);
    const inaccessible = await captureSource(store, { commandId: command("login-wall"), url: "https://example.com/login", scope: "research" }, { fetcher: async () => new Response("login", { status: 401, headers: { "content-type": "text/html" } }), resolveHost: publicResolver });
    expect(inaccessible.record.content.captureDisposition).toBe("inaccessible");
    expect(inaccessible.record.content.text).toBeUndefined();
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

describe("semantic notes", () => {
  it("preserves field evidence, corrections, contrary evidence, and supersession", async () => {
    const { store } = await fixture();
    const source = await captureSource(store, { commandId: command("note-source"), url: "https://example.com/note", scope: "research" }, { fetcher: async () => new Response("evidence", { headers: { "content-type": "text/plain" } }), resolveHost: publicResolver });
    const citation = { recordId: source.record.id, revisionId: source.record.revisionId, objectHash: source.record.content.object!.hash };
    const note = await createSemanticNote(store, { commandId: command("note-create"), scope: "personal", title: "Preference", role: "preference", confirmed: true, fields: [{ field: "theme", value: "dark", evidence: [citation], certainty: "confirmed" }], evidence: [citation] });
    const updated = await updateSemanticNote(store, { commandId: command("note-update"), recordId: note.record.id, expectedRevision: note.record.revisionId, scope: "personal", title: "Preference", role: "preference", confirmed: true, freshness: "current", contraryEvidence: [citation], fields: [{ field: "theme", value: "light", evidence: [citation], certainty: "confirmed" }] });
    const corrected = await correctSemanticNote(store, { commandId: command("note-correct"), recordId: updated.record.id, expectedRevision: updated.record.revisionId, scope: "personal", title: "Corrected", role: "preference", confirmed: true, fields: [{ field: "theme", value: "system", evidence: [citation], certainty: "confirmed" }] });
    const replacement = await supersedeSemanticNote(store, { commandId: command("note-supersede"), supersedesRecordId: corrected.record.id, supersedesRevisionId: corrected.record.revisionId, scope: "personal", title: "Current preference", role: "preference", confirmed: false });
    expect(replacement.record.relations).toContainEqual({ type: "supersedes", recordId: corrected.record.id, revisionId: corrected.record.revisionId });
    expect((await readCitedSourceObject(store, citation))?.byteLength).toBeGreaterThan(0);
  });
});
