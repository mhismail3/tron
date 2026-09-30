import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { GatewayError } from "../errors.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { drainDurableWriteStats } from "../util/durable-json.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { withInvocationContext } from "../extensions/owner-attribution.js";
import { KnowledgeTaggingBudget } from "./knowledge-tagger.js";

const roots: string[] = [];
const command = (name: string) => `connector-test-${name}`;
const headers = () => new Headers();
const publicResolver = async () => ["93.184.216.34"];

afterEach(async () => { vi.useRealTimers(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

function response(value: unknown, status = 200): ConnectorHTTPResponse { return { status, headers: headers(), body: JSON.stringify(value) }; }
async function fixture(http: (url: string, init: { headers: Record<string, string>; signal: AbortSignal; method?: "GET" | "PUT" | "POST" | "DELETE" }) => Promise<ConnectorHTTPResponse>, xPricing?: { accountId: string; costCentsPerAttempt: number; maxAttempts: number }, options: { assessment?: SourceAssessmentModel; sourceFetch?: (url: string, excerpt: string | undefined, signal: AbortSignal) => Promise<Response> } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-connector-")); roots.push(root);
  const owner = new ConnectionOwner(root);
  const setup = await owner.execute({ kind: "setup.begin", commandId: command("jev-budget-begin"), instanceId: "jev-budget", definitionId: "knowledge.jev", method: "token" }) as { operationId: string };
  await owner.execute({ kind: "setup.complete", commandId: command("jev-budget-complete"), operationId: setup.operationId, instanceId: "jev-budget", providerAccountId: "personal", credentialRef: "connector:jev:personal", policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 500, recurringApproved: false } });
  const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test-account", "synthetic-raindrop-token"], ["connector:x:test-account", "synthetic-x-token"], ["connector:jev:personal", "synthetic-jev-token"]]));
  const store = new KnowledgeStore(new TronWorkspace(root));
  const jevBudget = new KnowledgeTaggingBudget(store, owner, credentials);
  const extension = new KnowledgeConnectorExtension(store, {
    credentials,
    http,
    resolveHost: publicResolver,
    sourceFetch: options.sourceFetch ?? (async (_url, excerpt) => new Response(excerpt ?? "", { headers: { "content-type": "text/plain", ...(excerpt ? { "x-tron-source-capture-quality": "partial" } : {}) } })),
    ...(options.assessment ? { assessment: options.assessment } : {}),
    sleep: async () => {},
    now: () => "2026-01-01T00:00:00.000Z",
    ...(xPricing ? { xPricing } : {}),
    jevBudget,
  });
  return { store, extension, owner, jevBudget };
}

describe("knowledge connectors", () => {
  async function mappedRaindropFixture(http: (url: string, init: { headers: Record<string, string>; signal: AbortSignal; method?: "GET" | "PUT" | "POST" | "DELETE"; body?: string }) => Promise<ConnectorHTTPResponse>, sourceFetch?: (url: string, excerpt: string | undefined, signal: AbortSignal) => Promise<Response>, assessment?: SourceAssessmentModel, policyOptions: { allowWrites?: boolean; destination7?: string } = {}) {
    const root = await mkdtemp(join(tmpdir(), "tron-mapped-raindrop-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const setup = await owner.execute({ kind: "setup.begin", commandId: command("mapped-begin"), instanceId: "mapped", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: command("mapped-complete"), operationId: setup.operationId, instanceId: "mapped", providerAccountId: "42", credentialRef: "connector:raindrop:test-account", policy: { enabled: true, allowWrites: policyOptions.allowWrites ?? false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false }, raindropCollections: [{ collectionId: "7", scope: "research", ...(policyOptions.destination7 ? { destination: policyOptions.destination7 } : {}) }, { collectionId: "8", scope: "personal" }, { collectionId: "9", scope: "research" }] });
    const jevSetup = await owner.execute({ kind: "setup.begin", commandId: command("mapped-jev-budget-begin"), instanceId: "mapped-jev", definitionId: "knowledge.jev", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: command("mapped-jev-budget-complete"), operationId: jevSetup.operationId, instanceId: "mapped-jev", providerAccountId: "personal", credentialRef: "connector:jev:personal", policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 500, recurringApproved: false } });
    const store = new KnowledgeStore(new TronWorkspace(root));
    const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test-account", "synthetic-raindrop-token"], ["connector:jev:personal", "synthetic-jev-token"]]));
    const jevBudget = new KnowledgeTaggingBudget(store, owner, credentials);
    const extension = new KnowledgeConnectorExtension(store, { connections: owner, jevBudget, credentials, http, resolveHost: publicResolver, ...(sourceFetch ? { sourceFetch } : {}), ...(assessment ? { assessment } : {}), sleep: async () => {}, now: () => "2026-01-01T00:00:00.000Z" });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("mapped-configure"), connector: "raindrop", connectionId: "mapped", enabled: true } });
    return { root, owner, store, extension };
  }

  it("rejects unmapped collections and isolates pending intake by mapped collection", async () => {
    const requested: string[] = [];
    let httpCalls = 0;
    const items = (collectionId: string) => ({ items: [{ _id: collectionId, title: `Item ${collectionId}`, link: `https://example.com/${collectionId}`, note: `Note ${collectionId}`, collection: { $id: Number(collectionId) } }] });
    const { extension } = await mappedRaindropFixture(async url => { httpCalls += 1; if (url.endsWith("/user")) return response({ user: { _id: 42 } }); const match = /raindrops\/(\d+)/.exec(url); if (match) { requested.push(match[1]!); return response(items(match[1]!)); } throw new Error("unexpected provider request"); });
    await expect(extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("unmapped-collection"), connectionId: "mapped", sourceCollection: "99", dryRun: true, limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
    expect(httpCalls).toBe(0);
    const first = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("mapped-research-dry"), connectionId: "mapped", sourceCollection: "7", dryRun: true, limit: 1 } }) as any;
    const second = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("mapped-personal-dry"), connectionId: "mapped", sourceCollection: "8", dryRun: true, limit: 1 } }) as any;
    expect(first.pending.map((item: any) => item.id)).toEqual(["7"]);
    expect(second.pending.map((item: any) => item.id)).toEqual(["8"]);
    expect(requested).toEqual(["7", "8"]);
  });

  it("does not assign a duplicate item to a second collection when its provider collection contradicts the request", async () => {
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      const requested = /raindrops\/(\d+)/.exec(url)?.[1];
      if (requested === "7" || requested === "8") return response({ items: [{ _id: 77, title: "Same provider item", link: "https://example.com/same", collection: { $id: 7 } }] });
      throw new Error("unexpected provider request");
    });
    const first = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("duplicate-first"), connectionId: "mapped", sourceCollection: "7", dryRun: true, limit: 1 } }) as any;
    const second = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("duplicate-second"), connectionId: "mapped", sourceCollection: "8", dryRun: true, limit: 1 } }) as any;
    expect(first.pending.map((item: any) => item.id)).toEqual(["77"]);
    expect(second.pending).toEqual([]);
    expect((await store.connectorState("raindrop", "mapped"))?.pending.map(item => item.collectionId)).toEqual(["7"]);
  });

  it("re-scopes one canonical source when its bookmark moves to a mapped personal collection", async () => {
    let collection = "7";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Useful research", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      const requested = /raindrops\/(\d+)/.exec(url)?.[1];
      if (requested === "7" || requested === "8") return response({ items: [{ _id: 77, title: "Moved bookmark", link: "https://example.com/moved", note: "Personal note", collection: { $id: Number(requested) } }] });
      if (url.endsWith("/raindrop/77")) return response({ item: { _id: 77, collection: { $id: Number(collection) } } });
      throw new Error("unexpected provider request");
    }, async () => new Response("A real saved source with enough useful content for capture.", { headers: { "content-type": "text/plain" } }), assessment);
    const first = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("move-first-research"), connectionId: "mapped", sourceCollection: "7", limit: 1, pilot: { id: "research-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(first.retained).toBe(1);
    let sources = (await store.list({ kind: "source", includePending: true, includeArchived: true })).records.filter(record => record.kind === "source");
    expect(sources).toHaveLength(1);
    expect(sources[0]?.scope).toBe("research");
    collection = "8";
    const second = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("move-second-personal"), connectionId: "mapped", sourceCollection: "8", limit: 1 } }) as any;
    expect(second.retained).toBe(1);
    sources = (await store.list({ kind: "source", includePending: true, includeArchived: true })).records.filter(record => record.kind === "source");
    expect(sources).toHaveLength(1);
    expect(sources[0]).toMatchObject({ scope: "personal", content: { identity: { provider: "raindrop", itemId: "77" }, collectionId: "8", admission: { status: "retained" } } });
  });

  // Failure modes: the same identity is rediscovered from another mapped
  // collection, and scope-only decisions do not block admission processing.
  it("preserves decided admission and scope when a bookmark is rediscovered", async () => {
    let recommendArchive = false;
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Research source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: recommendArchive ? "archived" : "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/7?") || url.includes("/raindrops/9?")) { const collection = Number(/raindrops\/(\d+)/.exec(url)?.[1]); return response({ items: [{ _id: 701, title: "Decided source", link: "https://example.com/701", collection: { $id: collection } }] }); }
      throw new Error("unexpected provider request");
    }, async () => new Response("Complete, useful article text for intake.", { headers: { "content-type": "text/plain" } }), assessment);
    const intake = (id: string, sourceCollection: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), connectionId: "mapped", sourceCollection, limit: 1, pilot: { id: `pilot-${sourceCollection}`, maxItems: 1, budgetCents: 1 } } });
    const first = await intake("decision-first", "7") as any;
    expect(first).toMatchObject({ retained: 1, pending: 0 });
    const source = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "701" });
    const archived = await store.setSourceAdmission({ commandId: command("decision-archive"), recordId: source!.id, expectedRevision: source!.revisionId, status: "archived", producer: { actor: "connector" }, reason: "Jev archive" });
    const restored = await store.curateSource({ commandId: command("decision-restore"), operation: "placement", producer: { actor: "agent" }, item: { recordId: source!.id, expectedRevision: archived.record.revisionId, placement: { admission: "retained", reason: "Restored by agent" } } });
    const placed = await store.curateSource({ commandId: command("decision-scope"), operation: "placement", producer: { actor: "agent" }, item: { recordId: source!.id, expectedRevision: restored.record.revisionId, placement: { scope: "personal" } } });
    expect((placed.record as any).content.admission).toMatchObject({ status: "retained", producer: { actor: "agent" } });
    recommendArchive = true;
    const rerun = await intake("decision-rerun", "9") as any;
    const current = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "701" });
    expect(current?.scope).toBe("personal");
    expect(current?.content.admission).toMatchObject({ status: "retained", producer: { actor: "agent" } });
    expect(rerun).toMatchObject({ retained: 1, pending: 0 });
    expect(rerun.outcomes).toHaveLength(1);
  });

  it("decides a connector-pending admission while preserving an agent scope", async () => {
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Research source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    let captureCount = 0;
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/7?") || url.includes("/raindrops/9?")) { const collection = Number(/raindrops\/(\d+)/.exec(url)?.[1]); return response({ items: [{ _id: 703, title: "Scope decided, admission pending", link: "https://example.com/703", collection: { $id: collection } }] }); }
      throw new Error("unexpected provider request");
    }, async () => { const partial = captureCount++ === 0; return new Response(partial ? "Partial evidence for retry." : "Complete, useful article text for intake.", { headers: { "content-type": "text/plain", ...(partial ? { "x-tron-source-capture-quality": "partial" } : {}) } }); }, assessment);
    const intake = (id: string, sourceCollection: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), connectionId: "mapped", sourceCollection, limit: 1, pilot: { id: `scope-pilot-${sourceCollection}`, maxItems: 1, budgetCents: 1 } } });
    await intake("scope-first", "7");
    expect(captureCount).toBe(1);
    const source = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "703" });
    const pending = await store.setSourceAdmission({ commandId: command("scope-reset-admission"), recordId: source!.id, expectedRevision: source!.revisionId, status: "pending", producer: { actor: "connector" }, reason: "Awaiting intake" });
    await store.curateSource({ commandId: command("scope-agent-placement"), operation: "placement", producer: { actor: "agent" }, item: { recordId: source!.id, expectedRevision: pending.record.revisionId, placement: { scope: "personal" } } });
    const rerun = await intake("scope-rerun", "9") as any;
    expect(captureCount).toBe(2);
    const current = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "703" });
    expect(current?.scope).toBe("personal");
    expect(current?.content.admission).toMatchObject({ status: "retained", producer: { actor: "connector" } });
    expect(rerun).toMatchObject({ retained: 1, pending: 0 });
  });

  it("keeps an intake admission behind a connection-configuration revision race", async () => {
    let owner: ConnectionOwner | undefined;
    let changed = false;
    const { owner: connectionOwner, store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/8?")) return response({ items: [{ _id: 89, title: "Racing bookmark", link: "https://example.com/racing", collection: { $id: 8 } }] });
      throw new Error("unexpected provider request");
    }, async () => {
      if (!changed) {
        changed = true;
        const live = await owner!.resolveInstance("mapped");
        await owner!.execute({ kind: "policy.update", commandId: command("mapping-race-update"), instanceId: "mapped", expectedSetupRevision: live.setupRevision, policy: live.policy, raindropCollections: [{ collectionId: "7", scope: "research" }, { collectionId: "8", scope: "research" }] });
      }
      return new Response("Capture succeeded under the configuration admitted when intake began.", { headers: { "content-type": "text/plain" } });
    });
    owner = connectionOwner;
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("mapping-race-intake"), connectionId: "mapped", sourceCollection: "8", limit: 1 } }) as any;
    const sources = (await store.list({ kind: "source", includePending: true, includeArchived: true })).records.filter(record => record.kind === "source");
    expect(result).toMatchObject({ retained: 0, pending: 1 });
    expect(sources).toHaveLength(1);
    expect(sources[0]).toMatchObject({ scope: "personal", content: { admission: { status: "pending" }, collectionId: "8" } });
  });

  it("keeps assessment pilot cohorts independent for each mapped research collection", async () => {
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Research source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      const collection = /raindrops\/(\d+)/.exec(url)?.[1];
      if (collection === "7" || collection === "9") return response({ items: [{ _id: collection, title: `Research ${collection}`, link: `https://example.com/${collection}`, collection: { $id: Number(collection) } }] });
      throw new Error("unexpected provider request");
    }, async () => new Response("A real research item with sufficiently useful readable evidence.", { headers: { "content-type": "text/plain" } }), assessment);
    for (const [collectionId, pilotId] of [["7", "pilot-7"], ["9", "pilot-9"]]) {
      const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(`cohort-${collectionId}`), connectionId: "mapped", sourceCollection: collectionId!, limit: 1, pilot: { id: pilotId!, maxItems: 1, budgetCents: 1 } } }) as any;
      expect(result.retained).toBe(1);
    }
    expect(Object.keys((await store.connectorState("raindrop", "mapped"))?.assessmentPilots ?? {}).sort()).toEqual(["7", "9"]);
  });

  it("uses only the selected collection's approved remote destination", async () => {
    let remoteCollection = "7";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); return { summary: "Research source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric" }; } };
    const writes: string[] = [];
    const { extension } = await mappedRaindropFixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/7?")) return response({ items: [{ _id: 90, title: "Move-approved source", link: "https://example.com/move-approved", collection: { $id: 7 } }] });
      if (url.endsWith("/raindrop/90") && init.method === "PUT") { writes.push(JSON.parse(init.body ?? "{}").collection.$id); remoteCollection = "9"; return response({ item: { _id: 90, collection: { $id: 9 } } }); }
      if (url.endsWith("/raindrop/90")) return response({ item: { _id: 90, collection: { $id: Number(remoteCollection) } } });
      throw new Error("unexpected provider request");
    }, async () => new Response("Complete source text supports the collection move.", { headers: { "content-type": "text/plain" } }), assessment, { allowWrites: true, destination7: "9" });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("mapped-destination"), connectionId: "mapped", sourceCollection: "7", limit: 1, pilot: { id: "destination-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(writes).toEqual(["9"]);
    expect(result).toMatchObject({ moved: 1, retained: 1, pending: 0 });
  });

  it("admits a personal bookmark from its link and saved note when page capture fails, without Jev", async () => {
    let assessmentCalls = 0;
    const { store, extension } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/8?")) return response({ items: [{ _id: 88, title: "Personal bookmark", link: "https://example.com/personal", note: "Saved note", created: "2025-01-01T00:00:00.000Z", collection: { $id: 8 } }] });
      throw new Error("unexpected provider request");
    }, async () => { throw new Error("page fetch unavailable"); }, { assess: async () => { assessmentCalls += 1; throw new Error("Jev must not run for personal intake"); } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("personal-failed-capture"), connectionId: "mapped", sourceCollection: "8", limit: 1 } }) as any;
    const sources = (await store.list({ kind: "source", includePending: true, includeArchived: true })).records.filter(record => record.kind === "source");
    expect(result).toMatchObject({ retained: 1, pending: 0 });
    expect(sources).toHaveLength(1);
    expect(sources[0]).toMatchObject({ scope: "personal", content: { title: "Personal bookmark", collectionId: "8", admission: { status: "retained" }, annotations: [{ text: "Saved note" }] } });
    expect(assessmentCalls).toBe(0);
  });
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
  it.each([
    ["raindrop", "connector:x:wrong-account"],
    ["x", "connector:raindrop:wrong-account"],
  ] as const)("rejects a credential reference from another provider namespace (%s)", async (connector, credentialRef) => {
    const root = await mkdtemp(join(tmpdir(), `tron-credential-namespace-${connector}-`)); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, { credentials: { read: async () => "must-not-read" }, http: async () => { throw new Error("must-not-request"); } });
    await expect(extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command(`namespace-${connector}`), connector, enabled: true, accountId: "42", scope: "7", credentialRef } })).rejects.toMatchObject({ code: "invalid_request" });
    expect(await store.connectorState(connector)).toBeUndefined();
  });

  it("names the exact Keychain item to add when a connection credential is missing", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-missing-connection-credential-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const setup = await owner.execute({ kind: "setup.begin", commandId: command("missing-credential-begin"), instanceId: "personal", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: command("missing-credential-complete"), operationId: setup.operationId, instanceId: "personal", providerAccountId: "42", credentialRef: "connector:raindrop:personal", raindropCollections: [{ collectionId: "0", scope: "research" }], policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
    let httpCalls = 0;
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, { connections: owner, credentials: { read: async () => undefined }, http: async () => { httpCalls += 1; return response({ items: [] }); }, sleep: async () => {} });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("missing-credential-config"), connector: "raindrop", connectionId: "personal", enabled: true } });
    // The agent reads this failure text, so it has to name the service and the
    // exact account to add while never carrying a token.
    const failure = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("missing-credential-run"), connector: "raindrop", connectionId: "personal", limit: 1 } }).catch((error: unknown) => error as GatewayError);
    expect(failure).toMatchObject({ code: "unsupported" });
    expect(failure.message).toContain("service 'Tron Connector Credentials'");
    expect(failure.message).toContain("account 'connector:raindrop:personal'");
    expect(httpCalls).toBe(0);
    // The capability row iOS renders carries no credential reference, so it
    // names the Keychain service and sends the user to the agent for the account.
    const capability = (await owner.snapshot()).capabilities.find(item => item.connectionId === "personal" && item.id === "read");
    expect(capability).toMatchObject({ availability: "unavailable", detail: "Credential missing or rejected. Check the Mac Keychain item (service 'Tron Connector Credentials'); ask the agent for the exact account." });
  });

  it("starts no durable write when a read observes the same provider admission", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-connection-read-observation-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const setup = await owner.execute({ kind: "setup.begin", commandId: command("read-observe-begin"), instanceId: "personal", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: command("read-observe-complete"), operationId: setup.operationId, instanceId: "personal", providerAccountId: "42", scope: "0", credentialRef: "connector:raindrop:test-account", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false } });
    let user = { user: { _id: 42, email: "owner@example.test" } };
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, {
      connections: owner,
      credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test-account", "synthetic-raindrop-token"]])),
      http: async url => url.endsWith("/user") ? response(user) : response({ items: [] }),
      sleep: async () => {},
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("read-observe-config"), connector: "raindrop", connectionId: "personal", enabled: true } });
    const read = { operation: "knowledge.raindrop.read", request: { commandId: command("read-observe-read"), connectionId: "personal", read: { operation: "bookmarks", collectionId: "0", perpage: 1 } } } as const;
    await extension.invoke(read);
    expect((await owner.snapshot()).instances[0]).toMatchObject({ health: "ready", credentialAvailability: "available", providerIdentity: "admitted", providerDisplayName: "owner@example.test" });
    // The next read reuses the same `/user` verification against the same
    // revision, so it re-observes unchanged state: no fsync behind the await.
    drainDurableWriteStats();
    await extension.invoke(read);
    expect(drainDurableWriteStats().count).toBe(0);
    // A read that sees a different provider identity still persists it before
    // its response, so a real transition cannot be lost by the skip.
    user = { user: { _id: 42, email: "renamed@example.test" } };
    drainDurableWriteStats();
    await extension.invoke(read);
    expect(drainDurableWriteStats().count).toBe(2);
    expect((await owner.snapshot()).instances[0]).toMatchObject({ health: "ready", providerIdentity: "admitted", providerDisplayName: "renamed@example.test" });
  });

  it("does not debit or contact X when its credential is unavailable", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-missing-x-credential-")); roots.push(root);
    let calls = 0;
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, { credentials: { read: async () => undefined }, http: async () => { calls += 1; return response({ data: [] }); }, sleep: async () => {} });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("missing-x-config"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:missing", paidAccessApproved: true, paidBudgetCents: 1 } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("missing-x-run"), connector: "x", limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
    expect(calls).toBe(0);
    expect((await store.connectorState("x"))?.paidBudgetCents).toBe(1);
  });

  it("does not advance discovery state for a malformed successful envelope", async () => {
    const { store, extension } = await fixture(async url => url.endsWith("/user") ? response({ user: { _id: 42 } }) : response({ unexpected: true }));
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("malformed-discovery-config"), connector: "raindrop", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test-account" } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("malformed-discovery-run"), connector: "raindrop", limit: 1 } })).rejects.toMatchObject({ code: "internal" });
    const state = await store.connectorState("raindrop");
    expect(state?.pending).toEqual([]);
    expect(state?.checkpoints).toBeUndefined();
  });

  it("rejects malformed X discovery success without advancing its checkpoint", async () => {
    const { store, extension } = await fixture(async () => response({ meta: { next_token: "next" } }), { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 1 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("malformed-x-config"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 1 } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("malformed-x-run"), connector: "x", limit: 1 } })).rejects.toMatchObject({ code: "internal" });
    const state = await store.connectorState("x");
    expect(state?.pending).toEqual([]);
    expect(state?.checkpoints).toBeUndefined();
  });

  it("persists a destination-safety outcome without fetching a forbidden bookmark URL", async () => {
    let linkedFetches = 0;
    const { store, extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "Blocked target", link: "http://127.0.0.1/admin", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { sourceFetch: async () => { linkedFetches += 1; return new Response("must not fetch"); } });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("blocked-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("blocked-intake"), sourceCollection: "111", limit: 1, pilot: { id: "blocked-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(linkedFetches).toBe(0); expect(result).toMatchObject({ captured: 1, pending: 1, assessmentFailed: 0 });
    expect(result.outcomes).toHaveLength(1); expect(result.outcomes[0]).toMatchObject({ itemId: "1", disposition: "pending", assessment: "not-run", move: "not-attempted" });
    const source = (await store.list({ kind: "source", includePending: true })).records[0];
    expect(source?.content.captureDisposition).toBe("reference-only"); expect(source?.content.captureReason).toContain("Destination safety check failed");
  });

  it("only queues discovered bookmarks during a sweep and deduplicates shifted pages", async () => {
    let calls = 0;
    const first = Array.from({ length: 50 }, (_, index) => ({ _id: index + 1, title: `Bookmark ${index}`, link: `https://example.com/${index}`, excerpt: `Excerpt ${index}` }));
    let linkedFetches = 0;
    const { store, extension } = await fixture(async (url) => {
      calls += 1;
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/123?page=0")) return response({ items: first });
      if (url.includes("/raindrops/123?page=1")) return response({ items: [{ _id: 50, title: "Duplicate", link: "https://example.com/49" }, { _id: 51, title: "Bookmark 51", link: "https://example.com/51" }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { sourceFetch: async () => { linkedFetches += 1; return new Response("capture is intake-only"); } });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "123", credentialRef: "connector:raindrop:test-account" } });
    const dryRun = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("discover"), connector: "raindrop", limit: 51 } }) as { discovered: number; pending: number };
    expect(dryRun.discovered).toBe(51);
    expect(dryRun.pending).toBe(51);
    expect(calls).toBe(3);
    const state = await store.connectorState("raindrop");
    expect(state?.checkpoint).toBeUndefined();
    expect(state?.pending.map(item => item.id)).toHaveLength(51);
    const result = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("sweep"), connector: "raindrop", limit: 2 } }) as { discovered: number; pending: number };
    expect(result.discovered).toBe(0);
    expect(result.pending).toBe(51);
    expect(linkedFetches).toBe(0);
    expect((await store.list({ kind: "source", includePending: true })).records).toHaveLength(0);
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
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    // A fixed clock makes the provider cooldown exact: one second from now.
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));
    let calls = 0; let firstAt = 0; let retriedAt = 0;
    let firstAttempt!: () => void;
    const attempted = new Promise<void>(resolve => { firstAttempt = resolve; });
    const { extension } = await fixture(async () => {
      calls += 1;
      if (calls === 1) {
        firstAt = Date.now();
        firstAttempt();
        return { status: 429, body: "{}", headers: new Headers({ [header]: header === "Retry-After" ? new Date(firstAt + 1_000).toUTCString() : String((firstAt + 1_000) / 1_000) }) };
      }
      retriedAt = Date.now();
      return response({ user: { _id: 42 } });
    });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("retry-config"), connector: "raindrop", enabled: true, accountId: "42", credentialRef: "connector:raindrop:test-account" } });
    const read = extension.invoke({ operation: "knowledge.raindrop.read", request: { commandId: command("retry-read"), read: { operation: "user" } } });
    await attempted;
    // Let the request park in the provider cooldown before moving the clock.
    await new Promise(resolve => setImmediate(resolve));
    // A provider cooldown is never shortened: one millisecond early is too early.
    await vi.advanceTimersByTimeAsync(999);
    expect(calls).toBe(1);
    await vi.advanceTimersByTimeAsync(1_000);
    await read;
    expect(calls).toBe(2);
    expect(retriedAt - firstAt).toBeGreaterThanOrEqual(1_000);
  });

  it("serializes connector configuration behind an admitted discovery request", async () => {
    vi.useFakeTimers();
    let release!: () => void;
    let entered!: () => void;
    let requests = 0;
    const started = new Promise<void>(resolve => { entered = resolve; });
    const blocked = new Promise<void>(resolve => { release = resolve; });
    const { extension } = await fixture(async url => { requests += 1; entered(); await blocked; return url.endsWith("/user") ? response({ user: { _id: 42 } }) : response({ items: [] }); });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("lane-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "123", credentialRef: "connector:raindrop:test-account" } });
    const run = extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("lane-run"), connector: "raindrop", limit: 1 } });
    // Observe admission, not an assumed disk/scheduler latency under suite load.
    await started;
    const reconfigure = extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("lane-reconfigure"), connector: "raindrop", enabled: true, accountId: "account-2", scope: "456", credentialRef: "connector:raindrop:test-account" } });
    let settled = false; void reconfigure.then(() => { settled = true; });
    await vi.advanceTimersByTimeAsync(20);
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
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("x-run"), connector: "x", limit: 1 } })).rejects.toMatchObject({ code: "unsupported" });
    expect(calls).toBe(0);
  });

  it("debits every X retry attempt and refuses the request before exceeding budget", async () => {
    let calls = 0;
    const { store, extension } = await fixture(async () => { calls += 1; return response({ error: "retry" }, 500); }, { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 3 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-qualified"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 2 } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("x-budget"), connector: "x", limit: 1 } })).rejects.toMatchObject({ code: "internal" });
    expect(calls).toBe(2);
    expect((await store.connectorState("x"))?.paidBudgetCents).toBe(0);
  });

  it("charges a fresh allowance for each repeated run command", async () => {
    let calls = 0;
    const { store, extension } = await fixture(async () => { calls += 1; return response({ error: "rate limited" }, 429); }, { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 1 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-replay-configure"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 2 } });
    const run = { operation: "knowledge.connector.discover" as const, request: { commandId: command("x-replay-run"), connector: "x" as const, limit: 1 } };
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    await expect(extension.invoke(run)).rejects.toMatchObject({ code: "internal" });
    expect(calls).toBe(2);
    expect((await store.connectorState("x"))?.paidBudgetCents).toBe(0);
  });

  it("requires trusted current Automation authority for recurring X sweeps", async () => {
    const { extension } = await fixture(async () => response({ data: [] }), { accountId: "account-1", costCentsPerAttempt: 1, maxAttempts: 1 });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("x-recurring-configure"), connector: "x", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:x:test-account", paidAccessApproved: true, paidBudgetCents: 1 } });
    await expect(withInvocationContext({ invocationId: "invocation-1", operationId: "automation:run-1" }, () => extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("x-recurring-run"), connector: "x", limit: 1 } }))).rejects.toMatchObject({ code: "unsupported" });
  });

  it("captures, assesses, preserves collection provenance, and moves one bounded intake item", async () => {
    let collection = "111";
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); await context?.onDispatch?.(); return { summary: "Synthetic retained source", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained", confidence: 0.95, profileVersion: "fixture-profile", rubricVersion: "fixture-rubric", usage: { inputTokens: 100, outputTokens: 4, estimatedCostCents: 0.00042, pricing: "typesafe-jev-1.13.0-input-0.042-usd-per-million-output-free" } }; } };
    const { store, extension, jevBudget } = await fixture(async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "Synthetic item", link: "https://example.test/item", created: "2025-12-30T12:00:00Z", collection: { $id: 111 }, custom: { preserved: true } }] });
      if (url.endsWith("/raindrop/1") && init.method !== "PUT") return response({ item: { _id: 1, collection: { $id: Number(collection) } } });
      if (init.method === "PUT") { collection = "222"; return response({ item: { _id: 1, collection: { $id: 222 } } });
      }
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("Synthetic complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("intake-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account", destination: "222", allowWrites: true } });
    const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("intake-run"), sourceCollection: "111", limit: 1, pilot: { id: "synthetic-pilot", maxItems: 1, budgetCents: 1 } } });
    expect(result).toMatchObject({ moved: 1, retained: 1, archived: 0, assessmentFailed: 0, budget: { approvedCeilingCents: 1, conservativeReservedCents: 1, cohortItemCap: 1, cohortSelectedItems: 1, settledItems: 1, estimatedUsageCostCents: 0.00042, usageKnownAssessments: 1, usageUnknownAssessments: 0, pendingOutsideCohortItems: 0 } });
    expect((result as any).outcomes).toHaveLength(1);
    expect((result as any).outcomes[0]).toMatchObject({ itemId: "1", disposition: "retained", assessment: "dispatched-settled", move: "moved" });
    const firstSource = (await store.list({ kind: "source", includeArchived: true, includePending: true })).records[0];
    expect((result as any).outcomes[0].sourceId).toBe(firstSource?.id);
    expect((result as any).outcomes[0].sourceRevision).toBe(firstSource?.revisionId);
    expect(new Set((result as any).outcomes.map((entry: any) => entry.itemId)).size).toBe((result as any).outcomes.length);
    const rerun = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("intake-usage-rerun"), sourceCollection: "111", limit: 1, pilot: { id: "synthetic-pilot", maxItems: 1, budgetCents: 1 } } });
    expect(rerun).toMatchObject({ moved: 0, budget: { estimatedUsageCostCents: 0.00042, usageKnownAssessments: 1, usageUnknownAssessments: 0 } });
    const sources = (await store.list({ kind: "source", includeArchived: true })).records;
    expect(sources).toHaveLength(1);
    expect(sources[0]?.content.collectionId).toBe("111");
    expect(sources[0]?.content.sourceSavedAt).toBe("2025-12-30T12:00:00.000Z");
    expect(sources[0]?.content.sourcePublishedAt).toBeUndefined();
    expect(sources[0]?.content.representations?.[0]?.kind).toBe("provider-api");
    expect(sources[0]?.content.admission?.status).toBe("retained");
    expect((await store.connectorState("raindrop"))?.assessmentPilot).toMatchObject({ usedItems: 1, reservedCents: 1 });
    expect((await store.connectorState("raindrop"))?.assessmentAttempts?.["1"]).toMatchObject({ status: "settled", chargeCents: 1, inputTokens: 100, outputTokens: 4, estimatedCostCents: 0.00042 });
    expect(await jevBudget.status("jev-budget")).toMatchObject({ spentCents: 0.00042, reservedCents: 0 });
    const taggingAttempt = await jevBudget.reserve("jev-budget", "tag-after-intake", 0);
    expect(await jevBudget.status("jev-budget")).toMatchObject({ spentCents: 0.00042, reservedCents: 0.2688 });
    await jevBudget.releaseUndispatched("jev-budget", taggingAttempt);
  });

  // C5 failure modes: intake may not use an independent cohort allowance after
  // Knowledge disables Jev paid access, and assessment reservations/spend must
  // change the very ledger from which tagging reserves its next call.
  it("refuses intake dispatch when shared Jev paid access is off", async () => {
    let assessmentCalls = 0;
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); assessmentCalls += 1; return { summary: "unused", evidenceQuality: "none", freshness: "unknown", recommendation: "retained", model: "jev-1.13.0" }; } };
    const { extension, owner, jevBudget } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("paid-off-intake-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    await owner.execute({ kind: "policy.update", commandId: command("paid-off-jev"), instanceId: "jev-budget", expectedSetupRevision: 1, policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 500, recurringApproved: false } });
    await expect(jevBudget.reserve("jev-budget", "paid-off-tag", 0)).rejects.toMatchObject({ code: "unsupported" });
    const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("paid-off-intake"), limit: 1, pilot: { id: "paid-off-cohort", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(assessmentCalls).toBe(0);
    expect(intake.outcomes[0]).toMatchObject({ assessment: "preflight-failed" });
  });

  it("refuses intake assessment before dispatch when the monthly Jev budget is exhausted", async () => {
    let assessmentCalls = 0;
    const assessment: SourceAssessmentModel = { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); assessmentCalls += 1; return { summary: "unused", evidenceQuality: "none", freshness: "unknown", recommendation: "retained", model: "jev-1.13.0" }; } };
    const { extension, owner, jevBudget } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("exhausted-intake-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    await owner.execute({ kind: "policy.update", commandId: command("exhausted-jev"), instanceId: "jev-budget", expectedSetupRevision: 1, policy: { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 1, recurringApproved: false } });
    for (let i = 0; i < 3; i += 1) {
      const attempt = await jevBudget.reserve("jev-budget", `exhaustion-seed-${i}`, 0);
      await jevBudget.markDispatch("jev-budget", attempt);
      await jevBudget.reconcileUncertain("jev-budget", attempt);
    }
    const intake = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("exhausted-intake"), limit: 1, pilot: { id: "exhausted-cohort", maxItems: 1, budgetCents: 1 } } }) as any;
    expect(assessmentCalls).toBe(0);
    expect(intake.outcomes[0]).toMatchObject({ assessment: "preflight-failed" });
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
    const request = { operation: "knowledge.raindrop.intake" as const, request: { commandId: command("budget-intake"), sourceCollection: "111", limit: 2, pilot: { id: "budget-pilot", maxItems: 2, budgetCents: 1 } } };
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
      await context?.onDispatch?.();
      calls += 1;
      throw new Error("synthetic response uncertainty");
    } };
    const { store, extension } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("preflight-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const intake = (id: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), sourceCollection: "111", limit: 1, pilot: { id: "dispatch-fence", maxItems: 1, budgetCents: 1 } } });
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
    const retry = (id: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), limit: 1, pilot: { id: "explicit-retry", maxItems: 1, budgetCents: 1 } } });
    await retry("renewed-attempt");
    expect(calls).toBe(1);
    await retry("renewed-replay");
    expect(calls).toBe(1);
    const state = await store.connectorState("raindrop");
    expect(state?.assessmentPilot?.reservedCents).toBe(1);
    expect(state?.assessmentApprovals?.[0]).toMatchObject({ itemIds: ["1"], reservedCents: 0 });
    expect(state?.assessmentAttempts?.["1"]).toMatchObject({ status: "dispatched", chargeCents: 1 });
    expect(state?.assessmentAttempts?.["explicit-retry:1"]).toBeUndefined();
  });

  it("releases a reserved Jev attempt cancelled before dispatch so tagging can reserve", async () => {
    const controller = new AbortController();
    const assessment: SourceAssessmentModel = { async assess(_input, signal, context) {
      await context?.beforeDispatch?.();
      controller.abort(new Error("cancelled before POST"));
      if (signal.aborted) throw new Error("cancelled before POST");
      await context?.onDispatch?.();
      return { summary: "unreachable", evidenceQuality: "none", freshness: "unknown", model: "jev-1.13.0", recommendation: "retained" };
    } };
    const { store, extension, jevBudget } = await fixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/111?page=0")) return response({ items: [{ _id: 1, title: "One", link: "https://example.test/one", collection: { $id: 111 } }] });
      throw new Error(`unexpected endpoint ${url}`);
    }, undefined, { assessment, sourceFetch: async () => new Response("complete evidence", { headers: { "content-type": "text/plain" } }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("cancel-reservation-configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", credentialRef: "connector:raindrop:test-account" } });
    const reservedBefore = (await jevBudget.status("jev-budget")).reservedCents;
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("cancel-reservation-intake"), sourceCollection: "111", limit: 1, pilot: { id: "cancel-reservation", maxItems: 1, budgetCents: 1 } } }, controller.signal);
    expect(await jevBudget.status("jev-budget")).toMatchObject({ reservedCents: reservedBefore });
    const taggingAttempt = await jevBudget.reserve("jev-budget", "tag-after-cancelled-intake", 0);
    await jevBudget.releaseUndispatched("jev-budget", taggingAttempt);
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
      const result = await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("receipt-intake"), sourceCollection: "111", limit: 1, pilot: { id: "receipt-pilot", maxItems: 1, budgetCents: 1 } } }) as any;
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
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("no-jev-intake"), sourceCollection: "111", limit: 1, pilot: { id: "no-jev", maxItems: 1, budgetCents: 1 } } });
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
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("renew-first"), sourceCollection: "111", limit: 1, pilot: { id: "frozen-pilot", maxItems: 1, budgetCents: 1 } } });
    const approved = await extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command("renew-approve"), connector: "raindrop", id: "renewed-cohort", maxItems: 1, budgetCents: 1 } });
    expect(approved).toMatchObject({ assessmentPilot: { id: "frozen-pilot", maxItems: 1 }, assessmentApprovals: [{ id: "renewed-cohort" }] });
    await expect(extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command("renew-approve"), connector: "raindrop", id: "different", maxItems: 2, budgetCents: 2 } })).rejects.toMatchObject({ code: "conflict" });
    await extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command("renew-second"), sourceCollection: "111", limit: 1, pilot: { id: "renewed-cohort", maxItems: 1, budgetCents: 1 } } });
    const state = await store.connectorState("raindrop");
    expect(state?.assessmentPilot).toMatchObject({ id: "frozen-pilot", usedItems: 1, reservedCents: 1 });
    expect(state?.assessmentApprovals?.[0]).toMatchObject({ id: "renewed-cohort", usedItems: 1, reservedCents: 1 });
    expect(Object.keys(state?.assessmentAttempts ?? {})).toEqual(["1", "renewed-cohort:2"]);
  });

  it("discovers, reads, ingests and acknowledges one queued item without leaking its payload", async () => {
    const { store, extension, owner } = await mappedRaindropFixture(async url => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      if (url.includes("/raindrops/7?")) return response({ items: [{ _id: 701, title: "Queued bookmark", link: "https://example.test/queued", note: "private provider note", created: "2025-01-02T03:04:05Z", collection: { $id: 7 } }] });
      throw new Error(`unexpected provider request ${url}`);
    }, async () => new Response("A useful saved page.", { headers: { "content-type": "text/plain" } }));
    const discovered = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("primitive-discover"), connector: "raindrop", connectionId: "mapped", sourceCollection: "7", limit: 1 } }) as { discovered: number };
    expect(discovered.discovered).toBe(1);
    const queue = await extension.invoke({ operation: "knowledge.connector.queue", request: { connector: "raindrop", connectionId: "mapped", sourceCollection: "7", limit: 1 } }) as any;
    expect(queue.items).toEqual([{ id: "701", url: "https://example.test/queued", title: "Queued bookmark", collectionId: "7", savedAt: "2025-01-02T03:04:05Z", sourceExists: false, scope: "research" }]);
    expect(JSON.stringify(queue)).not.toContain("private provider note");
    const otherSetup = await owner.execute({ kind: "setup.begin", commandId: command("other-begin"), instanceId: "other", definitionId: "knowledge.raindrop", method: "token" }) as { operationId: string };
    await owner.execute({ kind: "setup.complete", commandId: command("other-complete"), operationId: otherSetup.operationId, instanceId: "other", providerAccountId: "99", credentialRef: "connector:raindrop:test-account", policy: { enabled: true, allowWrites: false, paidAccessApproved: false, paidBudgetCents: 0, recurringApproved: false }, raindropCollections: [{ collectionId: "7", scope: "research" }] });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("other-configure"), connector: "raindrop", connectionId: "other", enabled: true } });
    await store.updateConnectorState(command("other-queue"), "raindrop", state => ({ ...state!, pending: [...state!.pending, { id: "999", title: "Other account", url: "https://example.test/other", collectionId: "7" }] }), undefined, "other");
    const secondQueue = await extension.invoke({ operation: "knowledge.connector.queue", request: { connector: "raindrop", connectionId: "mapped", sourceCollection: "7", limit: 25 } }) as any;
    expect(secondQueue.items.map((item: any) => item.id)).toEqual(["701"]);
    const source = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("primitive-ingest"), connector: "raindrop", connectionId: "mapped", itemId: "701", scope: "research" } }) as any;
    expect(source.content.admission.status).toBe("pending");
    await expect(extension.invoke({ operation: "knowledge.raindrop.move", request: { commandId: command("primitive-move-denied"), connectionId: "mapped", itemId: "701", sourceId: source.id, expectedRevision: source.revisionId, sourceCollection: "7", destination: "9" } })).resolves.toMatchObject({ status: "unsupported" });
    const ackRequest = { commandId: command("primitive-ack"), connector: "raindrop" as const, connectionId: "mapped", itemId: "701", disposition: "processed" as const, reason: "Ingested into Knowledge" };
    const ack = await extension.invoke({ operation: "knowledge.connector.ack", request: ackRequest });
    expect(ack).toMatchObject({ id: "701", disposition: "processed", reason: "Ingested into Knowledge" });
    expect(await extension.invoke({ operation: "knowledge.connector.ack", request: { ...ackRequest, commandId: command("primitive-ack-replay") } })).toMatchObject({ id: "701", disposition: "processed" });
    expect(await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: command("primitive-rediscover"), connector: "raindrop", connectionId: "mapped", sourceCollection: "7", limit: 1 } })).toMatchObject({ discovered: 0 });
    expect((await extension.invoke({ operation: "knowledge.connector.queue", request: { connector: "raindrop", connectionId: "mapped", sourceCollection: "7" } }) as any).items).toEqual([]);
    expect((await store.connectorState("raindrop", "mapped"))?.pending).toEqual([]);
  });

  it("does not permit remote Raindrop effects without a separately approved write policy", async () => {
    const { store, extension } = await fixture(async () => response({ items: [] }));
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("write-config"), connector: "raindrop", enabled: true, accountId: "account-1", scope: "123", credentialRef: "connector:raindrop:test-account", destination: "456" } });
    const source = { kind: "source" as const, schemaVersion: 1 as const, id: "source-1", revisionId: "revision-1234567890123456", scope: "research" as const, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", provenance: { actor: "connector" as const, evidence: [] }, relations: [], content: { title: "Captured", uri: "https://example.com/1", captureDisposition: "complete" as const, capturedAt: "2026-01-01T00:00:00.000Z" } };
    const result = await extension.moveRaindrop({ commandId: command("move-denied"), itemId: "1", destination: "456", source });
    expect(result.status).toBe("unsupported");
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeUndefined();
  });
});
