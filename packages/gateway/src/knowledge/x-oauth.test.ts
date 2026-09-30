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
    const extension = new KnowledgeConnectorExtension(new KnowledgeStore(new TronWorkspace(root)), {
      credentials: credentialStore,
      connections: owner,
      xPricing: { accountId: "98765", costCentsPerAttempt: 1, maxAttempts: 3 },
      http: async (url, init) => {
        calls.push(url);
        if (url === "https://api.x.com/2/oauth2/token" && init.method === "POST") {
          const form = new URLSearchParams(init.body);
          expect(form.get("client_id")).toBe("public-client-id");
          expect(form.get("grant_type")).toBe("authorization_code");
          expect(form.get("code")).toBe("one-time-code");
          expect(createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url")).toBe(expectedChallenge);
          return response({ token_type: "bearer", access_token: "access-1", refresh_token: "refresh-1", expires_in: 7_200 });
        }
        if (url === "https://api.x.com/2/users/me?user.fields=id,username" && init.headers.authorization === "Bearer access-1") return response({ data: { id: "98765", username: "reader" } });
        if (url === "https://api.x.com/2/usage/credits" && init.headers.authorization === "Bearer access-1") return response({ data: { free_balance: 2.5, prepaid_balance: -0.5, total_balance: 2 } });
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
    expect(credits).toEqual({ freeBalance: 2.5, prepaidBalance: -0.5, totalBalance: 2 });
    expect(calls).toEqual(["https://api.x.com/2/oauth2/token", "https://api.x.com/2/users/me?user.fields=id,username", "https://api.x.com/2/usage/credits"]);
  });

  it("refreshes once after X returns 401 and persists the rotated refresh token before retry", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-x-oauth-refresh-")); roots.push(root);
    const owner = new ConnectionOwner(root);
    const credentials = new Map<string, string>();
    const credentialStore = { async read(reference: string) { return credentials.get(reference); }, async write(reference: string, value: string) { credentials.set(reference, value); }, async delete(reference: string) { credentials.delete(reference); } } as ConnectorCredentialStore & { write(reference: string, value: string): Promise<void>; delete(reference: string): Promise<void> };
    const calls: string[] = [];
    let bookmarkAttempts = 0;
    const extension = new KnowledgeConnectorExtension(new KnowledgeStore(new TronWorkspace(root)), {
      credentials: credentialStore, connections: owner, xPricing: { accountId: "98765", costCentsPerAttempt: 1, maxAttempts: 3 }, sleep: async () => {},
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
