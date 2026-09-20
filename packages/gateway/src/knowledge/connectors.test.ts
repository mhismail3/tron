import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "./connector-credentials.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { withInvocationContext } from "../extensions/owner-attribution.js";

const roots: string[] = [];
const command = (name: string) => `connector-test-${name}`;
const headers = () => new Headers();
const publicResolver = async () => ["93.184.216.34"];

afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function response(value: unknown, status = 200): ConnectorHTTPResponse { return { status, headers: headers(), body: JSON.stringify(value) }; }
async function fixture(http: (url: string, init: { headers: Record<string, string>; signal: AbortSignal; method?: "GET" | "PUT" | "POST" | "DELETE" }) => Promise<ConnectorHTTPResponse>, xPricing?: { accountId: string; costCentsPerAttempt: number; maxAttempts: number }) {
  const root = await mkdtemp(join(tmpdir(), "tron-connector-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  const extension = new KnowledgeConnectorExtension(store, {
    credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test-account", "synthetic-raindrop-token"], ["connector:x:test-account", "synthetic-x-token"]])),
    http,
    resolveHost: publicResolver,
    sourceFetch: async (_url, excerpt) => new Response(excerpt ?? "", { headers: { "content-type": "text/plain", ...(excerpt ? { "x-tron-source-capture-quality": "partial" } : {}) } }),
    sleep: async () => {},
    now: () => "2026-01-01T00:00:00.000Z",
    ...(xPricing ? { xPricing } : {}),
  });
  return { store, extension };
}

