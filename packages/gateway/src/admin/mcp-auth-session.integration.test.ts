import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AuthBroker } from "./auth-broker.js";
import { TrustService } from "./trust-service.js";
import { RuntimeRegistry } from "../sessions/runtime-registry.js";
import { GatewayService, type GatewayServiceDependencies } from "../transport/gateway-service.js";
import { CommandReceiptStore } from "../transport/command-receipts.js";
import { DeviceStore } from "../security/device-store.js";
import { UploadStore } from "../machine/upload-store.js";
import type { JsonValue } from "../protocol/types.js";
import { waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
const servers: Array<ReturnType<typeof createServer>> = [];
const registries: RuntimeRegistry[] = [];
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(registries.splice(0).map((registry) => registry.dispose()));
  for (const server of servers.splice(0)) await new Promise<void>((resolve) => server.close(() => resolve()));
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

function reply(res: ServerResponse, status: number, payload: unknown): void {
  res.writeHead(status, { "content-type": "application/json", "mcp-session-id": "fixture-session", "mcp-protocol-version": "2025-03-26" });
  res.end(JSON.stringify(payload));
}
async function requestBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}
const client = {
  id: "phone", identity: "device:mcp-auth-test", isLocal: true,
  beginSynchronization: () => "sync", establishSynchronization: () => {}, completeSynchronization: () => {},
  setPresentationVisibility: () => ({ visible: true, revision: 0 }), unsubscribe: () => true,
  attachTerminal: () => {}, detachTerminal: () => {}, ownsTerminal: () => false,
  isSubscribed: () => true, isRevoked: () => false, revokeDevice: () => {},
} as any;

