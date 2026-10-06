import { createHash } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AuthBroker } from "./auth-broker.js";
import type { JsonValue } from "../protocol/types.js";
import { FileAuthStorageBackend } from "../../node_modules/@earendil-works/pi-coding-agent/dist/core/auth-storage.js";
import {
  createMcpAuthProvider,
  McpOAuthCredentialStore,
  signInMcpServer,
} from "../../node_modules/@earendil-works/pi-coding-agent/dist/extensions/mcp/oauth.js";
import { parseWwwAuthenticate } from "../../node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-mcp/dist/oauth/index.js";
import { waitFor } from "../../test-support/wait-for.js";

const roots: string[] = [];
const servers: Array<ReturnType<typeof createServer>> = [];
afterEach(async () => {
  for (const server of servers.splice(0)) await new Promise<void>((resolve) => server.close(() => resolve()));
  for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
});

function response(res: ServerResponse, status: number, value: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(value));
}

async function body(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

function start(server: ReturnType<typeof createServer>): Promise<number> {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") reject(new Error("fixture failed to bind loopback"));
      else resolve(address.port);
    });
  });
}

function recordedEvents() {
  const events: Array<{ clientId: string; topic: string; payload: JsonValue }> = [];
  return {
    events,
    emit: (clientId: string, topic: string, payload: JsonValue) => events.push({ clientId, topic, payload }),
  };
}

