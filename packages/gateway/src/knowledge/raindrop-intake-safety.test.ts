import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { jevProfileVersion } from "./jev-assessment.js";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const response = (value: unknown, status = 200): ConnectorHTTPResponse => ({ status, headers: new Headers(), body: JSON.stringify(value) });

async function fixture(options: { failFirstMove?: boolean; initialScope?: string } = {}) {
  const root = await mkdtemp(join(tmpdir(), "tron-intake-safety-")); roots.push(root);
  const store = new KnowledgeStore(new TronWorkspace(root));
  const observed = { assessmentCalls: 0, moves: [] as string[] };
  const remote = new Map([["1", options.initialScope ?? "111"], ["2", options.initialScope ?? "111"]]);
  const extension = new KnowledgeConnectorExtension(store, {
    credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:synthetic", "synthetic-only"]])),
    resolveHost: async () => ["93.184.216.34"],
    sourceFetch: async url => new Response(`Distinct complete source evidence for ${url}`, { headers: { "content-type": "text/plain" } }),
    sleep: async () => {},
    assessment: { async assess(_input, _signal, context) { await context?.beforeDispatch?.(); observed.assessmentCalls += 1; return { summary: "Synthetic classification", evidenceQuality: "none", freshness: "unknown", recommendation: "retained", model: "jev-1.13.0" }; } },
    http: async (url, init) => {
      if (url.endsWith("/user")) return response({ user: { _id: 42 } });
      const list = new URL(url).pathname.match(/\/raindrops\/(\d+)$/);
      if (list) return response({ items: [...remote].filter(([, collection]) => collection === list[1]).map(([id, collection]) => ({ _id: Number(id), title: `Source ${id}`, link: `https://example.test/${id}`, collection: { $id: Number(collection) } })) });
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
  const configure = (scope: string, commandId: string, allowWrites = false) => extension.invoke({ operation: "knowledge.connector.configure", request: { commandId, connector: "raindrop", enabled: true, accountId: "42", scope, credentialRef: "connector:raindrop:synthetic", destination: "333", allowWrites } });
  await configure(options.initialScope ?? "111", "safety-initial-config", options.failFirstMove === true);
  const intake = (commandId: string, maxItems = 2) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId, dryRun: false, limit: 2, pilot: { id: "safety-pilot", maxItems, budgetCents: 100 } } });
  return { store, observed, remote, configure, intake };
}

describe("Raindrop intake safety boundaries", () => {
  it("does not overwrite an unresolved remote receipt by moving a second item", async () => {
    const { store, observed, intake } = await fixture({ failFirstMove: true });
    await intake("safety-uncertain-run");
    expect(observed.moves).toEqual(["1"]);
    expect((await store.connectorState("raindrop"))?.pendingRemote?.itemId).toBe("1");
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
});
