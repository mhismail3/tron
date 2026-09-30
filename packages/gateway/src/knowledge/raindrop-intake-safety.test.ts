import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { jevProfileVersion } from "./jev-assessment.js";
import { KnowledgeTaggingBudget } from "./knowledge-tagger.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const response = (value: unknown, status = 200): ConnectorHTTPResponse => ({ status, headers: new Headers(), body: JSON.stringify(value) });

async function fixture(options: { failFirstMove?: boolean; initialScope?: string; links?: Record<string, string>; sourceFetch?: (url: string) => Promise<Response> } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-intake-safety-")); roots.push(root);
  const owner = new ConnectionOwner(root);
  const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:synthetic", "synthetic-only"]]));
  const store = new KnowledgeStore(new TronWorkspace(root));
  const jevBudget = new KnowledgeTaggingBudget(store, () => true);
  const observed = { assessmentCalls: 0, moves: [] as string[] };
  const remote = new Map([["1", options.initialScope ?? "111"], ["2", options.initialScope ?? "111"]]);
  const extension = new KnowledgeConnectorExtension(store, {
    credentials,
    jevBudget,
    resolveHost: async () => ["93.184.216.34"],
    sourceFetch: options.sourceFetch ?? (async url => new Response(`Distinct complete source evidence for ${url}`, { headers: { "content-type": "text/plain" } })),
    sleep: async () => {},
    assessment: { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); observed.assessmentCalls += 1; return { summary: "Synthetic classification", evidenceQuality: "none", freshness: "unknown", recommendation: "retained", model: "jev-latest" }; } },
    http: async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      const list = new URL(url).pathname.match(/\/raindrops\/(\d+)$/);
      if (list) return response({ items: [...remote].filter(([, collection]) => collection === list[1]).map(([id, collection]) => ({ _id: Number(id), title: `Source ${id}`, link: options.links?.[id] ?? `https://example.test/${id}`, collection: { $id: Number(collection) } })) });
      const item = new URL(url).pathname.match(/\/raindrop\/(\d+)$/)?.[1];
      if (item) {
        if (init.method === "PUT") {
          observed.moves.push(item);
          if (options.failFirstMove && item === "1") return response({}, 503);
          remote.set(item, "333");
        }
        return response({ item: { _id: Number(item), collection: { $id: Number(remote.get(item)) } } });
      }
      throw new Error("Unexpected synthetic endpoint");
    },
  });
  const configure = (scope: string, commandId: string, allowWrites = false) => extension.invoke({ operation: "knowledge.connector.configure", request: { commandId, connector: "raindrop", enabled: true, accountId: "42", scope, credentialRef: "connector:raindrop:synthetic", allowWrites } });
  await configure(options.initialScope ?? "111", "safety-initial-config", options.failFirstMove === true);
  const intake = (commandId: string, maxItems = 2) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId, dryRun: false, limit: 2, pilot: { id: "safety-pilot", maxItems, budgetCents: 100 } } });
  return { store, observed, remote, configure, intake };
}

describe("Raindrop intake safety boundaries", () => {
  it("does not authorize remote effects from legacy source/destination connector state", async () => {
    const { store, observed, intake } = await fixture({ failFirstMove: true });
    await intake("safety-uncertain-run");
    expect(observed.moves).toEqual([]);
    expect((await store.connectorState("raindrop"))?.pendingRemote).toBeUndefined();
  });

  it("cannot reset an exhausted pilot by reconfiguring the same connector account", async () => {
    const { observed, configure, intake } = await fixture();
    await intake("safety-pilot-first", 1);
    expect(observed.assessmentCalls).toBe(1);
    // A refused scope change is also safe; an accepted one must retain paid authority.
    try { await configure("222", "safety-change-scope"); await configure("111", "safety-return-scope"); } catch { /* permitted fail-closed policy */ }
    await intake("safety-pilot-after-config", 1);
    expect(observed.assessmentCalls).toBe(1);
  });

  it("keeps per-item receipts distinct for a maximum-length command", async () => {
    const { observed, intake } = await fixture();
    await intake("x".repeat(160), 2);
    expect(observed.assessmentCalls).toBe(2);
  });

  it("counts a crash-uncertain dispatched attempt against the approved item cap", async () => {
    const { store, observed, remote, intake } = await fixture();
    remote.delete("1");
    await store.updateConnectorState("safety-crash-reservation", "raindrop", state => ({ ...state!, assessmentPilot: { id: "safety-pilot", maxItems: 1, budgetCents: 100, usedItems: 0, reservedCents: 1, accountId: "42", sourceCollection: "111", profileVersion: jevProfileVersion([]), itemIds: ["1"] }, assessmentAttempts: { "1": { status: "dispatched", chargeCents: 1 } } }));
    await intake("safety-after-crash", 1);
    expect(observed.assessmentCalls).toBe(0);
  });

  // Failure modes: a bookmarked X permalink is read as x.com's HTML app shell
  // (no post text), the connector's blanket X downgrade discards the provider's
  // truthful partial disposition, and an incomplete re-capture demotes a source
  // whose admission was already decided out of normal retrieval.
  describe("X permalink bookmarks", () => {
    const post = "https://x.com/synthetic/status/123456789?s=12&t=share";
    const fxBody = JSON.stringify({ code: 200, status: { id: "123456789", text: "Bookmarked post evidence", author: { id: "42", protected: false }, replying_to: null, raw_text: { facets: [] }, is_note_tweet: false, media: { photos: [{}] } }, thread: [], replies: [], cursor: {} });
    const xFixture = async (seen: string[]) => fixture({ links: { "1": post }, sourceFetch: async url => { seen.push(url); return url.startsWith("https://api.fxtwitter.com/") ? new Response(fxBody, { headers: { "content-type": "application/json" } }) : new Response("<html><body>JavaScript is not available.</body></html>", { headers: { "content-type": "text/html" } }); } });

    it("captures post text through the public post reader under the bookmark identity", async () => {
      const seen: string[] = [];
      const { store, observed, intake } = await xFixture(seen);
      await intake("x-intake-reader", 1);
      expect(seen[0]).toBe("https://api.fxtwitter.com/2/conversation/123456789");
      expect(seen.some(url => new URL(url).hostname === "x.com")).toBe(false);
      const source = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "1" });
      expect(source?.content.text).toContain("Bookmarked post evidence");
      expect(source?.content.captureDisposition).toBe("partial");
      expect(source?.content.admission?.status).toBe("pending");
      expect(observed.assessmentCalls).toBe(0);
      expect(observed.moves).toEqual([]);
    });

    it("keeps an already decided admission when a re-capture is still incomplete", async () => {
      const seen: string[] = [];
      const { store, intake } = await xFixture(seen);
      await intake("x-intake-first", 1);
      const first = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "1" });
      await store.setSourceAdmission({ commandId: "x-intake-user-retain", recordId: first!.id, expectedRevision: first!.revisionId, status: "retained", reason: "User retained provisional X evidence" });
      await intake("x-intake-second", 1);
      const second = await store.sourceByIdentity({ provider: "raindrop", accountId: "42", itemId: "1" });
      expect(second?.id).toBe(first!.id);
      expect(second?.content.admission?.status).toBe("retained");
    });
  });
});