describe("MCP auth relay integration", () => {
  it("uses Pi PKCE and dynamic registration, relays its loopback callback, persists tokens, and refreshes against a local MCP HTTP fixture", async () => {
    const root = await mkdtemp(join(tmpdir(), "tron-mcp-auth-e2e-"));
    roots.push(root);
    const authFile = join(root, "mcp-auth.json");
    let origin = "";
    let authorizationQuery: URLSearchParams | undefined;
    let registrationCount = 0;
    let refreshCount = 0;
    let accessToken = "";
    const fixture = createServer(async (req, res) => {
      const url = new URL(req.url ?? "/", origin || "http://127.0.0.1");
      if (url.pathname === "/.well-known/oauth-protected-resource") {
        return response(res, 200, { resource: `${origin}/mcp`, authorization_servers: [origin] });
      }
      if (url.pathname === "/.well-known/oauth-authorization-server") {
        return response(res, 200, {
          issuer: origin,
          authorization_endpoint: `${origin}/authorize`,
          token_endpoint: `${origin}/token`,
          registration_endpoint: `${origin}/register`,
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          token_endpoint_auth_methods_supported: ["none"],
          code_challenge_methods_supported: ["S256"],
        });
      }
      if (url.pathname === "/register" && req.method === "POST") {
        registrationCount += 1;
        const registration = JSON.parse(await body(req)) as { redirect_uris?: string[] };
        expect(registration.redirect_uris?.[0]).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/callback$/);
        return response(res, 201, { client_id: "fixture-client", redirect_uris: registration.redirect_uris });
      }
      if (url.pathname === "/authorize") {
        authorizationQuery = url.searchParams;
        const redirect = new URL(url.searchParams.get("redirect_uri")!);
        redirect.searchParams.set("code", "fixture-code");
        redirect.searchParams.set("state", url.searchParams.get("state")!);
        res.writeHead(302, { location: redirect.href });
        res.end();
        return;
      }
      if (url.pathname === "/token" && req.method === "POST") {
        const tokenRequest = new URLSearchParams(await body(req));
        if (tokenRequest.get("grant_type") === "authorization_code") {
          const verifier = tokenRequest.get("code_verifier") ?? "";
          const challenge = createHash("sha256").update(verifier).digest("base64url");
          if (challenge !== authorizationQuery?.get("code_challenge")) return response(res, 400, { error: "invalid_grant" });
          accessToken = "access-one";
          return response(res, 200, { access_token: accessToken, refresh_token: "refresh-one", token_type: "Bearer", expires_in: 1 });
        }
        if (tokenRequest.get("grant_type") === "refresh_token" && tokenRequest.get("refresh_token") === "refresh-one") {
          refreshCount += 1;
          accessToken = "access-two";
          return response(res, 200, { access_token: accessToken, refresh_token: "refresh-two", token_type: "Bearer", expires_in: 3600 });
        }
        return response(res, 400, { error: "unsupported_grant_type" });
      }
      if (url.pathname === "/mcp") {
        if (req.headers.authorization !== `Bearer ${accessToken}` || accessToken !== "access-two") {
          res.writeHead(401, { "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"` });
          res.end();
          return;
        }
        return response(res, 200, { jsonrpc: "2.0", id: 1, result: { tools: ["fixture_tool"] } });
      }
      res.writeHead(404);
      res.end();
    });
    servers.push(fixture);
    const port = await start(fixture);
    origin = `http://127.0.0.1:${port}`;
    const credentials = new McpOAuthCredentialStore(new FileAuthStorageBackend(authFile), root);
    const challengeResponse = await fetch(`${origin}/mcp`);
    expect(challengeResponse.status).toBe(401);
    const challenge = parseWwwAuthenticate(challengeResponse.headers.get("www-authenticate"));
    expect(challenge.resourceMetadataUrl?.href).toBe(`${origin}/.well-known/oauth-protected-resource`);
    const recorder = recordedEvents();
    const broker = new AuthBroker({} as never, recorder.emit);
    const admission = broker.startMcp("phone-1", "device-1", "mcp-command-001", "session-1", "fixture", async (interaction, operationId) => {
      await signInMcpServer({
        serverUrl: `${origin}/mcp`,
        store: credentials.forServer(`${origin}/mcp`),
        settings: {},
        challenge,
        prompt: {
          showAuthorizationUrl: (url) => broker.openMcpAuthorizationUrl(operationId, url.href, "session-1", "fixture"),
          promptForRedirectUrl: async (signal) => {
            await new Promise<void>((resolve, reject) => signal.addEventListener("abort", () => reject(new Error("cancelled")), { once: true }));
            return undefined;
          },
        },
      });
      interaction.notify({ type: "progress", message: "MCP sign-in completed" });
    });
    await waitFor(() => recorder.events.some((event) => event.topic === "auth.event"), "the auth event");
    const authEvent = recorder.events.find((event) => event.topic === "auth.event")!.payload as Record<string, any>;
    const authorizationUrl = new URL(authEvent.event.url as string);
    expect(authorizationUrl.searchParams.get("code_challenge_method")).toBe("S256");
    expect(authEvent.target).toEqual({ kind: "mcp", sessionId: "session-1", server: "fixture" });
    const browserResponse = await fetch(authorizationUrl, { redirect: "manual" });
    const redirected = new URL(browserResponse.headers.get("location")!);
    expect(await broker.forwardCallback("device-1", admission.operationId, authEvent.callbackCapture.id, redirected.search.slice(1))).toBe(true);
    await waitFor(() => recorder.events.some((event) => event.topic === "auth.completed"), "the auth completion event");

    const persisted = JSON.parse(await readFile(authFile, "utf8")) as Record<string, any>;
    const serverState = persisted[`${origin}/mcp`];
    expect(serverState.tokens.access_token).toBe("access-one");
    expect(registrationCount).toBe(1);
    expect(authorizationQuery?.get("code_challenge_method")).toBe("S256");

    const provider = createMcpAuthProvider({
      serverUrl: `${origin}/mcp`,
      store: credentials.forServer(`${origin}/mcp`),
      settings: () => ({}),
      onChallenge: () => {},
    });
    const token = await provider.token();
    expect(token).toBe("access-two");
    expect(refreshCount).toBe(1);
    const mcpResponse = await fetch(`${origin}/mcp`, { headers: { authorization: `Bearer ${token}` } });
    expect((await mcpResponse.json()).result.tools).toEqual(["fixture_tool"]);

    const artifact = {
      scenario: "local-mcp-oauth-pkce-dynamic-registration-callback-refresh",
      target: authEvent.target,
      dynamicRegistrationCount: registrationCount,
      pkceS256Validated: true,
      callbackRelayed: true,
      tokenSavedInTemporaryAgentDirectory: serverState.tokens.access_token === "access-one",
      refreshAfterExpiry: refreshCount === 1,
      mcpChallengeDiscovered: challengeResponse.status === 401 && challenge.resourceMetadataUrl?.href === `${origin}/.well-known/oauth-protected-resource`,
      mcpHttpAuthorized: mcpResponse.ok,
    };
    await mkdir(join(process.cwd(), "test-results"), { recursive: true });
    await writeFile(join(process.cwd(), "test-results", "mcp-auth-relay.json"), `${JSON.stringify(artifact, null, 2)}\n`);
    await writeFile(join(root, "mcp-auth.json"), JSON.stringify(persisted));
  });
});
