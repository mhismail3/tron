import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ConnectionOwner } from "../integrations/connection-owner.js";
import { KnowledgeStore } from "./knowledge-store.js";
import { TronWorkspace } from "../workspace/tron-workspace.js";
import { KnowledgeConnectorExtension, type ConnectorHTTPResponse } from "./connectors.js";
import type { ConnectorCredentialStore } from "./connector-credentials.js";

const roots: string[] = [];
afterEach(async () => { vi.useRealTimers(); await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
const response = (value: unknown, status = 200): ConnectorHTTPResponse => ({ status, headers: new Headers(), body: JSON.stringify(value) });
const policy = { enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 100, recurringApproved: false };

describe("X OAuth connection", () => {
  it("binds a PKCE authorization to its setup and stores rotated credentials before authenticated requests", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = {
      async read(reference: string) { return credentials.get(reference); },
      async write(reference: string, value: string) { credentials.set(reference, value); },
      async delete(reference: string) { credentials.delete(reference); },
    } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    const calls: string[] = [];
    let expectedChallenge = "";
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: credentialStore,
      connections: owner,
      http: async (url, init) => {
        calls.push(url);
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") {
          const form = new URLSearchParams(init.body);
          expect(form.get("client_id")).toBe("public-client-id");
          expect(form.get("grant_type")).toBe("authorization_code");
          expect(["one-time-code", "reconnect-code"]).toContain(form.get("code"));
          expect(createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url")).toBe(expectedChallenge);
          return response({ token_type: "bearer", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7_200 });
        }
        if (url === "https://api.x.com/2/users/me?user.fields=id,username" && init.headers.authorization === "Bearer access-1") return response({ data: { id: "98765", username: "reader" } });
        if (url === "https://api.x.com/2/usage/credits" && init.headers.authorization === "Bearer access-1") return response({ data: { free_balance: 0.2, prepaid_balance: 0.1, total_balance: 0.3 } });
        throw new Error(`Unexpected X OAuth request ${url}`);
      },
    });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "oauth-start-0001", instanceId: "x-reader", clientId: "public-client-id", redirectUri: "https://app.example/callback", policy } } as any) as any;
    const authorization = new URL(started.authorizationUrl);
    expect(authorization.origin + authorization.pathname).toBe("https://twitter.com/i/oauth2/authorize");
    expect(authorization.searchParams.get("response_type")).toBe("code");
    expect(authorization.searchParams.get("code_challenge_method")).toBe("S256");
    expectedChallenge = authorization.searchParams.get("code_challenge")!;
    expect(authorization.searchParams.get("scope")).toBe("tweet.read users.read bookmark.read offline.access");
    const callback = new URL("https://app.example/callback"); callback.searchParams.set("code", "one-time-code"); callback.searchParams.set("state", started.state);
    const completed = await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "oauth-complete-0001", operationId: started.operationId, callbackUrl: callback.toString() } } as any) as any;
    expect(completed).toMatchObject({ id: "x-reader", providerAccountId: "98765", setupRevision: 1 });
    const saved = JSON.parse(credentials.get("connector:x:x-reader")!);
    expect(saved).toMatchObject({ accessToken: "access-1", refreshToken: "refresh-1" });
    expect(JSON.stringify(await owner.snapshot())).not.toContain("access-1");
    const credits = await extension.invoke({ operation: "knowledge.x.credits", request: { connectionId: "x-reader" } } as any) as any;
    expect(credits).toEqual({ freeBalance: 0.2, prepaidBalance: 0.1, totalBalance: 0.3 });
    expect(calls).toEqual(["https://api.x.com/2/oauth2/token", "https://api.x.com/2/users/me?user.fields=id,username", "https://api.x.com/2/usage/credits"]);
    await store.updateConnectorState("reconnect-progress", "x", state => ({ ...state!, pending: [{ id: "pending", title: "Bookmark", url: "https://example.test" }], capturedIds: ["captured"], checkpoints: { "98765": "cursor" }, paidBudgetCents: 17 }), undefined, "x-reader");
    await owner.execute({ kind: "disconnect", commandId: "oauth-reconnect-disconnect", instanceId: "x-reader" });
    const reconnect = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "oauth-reconnect-start", instanceId: "x-reader", clientId: "public-client-id", redirectUri: "https://app.example/callback", policy } } as any) as any;
    expectedChallenge = new URL(reconnect.authorizationUrl).searchParams.get("code_challenge")!;
    const reconnectCallback = new URL("https://app.example/callback"); reconnectCallback.searchParams.set("code", "reconnect-code"); reconnectCallback.searchParams.set("state", reconnect.state);
    await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "oauth-reconnect-complete", operationId: reconnect.operationId, callbackUrl: reconnectCallback.toString() } } as any);
    expect(await store.connectorState("x", "x-reader")).toMatchObject({ pending: [{ id: "pending" }], capturedIds: ["captured"], checkpoints: { "98765": "cursor" }, paidBudgetCents: 17 });
    expect(await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "x", connectionId: "x-reader" } } as any)).toMatchObject({ capCents: 100, availableCents: 100 });
  });

  it("refreshes once after X returns 401 and persists the rotated refresh token before retry", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-refresh-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = { async read(reference: string) { return credentials.get(reference); }, async write(reference: string, value: string) { credentials.set(reference, value); }, async delete(reference: string) { credentials.delete(reference); } } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    const calls: string[] = [];
    let bookmarkAttempts = 0;
    const extension = new KnowledgeConnectorExtension(new KnowledgeStore(new TronWorkspace(root)), {
      credentials: credentialStore, connections: owner, sleep: async () => {},
      http: async (url, init) => {
        calls.push(url);
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") {
          const form = new URLSearchParams(init.body);
          return response(form.get("grant_type") === "refresh_token" ? { token_type: "bearer", access_token: "access-2", refresh_token: "refresh-2", expires_in: 7_200 } : { token_type: "bearer", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7_200 });
        }
        if (url.startsWith("https://api.x.com/2/users/me")) return response({ data: { id: "98765", username: "reader" } });
        if (url.startsWith("https://api.x.com/2/users/98765/bookmarks")) {
          bookmarkAttempts += 1;
          if (bookmarkAttempts === 1) return response({ errors: [{ title: "Unauthorized" }] }, 401);
          expect(JSON.parse(credentials.get("connector:x:x-reader")!).refreshToken).toBe("refresh-2");
          expect(init.headers.authorization).toBe("Bearer access-2");
          return response({ data: [], meta: {} });
        }
        throw new Error(`Unexpected X OAuth request ${url}`);
      },
    });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "oauth-refresh-start", instanceId: "x-reader", clientId: "client", redirectUri: "https://app.example/callback", policy } } as any) as any;
    const callback = new URL("https://app.example/callback"); callback.searchParams.set("code", "code"); callback.searchParams.set("state", started.state);
    await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "oauth-refresh-complete", operationId: started.operationId, callbackUrl: callback.toString() } } as any);
    const result = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "oauth-refresh-discovery", connector: "x", connectionId: "x-reader", limit: 1 } } as any) as any;
    expect(result.discovered).toBe(0);
    expect(bookmarkAttempts).toBe(2);
    expect(JSON.parse(credentials.get("connector:x:x-reader")!).refreshToken).toBe("refresh-2");
    expect(calls.filter(url => url === "https://api.x.com/2/oauth2/token")).toHaveLength(2);
  });

  // Failure mode: the adapter fenced its auth-error write on a private copy of
  // the setup revision that went stale on every policy update, so after any
  // policy change a revoked X login never reached the Knowledge connector state.
  it("records an X auth error after a policy update when refresh is refused", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-auth-error-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = { async read(reference: string) { return credentials.get(reference); }, async write(reference: string, value: string) { credentials.set(reference, value); }, async delete(reference: string) { credentials.delete(reference); } } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: credentialStore, connections: owner, sleep: async () => {},
      http: async (url, init) => {
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") {
          const form = new URLSearchParams(init.body);
          if (form.get("grant_type") === "refresh_token") return response({ error: "invalid_grant" }, 400);
          return response({ token_type: "bearer", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7_200 });
        }
        if (url.startsWith("https://api.x.com/2/users/me")) return response({ data: { id: "98765", username: "reader" } });
        if (url.startsWith("https://api.x.com/2/users/98765/bookmarks")) return response({ errors: [{ title: "Unauthorized" }] }, 401);
        throw new Error(`Unexpected X request ${url}`);
      },
    });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "auth-error-start", instanceId: "x-reader", clientId: "client", redirectUri: "https://app.example/callback", policy } } as any) as any;
    const callback = new URL("https://app.example/callback"); callback.searchParams.set("code", "code"); callback.searchParams.set("state", started.state);
    await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "auth-error-complete", operationId: started.operationId, callbackUrl: callback.toString() } } as any);
    const live = await owner.resolveInstance("x-reader");
    await owner.execute({ kind: "policy.update", commandId: "auth-error-policy-update", instanceId: "x-reader", expectedSetupRevision: live.setupRevision, policy: { ...live.policy, paidBudgetCents: 50 } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "auth-error-discovery", connector: "x", connectionId: "x-reader", limit: 1 } } as any)).rejects.toThrow("reconnect the account");
    expect(await store.connectorState("x", "x-reader")).toMatchObject({ health: "auth-error" });
  });

  it("persists token rotation but fences the access token when setup changes during refresh", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-race-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = { async read(reference: string) { return credentials.get(reference); }, async write(reference: string, value: string) { credentials.set(reference, value); }, async delete(reference: string) { credentials.delete(reference); } } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    let bookmarkCalls = 0;
    let refreshes = 0;
    const store = new KnowledgeStore(new TronWorkspace(root));
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: credentialStore, connections: owner, sleep: async () => {},
      http: async (url, init) => {
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") {
          const form = new URLSearchParams(init.body);
          if (form.get("grant_type") === "refresh_token") {
            refreshes += 1;
            const live = await owner.resolveInstance("x-reader");
            await owner.execute({ kind: "policy.update", commandId: "refresh-race-policy-update", instanceId: "x-reader", expectedSetupRevision: live.setupRevision, policy: live.policy });
            return response({ token_type: "bearer", access_token: "access-rotated", refresh_token: "refresh-rotated", expires_in: 7_200 });
          }
          return response({ token_type: "bearer", access_token: "access-initial", refresh_token: "refresh-initial", expires_in: 60 });
        }
        if (url.startsWith("https://api.x.com/2/users/me")) return response({ data: { id: "98765", username: "reader" } });
        if (url.startsWith("https://api.x.com/2/users/98765/bookmarks")) { bookmarkCalls += 1; return response({ data: [], meta: {} }); }
        throw new Error(`Unexpected X request ${url}`);
      },
    });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "refresh-race-start", instanceId: "x-reader", clientId: "client", redirectUri: "https://app.example/callback", policy } } as any) as any;
    const callback = new URL("https://app.example/callback"); callback.searchParams.set("code", "race-code"); callback.searchParams.set("state", started.state);
    await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "refresh-race-complete", operationId: started.operationId, callbackUrl: callback.toString() } } as any);
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "refresh-race-discovery", connector: "x", connectionId: "x-reader", limit: 1 } } as any)).rejects.toThrow(/connection changed during token refresh/);
    expect(refreshes).toBe(1);
    expect(bookmarkCalls).toBe(0);
    expect(JSON.parse(credentials.get("connector:x:x-reader")!).refreshToken).toBe("refresh-rotated");
    expect((await owner.resolveInstance("x-reader")).health).toBe("setup-required");
    expect((await store.connectorState("x", "x-reader"))?.health).toBe("ready");
  });

  it("prices bookmark pages from the OAuth connection and settles the returned resource count", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-pricing-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = { async read(reference: string) { return credentials.get(reference); }, async write(reference: string, value: string) { credentials.set(reference, value); }, async delete(reference: string) { credentials.delete(reference); } } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    const store = new KnowledgeStore(new TronWorkspace(root), undefined, async id => owner.resolveInstance(id).catch(() => undefined));
    let bookmarkRequests = 0;
    let reservedAtDispatch = -1;
    const extension = new KnowledgeConnectorExtension(store, {
      credentials: credentialStore, connections: owner, sleep: async () => {},
      http: async (url, init) => {
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") return response({ token_type: "bearer", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7_200 });
        if (url.startsWith("https://api.x.com/2/users/me")) return response({ data: { id: "98765", username: "reader" } });
        if (url.startsWith("https://api.x.com/2/users/98765/bookmarks")) {
          bookmarkRequests += 1;
          const maxResults = new URL(url).searchParams.get("max_results");
          reservedAtDispatch = (await store.connectorState("x", "x-reader"))?.xDiscoveryBudget?.reservedCents ?? -1;
          return response({ data: maxResults === "1" ? [{ id: "three", text: "three" }] : [{ id: "one", text: "one" }, { id: "two", text: "two" }], meta: {} });
        }
        throw new Error(`Unexpected X request ${url}`);
      },
    });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "price-start", instanceId: "x-reader", clientId: "client", redirectUri: "https://app.example/callback", policy: { ...policy, paidBudgetCents: 10 } } } as any) as any;
    const callback = new URL("https://app.example/callback"); callback.searchParams.set("code", "price-code"); callback.searchParams.set("state", started.state);
    await extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "price-complete", operationId: started.operationId, callbackUrl: callback.toString() } } as any);
    const result = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "price-discovery", connector: "x", connectionId: "x-reader", limit: 50 } } as any) as any;
    expect(result.discovered).toBe(2);
    expect(bookmarkRequests).toBe(1);
    expect(reservedAtDispatch).toBe(5); // Reserve 50 * 0.1 cents, rounded up, before dispatch.
    expect(await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "x", connectionId: "x-reader" } } as any)).toMatchObject({ capCents: 10, spentCents: 1, reservedCents: 0, availableCents: 9 }); // Settle 2 * 0.1 cents, rounded up.
    const live = await owner.resolveInstance("x-reader");
    await owner.execute({ kind: "policy.update", commandId: "price-lower-cap", instanceId: "x-reader", expectedSetupRevision: live.setupRevision, policy: { ...live.policy, paidBudgetCents: 4 } });
    await expect(extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "price-budget-refusal", connector: "x", connectionId: "x-reader", limit: 50 } } as any)).rejects.toMatchObject({ code: "unsupported" });
    expect(bookmarkRequests).toBe(1); // A page whose 5¢ reservation does not fit sends no X request.
    const oneItem = await extension.invoke({ operation: "knowledge.connector.discover", request: { commandId: "price-small-page", connector: "x", connectionId: "x-reader", limit: 1 } } as any) as any;
    expect(oneItem.discovered).toBe(1);
    expect(bookmarkRequests).toBe(2);
    expect(await extension.invoke({ operation: "knowledge.connector.status", request: { connector: "x", connectionId: "x-reader" } } as any)).toMatchObject({ capCents: 4, spentCents: 2, reservedCents: 0, availableCents: 2 });
  });

  it("rejects a callback from another attempt without exchanging its code", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-state-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = { async read() { return undefined; }, async write() {}, async delete() {} } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    let calls = 0;
    const extension = new KnowledgeConnectorExtension(new KnowledgeStore(new TronWorkspace(root)), { credentials, connections: owner, http: async () => { calls += 1; return response({}); } });
    const started = await extension.invoke({ operation: "knowledge.x.oauth.begin", request: { commandId: "oauth-start-state", instanceId: "x-reader", clientId: "client", redirectUri: "https://app.example/callback", policy } } as any) as any;
    await expect(extension.invoke({ operation: "knowledge.x.oauth.complete", request: { commandId: "oauth-complete-state", operationId: started.operationId, callbackUrl: "https://app.example/callback?code=secret&state=wrong" } } as any)).rejects.toThrow(/state/);
    expect(calls).toBe(0);
  });
});
