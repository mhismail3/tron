import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "./connector-credentials.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { withInvocationContext } from "../extensions/owner-attribution.js";

const roots: string[] = [];
const command = (name: string) => `connector-test-${name}`;
const headers = () => new Headers();
const publicResolver = async () => ["93.184.216.34"];

afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function response(value: unknown, status = 200): ConnectorHTTPResponse { return { status, headers: headers(), body: JSON.stringify(value) }; }
async function fixture(http: (url: string, init: { headers: Record<string, string>; signal: AbortSignal; method?: "GET" | "PUT" | "POST" | "DELETE" }) => Promise<ConnectorHTTPResponse>, xPricing?: { accountId: string; costCentsPerAttempt: number; maxAttempts: number }, options: { assessment?: SourceAssessmentModel; sourceFetch?: (url: string, excerpt: string | undefined, signal: AbortSignal) => Promise<Response> } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-connector-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  const extension = new KnowledgeConnectorExtension(store, {
    credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test-account", "synthetic-raindrop-token"], ["connector:x:test-account", "synthetic-x-token"]])),
    http,
    resolveHost: publicResolver,
    sourceFetch: options.sourceFetch ?? (async (_url, excerpt) => new Response(excerpt ?? "", { headers: { "content-type": "text/plain", ...(excerpt ? { "x-tron-source-capture-quality": "partial" } : {}) } })),
    ...(options.assessment ? { assessment: options.assessment } : {}),
    sleep: async () => {},
    now: () => "2026-01-01T00:00:00.000Z",
    ...(xPricing ? { xPricing } : {}),
  });
  return { store, extension };
}