describe("knowledge connectors", () => {
  it("discovers a bounded Raindrop batch before processing it and deduplicates shifted pages", async () => {
    let calls = 0;
    const first = Array.from({ length: 50 }, (_, index) => ({ _id: index + 1, title: `Bookmark ${index}`, link: `https://example.com/${index}`, excerpt: `Excerpt ${index}` }));
    const { store, extension } = await fixture(async (url) => {
      calls += 1;
      if (url.includes("/raindrops/123?page=0")) return response({ items: first });
      if (url.includes("/raindrops/123?page=1")) return response({ items: [{ _id: 50, title: "Duplicate", link: "https://example.com/49" }, { _id: 51, title: "Bookmark 51", link: "https://example.com/51" }] });
      throw new Error(`unexpected endpoint ${url}`);
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("configure"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account" } });
    const dryRun = await extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("discover"), connector: "raindrop", dryRun: true, limit: 51 } }) as { discovered: number; pending: number };
    expect(dryRun.discovered).toBe(51);
    expect(dryRun.pending).toBe(51);
    expect(calls).toBe(2);
    const state = await store.connectorState("raindrop");
    expect(state?.checkpoint).toBeUndefined();
    expect(state?.pending.map(item => item.id)).toHaveLength(51);
    const result = await extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("capture"), connector: "raindrop", dryRun: false, limit: 2 } }) as { captured: number; pending: number };
    expect(result.captured).toBe(0);
    expect(result.partial).toBe(1);
    expect(result.pending).toBe(51);
    expect((await store.list({ kind: "source" })).records).toHaveLength(1);
  });

  it("reads raw bookmark metadata and continues small pages without losing fields", async () => {
    const seen: string[] = [];
    const { extension } = await fixture(async (url) => {
      seen.push(url);
      if (url.endsWith("/user")) return { status: 200, headers: new Headers({ "X-RateLimit-Limit": "120", "RateLimit-Remaining": "119", "X-RateLimit-Reset": "2000000000" }), body: JSON.stringify({ user: { _id: 42, email: "private@example.test" } }) };
      if (url.includes("/raindrops/7?")) return { ...response({ items: [{ _id: 99, title: "Bookmark", link: "https://example.test/a", tags: ["one"], media: [{ type: "image" }], collection: { $id: 7 }, note: "keep", custom: { retained: true } }] }), headers: new Headers({ "RateLimit-Remaining": "118" }) };
      throw new Error(`unexpected endpoint ${url}`);
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("read-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("read-page"), read: { operation: "bookmarks", collectionId: "7", perpage: 1, page: 0 } } }) as any;
    expect(result.data.items[0].custom).toEqual({ retained: true });
    expect(result.nextPage).toBe(1);
    expect(result.rateLimit.remaining).toBe("118");
    expect(seen[0]).toMatch(/\/user$/);
    expect(seen[1]).toContain("\/raindrops\/7?");
  });

  it("reads child collections, scoped highlights and complete single items through GET only", async () => {
    const seen: string[] = [];
    const { extension } = await fixture(async (url, init) => {
      expect(init.method ?? "GET").toBe("GET"); seen.push(url);
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.endsWith("/collections")) return response({ items: [{ _id: 7, title: "Root" }] });
      if (url.endsWith("/collections/childrens")) return { ...response({ items: [{ _id: 8, parent: { $id: 7 } }] }), headers: new Headers({ "X-RateLimit-Remaining": "116" }) };
      if (url.endsWith("/raindrop/99")) return response({ item: { _id: 99, highlights: [{ text: "quote" }], cache: { status: "ready" }, unknownField: true } });
      if (url.includes("/highlights/7?")) return response({ items: [] });
      if (url.endsWith("/tags")) return response({ items: [{ _id: "tag", count: 3 }] });
      throw new Error("Unexpected endpoint");
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("endpoints-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "0", credentialRef: "connector:raindrop:test-account" } });
    const collections = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("collections-read"), read: { operation: "collections", children: true } } }) as any;
    expect(collections.data.children.items[0].parent.$id).toBe(7);
    expect(collections.rateLimit.remaining).toBe("116");
    const item = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("item-read"), read: { operation: "item", itemId: "99" } } }) as any;
    expect(item.data.item.unknownField).toBe(true);
    const highlights = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("highlights-read"), read: { operation: "highlights", collectionId: "7", perpage: 1 } } }) as any;
    expect(highlights.nextPage).toBeUndefined();
    expect(seen).toContain("https://api.raindrop.io/rest/v1/highlights/7?page=0&perpage=1");
    const tags = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("tags-read"), read: { operation: "tags" } } }) as any;
    expect(tags.data.items[0]._id).toBe("tag");
  });

  it.each([401, 403, 429])("redacts provider HTTP %s without retrying auth or shortening a long cooldown", async status => {
    let calls = 0;
    const { extension } = await fixture(async () => { calls += 1; return { status, headers: new Headers({ "Retry-After": "3600" }), body: "private provider error" }; });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command(`http-${status}`), connector: "raindrop", enabled: true, accountId: "42", credentialRef: "connector:raindrop:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("http-read"), read: { operation: "user" } } })).rejects.toMatchObject({ code: status === 429 ? "internal" : "unsupported" });
    expect(calls).toBe(1);
  });

  it.each([{ result: false }, { unexpected: true }])("rejects unusable metadata without reporting an empty library", async payload => {
    const { extension } = await fixture(async url => response(url.endsWith("/user") ? { user: { _id: 42 } } : payload));
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("shape-config"), connector: "raindrop", enabled: true, accountId: "42", credentialRef: "connector:raindrop:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("shape-read"), read: { operation: "bookmarks" } } })).rejects.toMatchObject({ code: "internal" });
  });

  it("fails closed when the authenticated Raindrop account differs", async () => {
    let calls = 0;
    const { extension } = await fixture(async (url) => { calls += 1; if (url.endsWith("/user")) return response({ user: { _id: 43 } }); return response({}); });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("mismatch-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("mismatch-read"), read: { operation: "user" } } })).rejects.toMatchObject({ code: "conflict" });
    expect(calls).toBe(1);
  });

  it("rejects oversized raw metadata instead of truncating provider fields", async () => {
    const { extension } = await fixture(async (url) => { if (url.endsWith("/user")) return response({ user: { _id: 42 } }); return response({ items: [{ _id: 1, huge: "x".repeat(2_100_000) }] }); });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("large-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("large-read"), read: { operation: "bookmarks", collectionId: "7" } } })).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("propagates cancellation through a provider request that honors AbortSignal", async () => {
    let entered!: () => void;
    const started = new Promise<void>(resolve => { entered = resolve; });
    const { extension } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      return await new Promise<ConnectorHTTPResponse>((_resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
        entered();
      });
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("cancel-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } });
    const controller = new AbortController();
    const pending = extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("cancel-read"), read: { operation: "bookmarks", collectionId: "7" } } }, controller.signal);
    await started;
    controller.abort(new Error("cancelled"));
    await expect(pending).rejects.toMatchObject({ code: "busy" });
  });

  it.each(["Retry-After", "X-RateLimit-Reset", "RateLimit-Reset"])("honors %s before a safe retry", async header => {
    let calls = 0; let firstAt = 0; let retryAt = 0;
    const { extension } = await fixture(async () => {
      calls += 1;
      if (calls === 1) {
        firstAt = Date.now(); retryAt = Math.ceil(firstAt / 1000) * 1000 + 1000;
        return { status: 429, body: "{}", headers: new Headers({ [header]: header === "Retry-After" ? new Date(retryAt).toUTCString() : String(retryAt / 1000) }) };
      }
      expect(Date.now()).toBeGreaterThanOrEqual(retryAt - 5);
      return response({ user: { _id: 42 } });
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("retry-config"), connector: "raindrop", enabled: true, accountId: "42", credentialRef: "connector:raindrop:test-account" } });
    await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("retry-read"), read: { operation: "user" } } });
    expect(calls).toBe(2);
    expect(Date.now() - firstAt).toBeGreaterThanOrEqual(995);
  });

  it("serializes connector configuration behind an admitted discovery request", async () => {
    let release!: () => void;
    let requests = 0;
    const blocked = new Promise<void>(resolve => { release = resolve; });
    const { extension } = await fixture(async () => { requests += 1; await blocked; return response({ items: [] }); });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("lane-configure"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account" } });
    const run = extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("lane-run"), connector: "raindrop", dryRun: true, limit: 1 } });
    await new Promise(resolve => setTimeout(resolve, 20));
    const reconfigure = extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("lane-reconfigure"), connector: "raindrop", enabled: true, accountId: "account-2", scope: "456", credentialRef: "connector:raindrop:test-account" } });
    let settled = false; void reconfigure.then(() => { settled = true; });
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(requests).toBe(1);
    expect(settled).toBe(false);
    release();
    await run; await reconfigure;
    expect(settled).toBe(true);
  });

  it("does not contact X without explicit paid access and budget", async () => {
    let calls = 0;
    const { extension } = await fixture(async () => { calls += 1; return response({ data: [] }); });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-configure"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("x-run"), connector: "x", dryRun: false, limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
    expect(calls).toBe(0);
  });

  it("debits every X retry attempt and refuses the request before exceeding budget", async () => {
    let calls = 0;
    const { store, extension } = await fixture(async () => { calls += 1; return response({ error: "retry" }, 500); }, { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 3 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-qualified"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 2 } });
    await expect(extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("x-budget"), connector: "x", dryRun: false, limit: 1 } })).rejects.toMatchObject({ code: "internal" });
    expect(calls).toBe(2);
    expect((await store.connectorState("x"))?.paidBudgetCents).toBe(0);
  });

  it("charges a fresh allowance for each repeated run command", async () => {
    let calls = 0;
    const { store, extension } = await fixture(async () => { calls += 1; return response({ error: "rate limited" }, 429); }, { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 1 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-replay-configure"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 2 } });
    const run = { operation: "knowledge.connector.run" as const, request: { commandId: command("x-replay-run"), connector: "x" as const, dryRun: false, limit: 1 } };
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    expect(calls).toBe(2);
    expect((await store.connectorState("x"))?.paidBudgetCents).toBe(0);
  });

  it("requires trusted current Automation authority for recurring X sweeps", async () => {
    const { extension } = await fixture(async () => response({ data: [] }), { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 1 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-recurring-configure"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 1 } });
    await expect(withInvocationContext({ invocationId: "invocation-1", operationId: "automation:run-1" }, () => extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("x-recurring-run"), connector: "x", dryRun: true, limit: 1 } }))).rejects.toMatchObject({ code: "unsupported" });
  });

  it("reconciles an admitted effect-before-response crash from its durable Raindrop receipt", async () => {
    let putAttempts = 0;
    let remoteCollection = 123;
    const { store, extension } = await fixture(async (_url, init) => {
      if (init.method === "PUT") { putAttempts += 1; remoteCollection = 456; return response({ error: "timeout-after-effect" }, 500); }
      return response({ item: { _id: 1, collection: { $id: remoteCollection } } });
    });
    const object = await store.putObject(new TextEncoder().encode("captured article"), "text/plain");
    const captured = await store.captureSource({ commandId: command("source"), record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Captured", uri: "https://example.com/1", text: "captured article", object, identity: { provider: "raindrop", accountId: "account-1", itemId: "1" }, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("write-approved"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account", destination: "456", allowWrites: true } });
    await expect(extension.moveRaindrop({ commandId: command("move-uncertain"), itemId: "1", destination: "456", source: captured.record as typeof captured.record & { kind: "source" }, expectedRevision: captured.record.revisionId, identity: { provider: "raindrop", accountId: "account-1", itemId: "1" } })).resolves.toEqual({ status: "conflict" });
    // The effect was admitted and the provider changed before its response;
    // reconciliation must inspect the exact item and clear the receipt rather
    // than issue a blind second PUT.
    expect(putAttempts).toBe(1);
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeDefined();
    const status = await extension.reconcile("raindrop");
    expect(status.health).toBe("ready");
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeUndefined();
  });

  it("does not permit remote Raindrop effects without a separately approved write policy", async () => {
    const { store, extension } = await fixture(async () => response({ items: [] }));
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("write-config"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account", destination: "456" } });
    const result = await extension.moveRaindrop({ commandId: command("move-denied"), itemId: "1", destination: "456", source: { kind: "source", schemaVersion: 1, id: "source-1", revisionId: "revision-1234567890123456", scope: "research", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Captured", uri: "https://example.com/1", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
    expect(result.status).toBe("unsupported");
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeUndefined();
  });
});
