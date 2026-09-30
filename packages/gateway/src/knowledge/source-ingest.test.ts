import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { InMemoryConnectorCredentialStore } from "../../test-support/connector-credentials.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";

const roots: string[] = [];
const command = (id: string) => `source-ingest-test-${id}`;
const response = (value: unknown): ConnectorHTTPResponse => ({ status: 200, headers: new Headers(), body: JSON.stringify(value) });
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

describe("knowledge.source.ingest", () => {
  it("ingests queued Raindrop and X items with explicit scopes and preserves a decided identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-source-ingest-")); roots.push(root);
    const store = new KnowledgeStore(new TronWorkspace(root));
    const credentials = new InMemoryConnectorCredentialStore(new Map([["connector:raindrop:test", "token"], ["connector:x:test", "token"]]));
    const extension = new KnowledgeConnectorExtension(store, { credentials, resolveHost: async () => ["93.184.216.34"], sourceFetch: async (_url, excerpt) => new Response(excerpt ?? "captured linked evidence", { headers: { "content-type": "text/plain" } }), http: async () => response({ data: [] }) });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("configure-r"), connector: "raindrop", connectionId: "raindrop-test", enabled: true, accountId: "42", scope: "7", credentialRef: "connector:raindrop:test" } });
    await extension.invoke({ operation: "knowledge.connector.configure", request: { commandId: command("configure-x"), connector: "x", connectionId: "x-test", enabled: true, accountId: "42", scope: "42", credentialRef: "connector:x:test" } });
    await store.updateConnectorState(command("queue-r"), "raindrop", state => ({ ...state!, pending: [{ id: "r1", title: "Bookmark", url: "https://example.test/bookmark", annotation: "provider note", collectionId: "7", apiPayload: JSON.stringify({ _id: "r1", created: "2025-01-02T03:04:05Z", note: "provider note" }) }] }), undefined, "raindrop-test");
    await store.updateConnectorState(command("queue-x"), "x", state => ({ ...state!, pending: [{ id: "x1", title: "Public post", url: "https://x.com/i/web/status/123", excerpt: "post evidence", apiPayload: JSON.stringify({ id: "123", text: "post evidence" }) }] }), undefined, "x-test");
    const raindrop = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("ingest-r"), connector: "raindrop", connectionId: "raindrop-test", itemId: "r1", scope: "research" } }) as any;
    expect(raindrop).toMatchObject({ scope: "research", content: { identity: { provider: "raindrop", accountId: "42", itemId: "r1" }, collectionId: "7", sourceSavedAt: "2025-01-02T03:04:05.000Z", annotations: [{ text: "provider note" }], admission: { status: "pending" }, representations: [{ kind: "provider-api" }] } });
    const repeated = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("ingest-r-again"), connector: "raindrop", connectionId: "raindrop-test", itemId: "r1", scope: "research" } }) as any;
    expect(repeated.id).toBe(raindrop.id);
    expect(repeated.revisionId).toBe(raindrop.revisionId);
    expect(repeated.scope).toBe("research");
    expect(repeated.content.admission.status).toBe("pending");
    const placement = await store.curateSource({ commandId: command("agent-placement"), operation: "placement", producer: { actor: "agent" }, item: { recordId: repeated.id, expectedRevision: repeated.revisionId, placement: { scope: "personal" } } });
    const decided = await store.setSourceAdmission({ commandId: command("decide"), recordId: raindrop.id, expectedRevision: placement.record.revisionId, status: "retained", producer: { actor: "agent" } });
    const later = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("ingest-decided"), connector: "raindrop", connectionId: "raindrop-test", itemId: "r1", scope: "research" } }) as any;
    expect(later.id).toBe(decided.record.id);
    expect(later.scope).toBe("personal");
    expect(later.content.admission).toMatchObject({ status: "retained", producer: { actor: "agent" } });
    const x = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("ingest-x"), connector: "x", connectionId: "x-test", itemId: "x1", scope: "personal" } }) as any;
    expect(x).toMatchObject({ scope: "personal", content: { identity: { provider: "x", accountId: "42", itemId: "x1" }, admission: { status: "pending" }, representations: [{ kind: "provider-api" }] } });
    const xDecision = await store.setSourceAdmission({ commandId: command("decide-x"), recordId: x.id, expectedRevision: x.revisionId, status: "retained", producer: { actor: "agent" } });
    const xAgain = await extension.invoke({ operation: "knowledge.source.ingest", request: { commandId: command("ingest-x-decided"), connector: "x", connectionId: "x-test", itemId: "x1", scope: "research" } }) as any;
    expect(xAgain).toMatchObject({ id: xDecision.record.id, scope: "personal", content: { admission: { status: "retained", producer: { actor: "agent" } } } });
    expect((await store.connectorState("raindrop", "raindrop-test"))?.pending).toHaveLength(1);
    expect((await store.connectorState("x", "x-test"))?.pending).toHaveLength(1);
  });
});