describe("knowledge connectors", () => {
  it("rejects malformed Raindrop read envelopes before credential lookup or HTTP", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-malformed-read-")); roots.push(root);
    let credentialReads = 0; let httpCalls = 0;
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: { read: async () => { credentialReads += 1; return "must-not-read"; } },
      http: async () => { httpCalls += 1; return response({ result: true }); },
    });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("malformed"), read: { operation: "collection" } } } as any)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("malformed-sort"), read: { operation: "bookmarks", sort: 42 } } } as any)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("malformed-extra"), read: { operation: "user", extra: true } } } as any)).rejects.toMatchObject({ code: "invalid_request" });
    expect(credentialReads).toBe(0); expect(httpCalls).toBe(0);
  });
  it("persists a destination-safety outcome without fetching a forbidden bookmark URL", async () => {
    let linkedFetches = 0;
    const { store, extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "Blocked target", link: "http://127.0.0.1/admin", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { sourceFetch: async () => { linkedFetches += 1; return new Response("must not fetch"); } });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("blocked-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("blocked-intake"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "blocked-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(linkedFetches).toBe(0); expect(result).toMatchObject({ captured: 1, pending: 1, assessmentFailed: 0 });
    expect(result.outcomes).toHaveLength(1); expect(result.outcomes[0]).toMatchObject({ itemId: "1", disposition: "pending", assessment: "not-run", move: "not-attempted" });
    const source = (await store.list({ kind: "source", includePending: true })).records[0];
    expect(source?.content.captureDisposition).toBe("reference-only"); expect(source?.content.captureReason).toContain("Destination safety check failed");
  });

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
    expect((await store.list({ kind: "source", includePending: true })).records).toHaveLength(1);
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

  it("accepts the documented single-collection envelope and retries a transient read without a fallback shape", async () => {
    let collectionCalls = 0;
    const { extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.endsWith("/collection/7")) {
        collectionCalls += 1;
        return collectionCalls === 1 ? response({ result: false }, 503) : response({ result: true, item: { _id: 7, title: "Resources", count: 273 } });
      }
      throw new Error(`unexpected endpoint ${url}`);
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("collection-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "0", credentialRef: "connector:raindrop:test-account" } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("collection-read"), read: { operation: "collection", collectionId: "7" } } }) as any;
    expect(result.data).toEqual({ result: true, item: { _id: 7, title: "Resources", count: 273 } });
    expect(collectionCalls).toBe(2);
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

  it("projects configuration health from current authority across scope and enabled changes", async () => {
    const { extension } = await fixture(async url => url.endsWith("/user") ? response({ user: { _id: 42 } }) : response({ items: [] }));
    const incomplete = await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("health-incomplete"), connector: "raindrop", enabled: true, accountId: "42", scope: "7" } }) as any;
    expect(incomplete.configured).toBe(false);
    expect(incomplete.health).toBe("unconfigured");
    const configured = await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("health-configured"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } }) as any;
    expect(configured.configured).toBe(true);
    expect(configured.health).toBe("ready");
    const disabled = await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("health-disabled"), connector: "raindrop", enabled: false } }) as any;
    expect(disabled.configured).toBe(true);
    expect(disabled.enabled).toBe(false);
    expect(disabled.health).toBe("unconfigured");
    const rescoped = await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("health-rescope"), connector: "raindrop", enabled: true, scope: "8" } }) as any;
    expect(rescoped.configured).toBe(true);
    expect(rescoped.scope).toBe("8");
    expect(rescoped.health).toBe("ready");
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

  it("captures, assesses, preserves collection provenance, and moves one bounded intake item", async () => {
    let collection = "111";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Synthetic retained source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric", usage: { inputTokens: 100, outputTokens: 4, estimatedCostCents: 0.00042, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } }; } };
    const { store, extension } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "Synthetic item", link: "https://example.test/item", collection: { $id: 111 }, custom: { preserved: true } }] });
      if (url.endsWith("/raindrop/1") && init.method !== "PUT") return response({ item: { _id: 1, collection: { $id: Number(collection) } } });
      if (init.method === "PUT") { collection = "222"; return response({ item: { _id: 1, collection: { $id: 222 } } });
      }
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("Synthetic complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("intake-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account", destination: "222", allowWrites: true } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("intake-run"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "synthetic-pilot", maxItems: 1, budgetCents: 1 } } });
    expect(result).toMatchObject({ moved: 1, retained: 1, archived: 0, assessmentFailed: 0, budget: { approvedCeilingCents: 1, conservativeReservedCents: 1, cohortItemCap: 1, cohortSelectedItems: 1, settledItems: 1, estimatedUsageCostCents: 0.00042, usageKnownAssessments: 1, usageUnknownAssessments: 0, pendingOutsideCohortItems: 0 } });
    expect((result as any).outcomes).toHaveLength(1);
    expect((result as any).outcomes[0]).toMatchObject({ itemId: "1", disposition: "retained", assessment: "dispatched-settled", move: "moved" });
    const firstSource = (await store.list({ kind: "source", includeArchived: true, includePending: true })).records[0];
    expect((result as any).outcomes[0].sourceId).toBe(firstSource?.id);
    expect((result as any).outcomes[0].sourceRevision).toBe(firstSource?.revisionId);
    expect(new Set((result as any).outcomes.map((entry: any) => entry.itemId)).size).toBe((result as any).outcomes.length);
    const rerun = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("intake-usage-rerun"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "synthetic-pilot", maxItems: 1, budgetCents: 1 } } });
    expect(rerun).toMatchObject({ moved: 0, budget: { estimatedUsageCostCents: 0.00042, usageKnownAssessments: 1, usageUnknownAssessments: 0 } });
    const sources = (await store.list({ kind: "source", includeArchived: true })).records;
    expect(sources).toHaveLength(1);
    expect(sources[0]?.content.collectionId).toBe("111");
    expect(sources[0]?.content.representations?.[0]?.kind).toBe("provider-api");
    expect(sources[0]?.content.admission?.status).toBe("retained");
    expect((await store.connectorState("raindrop"))?.assessmentPilot).toMatchObject({ usedItems: 1, reservedCents: 1 });
    expect((await store.connectorState("raindrop"))?.assessmentAttempts?.["1"]).toMatchObject({ status: "settled", chargeCents: 1, inputTokens: 100, outputTokens: 4, estimatedCostCents: 0.00042 });
  });

  it("keeps paid pilot spend monotonic and fences exact-command assessment replay", async () => {
    let jevCalls = 0;
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); jevCalls += 1; return { summary: "bounded", evidenceQuality: "none", freshness: "unknown", model: "jev-1.13.0", recommendation: "retained", confidence: 0.9, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { extension, store } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }, { _id: 2, title: "Two", link: "https://example.test/two", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("budget-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const request = { operation: "knowledge.raindrop.intake" as const, request: { commandId: command("budget-intake"), sourceCollection: "111", dryRun: false, limit: 2, pilot: { id: "budget-pilot", maxItems: 2, budgetCents: 1 } } };
    const first = await extension.invoke(request) as any;
    const second = await extension.invoke(request) as any;
    expect(first.budget).toMatchObject({ approvedCeilingCents: 1, conservativeReservedCents: 1, cohortItemCap: 2, cohortSelectedItems: 2, settledItems: 1, usageKnownAssessments: 0, usageUnknownAssessments: 1 });
    expect(second.budget).toMatchObject({ approvedCeilingCents: 1, conservativeReservedCents: 1, usageKnownAssessments: 0, usageUnknownAssessments: 1 });
    expect(new Set((first as any).outcomes.map((entry: any) => entry.itemId)).size).toBe((first as any).outcomes.length);
    expect((first as any).outcomes).toHaveLength(2);
    expect(jevCalls).toBe(1);
    expect((await store.connectorState("raindrop"))?.assessmentPilot).toMatchObject({ usedItems: 1, reservedCents: 1 });
  });

  it("reconciles an admitted effect-before-response crash from its durable Raindrop receipt", async () => {
    let putAttempts = 0;
    let remoteCollection = 123;
    const { store, extension } = await fixture(async (_url, init) => {
      if (init.method === "PUT") { putAttempts += 1; remoteCollection = 456; return response({ error: "timeout-after-effect" }, 500); }
      return response({ item: { _id: 1, collection: { $id: remoteCollection } } });
    });
    const object = await store.putObject(new TextEncoder().encode("captured article"), "text/plain");
    const captured = await store.captureSource({ commandId: command("source"), record: { kind: "source", scope: "research", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Captured", uri: "https://example.com/1", text: "captured article", object, identity: { provider: "raindrop", accountId: "account-1", itemId: "1" }, admission: { status: "retained", reason: "synthetic admission", decidedAt: "2026-01-01T00:00:00.000Z" }, captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
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

  it("does not reserve a paid attempt when model preflight fails, but fences an uncertain dispatch", async () => {
    let calls = 0; let preflight = true;
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) {
      if (preflight) { preflight = false; throw new Error("synthetic preflight rejection"); }
      await context?.beforeDispatch?.();
      calls += 1;
      throw new Error("synthetic response uncertainty");
    } };
    const { store, extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("preflight-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const intake = (id: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "dispatch-fence", maxItems: 1, budgetCents: 1 } } });
    await intake("preflight-failure");
    expect((await store.connectorState("raindrop"))?.assessmentAttempts).toBeUndefined();
    const uncertain = await intake("uncertain-dispatch") as any;
    expect((await store.connectorState("raindrop"))?.assessmentAttempts?.["1"]).toMatchObject({ status: "dispatched", chargeCents: 1 });
    expect(uncertain.outcomes).toHaveLength(1);
    expect(uncertain.outcomes[0]).toMatchObject({ itemId: "1", assessment: "dispatched-uncertain", move: "not-attempted" });
    await intake("uncertain-replay");
    expect(calls).toBe(1);
    // A renewed attempt is explicit and additive: the earlier uncertain charge
    // remains reserved, rather than being erased or automatically retried.
    await extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command("explicit-retry-approval"), connector: "raindrop", id: "explicit-retry", maxItems: 1, budgetCents: 1, itemIds: ["1"] } });
    const retry = (id: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), dryRun: false, limit: 1, pilot: { id: "explicit-retry", maxItems: 1, budgetCents: 1 } } });
    await retry("renewed-attempt");
    expect(calls).toBe(2);
    await retry("renewed-replay");
    expect(calls).toBe(2);
    const state = await store.connectorState("raindrop");
    expect(state?.assessmentPilot?.reservedCents).toBe(1);
    expect(state?.assessmentApprovals?.[0]).toMatchObject({ itemIds: ["1"], reservedCents: 1 });
    expect(state?.assessmentAttempts?.["1"]).toMatchObject({ status: "dispatched", chargeCents: 1 });
    expect(state?.assessmentAttempts?.["explicit-retry:1"]).toMatchObject({ status: "dispatched", chargeCents: 1 });
  });

  it.each(["completion", "admission"])("preserves the settled assessment when %s fails afterward", async failure => {
    let collection = "111";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "synthetic", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { store, extension } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "Receipt failure", link: "https://example.test/receipt", collection: { $id: 111 } }] });
      if (url.endsWith("/raindrop/1")) { if (init.method === "PUT") collection = "222"; return response({ item: { _id: 1, collection: { $id: Number(collection) } } }); }
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("receipt-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", destination: "222", allowWrites: true, credentialRef: "connector:raindrop:test-account" } });
    const original = store.updateConnectorState.bind(store);
    const update = vi.spyOn(store, "updateConnectorState").mockImplementation(async (commandId, connector, updater) => { if (failure === "completion" && commandId.includes(":done-1")) throw new Error("synthetic local receipt failure"); return original(commandId, connector, updater); });
    const admission = failure === "admission" ? vi.spyOn(store, "setSourceAdmission").mockRejectedValue(new Error("synthetic admission failure")) : undefined;
    try {
      const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("receipt-intake"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "receipt-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
      expect(result.outcomes).toHaveLength(1);
      expect(result.outcomes[0]).toMatchObject({ itemId: "1", assessment: "dispatched-settled", ...(failure === "completion" ? { move: "moved", reason: "Remote move verified; local completion receipt requires reconciliation" } : { move: "not-attempted", reason: "synthetic admission failure" }) });
      const source = await store.read(result.outcomes[0].sourceId, undefined, false, true, true);
      expect(source?.revisionId).toBe(result.outcomes[0].sourceRevision);
    } finally { update.mockRestore(); admission?.mockRestore(); }
  });

  it("captures complete source evidence even when Jev is unavailable", async () => {
    const { store, extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 9, title: "Standalone", link: "https://example.test/standalone", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { sourceFetch: async () => new Response("captured without assessment", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("no-jev-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("no-jev-intake"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "no-jev", maxItems: 1, budgetCents: 1 } } });
    const source = (await store.list({ kind: "source", includePending: true })).records[0];
    expect(source?.kind).toBe("source");
    expect(source?.content.text).toBe("captured without assessment");
    expect(source?.content.admission?.status).toBe("pending");
    expect((await store.connectorState("raindrop"))?.assessmentAttempts).toBeUndefined();
  });

  it("appends an explicit renewed cohort without resetting the frozen pilot", async () => {
    let collection = "111";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "synthetic", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { store, extension } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }, { _id: 2, title: "Two", link: "https://example.test/two", collection: { $id: 111 } }] });
      if (url.endsWith("/raindrop/1") || url.endsWith("/raindrop/2")) { const item = url.endsWith("/1") ? "1" : "2"; if (init.method === "PUT") collection = "222"; return response({ item: { _id: Number(item), collection: { $id: Number(collection) } } }); }
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("renew-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", destination: "222", allowWrites: true, credentialRef: "connector:raindrop:test-account" } });
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("renew-first"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "frozen-pilot", maxItems: 1, budgetCents: 1 } } });
    const approved = await extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command("renew-approve"), connector: "raindrop", id: "renewed-cohort", maxItems: 1, budgetCents: 1 } });
    expect(approved).toMatchObject({ assessmentPilot: { id: "frozen-pilot", maxItems: 1 }, assessmentApprovals: [{ id: "renewed-cohort" }] });
    await expect(extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command("renew-approve"), connector: "raindrop", id: "different", maxItems: 2, budgetCents: 2 } })).rejects.toMatchObject({ code: "conflict" });
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("renew-second"), sourceCollection: "111", dryRun: false, limit: 1, pilot: { id: "renewed-cohort", maxItems: 1, budgetCents: 1 } } });
    const state = await store.connectorState("raindrop");
    expect(state?.assessmentPilot).toMatchObject({ id: "frozen-pilot", usedItems: 1, reservedCents: 1 });
    expect(state?.assessmentApprovals?.[0]).toMatchObject({ id: "renewed-cohort", usedItems: 1, reservedCents: 1 });
    expect(Object.keys(state?.assessmentAttempts ?? {})).toEqual(["1", "renewed-cohort:2"]);
  });

  it("does not let generic connector sweep move a pending source", async () => {
    let puts = 0;
    const { store, extension } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 4, title: "Pending", link: "https://example.test/pending", collection: { $id: 111 } }] });
      if (init.method === "PUT") puts += 1;
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { sourceFetch: async () => new Response("partial", { headers: { "content-type": "text/plain", "x-tron-source-capture-quality": "partial" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("sweep-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", destination: "222", allowWrites: true, credentialRef: "connector:raindrop:test-account" } });
    const result = await extension.invoke({ operation: "knowledge.connector.run", request: { commandId: command("sweep-pending"), connector: "raindrop", dryRun: false, limit: 1 } });
    expect(result).toMatchObject({ partial: 1 });
    expect(puts).toBe(0);
    expect((await store.list({ kind: "source", includePending: true })).records[0]?.content.admission?.status).toBe("pending");
  });

  it("does not permit remote Raindrop effects without a separately approved write policy", async () => {
    const { store, extension } = await fixture(async () => response({ items: [] }));
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("write-config"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account", destination: "456" } });
    const result = await extension.moveRaindrop({ commandId: command("move-denied"), itemId: "1", destination: "456", source: { kind: "source", schemaVersion: 1, id: "source-1", revisionId: "revision-1234567890123456", scope: "research", createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", provenance: { actor: "connector", evidence: [] }, relations: [], content: { title: "Captured", uri: "https://example.com/1", captureDisposition: "complete", capturedAt: "2026-01-01T00:00:00.000Z" } } });
    expect(result.status).toBe("unsupported");
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeUndefined();
  });
});