describe("MCP auth through a live Gateway session", () => {
  it("relays OAuth from the MCP RPC, stores the token in the agent dir, then invokes the direct MCP tool next turn", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-auth-session-")); roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    let origin = "", authQuery: URLSearchParams | undefined, token = "", toolCalls = 0, registrationCount = 0, refreshCount = 0;
    const requests: string[] = [], rpcMethods: string[] = [];
    // The challenge names its own resource-metadata URL, and the well-known root
    // is not served. Sign-in succeeding would NOT prove the header was read --
    // pi-mcp falls back to the server origin as the authorization server, which
    // this fixture serves -- so the proof is the request log below: the only way
    // to learn the challenge path is the header.
    const challengePath = "/challenge/resource-metadata";
    const fixture = createServer(async (req, res) => {
      const url = new URL(req.url ?? "/", origin || "http://127.0.0.1");
      requests.push(`${req.method} ${url.pathname}`);
      if (url.pathname === "/.well-known/oauth-protected-resource") { res.writeHead(404); res.end(); return; }
      if (url.pathname === challengePath) return reply(res, 200, { resource: `${origin}/mcp`, authorization_servers: [origin] });
      if (url.pathname === "/.well-known/oauth-authorization-server") return reply(res, 200, {
        issuer: origin, authorization_endpoint: `${origin}/authorize`, token_endpoint: `${origin}/token`, registration_endpoint: `${origin}/register`,
        response_types_supported: ["code"], grant_types_supported: ["authorization_code", "refresh_token"], token_endpoint_auth_methods_supported: ["none"], code_challenge_methods_supported: ["S256"],
      });
      if (url.pathname === "/register") {
        registrationCount += 1;
        const registration = JSON.parse(await requestBody(req)) as { redirect_uris?: string[] };
        if (!registration.redirect_uris?.[0]?.match(/^http:\/\/127\.0\.0\.1:\d+\/callback$/)) return reply(res, 400, { error: "invalid_redirect_uri" });
        return reply(res, 201, { client_id: "fixture-client", redirect_uris: registration.redirect_uris });
      }
      if (url.pathname === "/authorize") {
        authQuery = url.searchParams;
        const callback = new URL(url.searchParams.get("redirect_uri")!);
        callback.searchParams.set("code", "fixture-code"); callback.searchParams.set("state", url.searchParams.get("state")!);
        res.writeHead(302, { location: callback.href }); res.end(); return;
      }
      if (url.pathname === "/token") {
        const form = new URLSearchParams(await requestBody(req));
        if (form.get("grant_type") === "refresh_token") {
          if (form.get("refresh_token") !== "fixture-refresh-token") return reply(res, 400, { error: "invalid_grant" });
          refreshCount += 1; token = "fixture-refreshed-token";
          return reply(res, 200, { access_token: token, token_type: "Bearer", refresh_token: "fixture-refresh-token", expires_in: 3600 });
        }
        const challenge = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
        if (form.get("grant_type") !== "authorization_code" || challenge !== authQuery?.get("code_challenge")) return reply(res, 400, { error: "invalid_grant" });
        token = "fixture-access-token";
        // One second: Pi refreshes a token this close to expiry, so the turn after sign-in
        // exercises the refresh path on the credential the sign-in itself persisted.
        return reply(res, 200, { access_token: token, token_type: "Bearer", refresh_token: "fixture-refresh-token", expires_in: 1 });
      }
      if (url.pathname === "/mcp") {
        if (req.headers.authorization !== `Bearer ${token}` || !token) {
          res.writeHead(401, { "www-authenticate": `Bearer resource_metadata="${origin}${challengePath}"` }); res.end(); return;
        }
        if (req.method !== "POST") { res.writeHead(405); res.end(); return; }
        const rpc = JSON.parse(await requestBody(req)) as { id: number; method: string; params?: any };
        rpcMethods.push(rpc.method);
        if (rpc.method === "initialize") return reply(res, 200, { jsonrpc: "2.0", id: rpc.id, result: { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } } });
        if (rpc.method === "notifications/initialized") { res.writeHead(202); res.end(); return; }
        if (rpc.method === "tools/list") return reply(res, 200, { jsonrpc: "2.0", id: rpc.id, result: { tools: [{ name: "fixture_tool", description: "fixture", inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } }] } });
        if (rpc.method === "tools/call") { toolCalls += 1; return reply(res, 200, { jsonrpc: "2.0", id: rpc.id, result: { content: [{ type: "text", text: `worked:${rpc.params.arguments.value}` }] } }); }
        return reply(res, 404, {});
      }
      res.writeHead(404); res.end();
    });
    servers.push(fixture);
    await new Promise<void>((resolve) => fixture.listen(0, "127.0.0.1", resolve));
    const address = fixture.address(); if (!address || typeof address === "string") throw new Error("fixture bind failed");
    origin = `http://127.0.0.1:${address.port}`;
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: `${origin}/mcp`, exposure: "direct" } } }));
    vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);

    const faux = fauxProvider({ provider: "mcp-auth-session", tokensPerSecond: 100_000 });
    const events: Array<{ topic: string; payload: JsonValue }> = [];
    const emit = (_client: string, topic: string, payload: JsonValue) => events.push({ topic, payload });
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
    runtime.registerNativeProvider(faux.provider);
    const authLog: unknown[] = [];
    const auth = new AuthBroker(runtime, emit, () => {}, { log: (...entry) => authLog.push(entry) as any });
    const registry = new RuntimeRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust: new TrustService(agentDir),
      modelRuntimeFactory: async () => runtime,
      mcpAuth: { openUrl: (operationId, url, targetSession, server) => auth.openMcpAuthorizationUrl(operationId, url, targetSession, server) },
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry); await registry.initialize();
    const slot = await registry.create(cwd);
    const model = faux.getModel(); await slot.setModel(model.provider, model.id);
    const devices = new DeviceStore(join(root, "gateway"), "machine"); await devices.initialize();
    const service = new GatewayService({ config: { tronHome: root }, sessions: registry, devices, auth,
      receipts: new CommandReceiptStore(root), uploads: new UploadStore(root, 1024), broadcast: () => {},
      requestRestart: () => {}, sessionDeleted: () => {},
    } as unknown as GatewayServiceDependencies);
    await waitFor(() => requests.includes("POST /mcp"), "the MCP POST request");
    await new Promise((resolve) => setTimeout(resolve, 500));
    await expect(service.invoke(client, "mcp.token.set", {
      commandId: "mcp-token-invalid-1", scope: "global", server: "invalid/name", token: "secret", unexpected: true,
    })).rejects.toMatchObject({ code: "invalid_request" });
    await expect(service.invoke(client, "mcp.token.set", {
      commandId: "mcp-token-invalid-2", scope: "global", server: "invalid/name", token: "secret",
    })).rejects.toMatchObject({ code: "invalid_request" });
    const sessionId = slot.id;
    expect(slot.hasBuiltinMcpCommand()).toBe(true);
    const admittedBuiltinCommand = slot.hasBuiltinMcpCommand.bind(slot);
    slot.hasBuiltinMcpCommand = () => false;
    const transcriptBeforeRejectedAuth = slot.snapshot().transcript;
    await expect(service.invoke(client, "mcp.auth.start", { sessionId, server: "fixture", commandId: "mcp-auth-command-rejected" }))
      .rejects.toMatchObject({ code: "unsupported" });
    expect(slot.snapshot().transcript).toEqual(transcriptBeforeRejectedAuth);
    expect(auth.activeOperationCount).toBe(0);
    slot.hasBuiltinMcpCommand = admittedBuiltinCommand;
    faux.setResponses([async () => fauxAssistantMessage("login command handled")]);
    await service.invoke(client, "mcp.auth.start", { sessionId, server: "fixture", commandId: "mcp-auth-command-001" });
    await waitFor(() => events.some((event) => event.topic === "auth.event" && (event.payload as any).event?.type === "auth_url"), "the auth URL event").catch((error) => { throw new Error(`no auth URL event; events=${JSON.stringify(events)} authLog=${JSON.stringify(authLog)} active=${auth.activeOperationCount} requests=${JSON.stringify(requests)}`, { cause: error }); });
    const authEvent = events.find((event) => event.topic === "auth.event" && (event.payload as any).event?.type === "auth_url")!.payload as any;
    expect(authEvent.target).toEqual({ kind: "mcp", sessionId, server: "fixture" });
    expect(authEvent.event.type).toBe("auth_url");
    const authorized = await fetch(authEvent.event.url, { redirect: "manual" });
    const callback = new URL(authorized.headers.get("location")!);
    const callbackResult = await service.invoke(client, "auth.callback", {
      operationId: authEvent.operationId, callbackId: authEvent.callbackCapture.id, query: callback.search.slice(1),
    }) as any;
    expect(callbackResult.forwarded).toBe(true);
    await waitFor(() => events.some((event) => event.topic === "auth.completed"), "the completed MCP authentication event").catch((error) => { throw new Error(`no completion; events=${JSON.stringify(events)} authLog=${JSON.stringify(authLog)} requests=${JSON.stringify(requests)} methods=${JSON.stringify(rpcMethods)}`, { cause: error }); });
    expect((events.find((event) => event.topic === "auth.completed")!.payload as any).success).toBe(true);
    expect(requests).toContain(`GET ${challengePath}`);
    expect(requests).not.toContain("GET /.well-known/oauth-protected-resource");
    const persisted = JSON.parse(await readFile(join(agentDir, "mcp-auth.json"), "utf8"));
    expect(Object.keys(persisted)).toEqual([`${origin}/mcp`]);
    expect(registrationCount).toBe(1);
    expect(authQuery?.get("code_challenge_method")).toBe("S256");
    // The fixture expires the sign-in token in one second, so Pi refreshes it and
    // persists the rotation before the session's next turn.
    expect(persisted[`${origin}/mcp`].tokens.access_token).toBe("fixture-refreshed-token");
    expect(refreshCount).toBe(1);

    faux.setResponses([
      fauxAssistantMessage([fauxToolCall("mcp__fixture__fixture_tool", { value: "next-turn" }, { id: "mcp-after-signin" })], { stopReason: "toolUse" }),
      fauxAssistantMessage("tool succeeded"),
    ]);
    await slot.prompt("Use the fixture tool");
    await waitFor(() => !slot.isBusy, "the MCP turn after sign-in to settle").catch((error) => { throw new Error(`turn stayed busy; requests=${JSON.stringify(requests)} calls=${toolCalls}`, { cause: error }); });
    expect(toolCalls).toBeGreaterThan(0);
    const toolResult = slot.snapshot().transcript.find((entry: any) => entry.kind === "message" && entry.role === "toolResult" && entry.toolCallId === "mcp-after-signin") as any;
    expect(toolResult?.content?.map((block: any) => block.type === "text" ? block.text : "").join("\\n")).toContain("worked:next-turn");
    expect(events.filter((event) => event.topic === "auth.event" && (event.payload as any).event?.type === "auth_url")).toHaveLength(1);
    const afterTurn = JSON.parse(await readFile(join(agentDir, "mcp-auth.json"), "utf8"));
    expect(afterTurn[`${origin}/mcp`].tokens.access_token).toBe("fixture-refreshed-token");
    expect(refreshCount).toBe(1);
    const toolOutput = toolResult?.content?.map((block: any) => block.type === "text" ? block.text : "").join("\\n") ?? "";
    const artifact = { rpcStarted: true, authTarget: authEvent.target, authUrlRelayed: true, callbackForwarded: callbackResult.forwarded,
      authCompleted: true, pkceS256: authQuery?.get("code_challenge_method") === "S256", dynamicRegistrationCount: registrationCount,
      challengeResourceMetadataUsed: requests.includes(`GET ${challengePath}`) && !requests.includes("GET /.well-known/oauth-protected-resource"),
      tokenPersistedInAgentDir: true, tokenRefreshedAfterExpiry: refreshCount === 1,
      directToolCallSucceeded: toolOutput.includes("worked:next-turn"), toolCallRequests: toolCalls, fauxProviderTurns: 2 };
    const artifactPath = join(process.cwd(), "test-results", "pi-sdk-099-mcp-signin-session.json");
    await mkdir(join(process.cwd(), "test-results"), { recursive: true });
    await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`);
  }, 45_000);

  it("fails closed when chat invokes /mcp login without a Tron operation", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-login-unowned-")); roots.push(root);
    const agentDir = join(root, "agent"), cwd = join(root, "workspace");
    await Promise.all([mkdir(agentDir, { recursive: true }), mkdir(cwd, { recursive: true })]);
    await writeFile(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { fixture: { url: "http://127.0.0.1:1/mcp", exposure: "direct" } } }));
    vi.stubEnv("PI_CODING_AGENT_DIR", agentDir);
    const faux = fauxProvider({ provider: "mcp-unowned-login", tokensPerSecond: 100_000 });
    let browserOpenCount = 0;
    const authEvents: Array<{ topic: string; payload: JsonValue }> = [];
    const runtime = await ModelRuntime.create({ modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
    runtime.registerNativeProvider(faux.provider);
    const auth = new AuthBroker(runtime, (_client, topic, payload) => authEvents.push({ topic, payload }));
    const registry = new RuntimeRegistry({ agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust: new TrustService(agentDir),
      modelRuntimeFactory: async () => runtime,
      mcpAuth: { openUrl: (operationId, url, targetSession, server) => { browserOpenCount += 1; auth.openMcpAuthorizationUrl(operationId, url, targetSession, server); } }, broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    registries.push(registry); await registry.initialize();
    const slot = await registry.create(cwd), model = faux.getModel(); await slot.setModel(model.provider, model.id);
    faux.setResponses([async () => fauxAssistantMessage("Done")]);
    await slot.prompt("/mcp login fixture");
    await waitFor(() => !slot.isBusy, "the slot to go idle");
    expect(browserOpenCount).toBe(0);
    expect(authEvents.filter((event) => event.topic === "auth.event" && (event.payload as any).event?.type === "auth_url")).toHaveLength(0);
  });
});
