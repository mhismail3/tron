import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse, type KnowledgeConnectorOptions } from "./connectors.js";
import type { SourceAssessmentModel } from "./source-capture.js";
import { jevInputDigest, jevProfileVersion } from "./jev-assessment.js";

const roots: string[] = [];
const workspaces: TronWorkspace[] = [];
afterEach(async () => {
  await Promise.all(workspaces.splice(0).map(workspace => workspace.dispose()));
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});
const response = (value: unknown, status = 200): ConnectorHTTPResponse => ({ status, headers: new Headers(), body: JSON.stringify(value) });
const command = (name: string) => `multipage-intake-${name}`;

describe("Raindrop intake pagination and cohort accounting", () => {
  // Every item is incomplete, so bounded recovery must cross multiple provider pages.
  it.each([{ total: 51, incomplete: 51, cohorts: 5 }])("discovers shifted pages and recovers with $incomplete incomplete heads among $total items", async ({ total, incomplete, cohorts }) => {
    const root = await mkdtemp(join(tmpdir(), "tron-intake-multipage-")); roots.push(root);
    let workspace = new TronWorkspace(root); workspaces.push(workspace);
    let store = new KnowledgeStore(workspace);
    const remote = new Map(Array.from({ length: total }, (_, index) => [String(index + 1), "111"]));
    const moved: string[] = []; const requestedPages: number[] = []; let failedMove = false;
    const assessment: SourceAssessmentModel = { async assess(input, _signal, context) {
      await context?.beforeDispatch?.();
      const interests: string[] = [];
      return { summary: "synthetic assessment", evidenceQuality: "high", freshness: "current", model: "jev-1.13.0", recommendation: "retained" as const, profileVersion: jevProfileVersion(interests), rubricVersion: "tron-source-rubric-v2", inputDigest: jevInputDigest(input, interests) };
    } };
    const options: KnowledgeConnectorOptions = {
      credentials: new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:synthetic", "synthetic-only"]])),
      assessment,
      resolveHost: async () => ["93.184.216.34"],
      sourceFetch: async url => {
        const id = new URL(url).pathname.split("/").at(-1);
        return new Response(Number(id) <= incomplete ? "" : `complete evidence ${id}`, { headers: { "content-type": "text/plain", ...(Number(id) <= incomplete ? { "x-tron-source-capture-quality": "partial" } : {}) } });
      },
      sleep: async () => {},
      now: () => "2026-01-01T00:00:00.000Z",
      http: async (url, init) => {
        if (url.endsWith("/user")) return response({ user: { _id: 42 } });
        const list = new URL(url).pathname.match(/\/raindrops\/(\d+)$/);
        if (list) {
          const page = Number(new URL(url).searchParams.get("page") ?? "0");
          requestedPages.push(page);
          const ids = [...remote].filter(([, collection]) => collection === list[1]).slice(page * 50, page * 50 + 50);
          return response({ items: ids.map(([id, collection]) => ({ _id: Number(id), title: `Source ${id}`, link: `https://example.test/${id}`, collection: { $id: Number(collection) } })) });
        }
        const id = new URL(url).pathname.match(/\/raindrop\/(\d+)$/)?.[1];
        if (!id) throw new Error(`unexpected endpoint ${url}`);
        if (init.method === "PUT") {
          moved.push(id); remote.set(id, "900");
          if (id === String(incomplete + 1) && !failedMove) { failedMove = true; return response({ error: "effect-before-response" }, 500); }
        }
        return response({ item: { _id: Number(id), collection: { $id: Number(remote.get(id)) } } });
      },
    };
    let extension = new KnowledgeConnectorExtension(store, options);
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("configure"), connector: "raindrop", enabled: true, accountId: "42", scope: "111", destination: "900", allowWrites: true, credentialRef: "connector:raindrop:synthetic" } });
    const intake = (id: string, pilot: string) => extension.invoke({ operation: "knowledge.raindrop.intake", request: { commandId: command(id), sourceCollection: "111", dryRun: false, limit: 10, pilot: { id: pilot, maxItems: 10, budgetCents: 10 } } });
    async function completeCohort(commandId: string, cohort: string, expectedMoves: number): Promise<void> {
      const first = await intake(commandId, cohort);
      const pending = (await store.connectorState("raindrop"))?.pendingRemote;
      if (pending) {
        expect(pending.itemId).toBe(String(incomplete + 1));
        expect(moved).toEqual([String(incomplete + 1)]);
        // Reload both persisted store and connector, not just the connector
        // wrapper, to prove the receipt survives owner recreation.
        await workspace.dispose();
        workspace = new TronWorkspace(root); workspaces.push(workspace);
        store = new KnowledgeStore(workspace);
        extension = new KnowledgeConnectorExtension(store, options);
        const resumed = await intake(`${commandId}-resumed`, cohort);
        expect(resumed).toMatchObject({ moved: expectedMoves });
      } else expect(first).toMatchObject({ moved: expectedMoves });
    }
    await completeCohort("first", "pilot", Math.max(0, 10 - incomplete));

    for (let cohort = 1; cohort <= cohorts; cohort += 1) {
      const id = `cohort-${cohort}`;
      await extension.invoke({ operation: "knowledge.connector.assessment.approve", request: { commandId: command(`approve-${cohort}`), connector: "raindrop", id, maxItems: 10, budgetCents: 10 } });
      const firstId = cohort * 10 + 1;
      const lastId = Math.min(total, firstId + 9);
      await completeCohort(id, id, Math.max(0, lastId - Math.max(incomplete, firstId - 1)));
    }
    const state = await store.connectorState("raindrop");
    const selected = Math.min(total, 10 + cohorts * 10);
    const discovered = Math.min(total, 10 + (cohorts + 1) * 10);
    const expectedPending = [
      ...Array.from({ length: Math.min(incomplete, discovered) }, (_, index) => String(index + 1)),
      ...Array.from({ length: Math.max(0, discovered - Math.max(selected, incomplete)) }, (_, index) => String(Math.max(selected, incomplete) + index + 1)),
    ];
    expect(state?.pending.map(item => item.id)).toEqual(expectedPending);
    expect(state?.pendingRemote).toBeUndefined();
    const completeIds = Array.from({ length: Math.max(0, selected - incomplete) }, (_, index) => String(incomplete + index + 1));
    expect(moved).toEqual(completeIds);
    expect(Object.keys(state?.assessmentAttempts ?? {})).toHaveLength(completeIds.length);
    expect(state?.assessmentApprovals?.reduce((sum, item) => sum + item.itemIds.length, 0) ?? 0).toBe(selected - 10);
    expect(requestedPages).toContain(0);
    if (total > 50) expect(requestedPages).toContain(1);
  }, 30_000);
});
